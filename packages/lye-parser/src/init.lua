--- Recursive descent parser for LuaJIT and its 3.0 backports. `Parser.new(source):parse()`
--- lexes and parses once and returns tokens, nodes, scopes and declarations together.

local lexer = require("lye-lexer")
local newTable = require("table.new")

---@alias lye.parser.Qualifier "local"|"global"|"field"|"param"|"loop"|"label"

---@alias lye.parser.NodeKind

---@class lye.parser.Diagnostic
---@field message string
---@field start integer
---@field stop integer
---@field statementStart integer? the byte the top-level statement that reported it began at

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
---@field isSafe boolean? the suffix was written `?.`, so a nil target passes through
---@field field string? the field an index reads
---@field callee string? the name a call invokes
---@field args integer[]? the argument node indices of a call
---@field params lye.parser.Declaration[]? the parameters a function node declares, `self` first
---@field value string|number|boolean? what a literal node stands for, or the value index of an assignment
---@field children integer[]? the nodes inside this one, by arena index
---@field targets integer[]? every assignment target, for an assignment node
---@field targetValues integer[]? every assigned value, for an assignment node
---@field targetPositions integer[]? which value each target takes, for an assignment node
---@field isMethod boolean? the call or declaration is written with `:`
---@field isDynamic boolean? an index whose key is an expression rather than a name
---@field isCall boolean? a call suffix
---@field isNumeric boolean? a table key is written as a number
---@field name string? a name node's text
---@field text string? a literal's source text
---@field operand integer? operand index, for a unary node
---@field key integer? key expression index, for a dynamic index
---@field group integer? parenthesis or call-group expression index
---@field body integer? body node index, for a function
---@field alternative integer? the else expression index of a ternary
---@field anchorIdx integer? token index of the statement opening a declaration
---@field inlineGenerics table? inline generic names on a function
---@field inlineVariadic boolean? the function declares an inline variadic parameter
---@field inlineVariadicStart integer? byte an inline variadic starts at
---@field inlineVariadicStop integer? byte an inline variadic stops at
---@field inlineReturns integer? number of inline returns
---@field inlineReturnsStart integer? byte inline returns start at
---@field inlineReturnsStop integer? byte inline returns stop at

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
---@field byKind table<string, lye.parser.Node[]> every node, listed under its kind, in emission order
---@field topLevel integer[] the statements of the chunk, by node index
---@field tokens lye.lexer.Tokens
---@field nodes lye.parser.Node[]
---@field declarations lye.parser.Declaration[]
---@field diagnostics lye.parser.Diagnostic[]
---@field resumeStats lye.parser.ResumeStats how much of the parse came from a previous one

---@class lye.parser.ResumeStats
---@field nodes integer nodes kept from the previous parse, 0 for a full parse
---@field tokens integer tokens kept from the previous scan, 0 for a full parse

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
---@field lastFields table<string, string>? the field kinds of the table just read
---@field lastDeclaration integer?
---@field statementStart integer? the byte the top-level statement now being parsed began at
---@field scopeStarts lye.parser.Frame[]
---@field scopes_ lye.parser.Scope[]
---@field tableFields table<integer, table<string, string>> field kinds per table literal
---@field tableIndexes table<integer, integer[]> positional element indices per table literal
---@field byKind table<string, lye.parser.Node[]> every node, listed under its kind, in emission order
local Parser = {}
Parser.KIND = lexer.KIND

--- What a kind with no nodes of its own answers with, so callers never test for nil.
local EMPTY_NODES = {}

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
---@field kind string what was kept: "statement", a run of top-level statements
---@field from integer the byte a statement starts at, where scanning resumes
---@field tokenIndex integer the token that statement starts with
---@field nodeCount integer how many nodes were emitted before it
---@field chunkIndex integer the chunk node of the parse being continued
---@field tokens lye.lexer.Tokens
---@field nodes lye.parser.Node[]
---@field declarations lye.parser.Declaration[]
---@field scopes lye.parser.Scope[]
---@field diagnostics lye.parser.Diagnostic[] the parser's problems wholly before the resume point
---@field tableFields table
---@field tableFieldValues table
---@field tableIndexes table

---@param source string
---@param resume lye.parser.Resume? a parse to carry on from, when the text before it is unchanged
--- Whether a source marks itself a definition file. `---@meta` says the file describes a library
--- rather than running, and such a file writes its types where a reader sees them:
--- `function f(n: number)`, `function f<T: number>(x: T): string`.
---@param source string
---@param tokens lye.lexer.Tokens
---@return boolean
local function marksDefinition(source, tokens)
	-- A plain search first: nearly every file has no marker, and the scan below is per token.
	if not source:find("@meta", 1, true) then return false end
	for at = 1, tokens.count do
		local token = tokens.arena[at]
		if token.kind == lexer.KIND.comment
			and tokens.texts[token.index]:match("^%-%-%-?%s*@meta%f[%A]") then
			return true
		end
	end
	return false
end

function Parser.new(source, resume, definition)
	local tokens
	if resume then
		tokens = lexer.resume(source, resume.from, resume.tokens)
		-- A cut inside a literal has no token boundary to start from. The kept nodes and token
		-- indices belong to the old scan, so the parse starts over rather than build on tokens
		-- that no longer line up with the text.
		if not tokens then
			resume = nil
			tokens = lexer.tokenize(source)
		end
	else
		tokens = lexer.tokenize(source)
	end
	-- The scanner's problems are copied rather than appended to, so the parse's diagnostics and
	-- `tokens.problems` stay separate lists: a resumed parse reports its own after the carried
	-- ones, and a reader of the token list sees exactly what the scanner found.
	local diagnostics = {}
	for index = 1, #tokens.problems do diagnostics[index] = tokens.problems[index] end
	local self = setmetatable({
		source = source,
		tokens = tokens,
		arena = tokens.arena,
		texts = tokens.texts,
		tokenCount = tokens.count,
		index = 1,
		-- A literal the scanner could not finish is a syntax error like any other, and the
		-- tokens the scan recovered from are what the tree is built on.
		diagnostics = diagnostics,
		-- Nodes and declarations run to a fraction of the source: sizing the arrays from it saves
		-- the rehashes and copies of growing a table one node at a time.
		nodes = newTable(math.floor(#source / 12) + 16, 0),
		declarations = newTable(16, 0),
		depth = 0,
		scopes = { {} },
		scopeStarts = {},
		scopes_ = {},
		tableFields = {},
		tableFieldValues = {},
		tableIndexes = {},
		byKind = newTable(0, 16),
		count_ = 0,
		building = {},
		lastKind = nil,
		-- How much of this parse was taken from a previous one, which the caller reports. A
		-- full parse keeps nothing.
		resumeStats = { nodes = 0, tokens = 0 },
		-- A definition file may write its types inline. A `.d.lua` name says so, and a `---@meta`
		-- marker says it for any name.
		definition = definition == true or marksDefinition(source, tokens),
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
	self.resumeStats = { nodes = keep, tokens = resume.tokenIndex - 1 }
	-- The scanner's problems (kept by `lexer.resume` when they lie before the resume point, and
	-- found again after it) come first, in source order, then the parser's own. The problems the
	-- previous parse found before the resume point are stable text, so they are carried rather
	-- than dropped or duplicated by a second walk over the kept statements.
	--
	-- The capped list is a budget, not a filter: a cold parse seeds the scanner's findings first
	-- and then reports while there is room, and the previous parse kept the first reports its own
	-- budget allowed. So only the first carried reports that the new scan leaves room for are
	-- ones a cold parse of this text would still hold; carrying the rest leaves the resumed list
	-- with findings the cold list dropped. An edit that turns one unterminated literal into many
	-- scanner findings moves the budget under the kept prefix, and `resumeAt` guarantees the
	-- previous list is whole, so the kept reports are exactly that prefix.
	local diagnostics = self.diagnostics
	local carried = resume.diagnostics or {}
	local room = Parser.MAX_DIAGNOSTICS - #tokens.problems
	if room > #carried then room = #carried end
	for index = 1, room do diagnostics[#diagnostics + 1] = carried[index] end
	-- `byKind` is left to `parse`: it walks every node, kept ones included, so a list built here
	-- would hold each kept node twice.
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

	-- The last statement that begins before the change, which is the one holding it. It has to
	-- begin strictly before, not merely end after: an edit in the comments above a statement is
	-- inside the text the scan would otherwise keep, and text inserted exactly at a statement's
	-- first byte can still be read as a continuation of the statement before it — a trailing `,`
	-- belongs to the `local` above it, and `+ 2` on the next line continues the value. Starting
	-- one statement earlier leaves that continuation in the re-read text, where a full parse would
	-- have read it.
	-- A nested statement is met part-way through the block holding it and that state is gone, and
	-- the chunk's children are not all statements, so the depth is what says which are.
	local first
	for _, childIdx in ipairs(statements) do
		local node = nodes[childIdx]
		if node and node.depth == 0 and node.start < offset then first = node end
	end
	if not first then return nil end

	-- A problem at or after the cut can still belong to the statement before it: an argument list
	-- left open above goes on reading the tokens of the next statement, and reports its missing
	-- `)` on the first one it cannot use — the token the cut starts at. A parse beginning there
	-- has no list open, so it reports nothing and the tree would lose a problem the whole text
	-- has. The cut is only a boundary the previous parse saw if every problem from it on was
	-- reported by a statement it starts inside, which the owner recorded on each problem says.
	-- Where one was not, the cut moves back to that statement: read again whole, it finds the same
	-- problem again on the same text.
	local rewound = true
	while rewound do
		rewound = false
		for index = 1, #parsed.diagnostics do
			local diagnostic = parsed.diagnostics[index]
			local owner = diagnostic.statementStart
			if owner and owner < first.start and diagnostic.start >= first.start then
				-- The statement that began at `owner` is the cut. A statement that only recovered
				-- emits no node of its own, and there is no boundary to trust there: the parse is
				-- redone whole instead.
				local target
				for _, childIdx in ipairs(statements) do
					local node = nodes[childIdx]
					if node and node.depth == 0 and node.start == owner then
						target = node
						break
					end
				end
				if not target then return nil end
				first = target
				rewound = true
				break
			end
		end
	end

	local keep = 0
	while keep < #nodes and nodes[keep + 1].stop < first.start do keep += 1 end
	if keep == 0 then return nil end

	-- A capped list cannot be carried. `report` stops once the cap is reached, so a problem the
	-- previous parse found before the cut may simply be absent with nothing saying so, and a cold
	-- parse of the new text can have a larger budget — fewer scanner findings — and hold it again.
	-- The resumed parse cannot walk the kept text to find it, so the parse is redone whole. An
	-- uncapped list holds every problem the previous parse found, which is what makes its prefix
	-- the same prefix a cold parse reports.
	if #parsed.diagnostics >= Parser.MAX_DIAGNOSTICS then return nil end

	-- A problem wholly before the change is text that did not move, so the resumed parse keeps it
	-- rather than reporting it twice or losing it. One reaching the change could be about text
	-- that is being re-read, and nothing says the same problem would come out of the new parse, so
	-- there is no safe way to keep it: the whole parse is redone instead.
	local problems = parsed.tokens.problems or {}
	local carried = {}
	for index = 1, #parsed.diagnostics do
		local diagnostic = parsed.diagnostics[index]
		if diagnostic.start < first.start then
			if diagnostic.stop >= first.start then return nil end
			-- The scanner's problems are already carried by `lexer.resume`.
			if index > #problems then carried[#carried + 1] = diagnostic end
		end
	end

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
	-- The cut is a token boundary only when the token before it ends before it. A kept token that
	-- spans the cut is a literal or comment the new scan would start inside of, and `lexer.resume`
	-- refuses to continue such a prefix, so carrying one would make the resumed parse disagree
	-- with the text it was handed.
	if found > 1 and parsed.tokens.arena[found - 1].stop >= first.start then return nil end

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
		kind = "statement",
		from = first.start, tokenIndex = found, nodeCount = keep, chunkIndex = parsed.root,
		tokens = parsed.tokens, nodes = nodes, declarations = before(parsed.declarations),
		scopes = before(parsed.scopes), diagnostics = carried,
		tableFields = indexed(parsed.tableFields),
		tableFieldValues = indexed(parsed.tableFieldValues), tableIndexes = indexed(parsed.tableIndexes),
	}
end

---@return lye.lexer.ffi.token?
---@param self lye.parser.Parser
function Parser:peek()
	return self.arena[self.index]
end

--- A token's text lives beside the arena, keyed by the token's own index, so a reader holding
--- a token needs nothing else.
---@param token lye.lexer.ffi.token
---@return string
---@param self lye.parser.Parser
function Parser:text(token)
	return self.texts[token.index]
end

---@param token lye.lexer.ffi.token
---@return string
---@param self lye.parser.Parser
function Parser:variant(token)
	return lexer.variantOf(token)
end

---@param token lye.lexer.ffi.token?
---@return boolean
---@param self lye.parser.Parser
function Parser:isEof(token)
	return not token or token.kind == lexer.KIND.eof
end

---@param ahead integer
---@return lye.lexer.ffi.token
---@param self lye.parser.Parser
function Parser:peekAt(ahead)
	return self.arena[self.index + ahead - 1] or self.arena[self.tokenCount]
end

---@param self lye.parser.Parser
function Parser:advance()
	local token = self.arena[self.index]
	if token.kind ~= lexer.KIND.eof then self.index += 1 end
	return token
end

---@return boolean
--- Whether the next token worth reading is `text`. A comment is not worth reading: it is content
--- the annotation pass wants, but it is written between any two tokens — `f(a --[[t]], b)` and
--- `if x --[[ why ]] then` are both ordinary — so asking what comes next means asking past them.
---
--- The scan is written out here rather than going through `peek` and `skipComments`: this is the
--- question the parser asks more than any other, once or twice per token, and the call is most
--- of what it costs.
---@param text string
---@return boolean
---@param self lye.parser.Parser
function Parser:check(text)
	local arena, texts = self.arena, self.texts
	local index = self.index
	local token = arena[index]
	while token and token.kind == lexer.KIND.comment do
		index += 1
		token = arena[index]
	end
	self.index = index
	return token ~= nil and token.kind ~= lexer.KIND.eof and texts[token.index] == text
end

---@return boolean
---@param text string
---@param self lye.parser.Parser
function Parser:accept(text)
	local arena, texts = self.arena, self.texts
	local index = self.index
	local token = arena[index]
	while token and token.kind == lexer.KIND.comment do
		index += 1
		token = arena[index]
	end
	if token and token.kind ~= lexer.KIND.eof and texts[token.index] == text then
		self.index = index + 1
		return true
	end
	-- The comments stepped over are kept stepped over, as `skipComments` leaves them.
	self.index = index
	return false
end

---@param candidates string[]
---@return boolean
---@param self lye.parser.Parser
function Parser:checkAny(candidates)
	local arena, texts = self.arena, self.texts
	local index = self.index
	local token = arena[index]
	while token and token.kind == lexer.KIND.comment do
		index += 1
		token = arena[index]
	end
	self.index = index
	if not token or token.kind == lexer.KIND.eof then return false end
	local text = texts[token.index]
	for at = 1, #candidates do
		if text == candidates[at] then return true end
	end
	return false
end

---@param self lye.parser.Parser
function Parser:report(token, message)
	if #self.diagnostics >= Parser.MAX_DIAGNOSTICS then return end
	-- Which statement reported it, so a resume can tell a problem of the kept text from one the
	-- statement at the cut would report on its own.
	self.diagnostics[#self.diagnostics + 1] = {
		message = message, start = token.start, stop = token.stop, statementStart = self.statementStart,
	}
end

---@return boolean
---@param text string
---@param self lye.parser.Parser
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
---@param node table? the fields the node is emitted with, which become the node itself
---@param child1 integer? idx of a node this one contains, which is re-parented to it
---@param child2 integer?
---@param child3 integer?
---@return integer idx
---@param self lye.parser.Parser
function Parser:emit(kind, start, stop, node, child1, child2, child3)
	self.count_ = self.count_ + 1
	local index = self.count_
	local parent = self.building[#self.building]
	-- The caller's table *is* the node: a field table merged into a second one is an allocation
	-- and a walk per node, and the caller wrote the fields it has. Callers pass a fresh table.
	node = node or {}
	node.kind = kind
	node.start = start
	node.stop = stop
	node.depth = self.depth
	node.index = index
	node.parent = parent
	local nodes = self.nodes
	nodes[index] = node
	-- The operands were emitted before the node that contains them, so each one is re-parented
	-- here. Nothing reads a node's own child list, and a list per node is a table per node, so
	-- the indices arrive as arguments and only the parent link is kept. Three at most: a ternary
	-- has three operands, and a list of any length is adopted by `adopt`.
	if child1 and nodes[child1] then nodes[child1].parent = index end
	if child2 and nodes[child2] then nodes[child2].parent = index end
	if child3 and nodes[child3] then nodes[child3].parent = index end
	if parent then
		local owner = nodes[parent]
		local children = owner.children
		if children then
			children[#children + 1] = index
		else
			owner.children = { index }
		end
	end
	return index
end

--- Re-parent a list of already-emitted nodes onto one that contains them. `unpack` is not
--- usable here: it stops at a few thousand values, so a list of arguments or statements has to
--- be walked.
---@param parentIdx integer
---@param childIdxs integer[]
---@param self lye.parser.Parser
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
---@param self lye.parser.Parser
function Parser:skipComments()
	local arena = self.arena
	local index = self.index
	local token = arena[index]
	while token and token.kind == lexer.KIND.comment do
		index += 1
		token = arena[index]
	end
	self.index = index
end

--- Open a node that expressions emitted before it closes become children of.
---@param index integer
---@param self lye.parser.Parser
function Parser:enter(index)
	self.building[#self.building + 1] = index
end

---@return integer? index the node that was being built
---@param self lye.parser.Parser
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
---@param self lye.parser.Parser
function Parser:isName(token)
	if token.kind == lexer.KIND.name then return true end
	if token.kind ~= lexer.KIND.keyword then return false end
	local text = self.texts[token.index]
	return text == "const" or text == "continue" or text == "goto"
end

---@param self lye.parser.Parser
function Parser:parseName()
	local token = self:peek()
	if self:isName(token) then
		self:advance()
		return self.texts[token.index], token
	end
	self:report(token, "expected a name")
	return nil, token
end

---@param self lye.parser.Parser
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
---@param self lye.parser.Parser
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

---@param self lye.parser.Parser
function Parser:pushScope(start, conditionIdx)
	assert(start, "pushScope needs the scope's start offset")
	self.depth += 1
	self.scopes[#self.scopes + 1] = {}
	self.scopeStarts[#self.scopeStarts + 1] = { start = start, conditionIdx = conditionIdx }
end

---@param self lye.parser.Parser
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
---@param self lye.parser.Parser
function Parser:isBlockEnd()
	local token = self:peek()
	if token.kind == lexer.KIND.eof then return true end
	return self:checkAny(BLOCK_END)
end

--- The nodes of one kind in a parse, in emission order. A pass that only wants the calls or the
--- index reads walks those rather than every node in the document.
---@param parsed lye.parser.Result
---@param kind lye.parser.NodeKind
---@return lye.parser.Node[]
function Parser.nodesOf(parsed, kind)
	return parsed.byKind[kind] or EMPTY_NODES
end

---@return lye.parser.Result
---@param self lye.parser.Parser
function Parser:parse()
	self:parseBlock()

	local last = self.arena[self.index]
	if last and last.kind ~= lexer.KIND.eof then
		self:report(last, string.format("unexpected '%s'", self.texts[last.index]))
	end

	local eof = self.arena[self.tokenCount]
	-- The chunk's children are the statements, which are the nodes still without a parent; the
	-- same walk lists every node under its kind, so a pass that only wants the calls or the index
	-- reads walks those and not every node in the document.
	local topLevel = {}
	local byKind = self.byKind
	for _, node in ipairs(self.nodes) do
		if not node.parent and node.kind ~= "chunk" then topLevel[#topLevel + 1] = node.index end
		local kind = node.kind
		local list = byKind[kind]
		if list then
			list[#list + 1] = node
		else
			byKind[kind] = { node }
		end
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
		byKind = self.byKind,
		topLevel = topLevel,
		tokens = self.tokens,
		nodes = self.nodes,
		declarations = self.declarations,
		diagnostics = self.diagnostics,
		resumeStats = self.resumeStats,
	}
end

-- Published before the grammar loads: `require` returns `package.loaded[name]` when it is
-- already set, so the grammar modules can require this one while it is still running and
-- inject their methods onto the same table.
package.loaded["lye-parser"] = Parser

require("lye-parser.expressions")
require("lye-parser.statements")

return Parser
