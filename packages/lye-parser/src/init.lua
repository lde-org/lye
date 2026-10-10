--- Recursive descent parser for LuaJIT and its 3.0 backports. `Parser.new(source):parse()`
--- lexes and parses once and returns tokens, nodes, scopes and declarations together.

local lexer = require("lye-lexer")

---@alias lye.parser.Qualifier "local"|"global"|"field"|"param"|"loop"|"label"

---@alias lye.parser.NodeKind

---@class lye.parser.Diagnostic
---@field message string
---@field start integer
---@field stop integer

---@class lye.parser.Node
---@field kind lye.parser.NodeKind
---@field index integer position in the arena, which is how nodes refer to each other
---@field parent integer? index of the node being built when this one was emitted
---@field start integer
---@field stop integer
---@field depth integer scope nesting, 0 at the top level
---@field isFunction boolean?
---@field op string? the operator, for a binary or unary node
---@field left integer? operand index, for a binary node
---@field right integer? operand index, for a binary node
---@field target integer? the expression an index or call applies to
---@field field string? the field an index reads
---@field callee string? the name a call invokes
---@field args integer[]? the argument node indices of a call
---@field params lye.parser.Declaration[]? the parameters a function node declares, `self` first

---@class lye.parser.Declaration
---@field name string
---@field qualifier lye.parser.Qualifier
---@field start integer
---@field stop integer
---@field depth integer
---@field isFunction boolean? the name declares a function, not a value
---@field initializer string? kind of the expression it was assigned
---@field valueIdx integer? arena index of the assigned expression
---@field anchorIdx integer? token index of the statement opening the declaration

--- A scope is guarded by a condition when the block only runs under one, as `if`/`while`
--- bodies do.
---@class lye.parser.Scope
---@field start integer
---@field stop integer
---@field depth integer scope nesting, 1 at the top level
---@field branch string? "then"|"elseif"|"else"|"do"|"body"
---@field conditionIdx integer? arena index of the expression guarding this block

---@class lye.parser.Result
---@field root integer index of the chunk node, which contains everything
---@field scopes lye.parser.Scope[]
---@field tableFields table<integer, table<string, string>> field kinds, keyed by table node
---@field tokens lye.lexer.Tokens
---@field nodes lye.parser.Node[]
---@field declarations lye.parser.Declaration[]
---@field diagnostics lye.parser.Diagnostic[]

---@class lye.parser.Frame
---@field start integer
---@field conditionIdx integer?

---@class lye.parser.Parser
---@field source string
---@field tokens lye.lexer.Tokens
---@field arena lye.lexer.ffi.token*
---@field texts string[]
---@field tokenCount integer
---@field index integer
---@field diagnostics lye.parser.Diagnostic[]
---@field nodes lye.parser.Node[]
---@field declarations lye.parser.Declaration[]
---@field depth integer
---@field scopes string[][]
---@field lastKind string?
---@field lastDeclaration integer?
---@field scopeStarts lye.parser.Frame[]
---@field scopes_ lye.parser.Scope[]
---@field tableFields table<integer, table<string, string>> field kinds per table literal
---@field tableIndexes table<integer, integer[]> positional element indices per table literal
local Parser = {}
Parser.KIND = lexer.KIND

--- The tokens that close a block. One list, not a table built per question.
local BLOCK_END = { "end", "else", "elseif", "until" }
Parser.__index = Parser

Parser.MAX_DIAGNOSTICS = 25

Parser.KEYWORD_LIST = {}
for word in string.gmatch("and break do else elseif end false for function if in local nil not or repeat return then true until while const continue", "%S+") do
	Parser.KEYWORD_LIST[#Parser.KEYWORD_LIST + 1] = word
end
table.sort(Parser.KEYWORD_LIST)

Parser.KEYWORDS = {}
for word in string.gmatch("and break do else elseif end false for function if in local nil not or repeat return then true until while const continue", "%S+") do
	Parser.KEYWORDS[word] = true
end

Parser.UNARY = { "-", "not", "#", "~", "!" }

Parser.BINARY = {
	{ "??" },
	{ "or", "||" },
	{ "and", "&&" },
	{ "<", ">", "<=", ">=", "~=", "==", "!=" },
	{ "|" },
	{ "~" },
	{ "&" },
	{ "<<", ">>", "~>>" },
	{ ".." },
	{ "+", "-" },
	{ "*", "/", "%" },
	{ "^" },
}

Parser.BINARY_LEVEL = {}
for level, group in ipairs(Parser.BINARY) do
	for _, symbol in ipairs(group) do
		Parser.BINARY_LEVEL[symbol] = level
	end
end

Parser.COMPOUND = {}
for _, symbol in ipairs({"+=", "-=", "*=", "/=", "%=", "^=", "..=", "|=", "&=", "~=", "<<=", ">>=", "~>>="}) do
	Parser.COMPOUND[symbol] = true
end

---@return lye.parser.Parser
function Parser.new(source)
	local tokens = lexer.tokenize(source)
	return setmetatable({
		source = source,
		tokens = tokens,
		arena = tokens.arena,
		texts = tokens.texts,
		tokenCount = tokens.count,
		index = 1,
		-- A literal the scanner could not finish is a syntax error like any other, and the
		-- tokens the scan recovered from are what the tree is built on.
		diagnostics = tokens.problems,
		nodes = {},
		declarations = {},
		depth = 0,
		scopes = { {} },
		scopeStarts = {},
		scopes_ = {},
		tableFields = {},
		tableFieldValues = {},
		tableIndexes = {},
		count_ = 0,
		building = {},
		lastKind = nil,
	}, Parser)
end

---@return lye.lexer.ffi.token?
function Parser:peek()
	return self.arena[self.index]
end

--- A token's text lives beside the arena, keyed by the token's own index, so a reader holding
--- a token needs nothing else.
---@param token lye.lexer.ffi.token
---@return string
function Parser:text(token)
	return self.texts[token.index]
end

---@param token lye.lexer.ffi.token
---@return string
function Parser:variant(token)
	return lexer.variantOf(token)
end

---@return boolean
function Parser:isEof(token)
	return not token or token.kind == lexer.KIND.eof
end

---@return lye.lexer.ffi.token
function Parser:peekAt(ahead)
	return self.arena[self.index + ahead - 1] or self.arena[self.tokenCount]
end

function Parser:advance()
	local token = self.arena[self.index]
	if token.kind ~= lexer.KIND.eof then self.index += 1 end
	return token
end

---@return boolean
function Parser:check(text)
	local token = self:peek()
	return token.kind ~= lexer.KIND.eof and self.texts[token.index] == text
end

---@return boolean
function Parser:accept(text)
	if self:check(text) then
		self:advance()
		return true
	end
	return false
end

---@return boolean
function Parser:checkAny(candidates)
	local text = self:text(self:peek())
	for _, candidate in ipairs(candidates) do
		if text == candidate then return true end
	end
	return false
end

function Parser:report(token, message)
	if #self.diagnostics >= Parser.MAX_DIAGNOSTICS then return end
	self.diagnostics[#self.diagnostics + 1] = { message = message, start = token.start, stop = token.stop }
end

---@return boolean
function Parser:expect(text)
	if self:accept(text) then return true end
	self:report(self:peek(), string.format("expected '%s'", text))
	return false
end

--- Nodes live in a flat arena and refer to each other by index. A recursive tree would be a
--- table per node on the Lua heap; an arena is one array, is cache friendly, and maps onto an
--- FFI struct array when the parser is ported.
---
--- The parent is recorded at emission, because that is the only moment it is known: the node
--- being built is whatever is on top of `building`.
--- `childIdxs` lists the nodes this one directly contains. It is passed explicitly rather
--- than derived from spans: an operand and its operator share a start offset, so no span
--- heuristic can tell which contains which, and guessing produced cycles.
---@param kind lye.parser.NodeKind
---@param start integer
---@param stop integer
---@param fields table?
---@param ... integer idx the nodes this one contains, which are re-parented to it
---@return integer idx
function Parser:emit(kind, start, stop, fields, ...)
	self.count_ = self.count_ + 1
	local parent = self.building[#self.building]
	local node = {
		kind = kind, start = start, stop = stop, depth = self.depth,
		index = self.count_, parent = parent,
	}
	if fields then
		for key, value in pairs(fields) do
			node[key] = value
		end
	end
	self.nodes[self.count_] = node
	-- The operands were emitted before the node that contains them, so each one is re-parented
	-- here. Nothing reads a node's own child list, and a list per node is a table per node, so
	-- the indices arrive as arguments and only the parent link is kept.
	for index = 1, select("#", ...) do
		local childIdx = select(index, ...)
		local child = childIdx and self.nodes[childIdx]
		if child and childIdx ~= self.count_ then child.parent = self.count_ end
	end
	if parent then
		local owner = self.nodes[parent]
		owner.children = owner.children or {}
		owner.children[#owner.children + 1] = self.count_
	end
	return self.count_
end

--- Re-parent a list of already-emitted nodes onto one that contains them. `unpack` is not
--- usable here: it stops at a few thousand values, so a list of arguments or statements has to
--- be walked.
---@param parentIdx integer
---@param childIdxs integer[]
function Parser:adopt(parentIdx, childIdxs)
	local children = self.nodes[parentIdx].children
	for _, childIdx in ipairs(childIdxs) do
		local child = self.nodes[childIdx]
		if child and childIdx ~= parentIdx then
			child.parent = parentIdx
			children = children or {}
			children[#children + 1] = childIdx
		end
	end
	self.nodes[parentIdx].children = children
end

--- A comment can sit anywhere a token can, including inside a table's field list, as LuaLS's
--- definitions write `---@type Proto[]` between two fields. Expressions and fields step over one;
--- annotations are read from their own offsets, so nothing depends on the parser stopping at them.
function Parser:skipComments()
	while true do
		local token = self:peek()
		if not token or token.kind ~= lexer.KIND.comment then return end
		self:advance()
	end
end

--- Open a node that expressions emitted before it closes become children of.
---@param index integer
function Parser:enter(index)
	self.building[#self.building + 1] = index
end

---@return integer? index the node that was being built
function Parser:leave()
	local index = self.building[#self.building]
	self.building[#self.building] = nil
	return index
end

--- An identifier. `goto` counts, because LuaJIT keeps it a soft keyword: it only starts a
--- statement when a name follows, so anywhere a name is expected it is a name.
---@return string?
---@return lye.lexer.ffi.token?
function Parser:parseName()
	local token = self:peek()
	if token.kind == lexer.KIND.name or self.texts[token.index] == "goto" then
		self:advance()
		return self.texts[token.index], token
	end
	self:report(token, "expected a name")
	return nil, token
end

function Parser:setInitializer(index, kind, valueIdx)
	local declaration = self.declarations[index]
	if not declaration then return end
	declaration.initializer = kind
	declaration.valueIdx = valueIdx
end

---@param name string
---@param qualifier lye.parser.Qualifier
---@param token lye.lexer.ffi.token
---@param isFunction boolean?
---@return lye.parser.Declaration
function Parser:declare(name, qualifier, token, isFunction)
	local declaration = {
		name = name,
		qualifier = qualifier,
		start = token.start,
		stop = token.stop,
		depth = self.depth,
		isFunction = isFunction,
	}
	-- The initializer is parsed *after* the name, so the kind is recorded later by
	-- `setInitializer` via the index returned here.
	declaration.initializer = isFunction and "function" or nil
	self.declarations[#self.declarations + 1] = declaration
	self.lastDeclaration = #self.declarations
	self.lastLiteral = nil
	local scope = self.scopes[#self.scopes]
	scope[#scope + 1] = name
	return declaration
end

function Parser:pushScope(start, conditionIdx)
	assert(start, "pushScope needs the scope's start offset")
	self.depth += 1
	self.scopes[#self.scopes + 1] = {}
	self.scopeStarts[#self.scopeStarts + 1] = { start = start, conditionIdx = conditionIdx }
end

function Parser:popScope(stop, kind)
	self.scopes[#self.scopes] = nil
	local frame = self.scopeStarts[#self.scopeStarts]
	self.scopeStarts[#self.scopeStarts] = nil
	if frame then
		self.scopes_[#self.scopes_ + 1] = {
			kind = "scope", branch = kind, start = frame.start, stop = stop, depth = self.depth,
			conditionIdx = frame.conditionIdx,
		}
	end
	self.depth -= 1
end

---@return boolean
function Parser:isBlockEnd()
	local token = self:peek()
	if token.kind == lexer.KIND.eof then return true end
	return self:checkAny(BLOCK_END)
end

---@return lye.parser.Result
function Parser:parse()
	self:parseBlock()

	local last = self.arena[self.index]
	if last and last.kind ~= lexer.KIND.eof then
		self:report(last, string.format("unexpected '%s'", self.texts[last.index]))
	end

	local eof = self.arena[self.tokenCount]
	-- The chunk's children are the statements, which are the nodes still without a parent.
	local topLevel = {}
	for _, node in ipairs(self.nodes) do
		if not node.parent and node.kind ~= "chunk" then topLevel[#topLevel + 1] = node.index end
	end
	local chunkIdx = self:emit("chunk", 1, eof.stop, nil)
	-- The chunk is emitted last, so its statements are adopted afterwards rather than appended
	-- as they were parsed. Adopting walks them rather than unpacking them: `unpack` gives up past
	-- a few thousand values, and a generated file can have that many statements.
	self:adopt(chunkIdx, topLevel)
	self.rootIdx = chunkIdx

		return {
		root = chunkIdx,
		scopes = self.scopes_,
		tableFields = self.tableFields,
		tableFieldValues = self.tableFieldValues,
		tableIndexes = self.tableIndexes,
		tokens = self.tokens,
		nodes = self.nodes,
		declarations = self.declarations,
		diagnostics = self.diagnostics,
	}
end

-- Published before the grammar loads: `require` returns `package.loaded[name]` when it is
-- already set, so the grammar modules can require this one while it is still running and
-- inject their methods onto the same table.
package.loaded["lye-parser"] = Parser

require("lye-parser.expressions")
require("lye-parser.statements")

return Parser
