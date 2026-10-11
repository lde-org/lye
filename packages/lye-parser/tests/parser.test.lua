--[[
	Tests for `lye-parser`.

	Acceptance is checked against `loadstring`, since the engine is the ground truth for
	the dialect. Rejection is checked the other way round: the parser must report a
	diagnostic for input the engine rejects, and must not raise.
]]

local test = require("lde-test")
local lexer = require("lye-lexer")
local Parser = require("lye-parser")

---@param source string
---@return boolean
local function engineAccepts(source)
	local fn = loadstring(source)
	return fn ~= nil
end

local VALID = {
	"local x = 1",
	"local a, b = 1, 2",
	"local function f() end",
	"function f() end",
	"function a.b.c() end",
	"function a:m() end",
	"return 1 + 2 * 3 ^ 4",
	"return -x",
	"return not x",
	"return #t",
	"return a and b or c",
	"return a .. b .. c",
	"return f()(g())",
	"return a.b.c.d",
	"return t[1][2]",
	"return f{1, 2}",
	'return f"str"',
	"return {1, 2; 3}",
	"return {a = 1, ['b'] = 2, [3] = 4}",
	"if a then elseif b then else end",
	"while true do break end",
	"repeat until true",
	"for i = 1, 10, 2 do end",
	"for k, v in pairs(t) do end",
	"do local y = 1 end",
	"return ...",
	"local t = {}; t.x = 1",
	"x, y = y, x",
	"::top:: goto top",
	-- LuaJIT 3.0 syntax, all verified present on this build.
	"local a = c ? 1 : 2",
	"local a = t?.x?.y",
	-- The guard is written before whatever it guards, not only before a field: `?.[k]`, `?.:m()`
	-- and `?.()` are all accepted, and only the field form was read.
	"local s = 'a' return s?.lower()",
	"local s = 'a' return s?.:lower()",
	"local s = 'a' return s?.[1]",
	"local s = 'a' return s?.()",
	"local s = 'a' return s?.(1)",
	"return t?.x.a?.[1]:m()",
	"local a = x ?? 1",
	"local a = 1 ~>> 2",
	"local a = 1 << 2 | 3 & 4 ~ 5",
	"local a = !b",
	"local a = b && c || d != e",
	"local a = 1_000_000",
	"local a = 0b1010",
	"const x = 1",
	"local f = x -> x + 1",
	"local f = |a, b| -> a + b",
	"for i = 1, 3 do continue end",
	"local a = 1 a += 2",
	"local s = 'a' s ..= 'b'",
	-- Nested and combined.
	"local f = function(a, b) return a ? b : a end",
	"local t = { f = x -> x * 2, g = |n| -> n + 1 }",
	"if a ? b : c then return t?.x ?? 0 end",
}

local INVALID = {
	"local = 1",
	"if then end",
	"function end",
	"local x = ",
	"return return",
	"for do end",
	"end",
	"local x = {",
	"f(",
	-- A guard owns its dot, and guards only what follows it: `s?..lower` writes two, and a `:`
	-- directly on the `?` is not the guard at all.
	"local s = 'a' return s?..lower",
	"local s = 'a' return s?:lower()",
	"local s = 'a' return s?.?.b",
	"local s = 'a' return s?.1",
}

test.it("parses every valid program without a diagnostic", function()
	for _, source in ipairs(VALID) do
		local label = string.format("%q", source)
		test.equal(engineAccepts(source), true, "engine should accept " .. label)
		local result = Parser.new(source):parse()
		test.equal(#result.diagnostics, 0,
			"should parse cleanly: " .. label .. " -> " .. (result.diagnostics[1]?.message or ""))
	end
end)

test.it("reports rather than raises on invalid input", function()
	for _, source in ipairs(INVALID) do
		local label = string.format("%q", source)
		test.equal(engineAccepts(source), false, "engine should reject " .. label)
		local isOk, result = pcall(function() return Parser.new(source):parse() end)
		test.equal(isOk, true, "parser must not raise on " .. label)
		test.truthy(#result.diagnostics > 0, "should report a diagnostic for " .. label)
	end
end)

test.it("keeps a diagnostic inside the source", function()
	local source = "local x = 1\nlocal = 2\n"
	local result = Parser.new(source):parse()
	local first = result.diagnostics[1]
	test.truthy(first)
	test.truthy(first.start >= 1 and first.stop <= #source, "span must be within the source")
	test.truthy(first.stop >= first.start)
end)

test.it("recovers and still parses what follows an error", function()
	-- The reason recovery exists: a broken line must not hide the rest of the file.
	local result = Parser.new("local = 1\nfunction ok(a) end\n"):parse()
	test.truthy(#result.diagnostics > 0)
	local found = false
	for _, declaration in ipairs(result.declarations) do
		if declaration.name == "ok" then found = true end
	end
	test.truthy(found, "the function after the error should still be found")
end)

test.it("records the condition guarding a block", function()
	-- Narrowing needs the condition expression, not a token range it has to re-derive.
	local source = table.concat({
		"if x then\n",
		"\tprint(1)\n",
		"elseif y == nil then\n",
		"\tprint(2)\n",
		"else\n",
		"\tprint(3)\n",
		"end\n",
		"while z do\n",
		"\tprint(4)\n",
		"end\n",
		"repeat\n",
		"\tprint(5)\n",
		"until w\n",
	}, "")
	local result = Parser.new(source):parse()

	local texts = {}
	local hasElse = false
	for _, scope in ipairs(result.scopes) do
		if scope.conditionIdx then
			local condition = result.nodes[scope.conditionIdx]
			texts[#texts + 1] = source:sub(condition.start, condition.stop)
		elseif scope.branch == "else" then
			hasElse = true
		end
	end
	test.equal(#result.scopes, 5, "three clauses plus a while and a repeat")
	test.equal(hasElse, true, "the else scope carries no condition")
	test.equal(#texts, 4, "then, elseif, while and until each keep theirs")
	test.equal(texts[1], "x")
	test.equal(texts[2], "y == nil")
	test.equal(texts[3], "z")
	test.equal(texts[4], "w", "the repeat condition is read after its body")
end)

test.it("parents every operand, however many there are", function()
	-- The parent link is what makes the arena walkable, and it is set from the operands the
	-- emit call names, so a fixed-length list here would silently drop the fifth value.
	local source = "local a, b, c, d, e, f = 1, 2, 3, 4, 5, 6\nf(1, 2, 3, 4, 5)\n"
	local result = Parser.new(source):parse()

	--- Every node, grouped by the kind it was emitted as.
	---@type table<string, lye.parser.Node[]>
	local byKind = {}
	for _, node in ipairs(result.nodes) do
		if not node.parent and node.kind ~= "chunk" then
			test.equal(true, false, node.kind .. " has no parent")
		end
		byKind[node.kind] = byKind[node.kind] or {}
		byKind[node.kind][#byKind[node.kind] + 1] = node
	end
	test.equal(#byKind.number, 11, "six values and five arguments")

	local localNode, callNode
	for _, node in ipairs(result.nodes) do
		if node.kind == "local" then localNode = node.index end
		if node.kind == "call" then callNode = node end
	end
	for _, node in ipairs(byKind.number) do
		local isArgument = node.start > callNode.start
		test.equal(node.parent, isArgument and callNode.index or localNode, "operand at " .. node.start)
	end
end)

test.it("parents a generated file with thousands of statements", function()
	-- Re-parenting top-level statements used to go through `unpack`, which stops at a few
	-- thousand values, so a generated file raised instead of parsing.
	local source = string.rep("x = 1\n", 9000)
	local result = Parser.new(source):parse()
	test.equal(#result.diagnostics, 0)
	for _, node in ipairs(result.nodes) do
		if not node.parent and node.kind ~= "chunk" then
			test.equal(true, false, node.kind .. " has no parent")
		end
	end
end)

test.it("collects local declarations at the right scope depth", function()
	local result = Parser.new(table.concat({
		"local top = 1\n",
		"function f(a)\n",
		"\tlocal inner = 2\n",
		"\tdo\n",
		"\t\tlocal deepest = 3\n",
		"\tend\n",
		"end\n",
	}, "")):parse()

	local byName = {}
	for _, declaration in ipairs(result.declarations) do
		byName[declaration.name] = declaration
	end

	test.equal(byName.top.depth, 0)
	test.equal(byName.top.qualifier, "local")
	test.equal(byName.f.depth, 0)
	test.equal(byName.f.qualifier, "global")
	test.equal(byName.a.depth, 1)
	test.equal(byName.a.qualifier, "param")
	test.equal(byName.inner.depth, 1)
	test.equal(byName.deepest.depth, 2)
end)

test.it("records a declaration's span on its name", function()
	local source = "local hello = 1"
	local result = Parser.new(source):parse()
	local declaration = result.declarations[1]
	test.equal(declaration.name, "hello")
	test.equal(source:sub(declaration.start, declaration.stop), "hello")
end)

test.it("declares method parameters and implicit self", function()
	local result = Parser.new("function M:greet(name) return name end"):parse()
	local names = {}
	for _, declaration in ipairs(result.declarations) do
		names[declaration.name] = declaration.qualifier
	end
	test.equal(names["M:greet"], "field")
	test.equal(names.self, "param")
	test.equal(names.name, "param")
end)

test.it("treats goto as a statement and as a name", function()
	-- LuaJIT keeps `goto` soft, so both of these are legal and must parse cleanly.
	test.equal(#Parser.new("::top:: goto top"):parse().diagnostics, 0)
	test.equal(#Parser.new("local goto = 1"):parse().diagnostics, 0)
end)

test.it("reads const and continue as names where a name belongs", function()
	-- Both are words this parser knows and neither is a word of Lua's, so they are ordinary
	-- identifiers everywhere a reader may write one. A table whose *first* field was called
	-- `const` used to end at that field, and the rest of it was read as statements.
	test.equal(#Parser.new("local t = { const = true, restrict = true }"):parse().diagnostics, 0)
	local parsed = Parser.new("local t = { const = true, restrict = true }"):parse()
	local fields = {}
	for index, names in pairs(parsed.tableFields) do
		_ = index
		for name in pairs(names) do fields[#fields + 1] = name end
	end
	table.sort(fields)
	test.equal(table.concat(fields, ","), "const,restrict", "both fields belong to the table")
	test.equal(#Parser.new("local const, continue = 1, 2"):parse().diagnostics, 0)
end)

test.it("keeps comments available to callers", function()
	local result = Parser.new("---@param x number\nlocal function f(x) end"):parse()
	local comments = 0
	for index = 1, result.tokens.count do
		local token = result.tokens.arena[index]
		if token.kind == lexer.KIND.comment then comments += 1 end
	end
	test.equal(comments, 1, "a LuaDoc comment must survive for a later annotation pass")
end)

test.it("emits a chunk node spanning the file and a node per construct", function()
	local source = "local x = 1\nif x then end\n"
	local result = Parser.new(source):parse()
	local kinds = {}
	for _, node in ipairs(result.nodes) do
		kinds[node.kind] = true
		test.truthy(node.stop >= node.start, "node span should be ordered")
	end
	test.equal(kinds.chunk, true)
	test.equal(kinds["local"], true)
	test.equal(kinds["if"], true)
end)

test.it("handles an empty file", function()
	local result = Parser.new(""):parse()
	test.equal(#result.diagnostics, 0)
	test.equal(#result.declarations, 0)
end)

test.it("keeps an argument's index when it is written as a long string", function()
	-- Every other child in the tree is an arena index, and a reader takes an argument out of the
	-- arena by one: `print[[hello]]` used to put the node table there instead, which read as no
	-- argument at all and left the call untyped.
	for _, source in ipairs({ 'print[[hello]]\n', 'ffi.cdef[[int x;]]\n', 'print{1}\n' }) do
		local result = Parser.new(source):parse()
		for _, node in ipairs(result.nodes) do
			if node.kind == "call" then
				local first = node.args and node.args[1]
				test.equal(type(first), "number", source)
				local argument = result.nodes[first]
				test.truthy(argument, "the index names a node: " .. source)
			end
		end
	end
end)

test.it("reads a parameter list a comment is written inside", function()
	-- `f(a --[[string]], b)` is a comment between two parameters. The lexer emits comments as
	-- tokens, so a list that steps past a name without stepping past the comment finds the comment
	-- where the comma should be and stops there — which read as a missing `)`.
	for _, source in ipairs({
		"local function f(a --[[string]], b --[[number]])\n\treturn a, b\nend\n",
		"local function f(a, --[[second]] b)\n\treturn a, b\nend\n",
		"local f = function(x --[[u]])\n\treturn x\nend\n",
		"local f = |a --[[t]], b| -> a\n",
	}) do
		local result = Parser.new(source):parse()
		test.equal(#result.diagnostics, 0, "a comment between parameters is not an error: " .. source)
		local fn
		for _, declaration in ipairs(result.declarations) do
			if declaration.name == "f" then fn = result.nodes[declaration.valueIdx] end
		end
		test.truthy(fn, "the function was read: " .. source)
		for _, param in ipairs(fn.params or {}) do
			test.truthy(param.name == "a" or param.name == "b" or param.name == "x",
				"the parameter is the name, not the comment: " .. tostring(param.name))
		end
	end
end)

return true
