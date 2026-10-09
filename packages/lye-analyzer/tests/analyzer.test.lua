--[[
	Tests for name resolution and type inference.
]]

local test = require("lde-test")
local analyzer = require("lye-analyzer")
local types = require("lye-doc.type")

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
	test.equal(types.display(analyzer.typeAt(result, byName.x, #source)), "number|string")
	test.equal(types.display(analyzer.typeAt(result, byName.y, #source)), "number|string",
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
	test.equal(types.display(analyzer.typeAt(result, localX, #source)), "number|string")
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
	test.equal(typeOf("local n = 42", "n"), "number")
	test.equal(typeOf("local t = {}", "t"), "table")
	-- A function is a signature now: its own arity, with an unannotated parameter as `any`,
	-- and a return that is inferred from the body.
	test.equal(typeOf("local f = function() end", "f"), "fn() -> nil")
	test.equal(typeOf("local f = function(a, b) return 1 end", "f"), "fn(any, any) -> number")
	test.equal(typeOf("local f = function(...) return 1 end", "f"), "fn(...) -> number")
	-- The bare `x -> e` shorthand does not declare its parameter, so this has none yet.
	test.equal(typeOf("local a = x -> x", "a"), "fn() -> unknown")
	test.equal(typeOf("local a = |x| -> x", "a"), "fn(any) -> any",
		"the named parameter is declared, and the body is what it returns")
	test.equal(typeOf("local g = true", "g"), "boolean")
end)

test.it("leaves a type unknown when it cannot be inferred", function()
	-- A call with no `@return` says nothing about what it produces.
	test.equal(typeOf("local u = call()", "u"), "unknown")
	test.equal(typeOf("local v = t[k]", "v"), "unknown")
end)

test.it("propagates through every operator", function()
	test.equal(typeOf("local b = 1 + 2", "b"), "number")
	test.equal(typeOf("local s = \"x\" .. \"y\"", "s"), "string")
	-- `..` coerces, so a number on either side still gives a string.
	test.equal(typeOf("local m = \"a\" .. 1", "m"), "string")
	test.equal(typeOf("local c = 1 == 2", "c"), "boolean")
	test.equal(typeOf("local n = -1", "n"), "number")
	test.equal(typeOf("local l = #\"abc\"", "l"), "number")
	test.equal(typeOf("local p = (1)", "p"), "number")
	-- A number and a string cannot be added, so the result is not claimed.
	test.equal(typeOf("local x = 1 + \"s\"", "x"), "unknown")
end)

test.it("propagates through a field of a known object", function()
	test.equal(typeOf("---@type { foo: number }\nlocal t = { foo = 1 }\nlocal v = t.foo", "v"), "number")
end)

test.it("pairs several names with several initializers", function()
	local source = "local a, b = 1, \"two\""
	test.equal(typeOf(source, "a"), "number")
	test.equal(typeOf(source, "b"), "string", "each name gets its own initializer")

	local three = "local a, b, c = \"s\", {}, function() end"
	test.equal(typeOf(three, "a"), "string")
	test.equal(typeOf(three, "b"), "table")
	test.equal(typeOf(three, "c"), "fn() -> nil")
end)

test.it("infers what a function returns from its body", function()
	test.equal(typeOf("local function f() return 1 end", "f"), "fn() -> number")
	test.equal(typeOf("local function f(a) if a then return 1 end return \"s\" end", "f"),
		"fn(any) -> number|string", "every return is unioned")
	test.equal(typeOf("local function f() return 1, \"s\" end", "f"), "fn() -> number|string")
	test.equal(typeOf("local function f() return end", "f"), "fn() -> nil",
		"a bare return gives the caller nil")
	test.equal(typeOf("local function f() end", "f"), "fn() -> nil",
		"and so does never returning")
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
	test.equal(typeOf(source, "fromOne"), "number")
	test.equal(typeOf(source, "fromMixed"), "number|string")
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
	test.equal(typeOf(source, "test"), "fn(string) -> number")

	local stub = "---@param x string\nlocal function test(x)\n\tprint(x)\nend\n"
	test.equal(typeOf(stub, "test"), "fn(string) -> any",
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
	test.equal(typeOf(source, "a"), "number")
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
	test.equal(typeAtOffset(source, "x", #source), "number|string")
	-- Before the second assignment it is still just a number.
	test.equal(typeAtOffset(source, "x", 12), "number")
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
	test.equal(types.display(analyzer.typeAt(result, variable, #source)), "boolean|number|string")
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
	test.truthy(result.diagnostics[1].message:match("fn%(number%) %-> any"), result.diagnostics[1].message)
end)

test.it("keeps a function's name visible after its own declaration", function()
	-- The body's scope used to open at the statement, which put the name inside it.
	local source = "local function f() end\nlocal g = f\n"
	local result = analyzer.analyze(source)
	local g = result.variables[2]
	test.equal(types.display(analyzer.typeAt(result, g, #source)), "fn() -> nil",
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

test.it("checks an argument against its parameter type", function()
	local bad = analyzer.analyze("---@param a string\nlocal function f(a) end\nf(5)\n")
	test.equal(#bad.diagnostics, 1)
	test.truthy(bad.diagnostics[1].message:match("expects string"))
	test.equal(bad.diagnostics[1].severity, 1)

	test.equal(#analyzer.analyze("---@param a string\nlocal function f(a) end\nf(\"s\")\n").diagnostics, 0)
	-- An argument whose type cannot be inferred must not be reported.
	test.equal(#analyzer.analyze("---@param a string\nlocal function f(a) end\nf(g())\n").diagnostics, 0)
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

return true
