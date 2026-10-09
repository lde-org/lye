--[[
	The lye language server: wires the protocol layer to the Lua tooling.
]]

local rpc = require("lye-rpc")
local framework = require("lye-framework")
local position = require("lye-framework.position")
local json = require("lye-json")
local Parser = require("lye-parser")
local analyzer = require("lye-analyzer")
local KIND = require("lye-lexer").KIND
local types = require("lye-doc.type")

local SYMBOL_KIND = { ["function"] = 12, variable = 13 }

local TOKEN_LEGEND = {
	tokenTypes = { "keyword", "string", "number", "comment", "operator", "variable", "function", "parameter" },
	tokenModifiers = {},
}

local TOKEN_TYPE = {}
for index, name in ipairs(TOKEN_LEGEND.tokenTypes) do
	TOKEN_TYPE[name] = index - 1
end

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
---@return lye.parser.Result?
function Lye:analyze(uri)
	local document = self.server.documents:get(uri)
	if not document then return nil end

	local result = Parser.new(document.text):parse()
	local names = analyzer.analyze(document.text)
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
			severity = 1,
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

---@return lye.lexer.Token?
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

---@param self lye.Server
---@return table?
function Lye:onHover(params)
	local uri, text, index, result, offset = self:resolvePosition(params)
	if not uri then return nil end

	local declaration = declarationFor(result, offset)
	if not declaration then return nil end

	local qualifier = declaration.qualifier == "param" and "parameter" or declaration.qualifier
	local variable = result.byStart[declaration.start]
	local shown = variable and types.display(analyzer.typeAt(result, variable, offset)) or "unknown"
	local origin = variable and variable.declared and "declared" or "inferred"

	return {
		contents = {
			kind = "markdown",
			value = string.format("```lua\n%s: %s\n-- %s, %s\n```", declaration.name, shown, qualifier, origin),
		},
		range = self:toRange(text, index, declaration.start, declaration.stop),
	}
end

---@param self lye.Server
---@return table?
function Lye:onDefinition(params)
	local uri, text, index, result, offset = self:resolvePosition(params)
	if not uri then return nil end

	local target = declarationFor(result, offset)
	if not target then return nil end

	return {
		uri = uri,
		range = self:toRange(text, index, target.start, target.stop),
	}
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

	local data, count = json.array(), 0
	local lastLine, lastStart = 0, 0
	local isFirst = true

	local tokens = result.tokens
	for at = 1, tokens.count do
		local token = tokens.arena[at]
		local written = tokens.texts[at]
		local target
		if token.kind == KIND.keyword then
			target = "keyword"
		elseif token.kind == KIND.string then
			target = "string"
		elseif token.kind == KIND.number then
			target = "number"
		elseif token.kind == KIND.comment then
			target = "comment"
		elseif token.kind == KIND.symbol and written ~= "::" and written ~= "label" then
			target = "operator"
		elseif token.kind == KIND.name then
			target = kinds[token.start] or "variable"
		end

		if target then
			local line, start = position.toPosition(text, index, token.start, encoding)
			local stopCharacter = select(2, position.toPosition(text, index, token.stop + 1, encoding))
			local deltaLine = isFirst and line or (line - lastLine)
			local deltaStart = isFirst and start or (deltaLine == 0 and (start - lastStart) or start)

			count += 1
			data[count] = deltaLine
			count += 1
			data[count] = deltaStart
			count += 1
			data[count] = math.max(stopCharacter - start, 1)
			count += 1
			data[count] = TOKEN_TYPE[target]
			count += 1
			data[count] = 0

			lastLine, lastStart, isFirst = line, start, false
		end
	end

	return { data = data }
end

local COMPLETION_KIND = { ["function"] = 3, variable = 6 }

---@param self lye.Server
---@return table
function Lye:onCompletion(params)
	local uri = params.textDocument?.uri
	local document = uri and self.server.documents:get(uri)
	if not uri or not document or not self.names[uri] then return { isIncomplete = false, items = json.array() } end

	local offset = position.toOffset(
		document.text, document.lineIndex, params.position.line, params.position.character, self.server.encoding
	)

	local items, seen = json.array(), {}
	for _, variable in ipairs(analyzer.visibleAt(self.names[uri], offset)) do
		if not seen[variable.name] then
			seen[variable.name] = true
			local shown = types.display(analyzer.typeAt(self.names[uri], variable, offset))
			items[#items + 1] = {
				label = variable.name,
				kind = COMPLETION_KIND[shown] or COMPLETION_KIND.variable,
				detail = shown,
			}
		end
	end

	for _, keyword in ipairs(Parser.KEYWORD_LIST) do
		if not seen[keyword] then
			seen[keyword] = true
			items[#items + 1] = { label = keyword, kind = 14 }
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

---@param self lye.Server
function Lye:register()
	local server = self.server
	local method = framework.METHOD

	server:capability("hoverProvider", true)
	server:capability("definitionProvider", true)
	server:capability("documentSymbolProvider", true)
	server:capability("semanticTokensProvider", { legend = TOKEN_LEGEND, full = true })
	server:capability("completionProvider", { triggerCharacters = { "." } })

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
