--[[
	Resume differential.

	`Parser.new(source, Parser.resumeAt(previous, from)):parse()` must build the same tree a fresh
	parse of `source` builds. Anything observable is compared: tokens (kind, text, span, index),
	nodes (count, kind, span, parent, children, arena index, every other field), declarations,
	scopes, the table maps, diagnostics, `byKind` and `topLevel`. Only table identity is allowed
	to differ, and it never appears in a snapshot.

	The cases are deterministic: the seeded edits below always generate the same sources.
]]

local test = require("lde-test")

--- The module's interface, which its own tests do not get through a dependency link: `new` builds
--- a parser, `parse` returns its result, and `resumeAt` finds the cut a resumed parse starts at.
---@class lye.parser.ResumeInstance : lye.parser.Parser
---@field parse fun(self: lye.parser.ResumeInstance): lye.parser.Result

---@class lye.parser.ResumeModule
---@field new fun(source: string, resume: lye.parser.Resume?, definition: boolean?): lye.parser.ResumeInstance
---@field resumeAt fun(parsed: lye.parser.Result, offset: integer): lye.parser.Resume?
---@field KIND table<string, integer>

local Parser = require("lye-parser") --[[@as lye.parser.ResumeModule]]

--- A total, deterministic encoding of a value, used to compare two parses exactly. Numeric keys
--- sort numerically so an index list keeps its order.
---@param value unknown
---@param parts string[]?
local function encode(value, parts)
	parts = parts or {}
	local valueType = type(value)
	if valueType == "table" then
		local keys = {}
		for key in pairs(value) do keys[#keys + 1] = key end
		table.sort(keys, function(a, b)
			local typeA, typeB = type(a), type(b)
			if typeA == typeB then
				if typeA == "number" or typeA == "string" then return a < b end
				return tostring(a) < tostring(b)
			end
			return typeA < typeB
		end)
		parts[#parts + 1] = "{"
		for _, key in ipairs(keys) do
			parts[#parts + 1] = tostring(key) .. "="
			encode(value[key], parts)
			parts[#parts + 1] = ";"
		end
		parts[#parts + 1] = "}"
	elseif valueType == "string" then
		parts[#parts + 1] = string.format("%q", value)
	else
		parts[#parts + 1] = tostring(value)
	end
	return parts
end

--- The encoding of a whole value, concatenated once. Concatenating at every recursion level
--- copies the parts collected so far each time, which is quadratic on a large tree.
---@param value unknown
local function flatten(value)
	return table.concat(encode(value, {}))
end

--- Everything a caller may observe in a parse.
---@param parsed lye.parser.Result
---@return table
local function snapshot(parsed)
	local tokens = {}
	for index = 1, parsed.tokens.count do
		local token = parsed.tokens.arena[index]
		tokens[index] = {
			index = token.index, kind = token.kind, start = token.start, stop = token.stop,
			text = parsed.tokens.texts[index],
		}
	end
	local byKind = {}
	for kind, list in pairs(parsed.byKind) do
		local indices = {}
		for index, node in ipairs(list) do indices[index] = node.index end
		byKind[kind] = indices
	end
	return {
		root = parsed.root,
		tokens = tokens,
		nodes = parsed.nodes,
		declarations = parsed.declarations,
		scopes = parsed.scopes,
		tableFields = parsed.tableFields,
		tableFieldValues = parsed.tableFieldValues,
		tableIndexes = parsed.tableIndexes,
		diagnostics = parsed.diagnostics,
		byKind = byKind,
		topLevel = parsed.topLevel,
	}
end

--- The number of leading bytes two sources share.
---@param a string
---@param b string
---@return integer
local function commonPrefix(a, b)
	local limit = math.min(#a, #b)
	local index = 1
	while index <= limit and a:byte(index) == b:byte(index) do index += 1 end
	return index - 1
end

--- A short window around the first difference between two encodings.
---@param a string
---@param b string
local function difference(a, b)
	local index = 1
	local limit = math.min(#a, #b)
	while index <= limit and a:byte(index) == b:byte(index) do index += 1 end
	local from = math.max(1, index - 160)
	return string.format("at byte %d\n  resumed: %s\n  fresh:   %s",
		index, a:sub(from, index + 160), b:sub(from, index + 160))
end

--- The invariants a resumed parse promises, checked on the parse itself so a corrupt-but-equal
--- tree cannot hide behind the comparison.
---@param parsed lye.parser.Result
---@param source string
---@param label string
local function checkInvariants(parsed, source, label)
	local nodes = parsed.nodes
	local tokens = parsed.tokens

	test.equal(tokens.count, #parsed.tokens.texts, label .. ": one text per token")
	for index = 1, tokens.count do
		local token = tokens.arena[index]
		test.equal(token.index, index, label .. ": token " .. index .. " keeps its index")
		if token.kind ~= assert(Parser.KIND).eof then
			test.equal(tokens.texts[index], source:sub(token.start, token.stop),
				label .. ": token " .. index .. " text is its own slice")
		end
	end

	local seen = 0
	for kind, list in pairs(parsed.byKind) do
		seen = seen + #list
		for _, node in ipairs(list) do
			test.equal(node.kind, kind, label .. ": byKind lists a node under its kind")
		end
	end
	test.equal(seen, #nodes - 1, label .. ": byKind holds every non-chunk node once")

	-- A problem belongs to the statement that reported it, which is how a resume tells the ones
	-- a cut above it would report again from the ones it would lose.
	for _, diagnostic in ipairs(parsed.diagnostics) do
		if diagnostic.statementStart then
			test.truthy(diagnostic.statementStart <= diagnostic.start,
				label .. ": a problem lies at or after the statement that reported it")
		end
	end

	local chunk = nodes[parsed.root]
	test.equal(chunk.kind, "chunk", label .. ": the root is the chunk")
	test.equal(parsed.root, #nodes, label .. ": the chunk is emitted last")
	local children = chunk.children or {}
	test.equal(#children, #parsed.topLevel, label .. ": topLevel is the chunk's children")
	for index, childIdx in ipairs(children) do
		test.equal(childIdx, parsed.topLevel[index], label .. ": chunk child " .. index)
		test.equal(nodes[childIdx].parent, parsed.root, label .. ": a statement is parented to the chunk")
	end
	for index = 1, #nodes do
		local node = nodes[index]
		test.equal(node.index, index, label .. ": node " .. index .. " keeps its arena index")
		if node.parent then
			test.truthy(node.parent > index, label .. ": node " .. index .. " parent follows it")
			test.truthy(node.parent <= #nodes, label .. ": node " .. index .. " parent exists")
		end
	end
end

--- Parse `oldText`, resume at the point `newText` first differs, and compare the whole parse with
--- a fresh one. `expectResume`, when given, is checked against whether a resume was possible.
---@param label string
---@param oldText string
---@param newText string
---@param expectResume boolean?
local function checkEdit(label, oldText, newText, expectResume)
	local previous = Parser.new(oldText):parse()
	local from = commonPrefix(oldText, newText) + 1
	local resume = Parser.resumeAt(previous, from)
	if expectResume ~= nil then
		test.equal(resume ~= nil, expectResume, label .. ": whether a resume is possible")
	end
	-- The prefix lists are checked before they are used: a parse appends to the arrays a resume
	-- carries, so the kept entries are read here, while they are still the kept ones.
	if resume then
		test.equal(resume.kind, "statement", label .. ": the resume kind")
		-- No kept token may span the cut. A literal or comment that starts before it and ends
		-- after it is a token of the old text, and a scan resumed at the cut would start inside
		-- it, so every kept token ends before the statement the cut re-reads.
		for index = 1, resume.tokenIndex - 1 do
			local token = resume.tokens.arena[index]
			test.truthy(token.stop < resume.from,
				label .. ": kept token " .. index .. " ends before the cut")
		end
		for _, declaration in ipairs(resume.declarations) do
			test.truthy(declaration.start < resume.from, label .. ": a kept declaration is in the prefix")
		end
		for _, scope in ipairs(resume.scopes) do
			test.truthy(scope.start < resume.from, label .. ": a kept scope is in the prefix")
		end
		for _, diagnostic in ipairs(resume.diagnostics) do
			test.truthy(diagnostic.stop < resume.from, label .. ": a carried problem lies before the cut")
		end
		-- A problem at or after the cut is one the resumed parse has to find on its own. When the
		-- statement above the cut reported it across the boundary, the cut has to be that
		-- statement instead: a parse beginning lower has no construct open and loses it.
		for _, diagnostic in ipairs(previous.diagnostics) do
			if diagnostic.start >= resume.from and diagnostic.statementStart then
				test.truthy(diagnostic.statementStart >= resume.from,
					label .. ": a problem at the cut belongs to a statement the cut re-reads")
			end
		end
		for key in pairs(resume.tableFields) do
			---@cast key integer
			test.truthy(key <= resume.nodeCount, label .. ": a kept table is in the prefix")
		end
		for key in pairs(resume.tableFieldValues) do
			---@cast key integer
			test.truthy(key <= resume.nodeCount, label .. ": a kept table value map is in the prefix")
		end
		for key in pairs(resume.tableIndexes) do
			---@cast key integer
			test.truthy(key <= resume.nodeCount, label .. ": a kept element map is in the prefix")
		end
	end

	local resumed = Parser.new(newText, resume):parse()
	local fresh = Parser.new(newText):parse()
	test.equal(fresh.resumeStats.nodes, 0, label .. ": a full parse keeps no nodes")
	test.equal(fresh.resumeStats.tokens, 0, label .. ": a full parse keeps no tokens")
	checkInvariants(resumed, newText, label)
	-- The diagnostic list is capped, and the cap is a budget that a scanner finding spends: a
	-- carried problem the cold parse drops because its budget fell is a problem the resumed parse
	-- must drop too. Every problem the resumed parse reports is therefore one the cold parse
	-- reports at the same place with the same message.
	local coldProblems = {}
	for _, diagnostic in ipairs(fresh.diagnostics) do
		coldProblems[string.format("%d|%d|%s", diagnostic.start, diagnostic.stop, diagnostic.message)] = true
	end
	for _, diagnostic in ipairs(resumed.diagnostics) do
		test.truthy(coldProblems[string.format("%d|%d|%s", diagnostic.start, diagnostic.stop, diagnostic.message)],
			label .. ": every resumed problem is one a cold parse keeps")
	end
	local resumedEncoding, freshEncoding = flatten(snapshot(resumed)), flatten(snapshot(fresh))
	if resumedEncoding ~= freshEncoding then
		error(label .. ": resumed parse differs from a fresh one\n" .. difference(resumedEncoding, freshEncoding), 2)
	end

	if resume then
		test.equal(resumed.resumeStats.nodes, resume.nodeCount, label .. ": kept node count")
		test.equal(resumed.resumeStats.tokens, resume.tokenIndex - 1, label .. ": kept token count")
		test.equal(resumed.tokens.arena[resume.tokenIndex].start, resume.from,
			label .. ": the resume point is a token boundary")
	end
end

--- An insertion at `at` (1-based, `at` may be `#base + 1`).
---@param base string
---@param at integer
---@param text string
local function insert(base, at, text)
	return base:sub(1, at - 1) .. text .. base:sub(at)
end

--- Replace the bytes `from..to` of `base` (inclusive; `from == to + 1` inserts).
---@param base string
---@param from integer
---@param to integer
---@param text string
local function splice(base, from, to, text)
	return base:sub(1, from - 1) .. text .. base:sub(to + 1)
end

--- The offset of `needle` in `base`, plus `offset`, failing the test when it is absent.
---@param base string
---@param needle string
---@param offset integer?
---@return integer
local function at(base, needle, offset)
	local found = base:find(needle, 1, true)
	test.truthy(found, "the fixture text should contain " .. string.format("%q", needle))
	return found + (offset or 0)
end

local RICH = table.concat({
	"local Vec = {}\n",
	"-- a line comment\n",
	"function Vec.new(x, y)\n",
	"\treturn setmetatable({ x = x, y = y }, Vec)\n",
	"end\n",
	"\n",
	"local s = \"hello world\"\n",
	"local long = [[line one\n",
	"line two]]\n",
	"--[[ a long\n",
	"comment ]]\n",
	"local n = 12 + 3 * (4 - 1)\n",
	"if n > 3 then\n",
	"\tprint(\"big\", s)\n",
	"elseif n == 3 then\n",
	"\tprint(long)\n",
	"else\n",
	"\tprint(\"small\")\n",
	"end\n",
	"\n",
	"---@param values number[]\n",
	"---@return number\n",
	"local function total(values)\n",
	"\tlocal sum = 0\n",
	"\tfor i = 1, #values do\n",
	"\t\tsum += values[i]\n",
	"\tend\n",
	"\treturn sum\n",
	"end\n",
	"\n",
	"local t = { a = 1, [2] = \"two\", 3, nested = { 4, 5 } }\n",
	"return Vec, s, long, n, t, total\n",
}, "")

local SMALL = "local a = 1\nlocal b = 2\nlocal c = 3\n"

--- The cases the seeded generator cannot be relied on to hit, one per edit site.
local DEFINITION = "---@meta\n---@param n number\n---@return number\nfunction square(n: number): number end\nlocal x: number = 1\nreturn x\n"
-- An argument list left open above reports its missing `)` on the first token of the statement
-- that follows, so that token is not a boundary a parse beginning there can see: `function` is
-- read as a fresh statement and the problem the whole text has is lost. The cut has to step back
-- to the statement that holds the list — the shape a definitions file's broken call takes.
local OPEN_CALL = "local a = 1\nf(1,\ng()\n--- a note\nh()\n"
local OPEN_CALL_DEFINITION = "---@meta\nlocal a = 1\nf(1,\nfunction g(): thread? end\nlocal z = 2\n"
local BROKEN = "local a = 1\nlocal = 2\nlocal c = 3\nlocal d @ 4\nreturn a, c\n"
local UNFINISHED_SHORT = "local s = \"unclosed\nlocal next = 1\n"
local UNFINISHED_LONG = "local s = [[unclosed\nlocal next = 1\n"
local CRLF = "local a = 1\r\nlocal b = 2\r\nreturn a + b"

-- Deleting a byte inside a short string can leave its closing quote escaped, so the string runs
-- on and every following string opens where the one before closed. Each leaked `\` is then a
-- scanner problem, and one keystroke turns a text with a single parser problem into one whose
-- scanner findings alone fill the diagnostic cap: the cold parse's budget for parser problems
-- falls to zero and it drops the one before the edit, which the resume must drop as well.
---@param lines integer
local function cappedBudget(lines)
	local parts = { "local = 1\n", "local s = \"\\0\"\n" }
	for index = 1, lines do
		parts[#parts + 1] = string.format("local v%d = \"a\\nb\"\n", index)
	end
	parts[#parts + 1] = "local tail = 2\nreturn tail\n"
	return table.concat(parts)
end
local CAPPED = cappedBudget(30)
local CAPPED_EDITED = splice(CAPPED, at(CAPPED, "\\0", 2), at(CAPPED, "\\0", 2), "")

local EDITS = {
	{ "insert inside a short string", RICH, insert(RICH, at(RICH, "\"hello world\"", 3), "XY"), true },
	{ "delete inside a short string", RICH, splice(RICH, at(RICH, "\"hello world\"", 2), at(RICH, "\"hello world\"", 5), ""), true },
	{ "replace inside a short string", RICH, splice(RICH, at(RICH, "\"hello world\"", 2), at(RICH, "\"hello world\"", 6), "bye"), true },
	{ "insert inside a long string", RICH, insert(RICH, at(RICH, "line one", 5), "zero "), true },
	{ "delete the newline in a long string", RICH, splice(RICH, at(RICH, "line one", 4), at(RICH, "line one", 4), ""), true },
	{ "insert inside a line comment before the second statement", RICH, insert(RICH, at(RICH, "a line comment", 3), "!!"), false },
	{ "insert inside a long comment", RICH, insert(RICH, at(RICH, "a long", 2), "very "), true },
	{ "edit after a call an open list reported on", OPEN_CALL, OPEN_CALL .. "local z = 1\n", true },
	{ "edit after an open list's problem in a definition file", OPEN_CALL_DEFINITION,
		splice(OPEN_CALL_DEFINITION, at(OPEN_CALL_DEFINITION, "z = 2", 5),
			at(OPEN_CALL_DEFINITION, "z = 2", 5), "22"), true },
	{ "edit inside a function body", RICH, insert(RICH, at(RICH, "return setmetatable", 3), "\n\t"), true },
	{ "delete inside a function body", RICH, splice(RICH, at(RICH, "setmetatable", 4), at(RICH, "setmetatable", 9), ""), true },
	{ "insert inside an annotation", RICH, insert(RICH, at(RICH, "---@param values", 8), "x"), true },
	{ "insert at top level between statements", RICH, insert(RICH, at(RICH, "local s ="), "local extra = 1\n"), true },
	{ "insert before the first statement", RICH, insert(RICH, 1, "-- header\n"), false },
	{ "insert at the first byte", RICH, insert(RICH, 1, "x"), false },
	{ "append at the end of the file", RICH, RICH .. "local last = true\n", true },
	{ "delete the file's tail", RICH, RICH:sub(1, at(RICH, "if n > 3") - 1), true },
	{ "replace across a statement boundary", RICH, splice(RICH, at(RICH, "local s =") - 1, at(RICH, "local n =") + 3, "-- cut\n"), true },
	{ "edit a table literal", RICH, splice(RICH, at(RICH, "nested ="), at(RICH, "nested =") + 5, "racy"), true },
	{ "edit a nested loop", RICH, insert(RICH, at(RICH, "sum += values[i]", 5), "0 + "), true },
	{ "edit the last statement", RICH, insert(RICH, at(RICH, "return Vec", 8), "0, "), true },
	{ "insert a trailing comma before the next statement", SMALL, insert(SMALL, at(SMALL, "local b =") - 1, ","), false },
	{ "insert an operator before the next statement", SMALL, insert(SMALL, at(SMALL, "local b =") - 1, " + 9"), false },
	{ "edit after a malformed declaration", BROKEN, insert(BROKEN, at(BROKEN, "local c") + 2, " -- x"), true },
	{ "edit after a malformed statement in a prefix", BROKEN, insert(BROKEN, at(BROKEN, "return a", 4), "0, "), true },
	{ "edit a definition file after its typed signature", DEFINITION, insert(DEFINITION, at(DEFINITION, "return x", 3), "2, "), true },
	{ "edit after an unfinished short string", UNFINISHED_SHORT, splice(UNFINISHED_SHORT, at(UNFINISHED_SHORT, "next = 1", 7), at(UNFINISHED_SHORT, "next = 1", 7), "22"), true },
	{ "edit inside an unfinished long bracket", UNFINISHED_LONG, splice(UNFINISHED_LONG, at(UNFINISHED_LONG, "next = 1", 7), at(UNFINISHED_LONG, "next = 1", 7), "22"), false },
	{ "edit a CRLF source", CRLF, splice(CRLF, at(CRLF, "b = 2", 4), at(CRLF, "b = 2", 4), "22"), true },
	{ "edit a comment-only source", "-- only\n-- comments\n", "-- only\n-- comments!\n", false },
	{ "edit an empty file", "", "local x = 1\n", false },
	-- A dense source whose tail is deleted: the kept tokens outnumber what the new length would
	-- estimate, which used to copy past the scan arena.
	{ "delete the tail of a dense source", string.rep("a=1;", 100) .. "b=2\n",
		(string.rep("a=1;", 100) .. "b=2\n"):sub(1, 200), true },
	-- An edit whose cascade of scanner findings shrinks the room the previous parser problems had.
	{ "delete a byte that spills a string across many findings", CAPPED, CAPPED_EDITED, true },
}

test.it("resumes every edit at the same tree a full parse builds", function()
	for _, case in ipairs(EDITS) do
		local label, oldText, newText, expectResume = case[1], case[2], case[3], case[4]
		---@cast label string
		---@cast oldText string
		---@cast newText string
		---@cast expectResume boolean
		checkEdit(label, oldText, newText, expectResume)
	end
end)

--- A small deterministic generator: the same seed gives the same edits every run.
---@param seed integer
---@return fun(limit: integer): integer
local function generator(seed)
	local state = seed
	return function(limit)
		state = (state * 1103515245 + 12345) % 2147483648
		return (state % limit) + 1
	end
end

local SNIPPETS = {
	"x", "42", "\"str\"", "--c\n", "local z = 1\n", "end\n", "[[", "\n", "function g() end\n",
	",", "(", ")", "---@type number\n", "return 1\n", "\"unclosed\n", "--[[\n", "...", " + ",
}

local SEEDED_BASES = { RICH, SMALL, "local a = 1\nlocal = 2\nlocal c = 3\nlocal d @ 4\nreturn a\n",
	"---@meta\nfunction f(x: number): string return \"x\" end\nlocal y: string = f(1)\nreturn y\n",
	"local a = 1\r\nlocal b = 2\r\nreturn a + b\r\n",
	OPEN_CALL, OPEN_CALL_DEFINITION,
	string.rep("a = 1\n", 40) .. "return a\n" }

test.it("resumes seeded edits at the same tree a full parse builds", function()
	for baseIndex, base in ipairs(SEEDED_BASES) do
		for seed = 1, 24 do
			local random = generator(baseIndex * 100003 + seed * 7919)
			local position = random(#base + 1)
			local operation = random(3)
			local width = random(20) - 1
			local stop = math.min(#base + 1, position + width)
			if stop <= position then stop = position + 1 end
			local newText
			if operation == 1 then
				newText = insert(base, position, SNIPPETS[random(#SNIPPETS)])
			elseif operation == 2 then
				newText = splice(base, position, stop - 1, "")
			else
				newText = splice(base, position, stop - 1, SNIPPETS[random(#SNIPPETS)])
			end
			if newText ~= base then
				checkEdit(string.format("base %d seed %d", baseIndex, seed), base, newText)
			end
		end
	end
end)

test.it("falls back to a full parse at the first statement", function()
	local parsed = Parser.new(RICH):parse()
	local firstStatement = parsed.nodes[parsed.topLevel[1]]
	-- Nothing precedes the first statement, so no offset in it can keep anything.
	for offset = 1, firstStatement.stop do
		test.equal(Parser.resumeAt(parsed, offset), nil,
			"no complete statement precedes byte " .. offset)
	end
	-- The first statement is kept once the change is inside the second.
	local secondStart = parsed.nodes[parsed.topLevel[2]].start
	test.truthy(Parser.resumeAt(parsed, secondStart + 1), "the first statement is kept")
end)

test.it("carries a prefix diagnostic exactly once", function()
	local broken = "local a = 1\nlocal = 2\nlocal c = 3\nlocal d @ 4\nreturn a, c\n"
	local previous = Parser.new(broken):parse()
	test.truthy(#previous.diagnostics > 0, "the fixture has problems to carry")
	local newText = insert(broken, at(broken, "return", 3), "0, ")
	local resume = Parser.resumeAt(previous, at(broken, "return"))
	test.truthy(resume, "an edit in the last statement can resume")
	test.truthy(#resume.diagnostics > 0, "the kept problems travel with the resume")
	local resumed = Parser.new(newText, resume):parse()
	local fresh = Parser.new(newText):parse()
	test.equal(#resumed.diagnostics, #fresh.diagnostics, "no problem is lost or repeated")
	for index = 1, #fresh.diagnostics do
		test.equal(resumed.diagnostics[index].message, fresh.diagnostics[index].message, "diagnostic " .. index)
		test.equal(resumed.diagnostics[index].start, fresh.diagnostics[index].start, "diagnostic " .. index .. " start")
	end
end)

test.it("keeps the tokens before the cut from the previous scan", function()
	local previous = Parser.new(RICH):parse()
	local cut = at(RICH, "local n =")
	local resume = Parser.resumeAt(previous, cut + 1)
	test.truthy(resume, "a later statement can resume")
	local resumed = Parser.new(insert(RICH, cut + 1, "x"), resume):parse()
	local lexer = require("lye-lexer")
	local tokens = lexer.resume(insert(RICH, cut + 1, "x"), resume.from, previous.tokens)
	test.equal(tokens.count, resumed.tokens.count, "the resumed scan is what the parser read")
	for index = 1, resume.tokenIndex - 1 do
		local before, after = previous.tokens.arena[index], tokens.arena[index]
		test.equal(after.kind, before.kind, "token " .. index .. " kind")
		test.equal(after.start, before.start, "token " .. index .. " start")
		test.equal(after.stop, before.stop, "token " .. index .. " stop")
		test.equal(tokens.texts[index], previous.tokens.texts[index], "token " .. index .. " text")
	end
end)

test.it("resumes an edit inside a long literal after a resumed parse", function()
	local base = "local head = 1\nlocal s = [[line one\nline two]]\nlocal tail = 2\nreturn head, s, tail\n"
	local appended = base .. "-- note\n"
	-- The parse the next keystroke resumes from is itself resumed, which is the state an editor
	-- holds between two edits.
	local firstResume = Parser.resumeAt(Parser.new(base):parse(), #base + 1)
	test.truthy(firstResume, "the append resumes")
	local first = Parser.new(appended, firstResume):parse()
	test.truthy(first.resumeStats.nodes > 0, "the first parse kept a prefix")

	-- An edit inside the long string, resumed from the parse that already carried a prefix.
	local cut = at(appended, "line one", 5)
	local edited = insert(appended, cut, "zero ")
	local held = Parser.resumeAt(first, cut)
	test.truthy(held, "an edit inside the long string resumes")
	for index = 1, held.tokenIndex - 1 do
		test.truthy(held.tokens.arena[index].stop < held.from,
			"kept token " .. index .. " ends before the cut")
	end
	local warm = Parser.new(edited, held):parse()
	local fresh = Parser.new(edited):parse()
	test.equal(flatten(snapshot(warm)), flatten(snapshot(fresh)),
		"the edit inside a long string is fresh-equivalent after a resumed parse")

	-- The same shape with a long comment and a cut that was itself found on a resumed parse.
	local commented = appended .. "--[[ a long\ncomment ]]\nlocal z = 3\n"
	local commentResume = Parser.resumeAt(first, #appended + 1)
	test.truthy(commentResume, "the comment insertion resumes")
	local resumedComment = Parser.new(commented, commentResume):parse()
	local commentCut = at(commented, "a long", 3)
	local commentEdit = insert(commented, commentCut, "and ")
	local commentHeld = Parser.resumeAt(resumedComment, commentCut)
	test.truthy(commentHeld, "an edit inside the long comment resumes")
	local commentWarm = Parser.new(commentEdit, commentHeld):parse()
	local commentFresh = Parser.new(commentEdit):parse()
	test.equal(flatten(snapshot(commentWarm)), flatten(snapshot(commentFresh)),
		"the edit inside a long comment is fresh-equivalent after a resumed parse")
end)

test.it("refuses a resume cut inside a literal", function()
	local lexer = require("lye-lexer")
	local source = "local a = 1\nlocal s = [[line one\nline two]]\nlocal b = 2\n"
	local tokens = lexer.tokenize(source)
	test.equal(lexer.resume(source, at(source, "line one", 2), tokens), nil,
		"a cut inside a long string has no prefix that fits")
	local commented = "local a = 1\n--[[ a long\ncomment ]]\nlocal b = 2\n"
	local commentTokens = lexer.tokenize(commented)
	test.equal(lexer.resume(commented, at(commented, "a long", 2), commentTokens), nil,
		"a cut inside a long comment has no prefix that fits")
	local short = "local a = 1\nlocal s = \"line one\"\nlocal b = 2\n"
	test.equal(lexer.resume(short, at(short, "line one", 2), lexer.tokenize(short)), nil,
		"a cut inside a short string has no prefix that fits")

	-- A statement boundary is a cut every kept token ends before.
	local boundary = at(source, "local b")
	local resumedTokens = lexer.resume(source, boundary, tokens)
	test.truthy(resumedTokens, "a statement boundary resumes")
	for index = 1, resumedTokens.count do
		local token = resumedTokens.arena[index]
		if token.start < boundary then
			test.truthy(token.stop < boundary, "kept token " .. index .. " ends before the cut")
		end
	end
end)

--- The 2331-line fixture, found by walking up from the test file so the path does not depend on
--- the runner's working directory.
local function benchmarkFixture()
	local source = debug.getinfo(1, "S").source
	local directory = source:match("^@(.*)[/\\][^/\\]*$")
	local candidates = { "editors/vscode/tests/fixtures/benchmark-lde.lua.txt" }
	if directory then
		local walk = directory
		for _ = 1, 8 do
			candidates[#candidates + 1] = walk .. "/editors/vscode/tests/fixtures/benchmark-lde.lua.txt"
			local parent = walk:match("^(.*)[/\\][^/\\]+$")
			if not parent or parent == walk then break end
			walk = parent
		end
	end
	for _, path in ipairs(candidates) do
		local handle = io.open(path)
		if handle then
			local text = handle:read("*a")
			handle:close()
			return text
		end
	end
	return nil
end

test.it("resumes a large file repeatedly and reports the reuse", function()
	local source = assert(benchmarkFixture(), "the benchmark fixture is readable")
	local first = Parser.new(source):parse()
	test.truthy(#first.nodes > 3000, "the fixture should be the large one")

	-- Edit near the end: a comment inserted at a line break after the last complete statement.
	local cut = source:find("\n", #source - 60, true) or #source
	local edited = insert(source, cut + 1, "-- bench edit\n")
	local resume = Parser.resumeAt(first, cut + 1)
	test.truthy(resume, "an edit near the end resumes")
	local resumed = Parser.new(edited, resume):parse()
	local fresh = Parser.new(edited):parse()
	checkInvariants(resumed, edited, "fixture")
	test.equal(flatten(snapshot(resumed)), flatten(snapshot(fresh)), "the large resumed parse is fresh-equivalent")
	test.truthy(resumed.resumeStats.nodes > #fresh.nodes / 2, "most of the file is kept")
	test.truthy(resumed.resumeStats.tokens > fresh.tokens.count / 2, "most of the scan is kept")
	print(string.format(
		"resume fixture: nodes kept %d/%d, tokens kept %d/%d",
		resumed.resumeStats.nodes, #fresh.nodes, resumed.resumeStats.tokens, fresh.tokens.count))

	-- A later edit, resuming from the parse that was itself resumed: the chain is stable.
	local secondEdit = edited .. "\n-- later edit\n"
	local secondResume = Parser.resumeAt(resumed, #edited + 1)
	test.truthy(secondResume, "a later edit resumes from a resumed parse")
	local second = Parser.new(secondEdit, secondResume):parse()
	local secondFresh = Parser.new(secondEdit):parse()
	test.equal(flatten(snapshot(second)), flatten(snapshot(secondFresh)), "the second resume is fresh-equivalent")
	test.truthy(second.resumeStats.nodes > 0, "the second resume keeps nodes")
	print(string.format(
		"resume fixture later edit: nodes kept %d/%d, tokens kept %d/%d",
		second.resumeStats.nodes, #secondFresh.nodes, second.resumeStats.tokens, secondFresh.tokens.count))
end)

return true
