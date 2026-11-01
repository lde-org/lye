--[[
	Method names a file declares, without its body: `function Owner:method` and
	`function Owner.method` are the fields a class gains, and a reader in another file needs their
	names before it can read a package whose source is not open.

	The scan is lexical, like the workspace's — the declaration index keeps annotations, and a
	method is not an annotation. The class each owner table declares is found the same way the
	workspace finds it: `---@class pkg.Thing` over `local Thing = {}` makes `Thing:method` a
	method of `pkg.Thing`.
]]

local lexer = require("lye-lexer")
local doc = require("lye-doc")
local types = require("lye-doc.type")

local KIND = lexer.KIND

local methods = {}

--- The class each table name declares, from the class annotations in a file.
---@param source string
---@param annotations lye.doc.Annotation[]
---@return table<string, string>
local function classOfTable(source, annotations)
	local found = {}
	for _, annotation in ipairs(annotations) do
		if annotation.tag == "class" then
			local className = (annotation.text or annotation.name or ""):match("^([^%s:<]+)")
			local rest = source:sub((annotation.stop or annotation.start) + 1)
			for line in rest:gmatch("([^\n]*)\n") do
				if not line:match("^%s*$") and not line:match("^%s*%-%-") then
					local global = line:match("^%s*([%w_%.]+)%s*=%s*{%s*}%s*$")
					local localName = line:match("^%s*local%s+([%w_%.]+)%s*=%s*{%s*}%s*$")
					if className and (global or localName) then
						found[global or localName] = className
					end
					break
				end
			end
		end
	end
	return found
end

--- The annotations written immediately above a declaration, from its own comment block.
---@param source string
---@param annotations lye.doc.Annotation[]
---@param at integer
---@return lye.doc.Annotation[]
local function blockOf(source, annotations, at)
	local block, next_ = {}, at
	for index = #annotations, 1, -1 do
		local annotation = annotations[index]
		if annotation.stop and annotation.stop < next_ then
			-- The block ends at the first line of code between it and the declaration.
			if not source:sub(annotation.stop + 1, next_ - 1):match("^%s*$") then break end
			table.insert(block, 1, annotation)
			next_ = annotation.start
		end
	end
	return block
end

--- Every method a file declares, in source order.
---@param source string
---@param annotations lye.doc.Annotation[]
---@param tokens lye.lexer.Tokens? the file's tokens, when the caller already read them
---@return lye.WorkspaceMethod[]
function methods.scan(source, annotations, tokens)
	tokens = tokens or lexer.tokenize(source)
	local arena, texts = tokens.arena, tokens.texts
	local classes = classOfTable(source, annotations)
	local found = {}
	---@param at integer
	---@return integer
	local function afterComments(at)
		while at <= tokens.count and arena[at].kind == KIND.comment do at += 1 end
		return at
	end
	for index = 1, tokens.count do
		local token = arena[index]
		if token.kind == KIND.keyword and texts[index] == "function" then
			local first = afterComments(index + 1)
			if first <= tokens.count and arena[first].kind == KIND.name then
				local parts = { texts[first] }
				local last, isMethod = first, false
				while true do
					local separator = afterComments(last + 1)
					local text = separator <= tokens.count and texts[separator]
					if text ~= "." and text ~= ":" then break end
					local nameAt = afterComments(separator + 1)
					if nameAt > tokens.count or arena[nameAt].kind ~= KIND.name then break end
					isMethod = text == ":"
					parts[#parts + 1] = texts[nameAt]
					last = nameAt
				end
				if #parts > 1 then
					local owner = table.concat(parts, ".", 1, #parts - 1)
					local name = parts[#parts]
					---@type string?
					local typeText
					---@type { name: string, type: string? }[]?
					local params
					---@type string[]?
					local returns
					for _, annotation in ipairs(blockOf(source, annotations, token.start)) do
						if annotation.tag == "type" and annotation.type then
							typeText = annotation.type
						elseif annotation.tag == "param" and annotation.name then
							params = params or {}
							params[#params + 1] = { name = annotation.name, type = annotation.type }
						elseif annotation.tag == "return" and annotation.type then
							returns = returns or {}
							for _, one in ipairs(types.splitValues(annotation.type)) do
								returns[#returns + 1] = one
							end
						end
					end
					found[#found + 1] = {
						owner = owner,
						name = name,
						start = arena[last].start,
						stop = arena[last].stop,
						isMethod = isMethod,
						class = classes[owner],
						typeText = typeText,
						params = params,
						returns = returns,
					}
				end
			end
		end
	end
	return found
end

--- The definitions' resolver, built once. A method signature written `ffi.array<T>` names a
--- builtin class, and reading it without the definitions leaves an extern the value it is checked
--- against cannot fit.
---@type fun(text: string): lye.doc.Type?
local preludeResolve

---@return fun(text: string): lye.doc.Type?
local function definitions()
	if preludeResolve then return preludeResolve end
	local ok, analyzer = pcall(require, "lye-analyzer")
	local okDefs, defs = pcall(require, "lye-defs")
	if ok and okDefs then
		preludeResolve = doc.classes.resolver(analyzer.prelude(defs))
	else
		preludeResolve = function() end
	end
	return preludeResolve
end

--- The type a method was written with: its own `---@type fun(...)`, or the `@param`/`@return`
--- block above it. A method with neither is a placeholder whose parameters and result are left to
--- the analysis that reads the file.
---@param method lye.WorkspaceMethod
---@param classes table<string, boolean|lye.doc.Type>
---@return lye.doc.Type
local function signatureOf(method, classes)
	---@param text string
	---@return lye.doc.Type?
	local function resolve(text)
		local held = classes[text]
		if type(held) == "table" then return held end
		return definitions()(text)
	end
	if method.typeText then
		local held = types.parse(method.typeText, resolve)
		if held and held.variant == "fn" then return held end
	end
	local params = {}
	local variadic
	for _, param in ipairs(method.params or {}) do
		local held = param.type and types.parse(param.type, resolve) or types.UNKNOWN_TYPE
		if param.name == "..." then
			variadic = held
		else
			params[#params + 1] = held
		end
	end
	local values
	if method.returns and #method.returns > 0 then
		values = {}
		for index, text in ipairs(method.returns) do
			values[index] = types.parse(text, resolve) or types.UNKNOWN_TYPE
		end
	end
	local fn = types.fn(params, (values and values[1]) or types.mutable(), variadic ~= nil, false, variadic)
	if values and #values > 1 then fn.values = values end
	if method.isMethod then fn.implicitSelf = true end
	return fn
end
methods.signatureOf = signatureOf

--- Give the classes a method list names as their fields. A method declared with a signature above
--- it is read as that signature; one without one is a placeholder whose parameters and result are
--- left to the analysis that reads the file, and whose name is enough for another file not to call
--- it missing.
---@param classes table<string, boolean|lye.doc.Type>
---@param found lye.WorkspaceMethod[]
function methods.add(classes, found)
	for _, method in ipairs(found) do
		local owner = method.class or method.owner
		local held = classes[owner]
		if type(held) == "table" and held.variant == "class" and held.fields[method.name] == nil then
			held.fields[method.name] = signatureOf(method, classes)
		end
	end
end

return methods
