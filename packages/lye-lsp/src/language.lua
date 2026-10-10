--[[
	The lye language server: wires the protocol layer to the Lua tooling.
]]

local rpc = require("lye-rpc")
local doc = require("lye-doc")
local framework = require("lye-framework")
local position = require("lye-framework.position")
local json = require("lye-json")
local definitionsIndex = require("lye-lsp.definitions")
local Parser = require("lye-parser")
local analyzer = require("lye-analyzer")
local cdef = require("lye-cdef")
local KIND = require("lye-lexer").KIND
local types = require("lye-doc.type")

local SYMBOL_KIND = { ["function"] = 12, variable = 13 }

--- The LuaJIT definitions, prepared once: they are the same for every document, and parsing
--- them per keystroke would be absurd.
local PRELUDE = analyzer.prelude(require("lye-defs"))

local TOKEN_LEGEND = {
	tokenTypes = {
		"keyword", "string", "number", "comment", "operator", "variable", "function", "parameter",
		"type", "namespace", "class", "property", "method",
	},
	tokenModifiers = { "documentation" },
}

local TOKEN_TYPE = {}
for index, name in ipairs(TOKEN_LEGEND.tokenTypes) do
	TOKEN_TYPE[name] = index - 1
end

--- Modifiers are a bitmask, one bit per legend entry, in legend order.
local TOKEN_MODIFIER = {}
for index, name in ipairs(TOKEN_LEGEND.tokenModifiers) do
	TOKEN_MODIFIER[name] = 2 ^ (index - 1)
end

--- The words that are grammar inside a type rather than the name of one.
local TYPE_KEYWORD = {
	const = true, fun = true, fn = true, async = true,
	-- The values a type can name are constants rather than names of one.
	["true"] = true, ["false"] = true, ["nil"] = true,
}

--- A conversion in a format string: `%d`, `%.2f`, `%%`, with the flags and the width a reader may
--- write between the `%` and the letter. Only strings handed to `string.format` are read for them.
local FORMAT_SPECIFIER = "^%%[-+ #0]*%d*%.?%d*[cdiouxXeEfgGqs%%]" 

--- A `---@tag` inside a comment, with the tag's own span. Whitespace is matched without
--- newlines, so a tag never counts as spanning two lines.
local DOC_TAG = "%-%-%-[ \t]*@"
local DOC_TAG_NAME = "[%a_][%w_]*"

---@class lye.Server
---@field server lye.framework.Server
---@field analysis table<string, lye.parser.Result>
---@field names table<string, lye.analyzer.Result>
local Lye = {}
Lye.__index = Lye

---@return lye.Server
function Lye.new(server)
	return setmetatable({ server = server, analysis = {}, names = {} }, Lye)
end

---@param self lye.Server
--- The modules a `require("...")` could name, in the layout the workspace uses. The listing comes
--- from `find`, because a language server has no way to read a directory in Lua.
---@param self lye.Server
---@param prefix string what has been typed inside the quotes so far
---@return { name: string, path: string }[]
function Lye:moduleNames(prefix)
	local root = self.server.rootPath
	local found, seen = {}, {}
	if root then
		local pipe = io.popen(string.format(
			"find %q -name '*.lua' -not -path '*/target/*' -not -path '*/.git/*' 2>/dev/null", root))
		if pipe then
			for path in pipe:lines() do
				local relative = path:sub(#root + 2)
				if relative ~= "" then
					local name = (relative:gsub("%.lua$", ""):gsub("/init$", ""):gsub("[/\\]", "."))
					-- The layout lde builds from: `packages/lye-doc/src/type.lua` is `lye-doc.type`.
					local pkg, rest = name:match("^packages%.([%w_%-]+)%.src%.(.+)$")
					if pkg then
						name = pkg .. "." .. rest
					elseif name:match("^src%.") then
						name = name:sub(5)
					end
					if name:sub(1, #prefix) == prefix and not seen[name] then
						seen[name] = true
						found[#found + 1] = { name = name, path = path }
					end
				end
			end
			pipe:close()
		end
	end

	-- The modules the engine ships are named the same way and are not files here, so they are
	-- listed from the definitions. A workspace module of the same name was added first and wins,
	-- which is the order `require` itself resolves in.
	for name in pairs(self:definitionIndex().modules) do
		if name:sub(1, #prefix) == prefix and not seen[name] then
			seen[name] = true
			found[#found + 1] = { name = name, detail = "LuaJIT" }
		end
	end

	table.sort(found, function(left, right) return left.name < right.name end)
	return found
end


--- The modules a `require("...")` could name, in the layout the workspace uses. The layouts
--- tried in turn: beside the root, under `src/`, and inside the package directory lde builds a
--- module from — `require("lye-doc.type")` is `packages/lye-doc/src/type.lua` there.
---@param self lye.Server
---@param name string
---@return string?
function Lye:moduleFile(name, from)
	local root = self.server.rootPath

	-- A `lye.json` beside a package or a workspace adds search paths of its own, in the shape
	-- `package.path` uses: a pattern per line with `?` where the module name goes, relative to the
	-- file that wrote it. It is asked first because it is written down: a project that says where
	-- its modules are is answered before anything is guessed.
	for _, pattern in ipairs(self:requirePaths(from)) do
		local path = pattern:gsub("%?", (name:gsub("%%.", "/")))
		local handle = io.open(path, "rb")
		if handle then
			handle:close()
			return path
		end
	end

	if root then
		local tail = (name:gsub("%.", "/"))
		local candidates = {
			root .. "/" .. tail .. ".lua",
			root .. "/" .. tail .. "/init.lua",
			root .. "/src/" .. tail .. ".lua",
		}
		local head, rest = name:match("^([%w_]+)%.(.+)$")
		if head then
			local under = (rest:gsub("%.", "/"))
			candidates[#candidates + 1] = root .. "/packages/" .. head .. "/src/" .. under .. ".lua"
			candidates[#candidates + 1] = root .. "/packages/" .. head .. "/src/" .. under .. "/init.lua"
		end

		-- What lde itself resolves against. `lde run -C <package>` puts exactly two patterns on
		-- `package.path` — `<package>/target/?.lua` and `<package>/target/?/init.lua` — and
		-- `target/` holds a link per dependency, so one rule answers `require("lye-doc.type")` (a
		-- sibling package) and `require("lye-lsp.language")` (the package's own module) alike. The
		-- names above are tried first, so a module living in `src/` is found where it is written
		-- rather than through the link `target/` makes to it.
		local owner = self:packageRoot(from)
		if owner then
			candidates[#candidates + 1] = owner .. "/target/" .. tail .. ".lua"
			candidates[#candidates + 1] = owner .. "/target/" .. tail .. "/init.lua"
		end

		for _, path in ipairs(candidates) do
			local handle = io.open(path, "rb")
			if handle then
				handle:close()
				return path
			end
		end
	end

	-- A module the engine ships is not a file in this workspace: `require("ffi")`, `require("jit")`
	-- and `require("string.buffer")` name the definitions, whose text is written to the cache for a
	-- client to open. The workspace was searched first, so a project's own module of that name
	-- shadows the builtin — which is what `require` itself does — and a document outside any
	-- workspace still resolves these, since they belong to no workspace.
	local builtin = self:definitionIndex().modules[name]
	if builtin then return builtin.path end
end

--- The directory of the lde package a document belongs to: the nearest one above it that declares
--- itself with an `lde.json`. That file is what makes the layout knowable — the package is the unit
--- lde resolves within, and everything it can `require` is linked into that package's `target/`.
---@param self lye.Server
---@param uri string?
---@return string?
function Lye:packageRoot(uri)
	local root = self.server.rootPath
	if not uri or not root then return nil end
	local path = uri:gsub("^file://", "")
	local at = path:match("^(.*)/[^/]+$")
	while at and #at >= #root do
		if self.packageRoots and self.packageRoots[at] then return self.packageRoots[at] or nil end
		local handle = io.open(at .. "/lde.json", "rb")
		if handle then
			handle:close()
			self.packageRoots = self.packageRoots or {}
			self.packageRoots[at] = at
			return at
		end
		self.packageRoots = self.packageRoots or {}
		self.packageRoots[at] = false
		at = at:match("^(.*)/[^/]+$")
	end
end

--- The search paths a document's project declares, each with `?` where the module name goes. Two
--- files are read, the package's and the workspace's, because a monorepo may have its own idea of
--- where a shared library lives and a package may have another.
---@param self lye.Server
---@param uri string?
---@return string[]
function Lye:requirePaths(uri)
	local out = {}
	local seen = {}
	local function read(dir)
		if not dir or seen[dir] then return end
		seen[dir] = true
		local handle = io.open(dir .. "/lye.json", "rb")
		if not handle then return end
		local written = handle:read("*a")
		handle:close()
		local ok, config = pcall(require("lye-json").decode, written)
		if not ok or type(config) ~= "table" then return end
		for _, pattern in ipairs(config.requirePaths or {}) do
			if type(pattern) == "string" and pattern ~= "" then
				-- A pattern is written the way `package.path` writes one; an absolute one is left
				-- alone and a relative one is read from the file that declared it.
				out[#out + 1] = pattern:sub(1, 1) == "/" and pattern or (dir .. "/" .. pattern)
			end
		end
	end
	read(self:packageRoot(uri))
	read(self.server.rootPath)
	return out
end

--- What `require("name")` is: the type the module file returns, analysed once and kept until its
--- text changes. A module that requires the file being analysed would come back around, so a name
--- already in progress answers nothing rather than recursing.
---@param self lye.Server
---@param name string
---@param from string? the document the require is written in, which is what says which package it
--- resolves within
---@return lye.doc.Type?
function Lye:moduleType(name, from)
	local path = self:moduleFile(name, from)
	if not path then return nil end
	self.modules = self.modules or {}
	self.requiring = self.requiring or {}
	if self.requiring[path] then return nil end

	local uri = "file://" .. path
	local document = self.server.documents:get(uri)
	local written
	if document then
		written = document.text
	else
		local handle = io.open(path, "rb")
		if not handle then return nil end
		written = handle:read("*a")
		handle:close()
	end

	local cached = self.modules[path]
	if cached and cached.text == written then return cached.type end

	self.requiring[path] = true
	-- The module's own `require`s resolve within *its* package: a dependency's file is a document
	-- of that package, and what it can reach is what lde linked into that package's `target/`.
	local names = analyzer.analyze(written, PRELUDE, self:declaredTypes(), function(inner)
		return self:moduleType(inner, "file://" .. path)
	end)
	self.requiring[path] = nil
	self.modules[path] = { text = written, type = names.module }
	return names.module
end

--- The type names the documents this server knows declare. An annotation may name a class another
--- file declares, which is not this file's namespace but is still not a typo.
---@return table<string, boolean>
function Lye:declaredTypes()
	local found = {}
	for _, names in pairs(self.names) do
		for _, annotation in ipairs(names.doc and names.doc.annotations or {}) do
			if (annotation.tag == "class" or annotation.tag == "alias") and annotation.name then
				found[annotation.name] = true
			end
		end
	end
	return found
end

---@return lye.parser.Result?
function Lye:analyze(uri)
	local document = self.server.documents:get(uri)
	if not document then return nil end

	-- The analyzer parses the document itself, so its result carries the tree, the scopes and the
	-- comments this needs. Parsing the same text a second time is a third of the cost of a
	-- keystroke on a large file, for the same tree.
	local names = analyzer.analyze(document.text, PRELUDE, self:declaredTypes(), function(name)
		return self:moduleType(name, uri)
	end)
	local result = names.parser
	self.analysis[uri] = result
	self.names[uri] = names
	-- Type errors from annotations belong in the same list as syntax errors.
	for _, entry in ipairs(names.diagnostics) do
		result.diagnostics[#result.diagnostics + 1] = entry
	end
	return result
end

---@param self lye.Server
---@return string?
---@return lye.framework.LineIndex?
function Lye:textOf(uri)
	local document = self.server.documents:get(uri)
	if not document then return nil end
	return document.text, document.lineIndex
end

---@param self lye.Server
---@param text string
---@param index lye.framework.LineIndex
---@param start integer
---@param stop integer
---@return table
function Lye:toRange(text, index, start, stop)
	local encoding = self.server.encoding
	local startLine, startCharacter = position.toPosition(text, index, start, encoding)
	local stopLine, stopCharacter = position.toPosition(text, index, stop + 1, encoding)

	return {
		start = { line = startLine, character = startCharacter },
		["end"] = { line = stopLine, character = stopCharacter },
	}
end

---@param self lye.Server
function Lye:publishDiagnostics(uri, result)
	local document = self.server.documents:get(uri)
	local text, index = document.text, document.lineIndex

	local diagnostics = json.array()
	for _, entry in ipairs(result.diagnostics) do
		diagnostics[#diagnostics + 1] = {
			range = self:toRange(text, index, entry.start, entry.stop),
			-- The severity the analysis gave it: a syntax error has none and is the loudest, and
			-- an unused local is a warning. Publishing everything as an error is how a warning
			-- becomes a red squiggle.
			severity = entry.severity or 1,
			source = "lye",
			message = entry.message,
		}
	end

	-- An empty set must still be published, or the client keeps showing stale markers.
	self.server:notify(framework.METHOD.publishDiagnostics, {
		uri = uri,
		diagnostics = diagnostics,
		version = document.version,
	})
end

---@return lye.lexer.ffi.token?
local function tokenAt(result, offset)
	local tokens = result.tokens.arena
	local low, high = 1, result.tokens.count
	while low <= high do
		local mid = math.floor((low + high) / 2)
		local token = tokens[mid]
		if offset < token.start then
			high = mid - 1
		elseif offset > token.stop then
			low = mid + 1
		else
			return token
		end
	end
end

---@return string? name
local function nameAt(result, offset)
	local token = tokenAt(result, offset)
	if token and token.kind == KIND.name then return result.tokens.texts[token.index], token end
end

--- The declaration a name at an offset refers to. The analyzer already resolves names
--- through the scope chain, so this asks it instead of repeating the search with looser rules:
--- two resolvers can disagree about which declaration shadows which.
---@param names lye.analyzer.Result
---@return lye.parser.Declaration?
local function declarationFor(names, offset)
	local name = nameAt(names.parser, offset)
	if not name then return nil end
	local variable = analyzer.lookupAt(names, name, offset)
	if variable then return variable.declaration end
	-- A `function t.m()` is declared under its dotted name, which no plain lookup reaches.
	local declarations = names.parser.declarations
	for index = #declarations, 1, -1 do
		local candidate = declarations[index]
		if candidate.start <= offset and candidate.name:match("([^%.:]+)$") == name then
			if candidate.qualifier == "field" or candidate.qualifier == "global" then
				return candidate
			end
		end
	end
end

---@param self lye.Server
---@return table?
function Lye:onDocumentSymbol(params)
	local uri = params.textDocument?.uri
	if not uri then return nil end

	local document = self.server.documents:get(uri)
	if not document then return nil end
	local result = self.analysis[uri] or self:analyze(uri)
	if not result then return nil end

	---@param declaration lye.parser.Declaration
	---@return table
	local function symbolOf(declaration)
		local range = self:toRange(document.text, document.lineIndex, declaration.start, declaration.stop)
		return {
			name = declaration.name,
			kind = declaration.isFunction and SYMBOL_KIND["function"] or SYMBOL_KIND.variable,
			range = range,
			selectionRange = range,
		}
	end

	-- Declarations arrive in source order with their scope depth. `enclosing[depth]` holds
	-- the last symbol seen at that depth, so a declaration one level deeper becomes its
	-- child and one at the same level becomes its sibling.
	local roots, enclosing = json.array(), {}
	for _, declaration in ipairs(result.declarations) do
		if declaration.qualifier ~= "label" then
			local depth = declaration.depth
			local symbol = symbolOf(declaration)
			local parent = enclosing[depth]

			if parent then
				parent.children = parent.children or json.array()
				parent.children[#parent.children + 1] = symbol
			else
				roots[#roots + 1] = symbol
			end

			enclosing[depth + 1] = symbol
			for deeper = depth + 2, #enclosing do enclosing[deeper] = nil end
		end
	end
	return roots
end

--- The document, its line index, the parse result and the byte offset under a cursor.
--- Every position-based feature needs exactly this, so it is resolved once.
---@param self lye.Server
---@param params table
---@return string? uri
---@return string? text
---@return lye.framework.LineIndex? index
---@return lye.parser.Result? result
---@return integer? offset
function Lye:resolvePosition(params)
	local uri = params.textDocument?.uri
	if not uri then return nil end

	local text, index = self:textOf(uri)
	if not text then return nil end
	local result = self.analysis[uri] or self:analyze(uri)
	local names = self.names[uri]
	if not result or not names then return nil end

	local offset = position.toOffset(
		text, index, params.position.line, params.position.character, self.server.encoding
	)
	return uri, text, index, names, offset
end

--- The type a value expression has, walking the suffix chain the arena recorded: a name reads its
--- variable where the cursor is, and each `.field` reads that field of what came before.
---@param result lye.analyzer.Result
---@param idx integer?
---@param offset integer
---@return lye.doc.Type?
local function typeOfExpression(result, idx, offset)
	local node = idx and result.parser.nodes[idx]
	if not node then return nil end
	if node.kind == "prefix" then
		local variable = node.callee and analyzer.lookupAt(result, node.callee, offset)
		return variable and analyzer.typeAt(result, variable, offset) or nil
	end
	if node.kind == "index" and node.target then
		local base = typeOfExpression(result, node.target, offset)
		if base and node.field then return types.indexResult(base, node.field) end
	end
	if node.kind == "call" then
		-- A generic result belongs to the call rather than to the function, so the analyzer's
		-- binding is read first and the callee's own return type is the fallback.
		local bound = result.callTypes and result.callTypes[idx]
		if bound then return bound end
		local fnType
		if node.field and node.target then
			local base = typeOfExpression(result, node.target, offset)
			fnType = base and types.indexResult(base, node.field)
		else
			local variable = node.callee and analyzer.lookupAt(result, node.callee, offset)
			fnType = variable and analyzer.typeAt(result, variable, offset)
		end
		if fnType and types.isFn(fnType) then return fnType.returns end
	end
end

--- A signature as its annotations wrote it: `print(...: any)`, `math.floor(x: number) -> number`.
--- The name is optional, since a completion item is already labelled with it, and so is the
--- signature: a caller that has none shows the type instead.
---@param signature lye.analyzer.Signature?
---@param name string?
---@return string
local function signatureText(signature, name)
	if not signature then return "" end
	local parts = {}
	for _, annotation in ipairs(signature.params) do
		local held = annotation.type or "any"
		local param = annotation.name
		parts[#parts + 1] = (param and param ~= "") and (param .. ": " .. held) or held
	end
	local returned = signature.returns and signature.returns.type
	return (name or "") .. "(" .. table.concat(parts, ", ") .. ")"
		.. (returned and (" -> " .. returned) or "")
end

--- The signature behind whatever sits at an offset: a name the definitions declare, a field read off
--- a standard library table, or a method of a class this document declares. It is how a hover finds
--- the documentation a call carries.
---@param names lye.analyzer.Result
---@param node lye.parser.Node
---@param offset integer
---@return lye.analyzer.Signature?
local function signatureFor(names, node, offset)
	local signatures = names.signatures or {}
	if node.callee and signatures[node.callee] then return signatures[node.callee] end
	-- `math.floor(...)` is a call whose callee is `math`: the field is on the node it targets, and
	-- that node carries the signature.
	if node.kind == "call" and node.target and not node.field then
		local target = names.parser.nodes[node.target]
		if target then return signatureFor(names, target, offset) end
	end
	if not node.field then return nil end

	-- A field: the type it holds is the identity the definitions recorded it under.
	local held = typeOfExpression(names, node.key or node.index, offset)
	if not held then
		local base = typeOfExpression(names, node.target, offset)
		if base then held = types.indexResult(base, node.field) end
	end
	if held and PRELUDE.fields[held] then return PRELUDE.fields[held] end

	-- A method of a class this document declares is keyed by the name it was declared under.
	local base = typeOfExpression(names, node.target, offset)
	if base and base.variant == "class" then
		return signatures[base.name .. "." .. node.field] or signatures[base.name .. ":" .. node.field]
	end
end

--- The documentation a completion item carries: the prose above the declaration it offers, from
--- the definitions or from this document.
---@param signature lye.analyzer.Signature?
---@return table?
local function documentationItem(signature)
	local doc = signature and signature.doc
	if not doc then return nil end
	return { kind = "markdown", value = doc }
end

--- What a name reads as, from the type behind it rather than from the syntax it was written
--- with: a global holding a table is a namespace, a name holding a function is a function. It is
--- what colours a reference and what picks a completion icon, so the two never disagree.
---@param names lye.analyzer.Result
---@param name string
---@param offset integer
---@return string?
local function readAsName(names, name, offset)
	local variable = analyzer.lookupAt(names, name, offset)
	if variable then
		local held = analyzer.typeAt(names, variable, offset)
		if types.isFn(held) then return "function" end
		if variable.qualifier == "global" then
			-- `math` and `string` are globals the definitions describe as classes: a reader sees
			-- a namespace, not a class they could construct.
			return held.variant == "class" and "namespace" or "variable"
		end
		if held.variant == "class" then return "class" end
		return variable.qualifier == "param" and "parameter" or "variable"
	end
	-- A function declared in the definitions has no variable in the document: `print` and
	-- `setmetatable` are known by their signature.
	if names.signatures and names.signatures[name] then return "function" end
end

--- The last byte of a value expression. A `prefix` node spans the first byte of its name — that
--- is where it starts, and the parser records nothing else — so the name's own length is what
--- says where it ends. Everything else spans what it reads.
---@param result lye.parser.Result
---@param node lye.parser.Node
---@return integer
local function valueStop(result, node)
	if node.group then return valueStop(result, result.nodes[node.group]) end
	if node.kind == "prefix" and node.callee then return node.start + #node.callee - 1 end
	return node.stop
end

--- How the value at a node is written, for a hover heading: `print`, `math.floor`, `p:add`. A call
--- node spans its arguments, so what it is called is read from the chain the arena recorded rather
--- than from the text under the cursor.
---@param result lye.analyzer.Result
---@param node lye.parser.Node
---@param source string
---@return string
local function writtenName(result, node, source)
	if node.field then
		local target = node.target and result.parser.nodes[node.target]
		return writtenName(result, target, source) .. (node.isMethod and ":" or ".") .. node.field
	end
	if node.kind == "call" and node.target then
		return writtenName(result, result.parser.nodes[node.target], source)
	end
	if node.callee then return node.callee end
	return (source:sub(node.start, valueStop(result, node)))
end

--- The expression node holding an offset, innermost first. Spans are enough: the arena already
--- says what each node is, so nothing is re-read from the text.
---@param result lye.analyzer.Result
---@param offset integer
---@return lye.parser.Node?
local function nodeAt(result, offset)
	local found
	for _, node in ipairs(result.parser.nodes) do
		local isValue = node.kind == "prefix" or node.kind == "index" or node.kind == "call"
			or node.kind == "name"
		if isValue and node.start <= offset and offset <= node.stop + 1 then
			-- The innermost: the latest start, and among those the shortest span.
			if not found or node.start > found.start
				or (node.start == found.start and node.stop < found.stop) then
				found = node
			end
		end
	end
	return found
end

--- The string inside a `require(...)` that an offset sits in, and what has been typed in it.
---@param self lye.Server
---@param uri string
---@param source string
---@param offset integer
---@return { from: integer, to: integer, typed: string }?
function Lye:requireStringAt(uri, source, offset)
	local names = self.names[uri] or (self:analyze(uri) and self.names[uri])
	local node = names and nodeAt(names, offset)
	if not node or node.kind ~= "call" or node.callee ~= "require" then return nil end
	local argument = node.args and node.args[1] and names.parser.nodes[node.args[1]]
	if not argument or argument.kind ~= "string" then return nil end
	if offset < argument.start or offset > argument.stop + 1 then return nil end
	-- The quotes are not part of the name, and the cursor may sit just past the last character.
	local contentFrom = argument.start + 1
	local contentTo = argument.stop - 1
	local typed = source:sub(contentFrom, math.min(offset, contentTo))
	return { from = contentFrom, to = contentTo, typed = typed }
end

---@param self lye.Server
---@return table?
local function wordSpan(source, offset)
	local at = offset
	if not source:sub(at, at):match("[%w_%.]") and source:sub(at - 1, at - 1):match("[%w_%.]") then
		at = at - 1
	end
	if not source:sub(at, at):match("[%w_%.]") then return nil end
	local from, to = at, at
	while from > 1 and source:sub(from - 1, from - 1):match("[%w_%.]") do from = from - 1 end
	while to < #source and source:sub(to + 1, to + 1):match("[%w_%.]") do to = to + 1 end
	return from, to
end

function Lye:onHover(params)
	local uri, text, index, result, offset = self:resolvePosition(params)
	if not uri then return nil end

	local declaration = declarationFor(result, offset)
	if declaration then
		local qualifier = declaration.qualifier == "param" and "parameter" or declaration.qualifier
		local variable = result.byStart[declaration.start]
		local shown = variable and types.display(analyzer.typeAt(result, variable, offset)) or "unknown"
		local origin = variable and variable.declared and "declared" or "inferred"
		local blocks = {
			string.format("```lua\n%s: %s\n-- %s, %s\n```", declaration.name, shown, qualifier, origin),
		}
		local signature = self.names[uri].signatures and self.names[uri].signatures[declaration.name]
		if signature and signature.doc then blocks[#blocks + 1] = signature.doc end

		return {
			contents = { kind = "markdown", value = table.concat(blocks, "\n\n") },
			-- The word being hovered, not the declaration it resolves to: a client highlights what
			-- the answer points at, and pointing at the declaration highlights another line.
			range = (function()
				local from, to = wordSpan(text, offset)
				return self:toRange(text, index, from or declaration.start, to or declaration.stop)
			end)(),
		}
	end

	-- Nothing is declared here, so the answer is what the expression holds: `math.floor` is a
	-- function of the standard library, and `first.x` is a number of the class the value is. A
	-- function is shown by the signature it was declared with, and with what was written above it,
	-- because that is what a reader of `setmetatable(...)` is asking for.
	local node = nodeAt(result, offset)
	if not node then return nil end
	local signature = signatureFor(self.names[uri], node, offset)
	local held = typeOfExpression(result, node.index, offset)
	if not signature and not held then return nil end

	local label = signature and signatureText(signature, writtenName(result, node, text))
	local blocks = {
		string.format("```lua\n%s\n```", label or types.display(held)),
	}
	if signature and signature.doc then blocks[#blocks + 1] = signature.doc end
	return {
		contents = { kind = "markdown", value = table.concat(blocks, "\n\n") },
		range = self:toRange(text, index, node.start, node.stop),
	}
end

---@param self lye.Server
---@return table?
--- The names the definitions declare, indexed once and written where a client can open them.
---@return table
function Lye:definitionIndex()
	if not self.definitions then
		self.definitions = definitionsIndex.prepare(require("lye-defs"))
	end
	return self.definitions
end

--- The name written at an offset, read from the source: an identifier, dotted if it is one.
---@param source string
---@param offset integer
---@return string?
local function writtenAt(source, offset)
	local at = offset
	if not source:sub(at, at):match("[%w_%.]") and source:sub(at - 1, at - 1):match("[%w_%.]") then
		at = at - 1
	end
	if not source:sub(at, at):match("[%w_%.]") then return nil end
	local from, to = at, at
	while from > 1 and source:sub(from - 1, from - 1):match("[%w_%.]") do from = from - 1 end
	while to < #source and source:sub(to + 1, to + 1):match("[%w_%.]") do to = to + 1 end
	return source:sub(from, to)
end

--- The name an offset sits under, when it sits inside a doc annotation rather than in code.
---@param names lye.analyzer.Result
---@param source string
---@param offset integer
---@return string?
local function nameInAnnotation(names, source, offset)
	for _, annotation in ipairs(names.doc and names.doc.annotations or {}) do
		if annotation.nameStart and offset >= annotation.nameStart and offset <= annotation.nameStop then
			-- The name the annotation declares is a declaration in its own right: `---@field call`
			-- is where the field is, and `---@class App` where the class is.
			return writtenAt(source, offset), annotation
		end
		local from, to = annotation.typeStart, annotation.typeStop
		if not from or offset < from or offset > to then
			from, to = annotation.start, annotation.stop
			if offset < from or offset > to then from = nil end
		end
		if from then return writtenAt(source, offset), nil end
	end
end

--- The span of the word an offset sits on, which is what a hover is about.
---@param source string
---@param offset integer
---@return integer? start
---@return integer? stop

--- A range in another file, resolved against that file's own text. A definition the server wrote
--- out is not an open document, so its line index is built when it is first needed.
---@param self lye.Server
---@param target lye.DefinitionLocation
---@return table
function Lye:rangeIn(target)
	local document = self.server.documents:get(target.uri)
	local text, lineIndex = document and document.text, document and document.lineIndex
	if not text then text, lineIndex = definitionsIndex.sourceOf(self:definitionIndex(), target.uri) end
	if not text or not lineIndex then
		return { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }
	end
	local line, character = position.toPosition(text, lineIndex, target.start, self.server.encoding)
	local stopLine, stopCharacter = position.toPosition(text, lineIndex, target.stop + 1, self.server.encoding)
	return {
		start = { line = line, character = character },
		["end"] = { line = stopLine, character = stopCharacter },
	}
end

--- The class or alias a name declares: in this document, in another the server has analysed, or in
--- the definitions — which is where the builtin types live.
---@param self lye.Server
---@param name string
---@param uri string
---@return lye.DefinitionLocation?
function Lye:targetOfType(name, uri)
	local function inDocument(documentUri, names)
		for _, annotation in ipairs(names and names.doc and names.doc.annotations or {}) do
			local isType = annotation.tag == "class" or annotation.tag == "alias"
			if isType and annotation.name == name then
				return {
					uri = documentUri,
					start = annotation.nameStart or annotation.start,
					stop = annotation.nameStop or annotation.stop,
				}
			end
		end
	end

	local mine = inDocument(uri, self.names[uri])
	if mine then return mine end
	for otherUri, names in pairs(self.names) do
		if otherUri ~= uri then
			local found = inDocument(otherUri, names)
			if found then return found end
		end
	end
	return definitionsIndex.find(self:definitionIndex(), name)
end

--- Where a name resolves: the declaration the parser recorded, or the definitions the server wrote
--- out, which is the only place a builtin can be found.
---@param self lye.Server
---@param uri string
---@param text string
---@param names lye.analyzer.Result
---@param offset integer
---@return lye.DefinitionLocation?
function Lye:targetAt(uri, text, names, offset)
	local written, declared = nameInAnnotation(names, text, offset)
	if written and declared then
		return { uri = uri, start = declared.nameStart, stop = declared.nameStop }
	end
	if written then
		local found = self:targetOfType(written, uri)
		if found then return found end
	end

	-- `require("a.b")` names a file: the string is a path, and the jump goes to the module.
	local required = nodeAt(names, offset)
	if required and required.kind == "call" and required.callee == "require"
		and required.args and required.args[1] then
		local argument = names.parser.nodes[required.args[1]]
		if argument and argument.kind == "string" and offset >= argument.start and offset <= argument.stop then
			local path = type(argument.value) == "string" and self:moduleFile(argument.value)
			if path then return { uri = "file://" .. path, start = 1, stop = 1 } end
		end
	end

	local declaration = declarationFor(names, offset)
	if declaration then
		return { uri = uri, start = declaration.start, stop = declaration.stop }
	end

	-- `math.floor` is declared by name in the definitions, and `Point.x` by the class it belongs
	-- to, which the receiver's own type names.
	-- `nodeAt` and `writtenName` both read the arena through the analysis result, whose `parser`
	-- field is the tree.
	local node = nodeAt(names, offset)
	if node then
		local dotted = writtenName(names, node, text)
		local found = definitionsIndex.find(self:definitionIndex(), dotted)
		if found then return found end
		if node.kind == "index" and node.field then
			local base = typeOfExpression(names, node.target, offset)
			local className = base and base.variant == "class" and base.name
			if className then
				found = definitionsIndex.find(self:definitionIndex(), className .. "." .. node.field)
				if found then return found end
			end
		end
		-- A name that is not declared here may still be a value of a type that is: `math` is the
		-- table `mathlib` describes, and the class is where a reader wants to land.
		local held = node.kind == "prefix" and node.callee
			and typeOfExpression(names, node.index, offset)
		if held and held.variant == "class" then
			local found = self:targetOfType(held.name, uri)
			if found and found.uri ~= uri then return found end
		end
	end
	return nil
end

---@param self lye.Server
---@return table?
function Lye:onDefinition(params)
	local uri, text, index, names, offset = self:resolvePosition(params)
	if not uri then return nil end

	local target = self:targetAt(uri, text, names, offset)
	if not target then return nil end
	if target.uri == uri then
		return { uri = uri, range = self:toRange(text, index, target.start, target.stop) }
	end
	return { uri = target.uri, range = self:rangeIn(target) }
end

--- The tokens of a `ffi.cdef` block, parsed once and kept: a header is small, and they are asked
--- for on every edit.
---@param self lye.Server
---@param text string
---@return { start: integer, stop: integer, kind: string }[]
function Lye:cdefSpans(text)
	local cached = self.cdefCache
	if cached and cached.text == text then return cached.spans end
	local spans = cdef.spans(cdef.parse(text))
	self.cdefCache = { text = text, spans = spans }
	return spans
end

---@param self lye.Server
---@return table
function Lye:onSemanticTokens(params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	local result = uri and (self.analysis[uri] or self:analyze(uri))
	if not document or not result then return { data = json.array() } end

	local text, index = document.text, document.lineIndex
	local encoding = self.server.encoding

	local kinds = {}
	for _, declaration in ipairs(result.declarations) do
		if declaration.qualifier ~= "label" then
			local target = declaration.isFunction and "function"
				or (declaration.qualifier == "param" and "parameter" or "variable")
			for at = declaration.start, declaration.stop do
				kinds[at] = target
			end
		end
	end

	-- Read before the emitters below: a closure that reads a local declared after it sees a
	-- global instead, which is nil and silent until it is indexed.
	local names = self.names[uri]
	local annotations = names and names.doc and names.doc.annotations or {}

	-- A name that is not a declaration is a reference, and what it reads as comes from the type
	-- behind it: `print` is a function of the definitions, `math` the table it holds, and
	-- `math.random` a function read off it. Colouring every reference as a variable is what left
	-- the whole standard library white.
	if names then
		for _, node in ipairs(result.nodes) do
			if node.kind == "prefix" and node.callee and not kinds[node.start] then
				kinds[node.start] = readAsName(names, node.callee, node.start)
			elseif node.kind == "index" and node.field and node.isDynamic ~= true then
				local fieldStart = node.stop - #node.field + 1
				if not kinds[fieldStart] then
					local base = typeOfExpression(names, node.target, node.start)
					local held = base and types.indexResult(base, node.field)
					kinds[fieldStart] = held and types.isFn(held) and "function" or "property"
				end
			end
		end
	end

	local data, count = json.array(), 0
	local lastLine, lastStart = 0, 0
	local isFirst = true

	--- Tokens are relative to the one before, and a token never spans a line. A comment or a string
	--- that does is emitted as one token per line it covers: emitting it whole is a protocol
	--- violation, and a client that clips it colours the first line and leaves the rest — which is
	--- what a multiline comment and an `ffi.cdef` block both looked like.
	---@param spanStart integer
	---@param spanStop integer
	---@param target string
	---@param modifiers integer?
	local function emitSpan(spanStart, spanStop, target, modifiers)
		if spanStop < spanStart then return end
		local from = spanStart
		while from <= spanStop do
			local newline = text:find("\n", from, true)
			local to = (newline and newline - 1 <= spanStop) and (newline - 1) or spanStop
			if to >= from then
				local line, start = position.toPosition(text, index, from, encoding)
				local stopCharacter = select(2, position.toPosition(text, index, to, encoding))
				local deltaLine = isFirst and line or (line - lastLine)
				local deltaStart = isFirst and start or (deltaLine == 0 and (start - lastStart) or start)

				count += 1
				data[count] = deltaLine
				count += 1
				data[count] = deltaStart
				count += 1
				data[count] = math.max(stopCharacter - start + 1, 1)
				count += 1
				data[count] = TOKEN_TYPE[target]
				count += 1
				data[count] = modifiers or 0

				lastLine, lastStart, isFirst = line, start, false
			end
			if not newline or newline > spanStop then break end
			from = newline + 1
		end
	end

	-- The text of an `ffi.cdef` call is C, and it is coloured from *our* parse of it rather than by
	-- asking the editor to inject a C grammar: an injection needs that grammar installed, it would
	-- not know LuaJIT's dialect even then, and a header is more useful coloured by what the names in
	-- it are — the struct a program uses reads as a class, its members as fields.
	local cdefSpans = {}
	for _, node in ipairs(result.nodes) do
		if node.kind == "call" and node.args and node.args[1] then
			local target = node.target and result.nodes[node.target]
			local field = node.field or (target and target.field)
			if field == "cdef" then
				local argument = result.nodes[node.args[1]]
				if argument and argument.kind == "string" and type(argument.value) == "string" then
					cdefSpans[argument.start] = {
						spans = self:cdefSpans(argument.value),
						from = cdef.textStart(text, argument.start, argument.stop),
					}
				end
			end
		end
	end

	-- What the parser calls a token, in the vocabulary this server advertises.
	local CDEF_KIND = {
		keyword = "keyword", type = "type", class = "class", member = "property",
		constant = "property", ["function"] = "function", number = "number", variable = "variable",
		comment = "comment",
	}

	--- A doc comment is emitted as the comment it is, with the tags, parameter names and types
	--- inside it marked out. The spans are cut at newlines because a token may not cross one.
	---@param token lye.lexer.ffi.token
	---@param written string
	local function emitComment(token, written)
		local carved, count_ = {}, 0
		---@param from integer
		---@param to integer
		---@param target string
		local function carve(from, to, target)
			if to < from or from < token.start or to > token.stop then return end
			count_ += 1
			carved[count_] = { start = from, stop = to, target = target }
		end

		local at, stop = written:find(DOC_TAG .. DOC_TAG_NAME)
		while at do
			local tagStart = token.start + at - 1
			carve(tagStart, token.start + stop - 1, "keyword")
			at, stop = written:find(DOC_TAG .. DOC_TAG_NAME, stop + 1)
		end

		-- The name of a parameter reads as a parameter, and the identifiers in a type read as a
		-- type. A string literal inside a type stays a string; the punctuation around them is
		-- grammar and stays part of the comment.
		for _, annotation in ipairs(annotations) do
			if annotation.start >= token.start and annotation.stop <= token.stop then
				if annotation.nameStart then
					-- What the name in an annotation *is*: a parameter is a parameter, a class or
					-- an alias names a type, and the name of a field is a field.
					local target = "variable"
					if annotation.tag == "param" then
						target = "parameter"
					elseif annotation.tag == "class" or annotation.tag == "alias" then
						target = "type"
					elseif annotation.tag == "field" then
						target = "property"
					end
					carve(annotation.nameStart, annotation.nameStop, target)
				end
				if annotation.typeStart then
					local typeText = text:sub(annotation.typeStart, annotation.typeStop)
					local cursor = 1
					while cursor <= #typeText do
						local quoteAt = typeText:find("['\"]", cursor)
						local nameAt = typeText:find("[%a_]", cursor)
						local numberAt = typeText:find("%d", cursor)
						local barAt = typeText:find("|", cursor, true)
						if quoteAt and (not nameAt or quoteAt < nameAt) then
							local quote = typeText:sub(quoteAt, quoteAt)
							local closeAt = typeText:find(quote, quoteAt + 1, true) or #typeText
							carve(annotation.typeStart + quoteAt - 1, annotation.typeStart + closeAt - 1, "string")
							cursor = closeAt + 1
						elseif nameAt and (not numberAt or nameAt < numberAt) and (not barAt or nameAt < barAt) then
							local _, nameStop = typeText:find("^[%a_][%w_%.]*", nameAt)
							local word = typeText:sub(nameAt, nameStop)
							-- `const` and the signature keywords are grammar rather than names of a
							-- type: `---@alias Font<const Size: number>` marks a parameter.
							local target = TYPE_KEYWORD[word] and "keyword" or "type"
							carve(annotation.typeStart + nameAt - 1, annotation.typeStart + nameStop - 1, target)
							cursor = nameStop + 1
						elseif numberAt and (not barAt or numberAt < barAt) then
							-- `---@type 2149 | 231` lists numbers, and a number is a number.
							local _, numberStop = typeText:find("^%d[%w%.]*", numberAt)
							carve(annotation.typeStart + numberAt - 1, annotation.typeStart + numberStop - 1,
								"number")
							cursor = numberStop + 1
						elseif barAt then
							-- The `|` between members is punctuation rather than comment text, so it
							-- reads in the editor's own colour instead of the comment's.
							carve(annotation.typeStart + barAt - 1, annotation.typeStart + barAt - 1, "operator")
							cursor = barAt + 1
						else
							break
						end
					end
				end
			end
		end

		if count_ == 0 then
			emitSpan(token.start, token.stop, "comment")
			return
		end
		table.sort(carved, function(left, right) return left.start < right.start end)

		---@param from integer
		---@param to integer
		---@param target string
		---@param modifiers integer?
		local function emitLines(from, to, target, modifiers)
			-- Split at newlines: a span that crosses one cannot be encoded.
			local cursor = from
			while cursor <= to do
				local newline = text:find("\n", cursor, true)
				local lineStop = (newline and newline - 1 < to) and newline - 1 or to
				emitSpan(cursor, lineStop, target, modifiers)
				cursor = lineStop + 2
			end
		end

		local cursor, seen = token.start, token.start - 1
		for _, span in ipairs(carved) do
			if span.start > seen then
				if span.start > cursor then
					emitLines(cursor, span.start - 1, "comment", TOKEN_MODIFIER.documentation)
				end
				emitLines(span.start, span.stop, span.target)
				cursor = span.stop + 1
				seen = span.stop
			end
		end
		if cursor <= token.stop then
			emitLines(cursor, token.stop, "comment", TOKEN_MODIFIER.documentation)
		end
	end

	local tokens = result.tokens
	for at = 1, tokens.count do
		local token = tokens.arena[at]
		local written = tokens.texts[at]
		if token.kind == KIND.comment then
			emitComment(token, written)
		else
			local target
			if token.kind == KIND.keyword then
				target = "keyword"
			elseif token.kind == KIND.string then
				target = "string"
			elseif token.kind == KIND.number then
				target = "number"
			elseif token.kind == KIND.symbol and written ~= "::" and written ~= "label" then
				target = "operator"
			elseif token.kind == KIND.name then
				target = kinds[token.start] or "variable"
			end
			local declared = cdefSpans[token.start]
			if declared then
				-- The brackets are what says this is a string at all, so they keep that colour
				-- even though nothing between them is coloured as one.
				-- The delimiter is what the content started after, and a long string is closed the
				-- way it was opened: `[[` and `]]`, `[==[` and `]==]`. The three go out in the order
				-- they appear, because a token's position is written as the distance from the one
				-- before it: out of order, every token after it lands in the wrong place.
				local width = declared.from - token.start
				emitSpan(token.start, declared.from - 1, "string")
				for _, span in ipairs(declared.spans) do
					local kind = CDEF_KIND[span.kind]
					if kind then
						emitSpan(declared.from + span.start - 1, declared.from + span.stop - 1, kind)
					end
				end
				emitSpan(token.stop - width + 1, token.stop, "string")
			elseif target then
				emitSpan(token.start, token.stop, target)
			end
		end
	end

	return { data = data }
end

--- Completion kinds, by number, as the protocol defines them.
local COMPLETION_KIND = {
	["function"] = 3, method = 2, field = 5, variable = 6, class = 7, module = 9, namespace = 9,
	parameter = 6, property = 10, keyword = 14, constant = 21,
}

--- Collect everything a value carries into one table: its own fields, its parents', and both
--- sides of a union. A field the class keeps to itself is left out, since reading one is reported.
---@param type lye.doc.Type
---@param out table<string, lye.doc.Type>
local function collectFields(type, out)
	if type.variant == "class" or type.variant == "object" then
		for name, field in pairs(type.fields or {}) do
			local visibility = type.visibility and type.visibility[name]
			if not out[name] and visibility ~= "private" then out[name] = field end
		end
		for _, parent in ipairs(type.parents or {}) do collectFields(parent, out) end
	elseif type.variant == "union" then
		for _, member in ipairs(type.types) do collectFields(member, out) end
	end
end

--- Everything a value carries, by name.
---@param type lye.doc.Type
---@return table<string, lye.doc.Type>
local function fieldsOf(type)
	local out = {}
	collectFields(type, out)
	return out
end

--- The value a `.` or `:` was written after, and the name typed after it so far. The arena
--- already knows: `math.` is an index whose field failed to parse, and `table.inse` one whose
--- field is half written, so nothing is recovered by looking at the text.
---@param result lye.analyzer.Result
---@param offset integer where the cursor is
---@return integer? target arena index of the value
---@return string prefix what has been typed of the field name
---@return boolean isMethod
---@return integer? keyFrom where the key text starts, when it has to be rewritten
---@return string? quote the quote a rewritten key is written with
local function accessAt(result, source, offset)
	local found
	for _, node in ipairs(result.parser.nodes) do
		-- `t["` names no field in the tree, and an `index` or a method call is what has one. The
		-- node spans its arguments too — and an unterminated call spans the rest of the file —
		-- so where the cursor is relative to the *field* is what decides, not where it is in
		-- the node.
		local isAccess = node.kind == "index" and node.isDynamic ~= true
			or (node.kind == "call" and node.isMethod == true)
		if node.target and isAccess then
			local target = result.parser.nodes[node.target]
			-- The field starts after the `.` or `:` that follows the value it is read on.
			local targetStop = target and valueStop(result, target)
			local fieldStart = targetStop and (targetStop + 2)
			local upToCursor = targetStop and source:sub(targetStop, offset - 1)
			if fieldStart and fieldStart <= offset
				and not upToCursor:find("\n", 1, true) then
				local fieldStop = node.field and (fieldStart + #node.field) or fieldStart
				if offset <= fieldStop + 1 and (not found or fieldStart > found.start) then
					local typed = node.field and node.field:sub(1, math.max(offset - fieldStart, 0)) or ""
					found = {
						target = node.target, prefix = typed,
						isMethod = node.isMethod == true, start = fieldStart,
					}
				end
			end
		elseif node.target and node.kind == "index" and node.isDynamic == true then
			-- `t["…` being typed: the parser has no field name for it, so what has been written
			-- of the key is the text between the bracket and the cursor. Only a quoted key is a
			-- field name — `t[i]` reads one the writer named elsewhere.
			local target = result.parser.nodes[node.target]
			local targetStop = target and valueStop(result, target)
			local keyStart = targetStop and (targetStop + 2)
			if keyStart and keyStart <= offset and (not found or keyStart > found.start) then
				local typed = source:sub(keyStart, offset - 1)
				local opening = typed:sub(1, 1)
				local quote, name
				if opening == '"' or opening == "'" then
					local rest = typed:sub(2)
					if rest:sub(-1) == opening and not rest:sub(1, -2):find(opening, 1, true) then
						-- The key is written and closed: the list is what the table holds, and
						-- choosing from it replaces the key rather than being inserted into it.
						quote, name = opening, ""
					elseif not rest:find(opening, 1, true) then
						quote, name = opening, rest
					end
				elseif typed == "" then
					-- Just the bracket: the field is about to be named, and a name only fits here
					-- as a string.
					quote, name = '"', ""
				end
				if name and not name:find("\n", 1, true) then
					found = {
						target = node.target, prefix = name, isMethod = false, start = keyStart,
						keyFrom = opening == "" and offset or keyStart, quote = quote,
					}
				end
			end
		end
	end
	if found then return found.target, found.prefix, found.isMethod, found.keyFrom, found.quote end
end

--- The primitives an annotation may name, which no file declares.
local PRIMITIVE_TYPES = {
	"any", "boolean", "function", "integer", "never", "nil", "number", "string", "table", "unknown",
}

---@param self lye.Server
---@param uri string
---@return table
function Lye:completeTypes(uri)
	local items, seen = json.array(), {}
	local namespace = doc.classes.read(self.names[uri].doc)
	---@param name string
	---@param detail string
	---@param kind integer
	local function offer(name, detail, kind)
		if seen[name] then return end
		seen[name] = true
		items[#items + 1] = { label = name, kind = kind, detail = detail }
	end

	---@param classes table<string, lye.doc.Class>
	---@param aliases table<string, lye.doc.Alias>
	local function offerNamespace(classes, aliases)
		for name, class in pairs(classes) do
			offer(name, class.parent and ("class: " .. class.parent) or "class", COMPLETION_KIND.class)
		end
		for name, alias in pairs(aliases) do
			offer(name, "alias of " .. alias.body, COMPLETION_KIND.class)
		end
	end

	for _, name in ipairs(PRIMITIVE_TYPES) do offer(name, "built-in type", COMPLETION_KIND.class) end
	-- This document's own come first, since they win over the definitions where they disagree.
	offerNamespace(namespace.classes, namespace.aliases)
	offerNamespace(PRELUDE.classes, PRELUDE.aliases)
	return { isIncomplete = false, items = items }
end

---@param self lye.Server
---@return table
function Lye:onCompletion(params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	if not uri or not document then return { isIncomplete = false, items = json.array() } end
	-- Analysed on demand, the way hover does it: a document that was just opened has not been
	-- through the analyzer yet, and answering nothing for it is how completion stops working in a
	-- file nobody has typed in.
	local names = self.names[uri] or (self:analyze(uri) and self.names[uri])
	if not names then return { isIncomplete = false, items = json.array() } end

	local source = document.text
	local offset = position.toOffset(
		source, document.lineIndex, params.position.line, params.position.character, self.server.encoding
	)

	-- Inside `require("...")` what is wanted is a module name, and the files of the workspace are
	-- the list of them. The item replaces the text inside the quotes.
	local inside = self:requireStringAt(uri, source, offset)
	if inside then
		local items = json.array()
		for _, found in ipairs(self:moduleNames(inside.typed)) do
			items[#items + 1] = {
				label = found.name,
				kind = 9,
				-- A builtin module has no path in this workspace to show, and its own name is what it
				-- is called: the definitions are where it comes from.
				detail = found.detail or found.path:sub(#(self.server.rootPath or "") + 2),
				textEdit = {
					range = self:toRange(source, document.lineIndex, inside.from, inside.to),
					newText = found.name,
				},
			}
		end
		return { isIncomplete = false, items = items }
	end

	-- Inside a `---@` comment the writer is naming a type rather than a value.
	local lineStart = source:sub(1, offset - 1):match(".*()\n") or 1
	local before = source:sub(lineStart, offset - 1)
	-- The pattern the doc reader uses, so `--- @param` offers types exactly where `---@param` does.
	if before:match("^%s*" .. doc.TAG_PATTERN) then return self:completeTypes(uri) end

	local target, prefix, isMethod, keyFrom, quote = accessAt(names, source, offset)
	if target then
		local items = json.array()
		local base = typeOfExpression(names, target, offset)
		if base then
			local signatures = names.signatures or {}
			for name, field in pairs(fieldsOf(base)) do
				if prefix == "" or name:sub(1, #prefix) == prefix then
					local kind = COMPLETION_KIND.field
					local item = { label = name, kind = kind, detail = types.display(field) }
					if types.isFn(field) then
						-- After a `:` the writer is calling a method; after a `.` it is reading a
						-- field, and a function stored in one is a function.
						kind = isMethod and COMPLETION_KIND.method or COMPLETION_KIND["function"]
						item.kind = kind
						-- The definitions keep the annotations a field was built from, and the
						-- document keeps its own declarations: either may carry documentation.
						local signature = PRELUDE.fields[field]
							or (base.variant == "class"
								and (signatures[base.name .. "." .. name]
									or signatures[base.name .. ":" .. name]))
						if signature then
							item.detail = signatureText(signature)
							item.documentation = documentationItem(signature)
						end
					end
					if quote then
						-- Inside a bracket the field is a *string* key, so the item replaces the
						-- text written of it — a bare label would leave `t[alpha]`.
						item.textEdit = {
							range = self:toRange(source, document.lineIndex, keyFrom, offset - 1),
							newText = quote .. name .. quote,
						}
					end
					items[#items + 1] = item
				end
			end
		end
		return { isIncomplete = false, items = items }
	end

	-- A name means nothing inside a string, and offering one there is how a completion writes
	-- `string.format` into the middle of a message. The module names above are the one thing a
	-- string may hold, and they were offered before this.
	local token = tokenAt(names.parser, offset)
	if token and token.kind == KIND.string then
		return { isIncomplete = false, items = json.array() }
	end

	local items, seen = json.array(), {}
	for _, variable in ipairs(analyzer.visibleAt(self.names[uri], offset)) do
		if not seen[variable.name] then
			seen[variable.name] = true
			local shown = types.display(analyzer.typeAt(self.names[uri], variable, offset))
			-- The icon follows the type: `math` is the namespace it holds, `join` the function it
			-- is, and a plain value is a variable.
			local as = readAsName(self.names[uri], variable.name, offset)
			items[#items + 1] = {
				label = variable.name,
				kind = COMPLETION_KIND[as or "variable"],
				detail = shown,
				documentation = documentationItem(self.names[uri].signatures
					and self.names[uri].signatures[variable.name]),
			}
		end
	end

	-- The definitions declare functions rather than variables, so `print`, `setmetatable` and the
	-- rest of the standard library are offered from their signatures. A name the document declares
	-- itself was already offered above, and a dotted name is reached through its table.
	--
	-- The definitions' names are reached through a `__index` metatable, and `pairs` does not see
	-- through one: iterating the table is how every prelude *function* — `print`, `pairs`,
	-- `pcall`, `type` and the rest — came to be missing from completion while the prelude *tables*
	-- beside them were offered, since those are injected as variables. So the list of names the
	-- definitions declare is walked, and the signature is looked up per name.
	local declaredSignatures = self.names[uri].signatures or {}
	---@param name string
	local function offerGlobal(name)
		if seen[name] or name:find("[%.:]") then return end
		local signature = declaredSignatures[name]
		seen[name] = true
		items[#items + 1] = {
			label = name,
			-- A name the definitions declare without a signature is a value, not a function:
			-- `arg` and `_VERSION` are written as plain assignments.
			kind = signature and COMPLETION_KIND["function"] or COMPLETION_KIND.variable,
			detail = signatureText(signature),
			documentation = documentationItem(signature),
		}
	end
	for name in pairs(declaredSignatures) do offerGlobal(name) end
	for name in pairs(PRELUDE.globalNames or {}) do offerGlobal(name) end

	for _, keyword in ipairs(Parser.KEYWORD_LIST) do
		if not seen[keyword] then
			seen[keyword] = true
			items[#items + 1] = { label = keyword, kind = COMPLETION_KIND.keyword }
		end
	end

	return { isIncomplete = false, items = items }
end

---@param self lye.Server
function Lye:onDocumentChanged(params)
	local uri = params.textDocument?.uri
	if not uri then return end

	local result = self:analyze(uri)
	if result then self:publishDiagnostics(uri, result) end
end

---@param self lye.Server
function Lye:onDocumentClosed(params)
	local uri = params.textDocument?.uri
	if not uri then return end

	self.analysis[uri] = nil
	self.names[uri] = nil
	self.server:notify(framework.METHOD.publishDiagnostics, { uri = uri, diagnostics = json.array() })
end

--- Every place a name is written: its declaration and each reference. The analyzer records the
--- references while it resolves them, so this is a lookup rather than a search.
---@param self lye.Server
---@param params table
---@return lye.analyzer.Variable?
---@return lye.analyzer.Result?
---@return lye.parser.Result?
local function targetAt(self, params)
	local uri, _, _, names, offset = self:resolvePosition(params)
	if not names then return nil, nil, nil end
	local name = nameAt(names.parser, offset)
	local variable = name and analyzer.lookupAt(names, name, offset)
	return variable, names
end

---@param self lye.Server
---@param text string
---@param index lye.framework.LineIndex
---@param variable lye.analyzer.Variable
---@return table[] ranges
local function placesOf(self, text, index, variable)
	local ranges = json.array()
	local declaration = variable.declaration
	ranges[#ranges + 1] = self:toRange(text, index, declaration.start, declaration.stop)
	for _, at in ipairs(variable.references) do
		ranges[#ranges + 1] = self:toRange(text, index, at, at + #variable.name - 1)
	end
	return ranges
end

---@param self lye.Server
---@return table?
function Lye:onReferences(params)
	local variable, names = targetAt(self, params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	if not variable or not document then return json.array() end

	local include = params.context == nil or params.context.includeDeclaration ~= false
	local places = placesOf(self, document.text, document.lineIndex, variable)
	local out = json.array()
	for index, range in ipairs(places) do
		if include or index > 1 then out[#out + 1] = { uri = uri, range = range } end
	end
	return out
end

---@param self lye.Server
---@return table?
function Lye:onDocumentHighlight(params)
	local variable, names = targetAt(self, params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	if not variable or not document then return json.array() end

	local out = json.array()
	local writes = {}
	for _, assignment in ipairs(variable.assignments) do writes[assignment.at] = true end
	for _, range in ipairs(placesOf(self, document.text, document.lineIndex, variable)) do
		-- A reference that a name is assigned to is a write; everything else is a read.
		local kind = writes[range.start.line + 1] and 3 or 2
		out[#out + 1] = { range = range, kind = kind }
	end
	return out
end

---@param self lye.Server
---@return table?
function Lye:onPrepareRename(params)
	local variable = targetAt(self, params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	if not variable or not document then return nil end
	local declaration = variable.declaration
	return {
		range = self:toRange(document.text, document.lineIndex, declaration.start, declaration.stop),
		placeholder = variable.name,
	}
end

---@param self lye.Server
---@return table?
function Lye:onRename(params)
	local variable = targetAt(self, params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	local newName = params.newName
	if not variable or not document or not newName then return nil end

	local edits = json.array()
	for _, range in ipairs(placesOf(self, document.text, document.lineIndex, variable)) do
		edits[#edits + 1] = { range = range, newText = newName }
	end
	return { changes = { [uri] = edits } }
end

--- The declaration a type came from: `---@class Point` over `local Point = {}` is a declaration
--- like any other, so go-to-type is a lookup by the class's name.
---@param self lye.Server
---@return table?
function Lye:onTypeDefinition(params)
	local uri, text, index, names, offset = self:resolvePosition(params)
	local result = names and names.parser
	if not names or not result then return nil end

	-- A type named in an annotation is already a type; what it needs is where it is declared.
	local target = self:targetAt(uri, text, names, offset)
	if target and target.uri ~= uri then return { uri = target.uri, range = self:rangeIn(target) } end

	local variable = analyzer.lookupAt(names, nameAt(result, offset) or "", offset)
	local held = variable and analyzer.typeAt(names, variable, offset)
	if not held then return nil end
	local wanted = held.variant == "class" and held.name or nil
	if not wanted then return nil end

	for _, declaration in ipairs(result.declarations) do
		if declaration.name == wanted then
			return {
				uri = uri,
				range = self:toRange(text, index, declaration.start, declaration.stop),
			}
		end
	end
end

--- Folding: the blocks the parser recorded, and the comment blocks above them.
---@param self lye.Server
---@return table
function Lye:onFoldingRange(params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	local result = uri and self.analysis[uri]
	if not document or not result then return json.array() end

	local text, index = document.text, document.lineIndex
	local out, seen = json.array(), {}
	local function add(from, to, kind)
		local startLine = select(1, position.toPosition(text, index, from, self.server.encoding))
		local endLine = select(1, position.toPosition(text, index, to, self.server.encoding))
		if endLine > startLine then
			local key = startLine .. ":" .. endLine
			if not seen[key] then
				seen[key] = true
				out[#out + 1] = { startLine = startLine, endLine = endLine, kind = kind }
			end
		end
	end

	for _, scope in ipairs(result.scopes) do add(scope.start, scope.stop, "region") end

	-- A run of comment lines is one folding range, which is what a doc block is.
	local runStart
	for at = 1, result.tokens.count do
		local token = result.tokens.arena[at]
		if token.kind == KIND.comment then
			if not runStart then runStart = token.start end
			local next_ = result.tokens.arena[at + 1]
			if not next_ or next_.kind ~= KIND.comment then
				add(runStart, token.stop, "comment")
				runStart = nil
			end
		else
			runStart = nil
		end
	end
	return out
end

--- Selection ranges: the chain of expressions and blocks containing a position, innermost first.
---@param self lye.Server
---@return table
function Lye:onSelectionRange(params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	local result = uri and self.analysis[uri]
	if not document or not result then return json.array() end

	local text, index, encoding = document.text, document.lineIndex, self.server.encoding
	local out = json.array()
	for _, where in ipairs(params.positions or {}) do
		local offset = position.toOffset(text, index, where.line, where.character, encoding)
		local held = {}
		for _, node in ipairs(result.nodes) do
			if node.start <= offset and offset <= node.stop then held[#held + 1] = node end
		end
		-- Outermost first, so each range can be written as the parent of the one inside it.
		table.sort(held, function(left, right)
			if left.start ~= right.start then return left.start < right.start end
			return left.stop > right.stop
		end)

		local range
		for _, node in ipairs(held) do
			local mine = self:toRange(text, index, node.start, node.stop)
			range = { range = mine, parent = range }
		end
		out[#out + 1] = range or { range = self:toRange(text, index, offset, offset) }
	end
	return out
end

--- Inlay hints: the type of a name that was inferred rather than written, which is what a reader
--- cannot see for themselves.
---@param self lye.Server
---@return table
--- How long an inlay hint may be. A table of twenty fields and a string of two hundred characters
--- are both correct answers to "what is this", and neither is readable beside a name.
local HINT_LIMIT = 32

--- The type an inlay hint shows, cut to fit. The hover still has all of it, so a hint only has to
--- say enough to be worth reading: what is kept is the beginning, cut back to a separator where
--- there is one rather than through the middle of a word.
---@param type lye.doc.Type
---@return string
local function hintText(type)
	local shown = types.display(type)
	if #shown <= HINT_LIMIT then return shown end
	local cut = shown:sub(1, HINT_LIMIT)
	-- A string value keeps its shape: `"a very long messa…"` still reads as a string.
	if shown:sub(1, 1) == '"' then return cut .. '…"' end
	local edge = cut:match("^.*[,;{}]")
	if edge and #edge >= HINT_LIMIT / 2 then return edge .. " …" end
	local word = cut:match("^.*%s")
	return (word or cut) .. "…"
end

function Lye:onInlayHint(params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	local names = uri and self.names[uri]
	if not document or not names then return json.array() end

	local text, index, encoding = document.text, document.lineIndex, self.server.encoding
	local from = params.range and position.toOffset(text, index, params.range.start.line, params.range.start.character, encoding) or 1
	local to = params.range and position.toOffset(text, index, params.range["end"].line, params.range["end"].character, encoding) or #text

	local out = json.array()
	for _, variable in ipairs(names.variables) do
		local declaration = variable.declaration
		local value = declaration.valueIdx and names.parser.nodes[declaration.valueIdx]
		-- A function's own declaration is not a name whose type a reader has to guess, and the
		-- hint would land on the `(` of its parameter list.
		local isFunction = value ~= nil and value.kind == "function"
		if not variable.declared and not isFunction and declaration.start >= from and declaration.stop <= to then
			local held = analyzer.typeAt(names, variable, declaration.stop)
			local shown = hintText(held)
			if shown ~= "unknown" and shown ~= "any" then
				out[#out + 1] = {
					position = select(2, position.toPosition(text, index, declaration.stop + 1, encoding)) and {
						line = select(1, position.toPosition(text, index, declaration.stop + 1, encoding)),
						character = select(2, position.toPosition(text, index, declaration.stop + 1, encoding)),
					} or nil,
					label = ": " .. shown,
					kind = 1,
					paddingLeft = false,
				}
			end
		end
	end
	return out
end

--- The call a position is inside, for signature help.
---@param result lye.parser.Result
---@param offset integer
---@return lye.parser.Node?
local function callAt(result, offset)
	local found
	for _, node in ipairs(result.nodes) do
		if node.kind == "call" and node.start <= offset and offset <= node.stop + 1 then
			if not found or node.start > found.start then found = node end
		end
	end
	return found
end

---@param self lye.Server
---@return table?
function Lye:onSignatureHelp(params)
	local uri, text, index, names, offset = self:resolvePosition(params)
	local result = names and names.parser
	if not names or not result then return nil end

	local node = callAt(result, offset)
	if not node then return nil end
	local signature = signatureFor(names, node, offset)
	if not signature then return nil end

	local parts, params_ = {}, json.array()
	for _, annotation in ipairs(signature.params) do
		local held = annotation.type or "any"
		local one = (annotation.name and annotation.name ~= "") and (annotation.name .. ": " .. held) or held
		parts[#parts + 1] = one
		params_[#params_ + 1] = { label = one }
	end
	local returned = signature.returns and signature.returns.type
	local label = writtenName(names, node, text) .. "(" .. table.concat(parts, ", ") .. ")"
		.. (returned and (" -> " .. returned) or "")

	-- Which argument the cursor is in: as many as have started before it.
	local active = 0
	for index_, argIdx in ipairs(node.args or {}) do
		local argument = result.nodes[argIdx]
		if argument and argument.start <= offset then active = index_ end
	end

	return {
		signatures = json.array({ {
			label = label,
			parameters = params_,
			documentation = signature.doc and { kind = "markdown", value = signature.doc } or nil,
		} }),
		activeSignature = 0,
		activeParameter = math.min(active, math.max(#signature.params - 1, 0)),
	}
end

--- The function a position names, for the call hierarchy: what a caller and a callee are both
--- about.
---@param self lye.Server
---@param params table
---@return table?
function Lye:onCallHierarchyPrepare(params)
	local uri, text, index, names, offset = self:resolvePosition(params)
	local result = names and names.parser
	if not names or not result then return nil end

	local name = nameAt(result, offset)
	local variable = name and analyzer.lookupAt(names, name, offset)
	if not variable then return nil end
	local declaration = variable.declaration
	return json.array({ {
		name = variable.name,
		kind = variable.declaration.isFunction and 12 or 13,
		uri = uri,
		range = self:toRange(text, index, declaration.start, declaration.stop),
		selectionRange = self:toRange(text, index, declaration.start, declaration.stop),
		data = { uri = uri, name = variable.name, offset = declaration.start },
	} })
end

--- The function a position is inside, which is what a caller is: the innermost declaration whose
--- body holds the offset.
---@param parsed lye.parser.Result
---@param offset integer
---@return lye.parser.Declaration?
local function enclosingFunction(parsed, offset)
	local owner
	for _, declaration in ipairs(parsed.declarations) do
		local body = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
		if body and body.kind == "function" and body.start <= offset and offset <= body.stop then
			if not owner or body.start > (parsed.nodes[owner.valueIdx].start) then owner = declaration end
		end
	end
	return owner
end

--- A hierarchy item for a declaration.
---@param self lye.Server
---@param uri string
---@param text string
---@param index lye.framework.LineIndex
---@param declaration lye.parser.Declaration
---@return table
local function hierarchyItem(self, uri, text, index, declaration)
	local range = self:toRange(text, index, declaration.start, declaration.stop)
	return {
		name = declaration.name,
		kind = declaration.isFunction and 12 or 13,
		uri = uri,
		range = range,
		selectionRange = range,
		data = { uri = uri, name = declaration.name, offset = declaration.start },
	}
end

---@param self lye.Server
---@param params table
---@return table[]
function Lye:onCallHierarchyIncoming(params)
	local item = params.item or {}
	local uri = item.data?.uri or item.uri
	local document = uri and self.server.documents:get(uri)
	local names = uri and self.names[uri]
	local result = uri and self.analysis[uri]
	if not document or not names or not result then return json.array() end

	local variable = item.data?.name and analyzer.lookupAt(names, item.data.name, item.data.offset or 1)
	if not variable then return json.array() end

	local text, index = document.text, document.lineIndex
	local calls, byCaller = json.array(), {}
	for _, at in ipairs(variable.references) do
		local caller = enclosingFunction(result, at)
		if caller then
			local key = caller.start
			local entry = byCaller[key]
			if not entry then
				entry = {
					from = hierarchyItem(self, uri, text, index, caller),
					fromRanges = json.array(),
				}
				byCaller[key] = entry
				calls[#calls + 1] = entry
			end
			entry.fromRanges[#entry.fromRanges + 1] = self:toRange(text, index, at, at + #variable.name - 1)
		end
	end
	return calls
end

---@param self lye.Server
---@param params table
---@return table[]
function Lye:onCallHierarchyOutgoing(params)
	local item = params.item or {}
	local uri = item.data?.uri or item.uri
	local document = uri and self.server.documents:get(uri)
	local names = uri and self.names[uri]
	local result = uri and self.analysis[uri]
	if not document or not names or not result then return json.array() end

	local owner
	for _, declaration in ipairs(result.declarations) do
		if declaration.start == item.data?.offset or declaration.name == item.name then owner = declaration end
	end
	if not owner or not owner.valueIdx then return json.array() end

	local text, index = document.text, document.lineIndex
	local body = result.nodes[owner.valueIdx]
	local out, byCallee = json.array(), {}
	for _, node in ipairs(result.nodes) do
		local inside = node.kind == "call" and node.start >= body.start and node.stop <= body.stop + 1
		local name = inside and (node.field or node.callee)
		if name then
			local callee = analyzer.lookupAt(names, name, node.start)
			if callee then
				local key = callee.declaration.start
				local entry = byCallee[key]
				if not entry then
					entry = {
						to = hierarchyItem(self, uri, text, index, callee.declaration),
						fromRanges = json.array(),
					}
					byCallee[key] = entry
					out[#out + 1] = entry
				end
				entry.fromRanges[#entry.fromRanges + 1] = self:toRange(text, index, node.start, node.stop)
			end
		end
	end
	return out
end

--- How deep a line is written: the number of blocks the parser recorded around it. The tree knows
--- which blocks are bodies, so nothing is guessed from the text.
---@param parsed lye.parser.Result
---@param offset integer
---@return integer
local function indentAt(parsed, offset)
	local depth, seen = 0, {}
	for _, scope in ipairs(parsed.scopes) do
		if scope.start <= offset and offset <= scope.stop and not seen[scope.start] then
			seen[scope.start] = true
			depth = depth + 1
		end
	end
	-- The outermost scope is the chunk, which is not something a line is indented inside of.
	return math.max(depth - 1, 0)
end

--- Whether a line starts inside a string that runs over more than one line, which no formatter can
--- reindent without changing what the string says.
---@param parsed lye.parser.Result
---@param source string
---@param from integer
---@param to integer
---@return boolean
local function insideLongString(parsed, source, from, to)
	local tokens = parsed.tokens
	for index = 1, tokens.count do
		local token = tokens.arena[index]
		if token.kind == KIND.string and token.start <= from and from <= token.stop then
			return true
		end
	end
	_ = source
	_ = to
	return false
end

--- The edits a formatter would make to the lines in a range: the indentation a line is written at,
--- and nothing else. Spacing inside a line is left alone deliberately — a formatter that rewrites
--- what a writer wrote is one they turn off — and so is a line inside a long string.
---@param self lye.Server
---@param uri string
---@param firstLine integer 0-based
---@param lastLine integer 0-based
---@return table[]
function Lye:formatRange(uri, firstLine, lastLine)
	local document = self.server.documents:get(uri)
	local parsed = self.analysis[uri]
	if not document or not parsed then return json.array() end

	local text, index, encoding = document.text, document.lineIndex, self.server.encoding
	local edits = json.array()
	local line, at = 0, 1
	while at <= #text do
		local newline = text:find("\n", at, true)
		local stop = (newline and newline - 1) or #text
		local written = text:sub(at, stop)
		if line >= firstLine and line <= lastLine then
			local trimmed = written:gsub("%s+$", "")
			if not insideLongString(parsed, text, at, stop) then
				local wanted = ("\t"):rep(indentAt(parsed, math.min(at, #text)))
					.. (trimmed:gsub("^[ \t]+", ""))
				if wanted ~= written then
					edits[#edits + 1] = {
						range = {
							start = { line = line, character = 0 },
							["end"] = { line = line, character = #written },
						},
						newText = wanted,
					}
				end
			elseif trimmed ~= written then
				edits[#edits + 1] = {
					range = {
						start = { line = line, character = #trimmed },
						["end"] = { line = line, character = #written },
					},
					newText = "",
				}
			end
		end
		line = line + 1
		at = stop + 2
		if not newline then break end
	end
	_ = index
	_ = encoding
	return edits
end

---@param self lye.Server
---@param params table
---@return table[]
function Lye:onFormatting(params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	if not document then return json.array() end
	local lines = 0
	for _ in document.text:gmatch("\n") do lines = lines + 1 end
	return self:formatRange(uri, 0, lines)
end

---@param self lye.Server
---@param params table
---@return table[]
function Lye:onFormattingRange(params)
	local uri = params.textDocument?.uri
	local range = params.range
	if not uri or not range then return json.array() end
	return self:formatRange(uri, range.start.line, range["end"].line)
end

--- `textDocument/onTypeFormatting`: after a newline, the line being written gets its indentation.
---@param self lye.Server
---@param params table
---@return table[]
function Lye:onTypeFormatting(params)
	local uri = params.textDocument?.uri
	local where = params.position
	if not uri or not where then return json.array() end
	return self:formatRange(uri, where.line, where.line)
end

--- The classes that extend the one under the cursor, which is what "go to implementations" asks
--- for in a language without interfaces: a class's child is its implementation.
---@param self lye.Server
---@param params table
---@return table[]
function Lye:onImplementation(params)
	local uri, text, index, names, offset = self:resolvePosition(params)
	if not names then return json.array() end

	local variable = analyzer.lookupAt(names, nameAt(names.parser, offset) or "", offset)
	local held = variable and analyzer.typeAt(names, variable, offset)
	if not held or held.variant ~= "class" then return json.array() end

	local out = json.array()
	local namespace = doc.classes.read(names.doc)
	local node = nodeAt(names, offset)
	local field = node and node.field
	for className, class in pairs(namespace.classes) do
		local parent = class.parent and class.parent:match("^([%w_%.]+)") or nil
		-- A child class implements its parent, and a child's method implements the one it overrides.
		local matches = parent == held.name
		if not matches and field then
			for _, one in ipairs(class.fields) do
				if one.name == field and class.parent then matches = true end
			end
		end
		if matches then
			for _, declaration in ipairs(names.parser.declarations) do
				local wanted = field and (className .. ":" .. field) or className
				if declaration.name == className or declaration.name == wanted
					or declaration.name == (className .. "." .. (field or "")) then
					out[#out + 1] = {
						uri = uri,
						range = self:toRange(text, index, declaration.start, declaration.stop),
					}
				end
			end
		end
	end
	return out
end

--- What an editor offers to do about a diagnostic: an unused local is renamed to `_name`, which is
--- how a writer says the name is deliberate.
---@param self lye.Server
---@param params table
---@return table[]
function Lye:onCodeAction(params)
	local uri = params.textDocument?.uri
	local actions = json.array()
	for _, diagnostic in ipairs(params.context?.diagnostics or {}) do
		local name = (diagnostic.message or ""):match("^unused local `([%w_]+)`$")
		if name then
			actions[#actions + 1] = {
				title = string.format("Mark `%s` as deliberately unused", name),
				kind = "quickfix",
				diagnostics = json.array({ diagnostic }),
				edit = {
					changes = {
						[uri] = json.array({ { range = diagnostic.range, newText = "_" .. name } }),
					},
				},
				isPreferred = false,
			}
		end
	end
	return actions
end

--- How many places read each function, above its declaration: the count a reader would otherwise
--- have to ask for.
---@param self lye.Server
---@param params table
---@return table[]
function Lye:onCodeLens(params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	local names = uri and self.names[uri]
	if not document or not names then return json.array() end

	local out = json.array()
	for _, variable in ipairs(names.variables) do
		local declaration = variable.declaration
		local isFunction = declaration.isFunction or (declaration.valueIdx
			and names.parser.nodes[declaration.valueIdx]
			and names.parser.nodes[declaration.valueIdx].kind == "function")
		local places = #variable.references
		if isFunction and places > 0 then
			out[#out + 1] = {
				range = self:toRange(document.text, document.lineIndex, declaration.start, declaration.stop),
				command = {
					title = places == 1 and "1 reference" or (places .. " references"),
					command = "",
				},
			}
		end
	end
	return out
end

--- The colours a number spells: `0xRRGGBB` and `0xAARRGGBB` are how LuaJIT code writes them, and
--- an editor shows a swatch for them.
---@param self lye.Server
---@param params table
---@return table[]
function Lye:onDocumentColor(params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	local parsed = uri and self.analysis[uri]
	if not document or not parsed then return json.array() end

	local text, index, encoding = document.text, document.lineIndex, self.server.encoding
	local out = json.array()
	for at = 1, parsed.tokens.count do
		local token = parsed.tokens.arena[at]
		if token.kind == KIND.number then
			local written = parsed.tokens.texts[at]
			local digits = written:match("^0[xX](%x+)$")
			if digits and (#digits == 6 or #digits == 8) then
				local function channel(from, to)
					return tonumber(digits:sub(from, to), 16) / 255
				end
				local alpha = #digits == 8 and channel(1, 2) or 1
				local shift = #digits == 8 and 2 or 0
				local from = select(1, position.toPosition(text, index, token.start, encoding))
				local to, character = position.toPosition(text, index, token.stop + 1, encoding)
				out[#out + 1] = {
					range = {
						start = { line = from, character = select(2, position.toPosition(text, index, token.start, encoding)) },
						["end"] = { line = to, character = character },
					},
					color = {
						red = channel(1 + shift, 2 + shift),
						green = channel(3 + shift, 4 + shift),
						blue = channel(5 + shift, 6 + shift),
						alpha = alpha,
					},
				}
			end
		end
	end
	return out
end

--- A symbol in the workspace: every `*.lua` file under the folder the client opened, read once and
--- kept until a file in it changes. LuaLS indexes the workspace the same way; the difference is that
--- this reads the files when the first symbol is asked for rather than while the editor starts.
---@param self lye.Server
---@return table[]
function Lye:workspaceSymbols()
	if self.workspace then return self.workspace end

	local out = json.array()
	local root = self.server.rootPath
	if not root then
		self.workspace = out
		return out
	end
	local pipe = io.popen(string.format("find %q -name '*.lua' -not -path '*/target/*' -not -path '*/.git/*' | head -2000", root))
	if not pipe then
		self.workspace = out
		return out
	end
	for file in pipe:lines() do
		local handle = io.open(file, "rb")
		if handle then
			local source = handle:read("*a")
			handle:close()
			local names = analyzer.analyze(source, PRELUDE)
			local result = names.parser
			local uri = "file://" .. file
			for _, declaration in ipairs(result.declarations) do
				if declaration.qualifier ~= "param" and declaration.qualifier ~= "label"
					and not declaration.name:find("[%.:]") then
					local range = self:toRange(source, nameIndex(source), declaration.start, declaration.stop)
					out[#out + 1] = {
						name = declaration.name,
						kind = declaration.isFunction and 12 or 13,
						location = { uri = uri, range = range },
					}
				end
			end
		end
	end
	pipe:close()
	self.workspace = out
	return out
end

--- The line index of a source, kept per call rather than rebuilt: a workspace symbol request is
--- rare enough that caching it would be more bookkeeping than it saves.
---@param source string
---@return lye.framework.LineIndex
function nameIndex(source)
	return position.buildLineIndex(source)
end

---@param self lye.Server
---@param params table
---@return table[]
function Lye:onWorkspaceSymbol(params)
	local query = (params.query or ""):lower()
	local out = json.array()
	for _, symbol in ipairs(self:workspaceSymbols()) do
		if query == "" or symbol.name:lower():find(query, 1, true) then out[#out + 1] = symbol end
	end
	return out
end

---@param self lye.Server
function Lye:register()
	local server = self.server
	local method = framework.METHOD

	server:capability("hoverProvider", true)
	server:capability("definitionProvider", true)
	server:capability("typeDefinitionProvider", true)
	server:capability("documentSymbolProvider", true)
	server:capability("documentHighlightProvider", true)
	server:capability("referencesProvider", true)
	server:capability("renameProvider", { prepareProvider = true })
	server:capability("foldingRangeProvider", true)
	server:capability("selectionRangeProvider", true)
	server:capability("inlayHintProvider", true)
	server:capability("callHierarchyProvider", true)
	server:capability("workspaceSymbolProvider", true)
	server:capability("implementationProvider", true)
	server:capability("codeActionProvider", { codeActionKinds = { "", "quickfix" } })
	server:capability("codeLensProvider", { resolveProvider = false })
	server:capability("colorProvider", true)
	server:capability("documentFormattingProvider", true)
	server:capability("documentRangeFormattingProvider", true)
	server:capability("documentOnTypeFormattingProvider", { firstTriggerCharacter = "\n" })
	server:capability("semanticTokensProvider", {
		legend = TOKEN_LEGEND, full = true, range = true,
	})
	-- `.` and `:` are what a field or a method call starts with; a name is completed as it is typed,
	-- which is what the client's own quick suggestions ask for.
	-- `[` is a trigger, not just `.` and `:`: `t[` is where a field with a name that is not an
	-- identifier is reached, and the client must ask there for the list to appear.
	server:capability("completionProvider", { triggerCharacters = { ".", ":", "[", '"', "'" } })
	server:capability("signatureHelpProvider", { triggerCharacters = { "(", "," } })

	server:on(method.didOpen, function(_, params)
		self.server:onDidOpen(params or {})
		self:onDocumentChanged(params or {})
	end)

	server:on(method.didChange, function(_, params)
		self.server:onDidChange(params or {})
		self:onDocumentChanged(params or {})
	end)

	server:on(method.didClose, function(_, params)
		self.server:onDidClose(params or {})
		self:onDocumentClosed(params or {})
	end)

	server:on(method.documentSymbol, function(_, params) return self:onDocumentSymbol(params or {}) end)
	server:on(method.hover, function(_, params) return self:onHover(params or {}) end)
	server:on(method.definition, function(_, params) return self:onDefinition(params or {}) end)
	server:on(method.semanticTokens, function(_, params) return self:onSemanticTokens(params or {}) end)
	server:on(method.completion, function(_, params) return self:onCompletion(params or {}) end)
	server:on(method.semanticTokensRange, function(_, params)
		return self:onSemanticTokens(params or {})
	end)
	server:on(method.signatureHelp, function(_, params) return self:onSignatureHelp(params or {}) end)
	server:on(method.references, function(_, params) return self:onReferences(params or {}) end)
	server:on(method.documentHighlight, function(_, params)
		return self:onDocumentHighlight(params or {})
	end)
	server:on(method.prepareRename, function(_, params) return self:onPrepareRename(params or {}) end)
	server:on(method.rename, function(_, params) return self:onRename(params or {}) end)
	server:on(method.typeDefinition, function(_, params) return self:onTypeDefinition(params or {}) end)
	server:on(method.foldingRange, function(_, params) return self:onFoldingRange(params or {}) end)
	server:on(method.selectionRange, function(_, params) return self:onSelectionRange(params or {}) end)
	server:on(method.inlayHint, function(_, params) return self:onInlayHint(params or {}) end)
	server:on(method.callHierarchyPrepare, function(_, params)
		return self:onCallHierarchyPrepare(params or {})
	end)
	server:on(method.callHierarchyIncoming, function(_, params)
		return self:onCallHierarchyIncoming(params or {})
	end)
	server:on(method.callHierarchyOutgoing, function(_, params)
		return self:onCallHierarchyOutgoing(params or {})
	end)
	server:on(method.workspaceSymbol, function(_, params) return self:onWorkspaceSymbol(params or {}) end)
	server:on(method.implementation, function(_, params) return self:onImplementation(params or {}) end)
	server:on(method.codeAction, function(_, params) return self:onCodeAction(params or {}) end)
	server:on(method.codeLens, function(_, params) return self:onCodeLens(params or {}) end)
	server:on(method.documentColor, function(_, params) return self:onDocumentColor(params or {}) end)
	server:on(method.formatting, function(_, params) return self:onFormatting(params or {}) end)
	server:on(method.formattingRange, function(_, params) return self:onFormattingRange(params or {}) end)
	server:on(method.typeFormatting, function(_, params) return self:onTypeFormatting(params or {}) end)
	server:on(method.workspaceDidChangeWatchedFiles, function()
		self.workspace = nil
	end)
end

---@return lye.Server
function Lye.start()
	local connection = rpc.Connection.new()
	local server = framework.Server.new(connection, { name = "lye", version = "0.1.0" })
	local lye = Lye.new(server)
	lye:register()
	server:run()
	return lye
end

return Lye
