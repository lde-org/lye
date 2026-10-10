--[[
	Tests for name resolution and type inference.
]]

local test = require("lde-test")
local lye = require("lye-analyzer")
local types = require("lye-doc.type")

-- These tests are about types and about what an editor reports as a problem. Every snippet here is
-- full of locals nothing reads, so the module is wrapped to keep the diagnostics that are about
-- types and about names that do not resolve; the unused-local rule is dropped by name, and tested
-- on its own below.
local analyzer = {
	analyze = function(source, prepared)
		local result = lye.analyze(source, prepared)
		local kept = {}
		for _, entry in ipairs(result.diagnostics) do
			if not entry.message:match("^unused local") then kept[#kept + 1] = entry end
		end
		result.diagnostics = kept
		return result
	end,
	prelude = lye.prelude,
	typeAt = lye.typeAt,
	lookupAt = lye.lookupAt,
	visibleAt = lye.visibleAt,
}

--- The type a name has at the end of the source, as text.
---@param source string
---@param name string
---@return string? inferred
local function typeOf(source, name)
	local result = analyzer.analyze(source)
	for _, variable in ipairs(result.variables) do
		if variable.name == name then return types.display(analyzer.typeAt(result, variable, #source)) end
	end
end

---@param source string
---@param offset integer
---@return string[]
test.it("evolves a name that is assigned after its declaration", function()
	local source = 'local x = 5\nx = "string"\nlocal y = x\n'
	local result = analyzer.analyze(source)
	local byName = {}
	for _, variable in ipairs(result.variables) do byName[variable.name] = variable end
	test.equal(types.display(analyzer.typeAt(result, byName.x, #source)), "5|string")
	test.equal(types.display(analyzer.typeAt(result, byName.y, #source)), "5|string",
		"an initializer sees what the name became, not what it started as")
end)

test.it("gives a parameter the type its @param names", function()
	local source = table.concat({
		"---@param name string\n",
		"---@param count number\n",
		"local function f(name, count)\n",
		"\tprint(name)\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source)
	local at = assert(source:find("print", 1, true))
	for name, expected in pairs({ name = "string", count = "number" }) do
		local variable = assert(analyzer.lookupAt(result, name, at), name)
		test.equal(types.display(analyzer.typeAt(result, variable, at)), expected)
		test.equal(variable.declared ~= nil, true, "it comes from the annotation")
	end
end)

test.it("does not hand one function's annotations to the next", function()
	local source = table.concat({
		"---@param a string\n",
		"local function f(a) end\n",
		"local function g(a)\n",
		"\tprint(a)\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source)
	local at = assert(source:find("print", 1, true))
	local a = assert(analyzer.lookupAt(result, "a", at))
	test.equal(types.display(analyzer.typeAt(result, a, at)), "any",
		"f's @param is not g's: an unannotated parameter is any")
end)

test.it("keeps a parameter clear of a local of the same name", function()
	-- The assignment belongs to the local, so the parameter keeps its own type and the local
	-- keeps its evolution.
	local source = table.concat({
		"local x = 5\n",
		'x = "string"\n',
		"local y = x\n",
		"---@param x number\n",
		"function test(x)\n",
		"\tprint(x)\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source)
	local at = assert(source:find("print", 1, true))
	local param = assert(analyzer.lookupAt(result, "x", at), "the parameter resolves here")
	test.equal(param.qualifier, "param")
	test.equal(#param.assignments, 0, "the local's assignment is not its own")
	test.equal(types.display(analyzer.typeAt(result, param, at)), "number")
	local localX = result.variables[1]
	test.equal(localX.qualifier, "local")
	test.equal(types.display(analyzer.typeAt(result, localX, #source)), "5|string")
end)

---@param source string
---@param needle string
---@return integer
local function offsetOf(source, needle)
	local at = source:find(needle, 1, true)
	assert(at, "test bug: " .. string.format("%q", needle) .. " is not in the source")
	return at
end

---@param source string
---@param offset integer
---@return string[]
local function visibleNames(source, offset)
	local result = analyzer.analyze(source)
	local names = {}
	for _, variable in ipairs(analyzer.visibleAt(result, offset)) do
		names[#names + 1] = variable.name
	end
	table.sort(names)
	return names
end

test.it("infers a type from what a name was assigned", function()
	test.equal(typeOf('local s = "hi"', "s"), "string")
	test.equal(typeOf("local n = 42", "n"), "42")
	test.equal(typeOf("local t = {}", "t"), "table")
	-- A function is a signature now: its own arity, with an unannotated parameter as `any`,
	-- and a return that is inferred from the body.
	test.equal(typeOf("local f = function() end", "f"), "fn()", "nothing is returned, so there is no result")
	test.equal(typeOf("local f = function(a, b) return 1 end", "f"), "fn(any, any) -> 1")
	test.equal(typeOf("local f = function(...) return 1 end", "f"), "fn(...) -> 1")
	-- The bare `x -> e` shorthand does not declare its parameter, so this has none yet.
	test.equal(typeOf("local a = x -> x", "a"), "fn() -> unknown")
	test.equal(typeOf("local a = |x| -> x", "a"), "fn(any) -> any",
		"the named parameter is declared, and the body is what it returns")
	test.equal(typeOf("local g = true", "g"), "true")
end)

test.it("leaves a type unknown when it cannot be inferred", function()
	-- A call with no `@return` says nothing about what it produces.
	test.equal(typeOf("local u = call()", "u"), "unknown")
	test.equal(typeOf("local v = t[k]", "v"), "unknown")
end)

test.it("propagates through every operator", function()
	test.equal(typeOf("local b = 1 + 2", "b"), "3")
	test.equal(typeOf("local s = \"x\" .. \"y\"", "s"), "string")
	-- `..` coerces, so a number on either side still gives a string.
	test.equal(typeOf("local m = \"a\" .. 1", "m"), "string")
	test.equal(typeOf("local c = 1 == 2", "c"), "boolean")
	test.equal(typeOf("local n = -1", "n"), "-1")
	test.equal(typeOf("local l = #\"abc\"", "l"), "number")
	test.equal(typeOf("local p = (1)", "p"), "1")
	-- A number and a string cannot be added, so the result is not claimed.
	test.equal(typeOf("local x = 1 + \"s\"", "x"), "unknown")
end)

test.it("propagates through a field of a known object", function()
	test.equal(typeOf("---@type { foo: number }\nlocal t = { foo = 1 }\nlocal v = t.foo", "v"), "number")
end)

test.it("pairs several names with several initializers", function()
	local source = "local a, b = 1, \"two\""
	test.equal(typeOf(source, "a"), "1")
	test.equal(typeOf(source, "b"), "string", "each name gets its own initializer")

	local three = "local a, b, c = \"s\", {}, function() end"
	test.equal(typeOf(three, "a"), "string")
	test.equal(typeOf(three, "b"), "table")
	test.equal(typeOf(three, "c"), "fn()")
end)

test.it("infers what a function returns from its body", function()
	test.equal(typeOf("local function f() return 1 end", "f"), "fn() -> 1")
	test.equal(typeOf("local function f(a) if a then return 1 end return \"s\" end", "f"),
		"fn(any) -> 1|string", "every return is unioned")
	-- A statement handing back several values gives a caller reading one the first of them, so
	-- the count is not part of what `f()` is: unioning it would claim `f()` may be a string, and
	-- `local n: number = f()` would be reported against a body that is right.
	test.equal(typeOf("local function f() return 1, \"s\" end", "f"), "fn() -> 1",
		"a caller reading one value gets the first")
	test.equal(typeOf("local function f(a) if a then return 1, \"s\" end return \"t\", 2 end", "f"),
		"fn(any) -> 1|string", "and the first of each statement is still unioned")
		test.equal(typeOf("local function f() return end", "f"), "fn()",
		"a bare return hands back nothing at all")
		test.equal(typeOf("local function f() end", "f"), "fn()",
		"and a body with no return statement is the same")
	test.equal(typeOf("local function f() return g() end", "f"), "fn() -> unknown",
		"a call it cannot type is unknown rather than invented")
end)

test.it("types a call from what the callee returns", function()
	-- The names avoid the parameter's, since a lookup takes the first of that name.
	local source = table.concat({
		"local function one() return 1 end\n",
		"local function mixed(a) if a then return 1 end return \"s\" end\n",
		"local fromOne = one()\n",
		"local fromMixed = mixed(true)\n",
	}, "")
	test.equal(typeOf(source, "fromOne"), "1")
	test.equal(typeOf(source, "fromMixed"), "1|string")
end)

test.it("infers the return of a function that only names its parameters", function()
	-- `@param` says what goes in, and says nothing about what comes out.
	local source = table.concat({
		"---@param x string\n",
		"local function test(x)\n",
		"\tprint(x)\n",
		"\treturn 5\n",
		"end\n",
	}, "")
	test.equal(typeOf(source, "test"), "fn(string) -> 5")

	local stub = "---@param x string\nlocal function test(x)\n\tprint(x)\nend\n"
	-- Nothing is claimed yet, and the answer is recomputable: a body that returns something
	-- promotes the unknown it started as, so a call typed before the body is read still sees it.
	test.equal(typeOf(stub, "test"), "fn(string) -> unknown",
		"a stub has not said what it returns, so nothing is claimed")
end)

test.it("keeps an annotated return over the inferred one", function()
	local source = table.concat({
		"---@return string\n",
		"local function f() return \"x\" end\n",
		"local v = f()\n",
	}, "")
	test.equal(typeOf(source, "f"), "fn() -> string")
	test.equal(typeOf(source, "v"), "string")
end)

test.it("reports a return that does not fit its annotation", function()
	local source = "---@return string\nlocal function f() return 1 end\n"
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 1, "returning a number from a `@return string` is a mismatch")
	temp = result.diagnostics[1]
	test.truthy(temp.message:match("string"), temp.message)
end)

test.it("leaves extra names unknown when there are fewer values", function()
	-- `local a, b = 1` gives `b` no initializer at all.
	local source = "local a, b = 1"
	test.equal(typeOf(source, "a"), "1")
	test.equal(typeOf(source, "b"), "unknown")
end)

test.it("links a reference to its declaration", function()
	local result = analyzer.analyze("local x = 1\nreturn x + x\n")
	for _, variable in ipairs(result.variables) do
		test.equal(#variable.references, 2, "both uses of x should resolve")
	end
end)

test.it("does not treat a declaration's own name as a reference", function()
	local result = analyzer.analyze("local x = 1")
	test.equal(#result.variables[1].references, 0)
end)

test.it("resolves to the innermost declaration in scope", function()
	local result = analyzer.analyze(table.concat({
		"local x = 1\n",
		"do\n",
		"\tlocal x = 2\n",
		"\tprint(x)\n",
		"end\n",
		"print(x)\n",
	}, ""))
	-- The inner print resolves to the inner x, the outer one to the outer x.
	test.equal(#result.variables[1].references, 1, "outer x is used once")
	test.equal(#result.variables[2].references, 1, "inner x is used once")
end)

test.it("does not resolve a name outside the block that declared it", function()
	local result = analyzer.analyze("do\n\tlocal inner = 1\nend\nprint(inner)\n")
	test.equal(#result.variables[1].references, 0, "the use after `end` is out of scope")
end)

test.it("offers only the names visible at an offset", function()
	local source = table.concat({
		"local outer = 1\n",
		"do\n",
		"\tlocal inner = 2\n",
		"\tprint(outer, inner)\n",
		"end\n",
		"print(outer)\n",
	}, "")
	-- Inside the block both are visible; after it only the outer one is.
	test.equal(table.concat(visibleNames(source, offsetOf(source, "print(outer, inner)")), ","), "inner,outer")
	test.equal(table.concat(visibleNames(source, offsetOf(source, "print(outer)\n")), ","), "outer")
end)

test.it("hides a name until its declaration has been reached", function()
	local source = "print(later)\nlocal later = 1\n"
	test.equal(table.concat(visibleNames(source, offsetOf(source, "print")), ","), "")
end)

test.it("sees parameters inside a function", function()
	local source = "function f(a, b)\n\treturn a\nend\n"
	local names = visibleNames(source, offsetOf(source, "return a"))
	test.truthy(#names >= 2, "both parameters should be visible: " .. table.concat(names, ","))
end)


--- The type a name has at a given offset, as text.
---@param source string
---@param name string
---@param offset integer
---@return string?
local function typeAtOffset(source, name, offset)
	local result = analyzer.analyze(source)
	for _, variable in ipairs(result.variables) do
		if variable.name == name then return types.display(analyzer.typeAt(result, variable, offset)) end
	end
end

test.it("evolves a type as later assignments widen it", function()
	local source = "local x = 5\nx = \"foo\"\n"
	test.equal(typeAtOffset(source, "x", #source), "5|string")
	-- Before the second assignment it is still just a number.
	test.equal(typeAtOffset(source, "x", 12), "5")
end)

test.it("does not evolve a type that an annotation fixed", function()
	local source = "---@type number\nlocal x = 5\nx = \"foo\"\n"
	test.equal(typeAtOffset(source, "x", #source), "number")

	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 1, "assigning a string to a number is an error")
	test.equal(result.diagnostics[1].severity, 1, "it is an error, not a warning")
end)

test.it("narrows away nil inside a truthiness branch", function()
	local source = "---@type string?\nlocal y = \"s\"\nif y then\n\tprint(y)\nend\n"
	local inside = assert(source:find("print(y)", 1, true))
	test.equal(typeAtOffset(source, "y", inside), "string", "nil is not possible in the branch")
	test.equal(typeAtOffset(source, "y", #source), "nil|string", "and possible again after it")
end)

test.it("narrows to nil in the else branch", function()
	local source = "---@type string?\nlocal y = \"s\"\nif y then\n\tprint(y)\nelse\n\tprint(y)\nend\n"
	local branch = assert(source:find("else", 1, true))
	test.equal(typeAtOffset(source, "y", branch + 8), "nil")
end)

test.it("narrows a discriminated union by the field it tests", function()
	local source = table.concat({
		"---@type { foo: number } | { bar: string }\n",
		"local x = { foo = 1 }\n",
		"if x.foo then\n",
		"\tprint(x)\n",
		"end\n",
	}, "")
	local inside = assert(source:find("print(x)", 1, true))
	test.equal(typeAtOffset(source, "x", inside), "{ foo: number }",
		"only the member carrying foo remains")
end)

test.it("accepts a table literal that fits the declared object type", function()
	-- The literal is typed from its fields, so it matches the union member rather than
	-- being a bare table.
	local result = analyzer.analyze("---@type { foo: number }\nlocal x = { foo = 1 }\n")
	test.equal(#result.diagnostics, 0)
end)

test.it("reports an assignment mismatch on the assignment, not the declaration", function()
	local source = '---@type number\nlocal x = 5\nx = "string"\n'
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 1)
	local diagnostic = result.diagnostics[1]
	local assigned = assert(source:find('"string"', 1, true))
	test.equal(diagnostic.start, assigned, "the squiggle belongs under the value that does not fit")
	test.truthy(diagnostic.stop >= diagnostic.start)
end)

test.it("reports a table literal whose field does not fit", function()
	local result = analyzer.analyze("---@type { foo: number }\nlocal x = { foo = \"s\" }\n")
	test.equal(#result.diagnostics, 1)
end)

test.it("widens to a union from two different values", function()
	local source = "local x = 1\nx = \"s\"\nx = true\n"
	local result = analyzer.analyze(source)
	local variable = result.variables[1]
	test.equal(types.display(analyzer.typeAt(result, variable, #source)), "1|string|true")
end)

---@param source string
---@param needle string
---@return integer
local function offsetOf(source, needle)
	local at = assert(source:find(needle, 1, true), needle)
	return at
end

test.it("narrows on a nil comparison", function()
	local source = "---@type string?\nlocal y = \"s\"\nif y ~= nil then\n\tprint(y)\nend\n"
	test.equal(typeAtOffset(source, "y", offsetOf(source, "print")), "string")

	local negated = "---@type string?\nlocal y = \"s\"\nif y ~= nil then\n\tprint(1)\nelse\n\tprint(y)\nend\n"
	test.equal(typeAtOffset(negated, "y", offsetOf(negated, "print(y)")), "nil")
end)

test.it("narrows on a type test", function()
	local source = "---@type string|number\nlocal x = 1\nif type(x) == \"number\" then\n\tprint(x)\nend\n"
	test.equal(typeAtOffset(source, "x", offsetOf(source, "print")), "number")

	local inverted = "---@type string|number\nlocal x = 1\nif type(x) == \"number\" then\n\tprint(1)\nelse\n\tprint(x)\nend\n"
	test.equal(typeAtOffset(inverted, "x", offsetOf(inverted, "print(x)")), "string")
end)

test.it("narrows a negation", function()
	-- `not y` keeps only the falsy members, and the else branch the truthy ones.
	local source = "---@type string?\nlocal y = \"s\"\nif not y then\n\tprint(1)\nelse\n\tprint(y)\nend\n"
	test.equal(typeAtOffset(source, "y", offsetOf(source, "print(y)")), "string")
end)

test.it("narrows inside a while body", function()
	local source = "---@type string?\nlocal y = \"s\"\nwhile y do\n\tprint(y)\nend\n"
	test.equal(typeAtOffset(source, "y", offsetOf(source, "print")), "string")
end)

test.it("narrows inside a repeat body", function()
	local source = "---@type string?\nlocal y = \"s\"\nrepeat\n\tprint(y)\nuntil y == nil\n"
	test.equal(typeAtOffset(source, "y", offsetOf(source, "print")), "string")
end)

test.it("keeps a repeat body un-narrowed for a truthiness test", function()
	-- The body runs before the test, so only a comparison says anything on the first pass.
	local source = "---@type string?\nlocal y = \"s\"\nrepeat\n\tprint(y)\nuntil y\n"
	test.equal(typeAtOffset(source, "y", offsetOf(source, "print")), "nil|string")
end)

test.it("narrows an elseif branch by the conditions before it", function()
	local source = "---@type string?\nlocal y = \"s\"\nif y then\n\tprint(1)\nelseif y == nil then\n\tprint(y)\nend\n"
	test.equal(typeAtOffset(source, "y", offsetOf(source, "print(y)")), "nil")
end)

test.it("narrows every else branch of a chain by the conditions before it", function()
	local source = table.concat({
		"---@type string|number\n",
		"local x = 1\n",
		"if type(x) == \"string\" then\n",
		"\tprint(1)\n",
		"elseif type(x) == \"number\" then\n",
		"\tprint(1)\n",
		"else\n",
		"\tprint(x)\n",
		"end\n",
	}, "")
	-- Both members are excluded by the chain, so nothing is left to narrow to and the
	-- declared type stands rather than a half-applied chain.
	test.equal(typeAtOffset(source, "x", offsetOf(source, "print(x)")), "number|string")
end)

test.it("intersects a nested condition with the one around it", function()
	local source = table.concat({
		"---@type string|number?\n",
		"local x = 1\n",
		"if x then\n",
		"\tif type(x) == \"string\" then\n",
		"\t\tprint(x)\n",
		"\tend\n",
		"end\n",
	}, "")
	test.equal(typeAtOffset(source, "x", offsetOf(source, "print")), "string")
end)

test.it("narrows a while body nested in a branch", function()
	local source = table.concat({
		"---@type string|number?\n",
		"local x = 1\n",
		"if type(x) == \"number\" then\n",
		"\twhile x do\n",
		"\t\tprint(x)\n",
		"\tend\n",
		"end\n",
	}, "")
	test.equal(typeAtOffset(source, "x", offsetOf(source, "print")), "number")
end)

test.it("narrows a branch nested in a while body", function()
	local source = table.concat({
		"---@type string?\n",
		"local y = \"s\"\n",
		"while y do\n",
		"\tif y == nil then\n",
		"\t\tprint(1)\n",
		"\telse\n",
		"\t\tprint(y)\n",
		"\tend\n",
		"end\n",
	}, "")
	test.equal(typeAtOffset(source, "y", offsetOf(source, "print(y)")), "string")
end)

test.it("narrows both sides of a conjunction", function()
	local source = table.concat({
		"---@type { foo: number } | { bar: string }\n",
		"local x = { foo = 1 }\n",
		"if x and x.foo then\n",
		"\tprint(x)\n",
		"end\n",
	}, "")
	test.equal(typeAtOffset(source, "x", offsetOf(source, "print(x)")), "{ foo: number }",
		"the second test only means something once the first holds")
end)

test.it("narrows both sides of a disjunction in its else branch", function()
	local source = table.concat({
		"---@type string?\n",
		"local x = \"s\"\n",
		"---@type number?\n",
		"local y = 1\n",
		"if x == nil or y == nil then\n",
		"\tprint(1)\n",
		"else\n",
		"\tprint(x)\n",
		"\tprint(y)\n",
		"end\n",
	}, "")
	-- Neither is nil where the disjunction fails, so both narrow in that branch.
	test.equal(typeAtOffset(source, "x", offsetOf(source, "print(x)")), "string")
	test.equal(typeAtOffset(source, "y", offsetOf(source, "print(y)")), "number")
end)

test.it("asserts nothing where a disjunction holds", function()
	local source = "---@type string?\nlocal x = \"s\"\nif x == nil or x == nil then\n\tprint(x)\nend\n"
	test.equal(typeAtOffset(source, "x", offsetOf(source, "print")), "nil|string",
		"either side could have held, so neither is certain")
end)

test.it("narrows an outer name before an inner one shadows it", function()
	local source = table.concat({
		"---@type string?\n",
		"local x = \"s\"\n",
		"if x then\n",
		"\tprint(x)\n",
		"\t---@type string?\n",
		"\tlocal x = nil\n",
		"\tprint(x)\n",
		"end\n",
	}, "")
	test.equal(typeAtOffset(source, "x", offsetOf(source, "print(x)")), "string",
		"the inner declaration is not in scope yet")
end)

test.it("never lets an inner declaration inherit an outer narrowing", function()
	local source = table.concat({
		"---@type string?\n",
		"local x = \"s\"\n",
		"if x then\n",
		"\tprint(1)\n",
		"\t---@type string?\n",
		"\tlocal x = nil\n",
		"\tprint(x)\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source)
	local at = offsetOf(source, "print(x)")
	local inner = assert(analyzer.lookupAt(result, "x", at), "the inner one resolves here")
	test.equal(types.display(analyzer.typeAt(result, inner, at)), "nil|string",
		"a different variable, so the outer branch says nothing about it")
	test.equal(typeAtOffset(source, "x", at), "string", "and the outer one is still narrowed")
end)

test.it("hard types a function from its own annotations", function()
	local source = table.concat({
		"---@param n number\n",
		"---@return string\n",
		"local function f(n) end\n",
		"local g = f\n",
		"f = 5\n",
	}, "")
	local result = analyzer.analyze(source)
	local byName = {}
	for _, variable in ipairs(result.variables) do byName[variable.name] = variable end
	test.equal(types.display(byName.f.declared), "fn(number) -> string")
	test.equal(types.display(analyzer.typeAt(result, byName.g, #source)), "fn(number) -> string",
		"the signature travels with the function")
	test.equal(#result.diagnostics, 1, "assigning a number to a function is an error")
	test.truthy(result.diagnostics[1].message:match("fn%(number%) %-> string"), result.diagnostics[1].message)
end)

test.it("rejects a function whose signature does not fit", function()
	local source = table.concat({
		"---@param s string\n",
		"local function wants(s) end\n",
		"---@param n number\n",
		"local function gives(n) end\n",
		"wants = gives\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 1, "a parameter that cannot accept the argument is a mismatch")
	test.truthy(result.diagnostics[1].message:match("fn%(number%) %-> unknown"), result.diagnostics[1].message)
end)

test.it("keeps a function's name visible after its own declaration", function()
	-- The body's scope used to open at the statement, which put the name inside it.
	local source = "local function f() end\nlocal g = f\n"
	local result = analyzer.analyze(source)
	local g = result.variables[2]
	test.equal(types.display(analyzer.typeAt(result, g, #source)), "fn()",
		"and it carries what f returns, which is nothing")
end)

test.it("reports arithmetic on a type that cannot be a number", function()
	local annotated = "---@param x string\nlocal y = |x| -> x * 2\n"
	local result = analyzer.analyze(annotated)
	test.equal(#result.diagnostics, 1, "a string cannot be multiplied")
	test.truthy(result.diagnostics[1].message:match("needs numbers"), result.diagnostics[1].message)

	local values = "---@type string\nlocal s = \"a\"\nlocal n = s * 2\n"
	test.equal(#analyzer.analyze(values).diagnostics, 1)

	test.equal(#analyzer.analyze("local n = 2 * 3\n").diagnostics, 0)
end)

test.it("claims nothing about arithmetic on an any", function()
	-- Whatever an `any` holds may have a metamethod, so the result is unknown rather than a
	-- number, and nothing is reported against it.
	local source = "local y = |x| -> x * 2\n"
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 0)
	local y = result.variables[1]
	test.equal(types.display(analyzer.typeAt(result, y, #source)), "fn(any) -> unknown")
end)

test.it("types a field through the class its name is annotated with", function()
	local source = table.concat({
		"---@class Point\n",
		"---@field x number\n",
		"---@field y number\n",
		"local Point = {}\n",
		"---@param p Point\n",
		"local function at(p)\n",
		"\tlocal sx = p.x\n",
		"\treturn sx\n",
		"end\n",
	}, "")
	test.equal(typeOf(source, "sx"), "number")
end)

test.it("keeps a generic class nominal in its arguments", function()
	local source = table.concat({
		"---@class Box<T>\n",
		"---@field item T\n",
		"local Box = {}\n",
		"---@param b Box<number>\n",
		"local function unbox(b) end\n",
		"---@type Box<string>\n",
		"local wrong = {}\n",
		"unbox(wrong)\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 1, "Box<string> is not Box<number>")
	test.truthy(result.diagnostics[1].message:match("Box<number>"), result.diagnostics[1].message)
	test.truthy(result.diagnostics[1].message:match("Box<string>"), result.diagnostics[1].message)
end)

test.it("reads a bare generic class as unknown in its arguments", function()
	local source = table.concat({
		"---@class Box<T>\n",
		"---@field item T\n",
		"local Box = {}\n",
		"---@type Box\n",
		"local loose = {}\n",
		"local value = loose.item\n",
	}, "")
	test.equal(#analyzer.analyze(source).diagnostics, 0, "an unspecified argument is unknown, not a mismatch")
end)

test.it("accepts a table for a class", function()
	-- `local Foo = {}` is how the class itself is declared, and how an instance is built.
	local source = table.concat({
		"---@class Point\n",
		"---@field x number\n",
		"---@type Point\n",
		"local built = { x = 1 }\n",
	}, "")
	test.equal(#analyzer.analyze(source).diagnostics, 0)
end)

test.it("lets a child class stand in for its parent", function()
	local source = table.concat({
		"---@class Animal\n",
		"---@field name string\n",
		"local Animal = {}\n",
		"---@class Dog: Animal\n",
		"---@field barks boolean\n",
		"local Dog = {}\n",
		"---@param a Animal\n",
		"local function pet(a) end\n",
		"---@type Dog\n",
		"local dog = {}\n",
		"pet(dog)\n",
	}, "")
	test.equal(#analyzer.analyze(source).diagnostics, 0)
end)

test.it("narrows a union of classes by the field it tests", function()
	local source = table.concat({
		"---@class Cat\n",
		"---@field meows boolean\n",
		"local Cat = {}\n",
		"---@class Dog\n",
		"---@field barks boolean\n",
		"local Dog = {}\n",
		"---@param a Cat|Dog\n",
		"local function speak(a)\n",
		"\tif a.meows then\n",
		"\t\tlocal c = a\n",
		"\telse\n",
		"\t\tlocal d = a\n",
		"\tend\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source)
	local at = assert(source:find("local c", 1, true))
	local byName = {}
	for _, variable in ipairs(result.variables) do byName[variable.name] = variable end
	test.equal(types.display(analyzer.typeAt(result, byName.c, at)), "Cat")
	test.equal(types.display(analyzer.typeAt(result, byName.d, at)), "Dog")
end)

test.it("resolves an alias where a type is written", function()
	local source = table.concat({
		"---@alias Id number|string\n",
		"---@param id Id\n",
		"local function keyed(id) end\n",
		"keyed(1)\n",
		"keyed(\"a\")\n",
		"keyed(true)\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 1, "a boolean is not an Id")
	test.truthy(result.diagnostics[1].message:match("number|string"), result.diagnostics[1].message)
end)

test.it("evolves a class with the methods declared on it", function()
	local source = table.concat({
		"---@class Dog\n",
		"---@field name string\n",
		"local Dog = {}\n",
		"function Dog:bark()\n",
		"\treturn \"woof\"\n",
		"end\n",
		"---@type Dog\n",
		"local d = {}\n",
		"local field = d.bark\n",
		"local called = d:bark()\n",
	}, "")
	test.equal(typeOf(source, "field"), "fn() -> string", "the method is a field of the class")
	test.equal(typeOf(source, "called"), "string", "and calling it yields what it returns")
end)

test.it("types self as the class its method was declared on", function()
	local source = table.concat({
		"---@class Dog\n",
		"---@field name string\n",
		"local Dog = {}\n",
		"function Dog:rename(to)\n",
		"\tlocal before = self.name\n",
		"\treturn before\n",
		"end\n",
	}, "")
	test.equal(typeOf(source, "before"), "string")
end)

test.it("reports a field read outside the class that keeps it", function()
	local source = table.concat({
		"---@class Account\n",
		"---@field name string\n",
		"---@field private balance number\n",
		"---@field protected limit number\n",
		"local Account = {}\n",
		"---@type Account\n",
		"local a = {}\n",
		"local open = a.name\n",
		"local secret = a.balance\n",
		"local guarded = a.limit\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 2, "a public field is fine; the other two are not")
	test.truthy(result.diagnostics[1].message:match("private"), result.diagnostics[1].message)
	test.truthy(result.diagnostics[2].message:match("protected"), result.diagnostics[2].message)
end)

test.it("allows a class to read its own fields", function()
	local source = table.concat({
		"---@class Account\n",
		"---@field private balance number\n",
		"local Account = {}\n",
		"function Account:peek()\n",
		"\treturn self.balance\n",
		"end\n",
	}, "")
	test.equal(#analyzer.analyze(source).diagnostics, 0)
end)

test.it("allows a subclass to read a protected field", function()
	local source = table.concat({
		"---@class Account\n",
		"---@field protected limit number\n",
		"local Account = {}\n",
		"---@class Savings: Account\n",
		"local Savings = {}\n",
		"function Savings:check()\n",
		"\treturn self.limit\n",
		"end\n",
	}, "")
	test.equal(#analyzer.analyze(source).diagnostics, 0)
end)

test.it("binds a generic from the argument it is given", function()
	local source = table.concat({
		"---@generic T\n",
		"---@param item T\n",
		"---@return T\n",
		"local function id(item) return item end\n",
		"local n = id(5)\n",
		"local s = id(\"a\")\n",
	}, "")
	test.equal(typeOf(source, "n"), "5")
	test.equal(typeOf(source, "s"), "string")
	test.equal(#analyzer.analyze(source).diagnostics, 0, "a generic name is not something to check an argument against")
end)

test.it("spreads a variadic generic through a list", function()
	-- What `unpack` needs, and what LuaLS writes ten parameters to imitate.
	local source = table.concat({
		"---@generic T...\n",
		"---@param list { [integer]: T }\n",
		"---@param i? integer\n",
		"---@return T...\n",
		"function unpack(list, i) end\n",
		"---@type number[]\n",
		"local list = {}\n",
		"local first = unpack(list)\n",
	}, "")
	test.equal(typeOf(source, "first"), "number")
	test.equal(#analyzer.analyze(source).diagnostics, 0)
end)

test.it("gives every name in a spread assignment the same type", function()
	local source = table.concat({
		"---@generic T...\n",
		"---@param list { [integer]: T }\n",
		"---@return T...\n",
		"function unpack(list) end\n",
		"---@type string[]\n",
		"local list = {}\n",
		"local a, b = unpack(list)\n",
	}, "")
	test.equal(typeOf(source, "a"), "string")
	test.equal(typeOf(source, "b"), "string", "the second name gets the spread's type too")
end)

test.it("reads a generic marker on either side of its name", function()
	for _, marker in ipairs({ "T...", "...T" }) do
		local source = "---@generic " .. marker .. "\n---@param item T\n---@return T\nlocal function id(item) return item end\nlocal out = id(true)\n"
		test.equal(typeOf(source, "out"), "true", marker)
	end
end)

test.it("types a declaration as the class declared above it", function()
	local source = table.concat({
		"---@class Point\n",
		"---@field x number\n",
		"local Point = {}\n",
		"local p = Point\n",
		"local x = p.x\n",
	}, "")
	test.equal(typeOf(source, "Point"), "Point")
	test.equal(typeOf(source, "p"), "Point")
	test.equal(typeOf(source, "x"), "number")
	test.equal(#analyzer.analyze(source).diagnostics, 0)
end)

test.it("reads the standard library through a prepared prelude", function()
	local prelude = analyzer.prelude({
		basic = table.concat({
			"---@generic T...\n",
			"---@param list { [integer]: T }\n",
			"---@return T...\n",
			"function unpack(list) end\n",
		}, ""),
	})
	local source = "local a, b = unpack({ \"x\", \"y\" })\n"
	local bare = analyzer.analyze(source)
	local with = analyzer.analyze(source, prelude)
	local first = with.variables[1]
	local second = with.variables[2]
	test.equal(types.display(analyzer.typeAt(bare, bare.variables[1], #source)), "unknown",
		"without the definitions there is nothing to read")
	test.equal(types.display(analyzer.typeAt(with, first, #source)), "string")
	test.equal(types.display(analyzer.typeAt(with, second, #source)), "string")
	test.equal(#with.diagnostics, 0)
end)

test.it("checks an argument against its parameter type", function()
	local bad = analyzer.analyze("---@param a string\nlocal function f(a) end\nf(5)\n")
	test.equal(#bad.diagnostics, 1)
	test.truthy(bad.diagnostics[1].message:match("expects string"))
	test.equal(bad.diagnostics[1].severity, 1)

	test.equal(#analyzer.analyze("---@param a string\nlocal function f(a) end\nf(\"s\")\n").diagnostics, 0)
	-- An argument whose type cannot be inferred must not be reported.
	test.equal(#analyzer.analyze(
		"---@return unknown\nlocal function g() end\n---@param a string\nlocal function f(a) end\nf(g())\n"
	).diagnostics, 0)
end)

test.it("checks each argument against its own parameter", function()
	local result = analyzer.analyze(
		"---@param a string\n---@param b number\nlocal function f(a, b) end\nf(\"s\", \"t\")\n"
	)
	test.equal(#result.diagnostics, 1)
	test.truthy(result.diagnostics[1].message:match("expects number"))
end)

test.it("propagates a declared return type to the assignment", function()
	local source = "---@return string\nlocal function g() end\nlocal x = g()\n"
	local result = analyzer.analyze(source)
	local variable
	for _, candidate in ipairs(result.variables) do
		if candidate.name == "x" then variable = candidate end
	end
	test.equal(types.display(analyzer.typeAt(result, variable, #source)), "string")
end)

test.it("limits a generic name to what it is declared to be", function()
	local prelude = analyzer.prelude({
		lib = table.concat({
			"---@generic T: table, V\n",
			"---@param t T\n",
			"---@return V\n",
			"function count(t) end\n",
		}, ""),
	})
	local ok = analyzer.analyze("local n = count({ 1 })\n", prelude)
	test.equal(#ok.diagnostics, 0, "a list is a table, and V is a name rather than a type")
	local bad = analyzer.analyze("local n = count(5)\n", prelude)
	test.equal(#bad.diagnostics, 1)
	test.truthy(bad.diagnostics[1].message:match("count expects table, got 5"))
end)

test.it("keeps a generic optional and still binds it", function()
	local prelude = analyzer.prelude({
		basic = table.concat({
			"---@generic T\n",
			"---@param v? T\n",
			"---@return T\n",
			"function assert(v) end\n",
		}, ""),
	})
	local result = analyzer.analyze("local a = assert(5)\n", prelude)
	test.equal(#result.diagnostics, 0, "an optional type is not nil on its own")
	test.equal(types.display(result.variables[1].initializer), "5")
end)

test.it("accepts a list where a table is wanted", function()
	local prelude = analyzer.prelude({ lib = "---@param t table\nfunction count(t) end\n" })
	test.equal(#analyzer.analyze("count({ 1, 2 })\n", prelude).diagnostics, 0)
	test.equal(#analyzer.analyze("count(\"s\")\n", prelude).diagnostics, 1)
end)

test.it("types a standard library table from the class that describes it", function()
	local prelude = analyzer.prelude({
		math = table.concat({
			"---@class mathlib\n",
			"math = {}\n",
			"---@param x number\n",
			"---@return number\n",
			"function math.floor(x) end\n",
		}, ""),
	})
	local source = "local n = math.floor(1.5)\n"
	local result = analyzer.analyze(source, prelude)
	test.equal(#result.diagnostics, 0)
	test.equal(types.display(analyzer.typeAt(result, result.variables[1], #source)), "number")

	local bad = analyzer.analyze("local n = math.floor(\"s\")\n", prelude)
	test.equal(#bad.diagnostics, 1)
	test.truthy(bad.diagnostics[1].message:match("math.floor expects number, got \"s\""),
		"the literal is named as the string it is")
end)

test.it("types the result of setmetatable as the metatable's class", function()
	local prelude = analyzer.prelude({
		basic = table.concat({
			"---@generic T: table\n",
			"---@param object table\n",
			"---@param metatable? T\n",
			"---@return T\n",
			"function setmetatable(object, metatable) end\n",
		}, ""),
	})
	local source = table.concat({
		"---@class Point\n",
		"---@field x number\n",
		"local Point = {}\n",
		"local p = setmetatable({}, Point)\n",
		"local x = p.x\n",
	}, "")
	local result = analyzer.analyze(source, prelude)
	test.equal(#result.diagnostics, 0)
	local byName = {}
	for _, variable in ipairs(result.variables) do byName[variable.name] = variable end
	test.equal(types.display(analyzer.typeAt(result, byName.p, #source)), "Point",
		"the metatable argument is what T was bound to")
	test.equal(types.display(analyzer.typeAt(result, byName.x, #source)), "number",
		"a field read before the binding settled is worked out again")
end)

test.it("checks an argument passed to a method", function()
	local source = table.concat({
		"---@class Box\n",
		"local Box = {}\n",
		"---@param n number\n",
		"function Box:add(n) end\n",
		"Box:add(\"s\")\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 1)
	test.truthy(result.diagnostics[1].message:match("Box:add expects number, got \"s\""))
	local good = source:gsub('Box:add%("s"%)', "Box:add(2)")
	test.equal(#analyzer.analyze(good).diagnostics, 0)
end)

test.it("types a numeric loop variable as a number", function()
	local source = table.concat({
		"local total = 0\n",
		"for i = 1, 10 do\n",
		"\ttotal = total + i\n",
		"\tlocal doubled = i * 2\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 0, "arithmetic on the control variable is arithmetic on a number")
	test.equal(typeOf(source, "doubled"), "number")
end)

test.it("gives the first name of a generic loop what the iterator yields", function()
	local prelude = analyzer.prelude({
		basic = "---@param t table\n---@return fun(table: unknown, i?: integer):integer, unknown\n---@return integer\nfunction ipairs(t) end\n",
	})
	local source = table.concat({
		"local list = { \"a\", \"b\" }\n",
		"for index, value in ipairs(list) do\n",
		"\tlocal plus = index + 1\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source, prelude)
	local byName = {}
	for _, variable in ipairs(result.variables) do byName[variable.name] = variable end
	test.equal(types.display(analyzer.typeAt(result, byName.index, #source)), "number")
	test.equal(types.display(analyzer.typeAt(result, byName.value, #source)), "unknown",
		"the definitions write one value per signature, so the second name stays unknown")
	test.equal(types.display(analyzer.typeAt(result, byName.plus, #source)), "number")
end)

test.it("lets a class reach itself through a field", function()
	local source = table.concat({
		"---@class Node\n",
		"---@field name string\n",
		"---@field children Node[]\n",
		"local Node = {}\n",
		"---@param n Node\n",
		"local function walk(n)\n",
		"\tlocal child = n.children[1]\n",
		"\tlocal seen = child.name\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 0)
	local byName = {}
	for _, variable in ipairs(result.variables) do byName[variable.name] = variable end
	test.equal(types.display(analyzer.typeAt(result, byName.child, #source)), "Node")
	test.equal(types.display(analyzer.typeAt(result, byName.seen, #source)), "string")
end)

test.it("reads a conjunction by what its left side can be", function()
	local prelude = analyzer.prelude({
		lib = "---@param byteAt integer\n---@return boolean\nfunction isDigit(byteAt) end\n",
	})
	local source = table.concat({
		"local byteAt = 5\n",
		"local digit = byteAt and byteAt >= 48 and byteAt <= 57\n",
	}, "")
	local result = analyzer.analyze(source, prelude)
	local byName = {}
	for _, variable in ipairs(result.variables) do byName[variable.name] = variable end
	test.equal(types.display(analyzer.typeAt(result, byName.digit, #source)), "boolean",
		"a number is never falsy, so the conjunction is the comparison")
end)

test.it("takes any function where a variadic wildcard is wanted", function()
	local source = table.concat({
		"---@param f fn(...) -> ...\n",
		"local function call(f) end\n",
		"---@param a number\n",
		"local function specific(a) return a end\n",
		"call(specific)\n",
	}, "")
	test.equal(#analyzer.analyze(source).diagnostics, 0)
end)

test.it("reads the definitions' map spelling as a table of values", function()
	local source = table.concat({
		"---@param options table<string, number>\n",
		"local function count(options)\n",
		"\tlocal one = options[\"first\"]\n",
		"\treturn one\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 0)
	local byName = {}
	for _, variable in ipairs(result.variables) do byName[variable.name] = variable end
	test.equal(types.display(analyzer.typeAt(result, byName.one, #source)), "number")
end)

test.it("reads a string literal as the one string it spells", function()
	local prelude = analyzer.prelude({
		basic = "---@param index integer|\"#\"\nfunction select(index) end\n",
	})
	test.equal(#analyzer.analyze("select(\"#\")\n", prelude).diagnostics, 0)
	test.equal(#analyzer.analyze("select(1)\n", prelude).diagnostics, 0)
	local mismatch = analyzer.analyze("select(\"all\")\n", prelude)
	test.equal(#mismatch.diagnostics, 1, "another string is not that string")
end)

test.it("narrows a name after a predicate call on its own line", function()
	local source = table.concat({
		"---@param x number?\n",
		"---@return x is -nil\n",
		"local function check(x) end\n",
		"---@param x number?\n",
		"local function use(x)\n",
		"\tcheck(x)\n",
		"\tlocal after = x + 1\n",
		"\treturn after\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 0, "the call proves x is a number for what follows it")
	test.equal(typeOf(source, "after"), "number")
end)

test.it("narrows both branches of a predicate condition", function()
	local source = table.concat({
		"---@param v string|number\n",
		"---@return v is string\n",
		"local function isString(v) end\n",
		"---@param v string|number\n",
		"local function describe(v)\n",
		"\tif isString(v) then\n",
		"\t\tlocal held = v\n",
		"\telse\n",
		"\t\tlocal other = v\n",
		"\tend\n",
		"\tif not isString(v) then\n",
		"\t\tlocal inverted = v\n",
		"\tend\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source)
	local byName = {}
	for _, variable in ipairs(result.variables) do byName[variable.name] = variable end
	test.equal(types.display(analyzer.typeAt(result, byName.held, #source)), "string")
	test.equal(types.display(analyzer.typeAt(result, byName.other, #source)), "number",
		"the else of a predicate is what the type leaves")
	test.equal(types.display(analyzer.typeAt(result, byName.inverted, #source)), "number",
		"`not` swaps which branch the predicate holds in")
end)

test.it("reports code after a call that never returns", function()
	local source = table.concat({
		"---@return never\n",
		"local function fail() end\n",
		"local function run()\n",
		"\tfail()\n",
		"\tlocal dead = 1\n",
		"\treturn dead\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 1, "only the first statement past it is reported")
	test.truthy(result.diagnostics[1].message:match("fail never returns"))
	test.equal(result.diagnostics[1].severity, 1)
	local at = assert(source:find("local dead", 1, true))
	local start, stop = result.diagnostics[1].start, result.diagnostics[1].stop
	test.equal(source:sub(start, stop), "local dead = 1", "the span is the statement that cannot run")
	test.equal(start, at, "which is the statement right after the call")
end)

test.it("reads error as never through the definitions", function()
	local prelude = analyzer.prelude({
		basic = "---@param message any\n---@return never\nfunction error(message) end\n",
	})
	local source = table.concat({
		"local function load()\n",
		"\terror(\"missing\")\n",
		"\treturn 1\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source, prelude)
	test.equal(#result.diagnostics, 1)
	test.truthy(result.diagnostics[1].message:match("error never returns"))
end)

test.it("narrows past a branch that cannot fall through", function()
	local prelude = analyzer.prelude({
		basic = table.concat({
			"---@class handle*\n",
			"local handle = {}\n",
			"---@return string\n",
			"function handle:read() end\n",
			"---@param message any\n",
			"---@return never\n",
			"function error(message) end\n",
		}, ""),
	})
	local source = table.concat({
		"---@param handle handle*?\n",
		"local function open(handle)\n",
		"\tif not handle then\n",
		"\t\terror(\"no handle\")\n",
		"\tend\n",
		"\tlocal body = handle:read()\n",
		"\treturn body\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source, prelude)
	test.equal(#result.diagnostics, 0)
	local byName = {}
	for _, variable in ipairs(result.variables) do byName[variable.name] = variable end
	test.equal(types.display(analyzer.typeAt(result, byName.body, #source)), "string",
		"the branch that raises leaves the name narrowed for the rest of the block")
end)

test.it("says nothing about a value that never exists", function()
	local source = table.concat({
		"---@return never\n",
		"local function fail() end\n",
		"local function run()\n",
		"\tlocal x = fail()\n",
		"\treturn x\n",
		"end\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 1, "the statement after it, and nothing about `never` itself")
end)

test.it("calls a name the file assigns a global, and not one nothing names", function()
	local result = analyzer.analyze(table.concat({
		"_ = 1\n",
		"local function read() return _ end\n",
		"read()\n",
		"notify()\n",
	}, ""))
	local undefined = {}
	for _, entry in ipairs(result.diagnostics) do
		if entry.message:match("^undefined global") then undefined[#undefined + 1] = entry.message end
	end
	test.equal(#undefined, 1, "only the call nothing declares")
	test.equal(undefined[1], "undefined global `notify`")
end)

local FIELD_SOURCE = table.concat({
	"---@class App\n",
	"---@field call fun(self: App, x: string): number\n",
	"\n",
	"---@type App\n",
	"local x = {}\n",
	"\n",
}, "")

test.it("takes a method's parameters from the field it is written for", function()
	local source = FIELD_SOURCE .. "function x:call(y)\n\treturn #y\nend\n"
	test.equal(typeOf(source, "y"), "string", "the field says what the method takes")
end)

test.it("reads a function assigned to a field the same way", function()
	local source = FIELD_SOURCE .. "x.call = function(y)\n\treturn #y\nend\n"
	test.equal(typeOf(source, "y"), "string", "the assignment form is the same function")
end)

test.it("checks a method call against the field, receiver included", function()
	local source = FIELD_SOURCE .. "function x:call(y)\n\treturn #y\nend\n\nx:call(1)\n"
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 1, "one argument cannot be what the field says")
	test.equal(result.diagnostics[1].message, "x:call expects string, got 1")
end)

--- The library a document is analysed against, written down here the way LuaJIT has it for the
--- parts these tests use.
local METATABLE_PRELUDE = analyzer.prelude({
	basic = table.concat({
		"---@class lye.Metatable<T: table>\n",
		"---@field __index? table|fun(self: T, key: any): any\n",
		"---@field __newindex? table|fun(self: T, key: any, value: any)\n",
		"---@field __add? fun(a: T, b: T): T\n",
		"---@field __concat? fun(a: T, b: T): string|T\n",
		"\n",
		"---@generic T: table\n",
		"---@param table T\n",
		"---@param metatable? lye.Metatable<table>\n",
		"---@return T\n",
		"function setmetatable(table, metatable) end\n",
	}, ""),
})

---@param source string
---@param name string
---@return boolean
local function mentions(source, name)
	for _, entry in ipairs(analyzer.analyze(source, METATABLE_PRELUDE).diagnostics) do
		if entry.message:find(name, 1, true) then return true end
	end
	return false
end

local VECTOR = table.concat({
	"---@class Vec\n",
	"---@field x number\n",
	"local Vec = {}\n",
	"\n",
	"Vec.__index = Vec\n",
	"\n",
	"---@param a Vec\n",
	"---@param b Vec\n",
	"---@return Vec\n",
	"function Vec.__add(a, b) end\n",
	"\n",
	"local v = setmetatable({ x = 1 }, Vec)\n",
}, "")

test.it("carries the metatable a value was given, and reads its fields through it", function()
	local source = VECTOR .. "local x = v.x\n"
	local result = analyzer.analyze(source, METATABLE_PRELUDE)
	local byName = {}
	for _, variable in ipairs(result.variables) do byName[variable.name] = variable end
	test.equal(types.display(analyzer.typeAt(result, byName.x, #source)), "number",
		"the field the class declares")
	local held = analyzer.typeAt(result, byName.v, #source)
	test.truthy(types.metatableOf(held), "the metatable is kept on the type, not thrown away")
end)

test.it("computes an operator through the metamethod the type defines", function()
	local source = VECTOR .. "local sum = v + v\n"
	local result = analyzer.analyze(source, METATABLE_PRELUDE)
	local byName = {}
	for _, variable in ipairs(result.variables) do byName[variable.name] = variable end
	test.equal(types.display(analyzer.typeAt(result, byName.sum, #source)), "Vec",
		"`__add` returns a Vec, so `v + v` is one")
end)

test.it("refuses a metatable whose metamethods are not functions", function()
	test.truthy(mentions("local t = setmetatable({}, { __add = 5 })\n",
		"expects lye.Metatable"), "a number is not a metamethod")
	test.truthy(mentions("local t = setmetatable({}, { __pluss = function() end })\n",
		"`__pluss` is not a metamethod"), "Lua has no such metamethod")
	test.truthy(mentions(table.concat({
		"---@param a string\n",
		"---@param b string\n",
		"local function add(a, b) end\n",
		"local t = setmetatable({}, { __add = add })\n",
	}, ""), "`__add` takes string as argument 1"), "an operand of another kind")
	local result = analyzer.analyze(table.concat({
		"---@param a table\n",
		"---@param b table\n",
		"local function add(a, b) end\n",
		"local t = setmetatable({}, { __add = add, __index = { x = 1 } })\n",
	}, ""), METATABLE_PRELUDE)
	local reported = {}
	for _, entry in ipairs(result.diagnostics) do
		if not entry.message:match("^unused") then reported[#reported + 1] = entry.message end
	end
	test.equal(#reported, 0, table.concat(reported, " / "))
end)

test.it("reports a type name nothing declares", function()
	local source = table.concat({
		"---@class Vec\n",
		"local Vec = {}\n",
		"---@param a Vec\n",
		"---@return s\n",
		"function Vec.copy(a) end\n",
	}, "")
	local reported = {}
	for _, entry in ipairs(analyzer.analyze(source).diagnostics) do
		reported[#reported + 1] = entry.message
	end
	test.equal(#reported, 1, table.concat(reported, " / "))
	test.equal(reported[1], "unknown type `s`")

	---@param source string
	---@return string[]
	local function unknowns(source, elsewhere)
		local found = {}
		for _, entry in ipairs(analyzer.analyze(source, nil, elsewhere).diagnostics) do
			if entry.message:match("^unknown type") then found[#found + 1] = entry.message end
		end
		return found
	end

	test.equal(#unknowns("---@class Box<T>\nlocal Box = {}\n---@param b Box<string>\nlocal function f(b) end\n"), 0,
		"a generic spelling is the class it names")
	test.equal(#unknowns("---@generic T: table\n---@param v T\n---@return T\nlocal function id(v) end\n"), 0,
		"a generic name is declared by the annotation that limits it")
	test.equal(#unknowns("---@param t thread\n---@param u userdata\n---@param c cdata\nlocal function g(t, u, c) end\n"), 0,
		"the engine's own names are types")
	test.equal(#unknowns(table.concat({
		"---@class file*\n",
		"local file = {}\n",
		"---@param f file*\n",
		"local function h(f) end\n",
	}, "")), 0, "a class whose name carries the marker is the class it names")
	-- The set of names other files declare is the third argument to `analyze`; the server and the
	-- batch checker pass it, and the sweep of this repository is what exercises it.
	test.equal(#unknowns("---@param p Elsewhere\nlocal function f(p) end\n"), 1,
		"a name nothing declares here is reported")
end)

--- A library with `error` declared, so a branch that calls it cannot fall through and the
--- narrowing after it is what is being measured rather than the missing definition.
local NEVER = analyzer.prelude({
	basic = table.concat({
		"---@param message any\n",
		"---@param level? integer\n",
		"---@return never\n",
		"function error(message, level) end\n",
	}, ""),
})

---@param body string what the function does between the check and the read
---@return number how many diagnostics a declared `-> string` reports
local function narrowedField(body)
	local source = table.concat({
		"---@class Config\n",
		"---@field name string?\n",
		"---@field other number?\n",
		"local Config = {}\n",
		"---@param config Config\n",
		"---@param other Config\n",
		"---@param touch fun(c: Config)\n",
		"---@return string\n",
		"local function read(config, other, touch)\n",
		"\tif config.name == nil then error(\"no name\") end\n",
		body,
		"\treturn config.name\n",
		"end\n",
	}, "")
	local count = 0
	for _, entry in ipairs(analyzer.analyze(source, NEVER).diagnostics) do
		if not entry.message:match("^unused") then count = count + 1 end
	end
	return count
end

test.it("narrows a field for what follows, until something could change it", function()
	test.equal(narrowedField(""), 0, "the check holds, so the field reads as a string")
	test.equal(narrowedField("\tconfig.name = nil\n"), 1, "writing the field ends the fact")
	test.equal(narrowedField("\tconfig.other = 1\n"), 1, "and so does writing another field of it")
	test.equal(narrowedField("\tconfig = other\n"), 1, "or the object itself")
	test.equal(narrowedField("\ttouch(config)\n"), 1, "and any call, which may hold the same table")
end)

test.it("types a method's parameters from the field it implements", function()
	-- `function Cache:put()` names the class, which is also a local holding the table it was built
	-- from: the parameter types come from what the reader wrote on the field, not from the method
	-- the class grew out of this very declaration.
	local source = table.concat({
		"---@class Cache\n",
		"---@field put fn(self: Cache, key: string, value: string)\n",
		"local Cache = {}\n",
		"Cache.__index = Cache\n",
		"function Cache:put(key, value)\n",
		"\trawset(self, key, value)\n",
		"end\n",
	}, "")
	test.equal(typeOf(source, "self"), "Cache")
	test.equal(typeOf(source, "key"), "string", "the field says what the method takes")
	test.equal(typeOf(source, "value"), "string")

	local annotated = table.concat({
		"---@class App\n",
		"---@field call fun(self: App, x: string): number\n",
		"---@type App\n",
		"local app = {}\n",
		"function app:call(y)\n",
		"\treturn #y\n",
		"end\n",
	}, "")
	test.equal(typeOf(annotated, "y"), "string", "and the same when the value is typed")
end)

test.it("narrows a tagged union by its discriminant", function()
	-- Without the discriminant there is no narrowing, and the second read would be `nil|string`
	-- against a declared `-> string`: one diagnostic, which is what makes this a test.
	local source = table.concat({
		"---@alias Result { ok: true, value: string } | { ok: false, message: string }\n",
		"---@param parsed Result\n",
		"---@return string\n",
		"local function pick(parsed)\n",
		"\tif parsed.ok then return parsed.value end\n",
		"\treturn parsed.message\n",
		"end\n",
	}, "")
	local reported = {}
	for _, entry in ipairs(analyzer.analyze(source).diagnostics) do
		if not entry.message:match("^unused") then reported[#reported + 1] = entry.message end
	end
	test.equal(#reported, 0, table.concat(reported, " / "))

	-- The other half: a body that reads the field of the member it is *not* in is still wrong.
	local wrong = table.concat({
		"---@alias Result { ok: true, value: string } | { ok: false, message: string }\n",
		"---@param parsed Result\n",
		"---@return string\n",
		"local function pick(parsed)\n",
		"\tif parsed.ok then return parsed.message end\n",
		"\treturn parsed.message\n",
		"end\n",
	}, "")
	local broken = 0
	for _, entry in ipairs(analyzer.analyze(wrong).diagnostics) do
		if not entry.message:match("^unused") then broken = broken + 1 end
	end
	test.equal(broken, 1, "the member that carries no `message` cannot be read for one")
end)

test.it("keeps both declarations when a name is declared twice in one scope", function()
	-- A name declared again in the same block shadows itself. Keeping only the last one made the
	-- reads above it resolve to nothing at all, which reported a plain `local x` as an undefined
	-- global the moment a second `local x` appeared further down the file.
	local source = table.concat({
		"local x = 1\n",
		"local first = x\n",
		"local x = \"s\"\n",
		"local second = x\n",
	}, "")
	test.equal(typeOf(source, "first"), "1", "the read above the second declaration is the first x")
	test.equal(typeOf(source, "second"), "string", "and the read below it is the second")
	local result = analyzer.analyze(source)
	for _, entry in ipairs(result.diagnostics) do
		test.truthy(not entry.message:match("undefined global"), entry.message)
		test.truthy(not entry.message:match("unused local `x`"), entry.message)
	end
end)

return true
