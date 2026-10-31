--[[
	The workspace as a name index: every token and annotation of every file, kept per file and
	rebuilt only when that file's text moves.

	The declaration index answers what a file declares. This answers where a name is written — the
	other half of find-references, rename and a module-file rename. It is deliberately lexical: the
	analysis still decides what a position means, and the caller filters these occurrences against
	the symbol it resolved. A per-file record is cached by the text, so a keystroke rebuilds one
	file and not the workspace.
]]

local fs = require("fs")
local lexer = require("lye-lexer")
local doc = require("lye-doc")
local types = require("lye-doc.type")

local KIND = lexer.KIND

---@class lye.WorkspaceOccurrence
---@field name string
---@field start integer
---@field stop integer
---@field field boolean? written after `.` or `:`
---@field colon boolean? written after `:`
---@field annotation boolean? written inside an annotation
---@field typeText boolean? written in the type part of an annotation
---@field base string? the name before the `.` or `:`, when this is a field
---@field declaration boolean? the occurrence declares the name rather than reading it
---@field tag string? the annotation tag the occurrence was written inside

---@class lye.WorkspaceMethod
---@field owner string
---@field name string
---@field start integer
---@field stop integer
---@field isMethod boolean? declared with `:`, so `self` is implicit
---@field class string? the class the owner table declares, when an annotation says so

---@class lye.WorkspaceRequire
---@field value string
---@field start integer
---@field stop integer

---@class lye.WorkspaceFile
---@field uri string
---@field path string
---@field text string
---@field key string
---@field occurrences lye.WorkspaceOccurrence[]
---@field byName table<string, lye.WorkspaceOccurrence[]>
---@field methods lye.WorkspaceMethod[]
---@field requires lye.WorkspaceRequire[]
---@field classOfTable table<string, string> the class each table name declares

---@class lye.Workspace
---@field lye lye.Server
---@field cached table<string, { key: string, info: lye.WorkspaceFile }>
---@field files_ lye.WorkspaceFile[]?
---@field methods_ table<string, table<string, lye.doc.Type>>?
---@field methodsStamp integer
local Workspace = {}
Workspace.__index = Workspace

---@param uri string
---@return string
local function pathOf(uri)
	return (uri:gsub("^file://", ""))
end

---@param path string
---@return string
local function uriOf(path)
	return path:sub(1, 7) == "file://" and path or ("file://" .. path)
end

---@param text string
---@return string
local function unquote(text)
	if #text < 2 then return text end
	local quote = text:sub(1, 1)
	if (quote ~= '"' and quote ~= "'") or text:sub(-1) ~= quote then return text end
	local body = text:sub(2, -2)
	local out = {}
	local index = 1
	while index <= #body do
		local char = body:sub(index, index)
		---@cast char string
		if char ~= "\\" then
			out[#out + 1] = char
			index += 1
		else
			local nextChar = body:sub(index + 1, index + 1)
			---@cast nextChar string
			if nextChar == "n" then out[#out + 1] = "\n"; index += 2
			elseif nextChar == "t" then out[#out + 1] = "\t"; index += 2
			elseif nextChar == "r" then out[#out + 1] = "\r"; index += 2
			elseif nextChar == "a" then out[#out + 1] = "\a"; index += 2
			elseif nextChar == "b" then out[#out + 1] = "\b"; index += 2
			elseif nextChar == "f" then out[#out + 1] = "\f"; index += 2
			elseif nextChar == "v" then out[#out + 1] = "\v"; index += 2
			elseif nextChar == "x" then
				local hex = body:sub(index + 2, index + 3)
				local value = tonumber(hex, 16)
				if value then out[#out + 1] = string.char(value); index += 4
				else out[#out + 1] = nextChar; index += 2 end
			elseif nextChar:match("%d") then
				---@cast nextChar string
				local digits = body:sub(index + 1, index + 3):match("^%d%d?%d?") or ""
				local value = tonumber(digits)
				if value and value <= 255 then out[#out + 1] = string.char(value); index += 1 + #digits
				else out[#out + 1] = nextChar; index += 2 end
			elseif nextChar == "z" then
				index += 2
				while (body:sub(index, index):match("%s")) do index += 1 end
			else
				out[#out + 1] = nextChar
				index += 2
			end
		end
	end
	return table.concat(out)
end

--- The name chain ending at `index`, read backwards over `.` and `:` separators. The owner is
--- every part but the last and the method is the last.
---@param tokens lye.lexer.Tokens
---@param index integer the last name token
---@return string? owner
---@return string? name
---@return integer start
---@return boolean isMethod
local function chainAt(tokens, index)
	local arena, texts = tokens.arena, tokens.texts
	local parts, start, isMethod = {}, nil, false
	local at = index
	while at >= 1 do
		if at < index then
			local separator = texts[at + 1]
			if separator == ":" then isMethod = true
			elseif separator ~= "." then break end
		end
		if arena[at].kind ~= KIND.name then break end
		table.insert(parts, 1, texts[at])
		start = arena[at].start
		-- Step over the separator before this name, if there is one.
		if at >= 2 and (texts[at - 1] == "." or texts[at - 1] == ":") then at -= 2
		else break end
	end
	if #parts < 2 then return nil, nil, index, false end
	local name = parts[#parts]
	table.remove(parts)
	---@cast start integer
	return table.concat(parts, "."), name, start, isMethod
end

---@param tokens lye.lexer.Tokens
---@return lye.WorkspaceMethod[]
---@return lye.WorkspaceRequire[]
local function scanStructure(tokens)
	local arena, texts = tokens.arena, tokens.texts
	local methods = {}
	local requires = {}
	---@param occurrence lye.WorkspaceMethod
	local function addMethod(occurrence)
		-- A declaration is one place; a file that mentions the same method twice still has one
		-- declaration of it.
		for _, held in ipairs(methods) do
			if held.owner == occurrence.owner and held.name == occurrence.name
				and held.start == occurrence.start then return end
		end
		methods[#methods + 1] = occurrence
	end

	for index = 1, tokens.count do
		local kind = arena[index].kind
		local text = texts[index]
		if kind == KIND.keyword and text == "function" then
			-- `function Owner:method(`. The next name starts the chain, and the `(` ends it.
			local nextIndex = index + 1
			while nextIndex <= tokens.count and arena[nextIndex].kind == KIND.comment do nextIndex += 1 end
			if nextIndex <= tokens.count and arena[nextIndex].kind == KIND.name then
				local last = nextIndex
				while last <= tokens.count do
					local after = last + 1
					while after <= tokens.count and arena[after].kind == KIND.comment do after += 1 end
					if after <= tokens.count and (texts[after] == "." or texts[after] == ":") then
						local nameAt = after + 1
						while nameAt <= tokens.count and arena[nameAt].kind == KIND.comment do nameAt += 1 end
						if nameAt <= tokens.count and arena[nameAt].kind == KIND.name then last = nameAt
						else break end
					else
						break
					end
				end
				local owner, name, start, isMethod = chainAt(tokens, last)
				if owner and name then
					addMethod({ owner = owner, name = name, start = start, stop = arena[last].stop, isMethod = isMethod })
				end
			end
		elseif kind == KIND.name and text ~= nil then
			-- `Owner:method = function` and `Owner.method = function`, the assignment spelling.
			local equal = index + 1
			while equal <= tokens.count and arena[equal].kind == KIND.comment do equal += 1 end
			if equal <= tokens.count and texts[equal] == "=" then
				local functionIndex = equal + 1
				while functionIndex <= tokens.count and arena[functionIndex].kind == KIND.comment do functionIndex += 1 end
				if functionIndex <= tokens.count and arena[functionIndex].kind == KIND.keyword
					and texts[functionIndex] == "function" then
					local owner, name, start, isMethod = chainAt(tokens, index)
					if owner and name then
						addMethod({ owner = owner, name = name, start = start, stop = arena[index].stop, isMethod = isMethod })
					end
				end
			end
		elseif kind == KIND.string then
			-- `require("a.b")` and `require "a.b"`: the string is the module name, and a file rename
			-- is the one caller that needs every spelling of it.
			local previous = index - 1
			while previous >= 1 and arena[previous].kind == KIND.comment do previous -= 1 end
			local isRequire = previous >= 1 and texts[previous] == "require"
			if not isRequire and previous >= 2 and texts[previous] == "(" then
				local before = previous - 1
				while before >= 1 and arena[before].kind == KIND.comment do before -= 1 end
				isRequire = before >= 1 and texts[before] == "require"
			end
			if isRequire then
				requires[#requires + 1] = {
					value = unquote(text), start = arena[index].start, stop = arena[index].stop,
				}
			end
		end
	end
	return methods, requires
end

---@param info lye.WorkspaceFile
---@param occurrence lye.WorkspaceOccurrence
local function remember(info, occurrence)
	info.occurrences[#info.occurrences + 1] = occurrence
	local list = info.byName[occurrence.name]
	if not list then
		list = {}
		info.byName[occurrence.name] = list
	end
	list[#list + 1] = occurrence
end

---@param source string
---@param tokens lye.lexer.Tokens
---@return lye.WorkspaceFile
local function read(source, tokens)
	---@type lye.WorkspaceFile
	local info = {
		uri = "", path = "", text = source, key = "",
		occurrences = {}, byName = {}, methods = {}, requires = {}, classOfTable = {},
	}
	local arena, texts = tokens.arena, tokens.texts
	local previous, previousName
	for index = 1, tokens.count do
		local token = arena[index]
		if token.kind == KIND.name then
			local text = texts[index]
			---@cast text string
			remember(info, {
				name = text, start = token.start, stop = token.stop,
				field = previous == "." or previous == ":",
				colon = previous == ":",
				base = (previous == "." or previous == ":") and previousName or nil,
				declaration = previous == "local" or previous == "const" or previous == "for",
			})
			previousName = text
		end
		if token.kind ~= KIND.comment then previous = texts[index] end
	end

	local file = doc.parse(source, tokens)
	-- The class a table declares is written above it: `---@class pkg.Thing` over `local Thing = {}`
	-- makes `function Thing:grow` a method of `pkg.Thing`, and that is the name a class type is
	-- looked up by in another file.
	for _, annotation in ipairs(file.annotations or {}) do
		if annotation.tag == "class" then
			local className = (annotation.text or annotation.name or ""):match("^([^%s:<]+)")
			local rest = source:sub(annotation.stop + 1)
			for line in rest:gmatch("([^\n]*)\n") do
				if not line:match("^%s*$") and not line:match("^%s*%-%-") then
					local global = line:match("^%s*([%w_%.]+)%s*=%s*{%s*}%s*$")
					local localName = line:match("^%s*local%s+([%w_%.]+)%s*=%s*{%s*}%s*$")
					if className and (global or localName) then
						info.classOfTable[global or localName] = className
					end
					break
				end
			end
		end
	end

	for _, annotation in ipairs(file.annotations or {}) do
		if annotation.name and annotation.nameStart then
			remember(info, {
				name = annotation.name, start = annotation.nameStart, stop = annotation.nameStop or annotation.nameStart,
				annotation = true, tag = annotation.tag,
				declaration = annotation.tag == "class" or annotation.tag == "alias"
					or annotation.tag == "enum" or annotation.tag == "field" or annotation.tag == "param",
			})
		end
		local written, from = annotation.typeText, annotation.typeStart
		if written and from then
			local at = 1
			while true do
				local first, last, word = written:find("([%a_][%w_]*)", at)
				if not first then break end
				---@cast word string
				remember(info, {
					name = word, start = from + first - 1, stop = from + last - 1,
					annotation = true, typeText = true, tag = annotation.tag,
				})
				at = last + 1
			end
		end
	end

	local methods, requires = scanStructure(tokens)
	for _, method in ipairs(methods) do
		method.class = info.classOfTable[method.owner]
	end
	info.methods, info.requires = methods, requires
	return info
end

---@param lye lye.Server
---@return lye.Workspace
function Workspace.new(lye)
	return setmetatable({ lye = lye, cached = {}, files_ = nil, methods_ = nil, methodsStamp = -1 }, Workspace)
end

--- The record for a file, rebuilt when its text or its metadata moved. A request about a document
--- the editor holds always reads that text; a request about a file on disk reuses the record until
--- its size or modification time changes.
---@param self lye.Workspace
---@param uri string
---@return lye.WorkspaceFile?
function Workspace:file(uri)
	local path = pathOf(uri)
	local document = self.lye.server.documents and self.lye.server.documents:get(uri)
	local source, key
	if document then
		source = document.text
		key = "open\0" .. source
	else
		local stat = fs.stat(path)
		if not stat then return nil end
		key = tostring(stat.size) .. "\0" .. tostring(stat.modifyTime)
		source = fs.read(path)
		if type(source) ~= "string" then return nil end
	end
	local held = self.cached[uri]
	if held and held.key == key then return held.info end
	local tokens = lexer.tokenize(source)
	local info = read(source, tokens)
	info.uri, info.path, info.key = uri, path, key
	self.cached[uri] = { key = key, info = info }
	self.files_ = nil
	return info
end

--- Every file the workspace search reaches: the declaration index's manifest, plus any open
--- document outside it. A file that cannot be read is left out rather than made an error.
---@param self lye.Workspace
---@return lye.WorkspaceFile[]
function Workspace:files()
	if self.files_ then return self.files_ end
	---@type lye.WorkspaceFile[]
	local out = {}
	---@type table<string, boolean>
	local seen = {}
	---@param uri string
	local function add(uri)
		if seen[uri] then return end
		seen[uri] = true
		local info = self:file(uri)
		---@cast info lye.WorkspaceFile
		if info then out[#out + 1] = info end
	end
	-- The open buffers first: a file the editor holds is the text every answer is about.
	if self.lye.server.documents then
		for uri in pairs(self.lye.server.documents.byUri) do add(uri) end
	end
	local roots = self.lye.server.rootPaths or { self.lye.server.rootPath }
	for _, root in ipairs(roots) do
		local index = self.lye.declarations:ensureWorkspace(root)
		if index then
			for path in pairs(index:files()) do
				---@cast path string
				add(uriOf(path))
			end
		end
	end
	self.files_ = out
	return out
end

--- Occurrences of `name`, grouped by the file they are written in. The caller decides which of
--- them mean the symbol it resolved.
---@param self lye.Workspace
---@param name string
---@return { file: lye.WorkspaceFile, occurrences: lye.WorkspaceOccurrence[] }[]
function Workspace:occurrences(name)
	local out = {}
	for _, info in ipairs(self:files()) do
		local held = info.byName[name]
		if held then out[#out + 1] = { file = info, occurrences = held } end
	end
	return out
end

--- Every method every file declares, by class name. A method declared twice keeps the first
--- spelling; the analysis that reads it has the real signature when the declaration is in the
--- document being analysed.
---@param self lye.Workspace
---@return table<string, table<string, lye.doc.Type>>
function Workspace:methods()
	local stamp = 0
	for _, held in pairs(self.cached) do
		stamp += #held.key
	end
	if self.methods_ and self.methodsStamp == stamp then return self.methods_ end
	---@type table<string, table<string, lye.doc.Type>>
	local out = {}
	for _, info in ipairs(self:files()) do
		for _, method in ipairs(info.methods) do
			local owner = method.class or method.owner
			---@type table<string, lye.doc.Type>?
			local fields = out[owner]
			if not fields then
				fields = {}
				out[owner] = fields
			end
			---@cast fields table<string, lye.doc.Type>
			if not fields[method.name] then
				-- The body is not read here, so the callable accepts any arguments and says nothing
				-- about what it returns. The analysis that declares the method replaces this with
				-- the written signature; this entry exists so a reader in another file knows the
				-- name is a field of the class rather than reporting it missing.
				local fn = types.fn({}, types.UNKNOWN_TYPE, true)
				fn.implicitSelf = method.isMethod
				fields[method.name] = fn
			end
		end
	end
	self.methods_ = out
	self.methodsStamp = stamp
	return out
end

--- Every string a `require` is handed, by file.
---@param self lye.Workspace
---@return lye.WorkspaceFile[]
function Workspace:requires()
	local out = {}
	for _, info in ipairs(self:files()) do
		if #info.requires > 0 then out[#out + 1] = info end
	end
	return out
end

--- Forget one file, because its text is about to change or it closed.
---@param self lye.Workspace
---@param uri string
function Workspace:invalidate(uri)
	self.cached[uri] = nil
	self.files_ = nil
	self.methods_ = nil
end

--- Forget every file. The declaration index moved, or the workspace root did.
---@param self lye.Workspace
function Workspace:clear()
	self.cached = {}
	self.files_ = nil
	self.methods_ = nil
end

Workspace.pathOf = pathOf
Workspace.uriOf = uriOf
Workspace.unquote = unquote

return Workspace
