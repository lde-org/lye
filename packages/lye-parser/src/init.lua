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
---@field position integer? which name of its statement this is, 1 for the first
---@field valuePosition integer? which value of its initializer this name takes, 1 unless the last expression gives several

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
---@field KIND table? the lexical kinds, as the lexer names them
---@field MAX_DIAGNOSTICS integer? how many problems are kept before the rest are dropped
---@field KEYWORD_LIST string[] the reserved words, in the order they are written
---@field KEYWORDS table<string, boolean>? the same set, for lookup
---@field UNARY string[]? the operators that take one operand
---@field BINARY string[][] those that take two, grouped by precedence
---@field BINARY_LEVEL table<integer, string[]>? those operators grouped by precedence
---@field COMPOUND table<string, boolean>? the assignments that also compute: `+=`, `..=`
---@field source string
---@field tokens lye.lexer.Tokens
---@field arena lye.lexer.ffi.token[]
---@field texts string[]
---@field tokenCount integer
---@field index integer
---@field diagnostics lye.parser.Diagnostic[]
---@field nodes lye.parser.Node[]
---@field declarations lye.parser.Declaration[]
---@field depth integer
---@field scopes string[][]
---@field count_ integer how many nodes have been emitted, which the next one's index is
---@field tableFieldValues table<integer, table>?
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

---@class lye.parser.Resume
---@field from integer the byte a statement starts at, where scanning resumes
---@field tokenIndex integer the token that statement starts with
---@field nodeCount integer how many nodes were emitted before it
---@field chunkIndex integer the chunk node of the parse being continued
---@field tokens lye.lexer.Tokens
---@field nodes lye.parser.Node[]
---@field declarations lye.parser.Declaration[]
---@field scopes lye.parser.Scope[]
---@field tableFields table
---@field tableFieldValues table
---@field tableIndexes table

---@param source string
---@param resume lye.parser.Resume? a parse to carry on from, when the text before it is unchanged
function Parser.new(source, resume)
	local tokens = resume and lexer.resume(source, resume.from, resume.tokens) or lexer.tokenize(source)
	local self = setmetatable({
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
	if not resume then return self end

	-- The same nodes at the same indices spanning the same bytes, which is what lets the passes
	-- above reuse what they worked out for them.
	local nodes, keep = resume.nodes, resume.nodeCount
	for index = 1, keep do
		local node = nodes[index]
		-- The old chunk is not kept, so its statements answer as parentless and the new one takes them.
		if node.parent == resume.chunkIndex then node.parent = nil end
		self.nodes[index] = node
	end
	self.index = resume.tokenIndex
	self.count_ = keep
	self.declarations = resume.declarations
	self.scopes_ = resume.scopes
	self.tableFields = resume.tableFields
	self.tableFieldValues = resume.tableFieldValues
	self.tableIndexes = resume.tableIndexes
	return self
end

--- Where a parse could carry on from if `offset` changed, or nil when nothing is gained.
--- A top-level statement is the unit: statements share no state, so the ones before the change can
--- be kept whole. Their node count is found by span, because emission follows the source.
---@param parsed lye.parser.Result
---@param offset integer the byte the change starts at
---@return lye.parser.Resume?
function Parser.resumeAt(parsed, offset)
	local nodes = parsed.nodes
	local chunk = nodes[parsed.root]
	local statements = chunk and chunk.children
	if not statements then return nil end

	-- The last statement that begins at or before the change, which is the one holding it or the
	-- one it was written after. It has to begin before, not merely end after: an edit in the
	-- comments above a statement is inside the text the scan would otherwise keep.
	-- A nested statement is met part-way through the block holding it and that state is gone, and
	-- the chunk's children are not all statements, so the depth is what says which are.
	local first
	for _, childIdx in ipairs(statements) do
		local node = nodes[childIdx]
		if node and node.depth == 0 and node.start <= offset then first = node end
	end
	if not first then return nil end

	local keep = 0
	while keep < #nodes and nodes[keep + 1].stop < first.start do keep += 1 end
	if keep == 0 then return nil end

	local found, low, high = nil, 1, parsed.tokens.count
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if parsed.tokens.arena[mid].start >= first.start then
			found = mid
			high = mid - 1
		else
			low = mid + 1
		end
	end
	if not found or parsed.tokens.arena[found].start ~= first.start then return nil end

	-- The lists a parse builds run to the end of the file, so keeping them whole would count the
	-- suffix twice.
	---@param list table[]
	---@return table[]
	local function before(list)
		local held = {}
		for _, entry in ipairs(list or {}) do
			if (entry.start or 0) < first.start then held[#held + 1] = entry end
		end
		return held
	end
	---@param keyed table<integer, unknown>
	---@return table<integer, unknown>
	local function indexed(keyed)
		local held = {}
		for key, value in pairs(keyed or {}) do
			if type(key) == "number" and key <= keep then held[key] = value end
		end
		return held
	end

	return {
		from = first.start, tokenIndex = found, nodeCount = keep, chunkIndex = parsed.root,
		tokens = parsed.tokens, nodes = nodes, declarations = before(parsed.declarations),
		scopes = before(parsed.scopes), tableFields = indexed(parsed.tableFields),
		tableFieldValues = indexed(parsed.tableFieldValues), tableIndexes = indexed(parsed.tableIndexes),
	}
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
--- Whether a token is a name a reader may write. `const` and `continue` are words this parser
--- knows — a `const` parameter and a `continue` statement — but Lua has neither, so both are
--- ordinary identifiers wherever a name is wanted: `{ const = true }` is a table, and reading the
--- first field as something else left the rest of the table parsed as statements.
---@param token lye.lexer.ffi.token
---@return boolean
function Parser:isName(token)
	if token.kind == lexer.KIND.name then return true end
	if token.kind ~= lexer.KIND.keyword then return false end
	local text = self.texts[token.index]
	return text == "const" or text == "continue" or text == "goto"
end

function Parser:parseName()
	local token = self:peek()
	if self:isName(token) then
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
---@param position integer? which name of its statement this is, so a `---@type A, B` above two names is read one type per name
---@return lye.parser.Declaration
function Parser:declare(name, qualifier, token, isFunction, position)
	local declaration = {
		name = name,
		qualifier = qualifier,
		start = token.start,
		stop = token.stop,
		depth = self.depth,
		isFunction = isFunction,
		position = position,
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

	-- The text the tree was read from, so a reader that wants what a node *spells* — the exact
	-- literal a condition compared against, say — does not have to be handed it separately.
	return {
		root = chunkIdx,
		source = self.source,
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
