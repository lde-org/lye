--[[
	`ffi.cdef`, read and coloured by the plugin that owns the ffi dialect.

	The C a `ffi.cdef` call writes is not Lua, so the plugin parses it twice for two different
	readers: `tokens` colours it, and `types` turns what it declared into the classes and aliases
	the rest of the analysis resolves `---@type Vec` and `ffi.new("Vec")` against. Nothing in the
	analyzer knows what a cdef is any more; a workspace that turns this plugin off reads the same
	file with `ffi.new` typed as the plain `ffi.cdata` its definitions say.

	`ffi.C`, `ffi.load` and the callback types follow from the same declarations. They are attached
	after the document's own namespace exists, so a class the writer declared wins over the one a
	block generated, and a type the plugin contributes resolves against both.
]]

local cdef = require("lye-cdef")
local doc = require("lye-doc")
local types = require("lye-doc.type")

local ffiPlugin = {}

--- What a name of a declaration is, in the vocabulary the server advertises.
local DECLARED = {
	keyword = "keyword", type = "type", class = "class", member = "property",
	constant = "property", ["function"] = "function", number = "number", variable = "variable",
	comment = "comment",
}

--- The blocks already parsed, by their own text: a cdef is read on every keystroke, and the
--- colour pass and the type pass ask for the same block. A handful is all a file has; the entry
--- holds the C namespace, the token spans and the annotations built from them, so the table is
--- kept small and dropped whole when it grows rather than grown forever.
---@type table<string, { declared: lye.cdef.Namespace, spans: table[], annotations: lye.doc.File }>
local parsed = {}

---@param text string the block
local function blockOf(text)
	local held = parsed[text]
	if held then return held end
	if next(parsed) and #parsed > 8 then
		for key in pairs(parsed) do parsed[key] = nil end
	end
	local declared = cdef.parse(text)
	held = {
		declared = declared,
		spans = cdef.spans(declared),
		annotations = doc.parse(cdef.annotations(declared)),
	}
	parsed[text] = held
	return held
end

--- Where the text inside a cdef string begins: past the quote, or past the brackets and whatever
--- `=` signs a long one was written with. The parser reports offsets into the text it was handed,
--- and a reader has to be told where in their file that is. A quoted string with escapes in it
--- would drift — a cdef is written as a long string in practice.
---@param written string the document
---@param argument lye.parser.Node the string the cdef was written as
---@param offset integer 1-based, into the text the parser read
local function cdefTextStart(written, argument, offset)
	local source = written:sub(argument.start, argument.stop)
	local level = source:match("^%[(=*)%[")
	local opened = 1
	if level then opened = 2 + #level end
	return argument.start + opened + offset - 1
end

--- The dotted name a call is written with, as the analyzer names it. `context.callName` is the
--- analyzer's own reader; the fallback keeps the colour hook usable when a caller hands it only a
--- parse tree.
---@param context lye.plugin.TokenContext
---@param node lye.parser.Node
---@return string?
local function callNameOf(context, node)
	if context.callName then return context.callName(node) end
	local parsed_ = context.parsed
	local target = node.target and parsed_.nodes[node.target]
	local field = node.field or (target and target.field)
	if not field then return nil end
	local base = target and target.target and parsed_.nodes[target.target]
	local owner = base and base.callee
	return owner and (owner .. "." .. field) or field
end

---@param context lye.plugin.TokenContext
---@return lye.plugin.Span[]
function ffiPlugin.tokens(context)
	local parsed_, text, map = context.parsed, context.text, context.map
	local spans = {}
	-- The calls of the document, from the index the parser keeps: a plugin is asked about
	-- the same document on every keystroke, and walking every node to find a call is the walk
	-- this one is over.
	for _, node in ipairs(parsed_.byKind.call or {}) do
		if node.kind == "call" and node.args and node.args[1] then
			if callNameOf(context, node) == "ffi.cdef" then
				local argument = parsed_.nodes[node.args[1]]
				if argument and argument.kind == "string" and type(argument.value) == "string" then
					local from = cdef.textStart(text, argument.start, argument.stop)
					for _, span in ipairs(blockOf(argument.value).spans) do
						local kind = DECLARED[span.kind]
						local first, last = from + span.start - 1, from + span.stop - 1
						-- What lye read out of text a lowering plugin wrote has no place in the
						-- document, and a block the plugin wrote is one lye should not colour.
						if kind and not map:rangeIsWritten(first, last) then
							local at, stop = map:toOriginalRange(first, last)
							spans[#spans + 1] = { from = at, to = stop, type = kind }
						end
					end
				end
			end
		end
	end
	return spans
end

--- What a call that names a C type is worth: `ffi.new("Vec")` and `ffi.cast("Vec", v)` hand back
--- a Vec, `ffi.typeof("Vec")` hands back the ctype, and `ffi.load("curl")` hands back the functions
--- the file's blocks declared. Only names the blocks introduced resolve; `ffi.new("int")` is a
--- number, which the definitions already say.
---@param cdefs lye.cdef.Namespace[]
---@param resolve fun(name: string): lye.doc.Type?
---@param parsed_ lye.parser.Result
---@param callName fun(node: lye.parser.Node): string?
local function providersOf(cdefs, resolve, parsed_, callName)
	---@param written string
	---@return lye.cdef.Type?
	---@return lye.cdef.Namespace?
	local function cTypeNamed(written)
		for _, declared in ipairs(cdefs) do
			local found = cdef.typeOf(declared, written)
			if found then return found, declared end
		end
	end

	--- What a Lua function handed to `ffi.cast` has to be. The value really is a C function
	--- pointer at runtime, so the callback's parameters are the C ones and its result is converted
	--- back into the C type — which is what makes `buf:putcdata(ptr, len)` inside one the right
	--- thing to do and `size * nmemb` a number.
	---@param written string the type the cast names
	---@return lye.cdef.Type?
	---@return lye.cdef.Namespace?
	local function cTypeOfCallback(written)
		local found, declared = cTypeNamed(written)
		if not found then return nil end
		if found.kind == "function" then return found, declared end
		if found.kind == "pointer" and found.target and found.target.kind == "function" then
			return found.target, declared
		end
		-- A typedef of a callback: `curl_write_callback` is one.
		local resolved = cdef.resolve(declared, found.name or written)
		if resolved and resolved.kind == "pointer" and resolved.target
			and resolved.target.kind == "function" then
			return resolved.target, declared
		end
		if resolved and resolved.kind == "function" then return resolved, declared end
	end

	--- The C signature of each function literal written as a callback, by the node that is the
	--- function, and the type each of its parameters was declared as. An anonymous function has no
	--- declaration of its own to hang them on, so the parameter object is the key.
	---@type table<lye.parser.Declaration, lye.doc.Type>
	local callbackParams = {}
	---@type table<integer, lye.doc.Type>
	local callbackReturns = {}
	for _, node in ipairs(parsed_.byKind.call or {}) do
		if node.args and node.args[2] then
			local called = callName(node)
			if called == "ffi.cast" or called == "ffi.new" then
				local written = parsed_.nodes[node.args[1]]
				local body = parsed_.nodes[node.args[2]]
				if written and written.kind == "string" and type(written.value) == "string"
					and body and body.kind == "function" then
					local signature, declared = cTypeOfCallback(written.value)
					if signature then
						for index, param in ipairs(body.params or {}) do
							local wanted = signature.params and signature.params[index]
							if wanted then
								callbackParams[param] = types.parse(
									cdef.notation(declared, wanted, "parameter"), resolve)
							end
						end
						-- The engine converts what the callback returns into the C result type, so
						-- the C says what the body has to give — a promise like a `@return`.
						local returned = signature.returns
						if returned then
							callbackReturns[node.args[2]] = types.parse(
								cdef.notation(declared, returned), resolve)
						end
					end
				end
			end
		end
	end

	--- The signatures the file's `ffi.cdef`s declared, as the fields a `ffi.load` gives back. A
	--- cdef declares the functions of one library, and the file that wrote it is the one that
	--- knows them: taking every symbol the process has ever seen would be a list nobody can read.
	local loaded
	---@return lye.doc.Type?
	local function loadedSymbols()
		if loaded ~= nil then return loaded or nil end
		local fields = {}
		for _, declared in ipairs(cdefs) do
			for _, name in ipairs(declared.order) do
				local type = declared.types[name]
				if type and type.kind == "function" then
					local parts = {}
					for _, param in ipairs(type.params or {}) do
						parts[#parts + 1] = cdef.notation(declared, param, "parameter")
					end
					if type.variadic then parts[#parts + 1] = "..." end
					local returned = type.returns and cdef.notation(declared, type.returns)
					local written = "fun(" .. table.concat(parts, ", ") .. ")"
					if returned and returned ~= "nil" then written = written .. ": " .. returned end
					local held = types.parse(written, resolve)
					if held then fields[name] = held end
				end
			end
		end
		loaded = next(fields) and types.object(fields) or false
		return loaded or nil
	end

	---@param node lye.parser.Node
	---@return lye.doc.Type?
	local function cTypeOf(node)
		local called = callName(node)
		if called == "ffi.load" then return loadedSymbols() end
		if called ~= "ffi.new" and called ~= "ffi.cast" and called ~= "ffi.typeof" then return nil end
		local argument = node.args and node.args[1] and parsed_.nodes[node.args[1]]
		if not argument or argument.kind ~= "string" or type(argument.value) ~= "string" then return nil end
		local found, declared = cTypeNamed(argument.value)
		if not found then return nil end
		-- A struct, a union, an enum or a typedef of one is a class this file declares, and looking the
		-- name up lets the document's own class win over the generated one. Everything else is mapped.
		local className = cdef.className(found)
		local named = className and resolve(className)
		if named and (found.kind == "struct" or found.kind == "union" or found.kind == "enum"
			or (found.kind == "typedef" and cdef.resolve(declared, found.name or "") ~= nil)) then
			return named
		end
		return types.parse(cdef.notation(declared, found), resolve)
	end

	local answer = {}
	answer.call = cTypeOf
	-- `ffi.C` reaches the functions the file's own blocks declared, and the name is what says so:
	-- the far side is read the way `ffi.cdef`, `ffi.new` and `ffi.load` are, since a file that
	-- requires `ffi` has that name for it whether or not the definitions reach the table.
	answer.field = function(_, baseName, field)
		if field == "C" and baseName == "ffi" then return loadedSymbols() end
	end
	answer.parameter = function(declaration) return callbackParams[declaration] end
	answer.callbackReturns = callbackReturns
	return answer
end

---@param context lye.plugin.TypeContext
---@return lye.plugin.Types?
function ffiPlugin.types(context)
	local source, parsed_, callName = context.source, context.parsed, context.callName
	-- Only a file that writes the word can be declaring C, and the scan is per node: reading the
	-- text first is what keeps a file that declares nothing from paying for the search.
	if not source:find("cdef", 1, true) then return nil end
	local cdefs, files, diagnostics = {}, {}, {}
	for _, node in ipairs(parsed_.byKind.call or {}) do
		if callName(node) == "ffi.cdef" then
			local argument = node.args and node.args[1] and parsed_.nodes[node.args[1]]
			if argument and argument.kind == "string" and type(argument.value) == "string" then
				local held = blockOf(argument.value)
				cdefs[#cdefs + 1] = held.declared
				files[#files + 1] = held.annotations
				-- A declaration that could not be read is reported inside the string, so the
				-- offsets the parser gives have to be mapped before they mean anything. What *was*
				-- readable is still used.
				for _, problem in ipairs(held.declared.problems) do
					local at = cdefTextStart(source, argument, problem.start)
					diagnostics[#diagnostics + 1] = {
						message = "cdef: " .. problem.message,
						severity = 1,
						start = at,
						stop = at + math.max(problem.stop - problem.start, 0),
					}
				end
			end
		end
	end
	if #cdefs == 0 then return nil end
	return {
		annotations = files,
		diagnostics = diagnostics,
		attach = function(resolve)
			return providersOf(cdefs, resolve, parsed_, callName)
		end,
	}
end

return ffiPlugin
