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
	analyze = function(source, ...)
		local result = lye.analyze(source, ...)
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
test.it("gives a table the fields its own writes add", function()
	-- `local M = {}` given its functions below is how a Lua module is written, and the table a
	-- `require` hands back is only useful if those writes are part of its shape.
	test.equal(typeOf("local t = {}\nfunction t.f(x) return x end\nlocal held = t.f\n", "held"),
		"fn(any) -> any", "a function declared on the table")
	test.equal(typeOf("local t = {}\nt.f = function(x) return x end\nlocal held = t.f\n", "held"),
		"function", "and one assigned to it")
	test.equal(typeOf("local t = {}\nt.count = 2\nlocal held = t.count\n", "held"), "2",
		"a value written to it")
	test.equal(typeOf("local t = {}\nt.f = 2\nt.f = \"s\"\nlocal held = t.f\n", "held"),
		"2|string", "two writes are two possible values, as they are for a name")
	test.equal(typeOf("local A = { B = {} }\nfunction A.B.f() end\nlocal held = A.B.f\n", "held"),
		"fn()", "and the name it is written on may be dotted")

	-- An annotation governs the value: the literal behind `---@type App` is not where the fields
	-- of an App live, and evolving it would give the same table two different shapes.
	test.equal(typeOf("---@class App\n---@field call fun(self: App): number\n"
		.. "---@type App\nlocal x = {}\nfunction x:call() return 1 end\nlocal held = x.call\n", "held"),
		"fn(App) -> number", "a declared type is the shape, not the literal")
end)

test.it("reads the types an ffi.cdef declares", function()
	-- The header is text in the file, so its types are the file's types: an annotation may name
	-- them, `ffi.new` answers with one, and a member the header never wrote is reported against it.
	-- This is what makes a cdef worth declaring rather than a comment.
	local source = table.concat({
		'local ffi = require("ffi")\n',
		'ffi.cdef[[\n',
		'\ttypedef struct { double x, y; } Vec;\n',
		'\ttypedef struct Node { struct Node *next; int value; } Node;\n',
		'\tenum Color { RED, GREEN = 5 };\n',
		']]\n',
		'local made = ffi.new("Vec")\n',
		'local listed = ffi.new("Vec *")\n',
		'local colored = ffi.new("Color")\n',
		'made.x = 1\n',
		'made.y = 2\n',
		'made.nope = 3\n',
	}, "")
	test.equal(typeOf(source, "made"), "Vec", "a struct the cdef declared")
	test.equal(typeOf(source, "listed"), "Vec", "and a pointer to one is still that struct")
	test.equal(typeOf(source, "colored"), "Color", "an enum's value is a cdata with a name")

	local messages = {}
	for _, entry in ipairs(analyzer.analyze(source).diagnostics) do
		messages[#messages + 1] = entry.message
	end
	test.truthy(table.concat(messages, "; "):match("`nope` is not a field of Vec"),
		"a member the header never declared: " .. table.concat(messages, "; "))
end)

test.it("types a callback from the C signature it was cast to", function()
	-- A Lua function handed to `ffi.cast` is called by C, so the values it is given are the ones
	-- the header declares rather than Lua's: `ptr` is a pointer (not a string) and `size` a
	-- `size_t`. The result crosses back, so what the C says it returns is what the body must give.
	local header = table.concat({
		'local ffi = require("ffi")\n',
		"ffi.cdef[[\n",
		"\ttypedef unsigned long size_t;\n",
		"\ttypedef struct { int x; } Vec;\n",
		"\ttypedef size_t (*write_cb)(char *ptr, size_t size, size_t nmemb, void *userdata);\n",
		"\ttypedef void (*visit_cb)(Vec *item, int count);\n",
		"]]\n",
	}, "")

	local source = header .. table.concat({
		'local cb = ffi.cast("write_cb", function(ptr, size, nmemb, _)\n',
		"\tlocal len = size * nmemb\n",
		"\treturn len\n",
		"end)\n",
		'local visit = ffi.cast("visit_cb", function(item, count)\n',
		"\treturn item.x + count\n",
		"end)\n",
	}, "")
	test.equal(typeOf(source, "ptr"), "ffi.ptr<ffi.char>",
		"a char pointer arrives as a pointer to a char")
	test.equal(typeOf(source, "size"), "ffi.size_t", "a size_t is the cdata type the engine hands over")
	test.equal(typeOf(source, "nmemb"), "ffi.size_t")
	test.equal(typeOf(source, "_"), "ffi.ptr<ffi.cdata>", "and a void pointer points at anything")
	test.equal(typeOf(source, "item"), "Vec", "a struct pointer is the struct the header named")
	test.equal(typeOf(source, "count"), "number")

	-- Not `require`: this suite runs without the definitions, which is a separate matter from what
	-- the callback bodies return.
	local reported = {}
	for _, entry in ipairs(analyzer.analyze(source).diagnostics) do
		if entry.message:match("the result") then reported[#reported + 1] = entry.message end
	end
	test.equal(#reported, 0, "and the bodies give what the C asks for: " .. table.concat(reported, "; "))

	-- A body that gives the wrong thing is reported against the signature it was cast to.
	local wrong = header .. 'local cb = ffi.cast("write_cb", function(ptr, size)\n\treturn "nope"\nend)\n'
	local messages = {}
	for _, entry in ipairs(analyzer.analyze(wrong).diagnostics) do
		if entry.message:match("the result") then messages[#messages + 1] = entry.message end
	end
	test.equal(messages[1], "the result is declared as ffi.size_t but is assigned string",
		table.concat(messages, "; "))
end)

test.it("reports a cdef it could not read where it is written", function()
	-- The message is worth nothing without a place: the offsets the C parser reports are its own, so
	-- they are mapped back into the document and the diagnostic lands on the text inside the
	-- brackets. A header is rarely wrong in only one place, so what could be read is still used.
	local source = table.concat({
		'local ffi = require("ffi")\n',
		'ffi.cdef[[\n',
		'\tstruct Broken { int x }\n',
		'\ttypedef struct { int y; } Good;\n',
		']]\n',
		'local made = ffi.new("Good")\n',
	}, "")
	local reported = {}
	for _, entry in ipairs(analyzer.analyze(source).diagnostics) do
		if entry.message:match("^cdef:") then
			reported[#reported + 1] = {
				message = entry.message, text = source:sub(entry.start, entry.stop),
				severity = entry.severity,
			}
		end
	end
	test.equal(#reported, 1, "one problem, not a crash: " .. #reported)
	test.equal(reported[1].message, "cdef: expected `;`, found `}`")
	test.equal(reported[1].text, "}", "the diagnostic is on the text inside the brackets")
	test.equal(reported[1].severity, 1, "reported as the error it is")
	test.equal(typeOf(source, "made"), "Good", "and the declaration after it is still read")
end)

test.it("reads a cdef type named as a string, and leaves the rest alone", function()
	local source = table.concat({
		'local ffi = require("ffi")\n',
		'ffi.cdef[[ typedef struct { int value; } Node; ]]\n',
		'local known = ffi.new("Node")\n',
		'local pointer = ffi.new("Node *")\n',
		'local missing = ffi.new("Nowhere")\n',
		'local builtin = ffi.new("int[4]")\n',
	}, "")
	test.equal(typeOf(source, "known"), "Node")
	test.equal(typeOf(source, "pointer"), "Node")
	test.equal(typeOf(source, "missing"), "unknown", "a name the header never declared")
	-- `ffi.new("int[4]")` is not a class the cdef made, but it is not nothing either: the mapping
	-- names it, and that is what lets the array be indexed and the length be known.
	test.equal(typeOf(source, "builtin"), "ffi.array<ffi.int, 4>")
end)

test.it("compares a string argument by the value it spells", function()
	-- A long string is the same argument as a quoted one: reading the source instead made
	-- `f([[read]])` a type named after its own brackets, which matched no parameter at all.
	local source = table.concat({
		'---@param mode "read"|"write"\n',
		"local function open_(mode) end\n",
		'open_("read")\n',
		"open_([[write]])\n",
		'open_("nope")\n',
	}, "")
	local messages = {}
	for _, entry in ipairs(analyzer.analyze(source).diagnostics) do
		if not entry.message:match("^unused") then messages[#messages + 1] = entry.message end
	end
	test.equal(#messages, 1, table.concat(messages, "; "))
	test.equal(messages[1], 'open_ expects "read"|"write", got "nope"')
end)

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
	-- The bare `x -> e` shorthand names its one parameter the way the barred form does.
	test.equal(typeOf("local a = x -> x", "a"), "fn(any) -> any")
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

test.it("reads a pattern written at the call to see what the call gives back", function()
	-- `string.find(s, p)` gives two positions and then the captures it made, `string.match` the
	-- captures themselves, and a pattern anchored at both ends cannot fail — so it gives a string
	-- rather than a string that may be absent.
	local source = table.concat({
		"local s = \"n=42\"\n",
		"local start, finish, x = string.find(s, \"(%d+)\")\n",
		"local a, b = s:match(\"(%d+),(%d+)\")\n",
		"local whole = s:match(\"^[%w=]+$\")\n",
		"local at = s:find(\"()%d+\")\n",
		"local out, count = s:gsub(\"%d+\", \"x\")\n",
		"return start, finish, x, a, b, whole, at, out, count\n",
	}, "")
	test.equal(typeOf(source, "start"), "number?", "both positions, and either may be absent")
	test.equal(typeOf(source, "finish"), "number?")
	test.equal(typeOf(source, "x"), "string?", "the capture the pattern makes")
	test.equal(typeOf(source, "a"), "string?")
	test.equal(typeOf(source, "b"), "string?")
	test.equal(typeOf(source, "whole"), "string", "anchored at both ends, so it always matches")
	test.equal(typeOf(source, "at"), "number?", "a position capture is a number")
	test.equal(typeOf(source, "out"), "string", "gsub always gives a result")
	test.equal(typeOf(source, "count"), "number", "and a count")
end)

test.it("gives each name the value the callee returns at its position", function()
	-- `local class, args = resolve(ns, text)`: a function handing back two values fills two names,
	-- whether the values were written down or read off its body.
	local source = table.concat({
		"---@param text string\n",
		"---@return string, string[]\n",
		"local function annotated(text) return text, { text } end\n",
		"---@param text string\n",
		"local function inferred(text) return text, { text } end\n",
		"local a, b = annotated(\"x\")\n",
		"local c, d = inferred(\"y\")\n",
		"return a, b, c, d\n",
	}, "")
	test.equal(typeOf(source, "a"), "string")
	test.equal(typeOf(source, "b"), "string[]", "the second name takes the second value")
	test.equal(typeOf(source, "c"), "string")
	test.equal(typeOf(source, "d"), "string[]", "and an inferred value is no different")
	local result = analyzer.analyze(source)
	test.equal(typeOf(source, "annotated"), "fn(string) -> string, string[]", "both are named")
	test.equal(#(result.signatures.inferred.inferredValues or {}), 2, "and the hover has both")
end)

test.it("infers what a function returns from its body", function()
	test.equal(typeOf("local function f() return 1 end", "f"), "fn() -> 1")
	test.equal(typeOf("local function f(a) if a then return 1 end return \"s\" end", "f"),
		"fn(any) -> 1|string", "every return is unioned")
	-- Every value a statement hands back is named, and the *first* is what a caller reading one
	-- gets: a signature that unioned them would claim `f()` may be a string, and
	-- `local n: number = f()` would be reported against a body that is right.
	test.equal(typeOf("local function f() return 1, \"s\" end", "f"), "fn() -> 1, string",
		"both values are named")
	test.equal(typeOf("local function f() return 1, \"s\" end\nlocal n = f()\n", "n"), "1",
		"and a name reading one value gets the first")
	test.equal(typeOf("local function f(a) if a then return 1, \"s\" end return \"t\", 2 end", "f"),
		"fn(any) -> 1|string, 2|string", "and each position is unioned on its own")
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
	-- Lua gives nil, and now this says so: a literal is one value, so the second name has none.
	test.equal(typeOf(source, "b"), "nil")
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

test.it("does not carry a closed sibling scope into the next block", function()
	local source = table.concat({
		"do\n",
		"\tlocal first = 1\n",
		"\tprint(first)\n",
		"end\n",
		"do\n",
		"\tlocal second = 2\n",
		"\tprint(second)\n",
		"end\n",
		"print(first, second)\n",
	}, "")
	local result = analyzer.analyze(source)
	local after = offsetOf(source, "print(first, second)")
	test.equal(analyzer.lookupAt(result, "first", after), nil)
	test.equal(analyzer.lookupAt(result, "second", after), nil)
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

test.it("takes a declared type as where a name starts and narrows it at the next write", function()
	-- An annotation says what the name is where it is written. Every assignment below is still
	-- checked against it — a string into a `number` is an error either way — but the name is the
	-- written value from there on, which is what makes `x = x or default` narrow `x?` to `x`.
	local source = "---@type number\nlocal x = 5\nx = \"foo\"\n"
	local beforeWrite = source:find('x = "foo"', 1, true) - 1
	test.equal(typeAtOffset(source, "x", beforeWrite), "number", "the annotation, until something writes")
	test.equal(typeAtOffset(source, "x", #source), "string", "and the last write after it")

	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 1, "assigning a string to a number is an error")
	test.equal(result.diagnostics[1].severity, 1, "it is an error, not a warning")
end)

test.it("narrows away nil inside a truthiness branch", function()
	local source = "---@type string?\nlocal y = \"s\"\nif y then\n\tprint(y)\nend\n"
	local inside = assert(source:find("print(y)", 1, true))
	test.equal(typeAtOffset(source, "y", inside), "string", "nil is not possible in the branch")
	test.equal(typeAtOffset(source, "y", #source), "string?", "and possible again after it")
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

test.it("keeps a list a list when the other branch is an empty table", function()
	-- `args ? split(args) : {}` and `args and split(args) or {}` are a list of strings either way:
	-- the empty branch is a container waiting to be filled, so it takes the shape of the other one
	-- rather than widening it to a bare table. A `nil` still counts as a member, because a value
	-- that may be absent is a different question from a container with nothing in it yet.
	local source = table.concat({
		"---@param text string\n",
		"---@return string[]\n",
		"local function split(text) return { text } end\n",
		"---@param args string?\n",
		"local function pick(args)\n",
		"\tlocal list = args ? split(args) : {}\n",
		"\tlocal either = args and split(args) or {}\n",
		"\treturn list, either\n",
		"end\n",
		"local c = nil\n",
		"c = {}\n",
		"return pick, c\n",
	}, "")
	test.equal(typeOf(source, "list"), "string[]", "the empty branch does not widen the list")
	test.equal(typeOf(source, "either"), "string[]", "nor does it widen an `and`/`or`")
	test.equal(typeOf(source, "c"), "table?", "while nil is still part of what it may be")
end)

test.it("accepts a table literal that fits the declared object type", function()
	-- The literal is typed from its fields, so it matches the union member rather than
	-- being a bare table.
	local result = analyzer.analyze("---@type { foo: number }\nlocal x = { foo = 1 }\n")
	test.equal(#result.diagnostics, 0)
end)

test.it("reads a multi-value `---@type` one type per name", function()
	-- `---@type "git" | "path", string` above `local depType, depValue` is how a name per returned
	-- value is annotated. Reading the whole text as both types made each one a union with the other,
	-- so assigning a plain string to either was reported.
	local source = table.concat({
		"---@type \"git\" | \"path\", string?\n",
		"local depType, depValue\n",
		"depType = \"git\"\n",
		"depValue = \"url\"\n",
		"return depType, depValue\n",
	}, "")
	test.equal(#analyzer.analyze(source).diagnostics, 0)
	-- Read where each is written, before the assignment below replaces it.
	test.equal(typeAtOffset(source, "depType", source:find("depType =", 1, true) - 1), '"git"|"path"',
		"the first name takes the first type")
	test.equal(typeAtOffset(source, "depValue", source:find("depValue =", 1, true) - 1), "string?",
		"and the second the second")
end)

test.it("lets a class table be built by assignment", function()
	-- `---@class pkg.Thing` above `local Thing = {}` declares the class and the table it is built on
	-- at once, and `Thing.Config = ...` is how that table gets its fields — the same thing a method
	-- declaration does, written as an assignment. A value *of* the class still has only the fields
	-- the class names.
	local built = table.concat({
		"---@class pkg.Thing\n",
		"---@field name string\n",
		"local Thing = {}\n",
		"Thing.Config = { loud = false }\n",
		"Thing.version = \"1.0\"\n",
		"return Thing\n",
	}, "")
	test.equal(#analyzer.analyze(built).diagnostics, 0, "a class table is filled in by assignment")

	local value = table.concat({
		"---@class pkg.Point\n",
		"---@field x number\n",
		"---@return pkg.Point\n",
		"local function make() return { x = 1 } end\n",
		"local one = make()\n",
		"one.extra = 1\n",
		"return one\n",
	}, "")
	local diagnostics = analyzer.analyze(value).diagnostics
	test.equal(#diagnostics, 1, "a value of the class does not")
	test.equal(diagnostics[1].message, "`extra` is not a field of pkg.Point")
end)

test.it("checks a call chained off another call against its own callee", function()
	-- `load("x").lazy(f)` calls `lazy`. The name the first call was written on travelled onto the
	-- second call's node, so the function was checked against `load`'s `string` parameter — every
	-- `require("x").something(f)` in a project was reported.
	local source = table.concat({
		"local M = {}\n",
		"---@param fn fun(): any\n",
		"function M.lazy(fn) return fn end\n",
		"---@param name string\n",
		"---@return any\n",
		"local function load(name) return M end\n",
		"local held = load(\"x\").lazy(function() return 1 end)\n",
		"return held\n",
	}, "")
	test.equal(#analyzer.analyze(source).diagnostics, 0, "the function is what `lazy` takes")
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
	test.equal(typeAtOffset(source, "y", offsetOf(source, "print")), "string?")
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
	test.equal(typeAtOffset(source, "x", offsetOf(source, "print")), "string?",
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
	test.equal(types.display(analyzer.typeAt(result, inner, at)), "string?",
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

test.it("spans the whole name an argument is written with", function()
	local source = table.concat({
		"---@type string?\n",
		"local maybe = nil\n",
		"---@param a string\n",
		"local function f(a) end\n",
		"f(maybe)\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 1)
	local entry = result.diagnostics[1]
	test.truthy(entry.message:match("f expects string"))
	test.equal(source:sub(entry.start, entry.stop), "maybe",
		"the diagnostic covers the whole name, not its first character")
end)

test.it("checks what an argument past the named ones has to be", function()
	-- `---@param ... string|number` is a promise about every extra argument, so a table or a nil
	-- written there is the same contradiction as one written for a named parameter.
	local source = table.concat({
		"---@param ... string|number\n",
		"local function takes(...) end\n",
		"takes(1, \"a\")\n",
		"takes({})\n",
		"takes(nil)\n",
	}, "")
	local result = analyzer.analyze(source)
	test.equal(#result.diagnostics, 2, "the table and the nil are refused, the number and string are not")
	test.truthy(result.diagnostics[1].message:match("takes expects number|string, got table"),
		result.diagnostics[1].message)
	test.truthy(result.diagnostics[2].message:match("got nil"), result.diagnostics[2].message)
end)

test.it("holds a definition file to its annotations, not to bodies it does not have", function()
	-- `---@meta` says the file describes a library: `---@return true?` over an empty function is
	-- the whole of that function, and there is no body to contradict the annotation.
	local source = "---@meta\n---@type string\nlocal x = 1\nreturn x\n"
	test.equal(#analyzer.analyze(source).diagnostics, 0,
		"a definition file's annotations describe the library rather than a body")

	local same = source:gsub("^%-%-%-@meta\n", "")
	test.equal(#analyzer.analyze(same).diagnostics, 1,
		"and without the marker what is written is checked against what it says")
end)

test.it("checks against the types a definition file writes inline", function()
	-- `local function test(n: number)` and `function generic<T: number>(f: T)` carry their types in
	-- the source rather than in annotations, and they are the signature all the same.
	local source = table.concat({
		"local function test(n: number) return n end\n",
		"function generic<T: number>(f: T) return f end\n",
		"test(\"not a number\")\n",
		"generic({})\n",
		"test(1)\n",
		"return test, generic\n",
	}, "")
	local result = analyzer.analyze(source, nil, nil, nil, nil, nil, nil, true)

	test.equal(#result.diagnostics, 2, "the string and the table are refused, the number is not")
	test.truthy(result.diagnostics[1].message:find("test expects number, got", 1, true),
		result.diagnostics[1].message)
	test.truthy(result.diagnostics[2].message:match("generic expects number, got table"),
		result.diagnostics[2].message)
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
	test.equal(types.display(analyzer.typeAt(result, byName.value, #source)), "string",
		"and the second takes what the table it walks holds, which is what makes `for _, x in ipairs(list)` a string")
	test.equal(types.display(analyzer.typeAt(result, byName.plus, #source)), "number")
end)

test.it("reads what a table holds at a computed key from the writes to it", function()
	local source = table.concat({
		"---@param name string\n",
		"local function mark(name)\n",
		"\tlocal consts = {}\n",
		"\tconsts[name] = true\n",
		"\treturn consts\n",
		"end\n",
		"---@param name string\n",
		"local function add(name)\n",
		"\tlocal names = {}\n",
		"\tnames[#names + 1] = name\n",
		"\treturn names\n",
		"end\n",
		"---@param name string\n",
		"---@param text string\n",
		"local function pair(name, text)\n",
		"\tlocal held = {}\n",
		"\theld[name] = text\n",
		"\tlocal first = held[name]\n",
		"\treturn first\n",
		"end\n",
	}, "")
	test.equal(typeOf(source, "consts"), "table<string, true>",
		"a `true` written at a string key is what makes a table a set")
	test.equal(typeOf(source, "names"), "string[]",
		"a name written one past the end of a list is what makes it a list")
	test.equal(typeOf(source, "held"), "table<string, string>",
		"and a value written at a string key is what the key holds")
	test.equal(typeOf(source, "first"), "string",
		"which is what reading that key back gives")
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
		-- Errors only: what the body infers is reported as a hint, and this counts what is wrong.
		if (entry.severity or 1) < 3 then count = count + 1 end
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

test.it("reads an annotation written after a declaration as that declaration's type", function()
	-- `local pending = {} ---@type string[]` is the other spelling of the same annotation and says
	-- what the declaration on its line is. Read as the block above the *next* line, it typed
	-- `pending` as a plain table and the name below it as a list of strings.
	local source = table.concat({
		"local pending = {} ---@type string[]\n",
		"local other = 1\n",
		"local running = false ---@type boolean\n",
		"local last = \"x\"\n",
		"return pending, other, running, last\n",
	}, "")
	test.equal(typeOf(source, "pending"), "string[]", "the trailing annotation is the line's own")
	test.equal(typeOf(source, "other"), "1", "and is not read as the next declaration's")
	test.equal(typeOf(source, "running"), "boolean")
	test.equal(typeOf(source, "last"), "string", "which keeps what the body infers")
end)

test.it("casts the expression a bracketed annotation is written beside", function()
	-- `f --[[@as Vec]].x` is how a value gets a type where nothing declares one, and the annotation
	-- is read from the comment token it forms — not from the same characters quoted in a comment
	-- that explains the spelling, which attached a cast to whatever sat above the sentence.
	local source = table.concat({
		"---@class Vec\n",
		"---@field x number\n",
		"\n",
		"---@param raw unknown\n",
		"local function read(raw)\n",
		"\tlocal x = raw --[[@as Vec]].x\n",
		"\treturn x\n",
		"end\n",
	}, "")
	test.equal(typeOf(source, "x"), "number", "the field of the cast type is what is read")
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
		if (entry.severity or 1) < 3 then reported[#reported + 1] = entry.message end
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

test.it("reports a parameter annotation naming nothing the function takes", function()
	-- The typo nothing else catches: the annotation is read, the parameter it was meant for keeps
	-- what it would have had, and every call is checked against a signature describing a parameter
	-- the body does not have.
	local function said(source)
		local found = {}
		for _, entry in ipairs(analyzer.analyze(source).diagnostics) do
			if entry.message:match("is not a parameter") then found[#found + 1] = entry.message end
		end
		return table.concat(found, "; ")
	end

	test.equal(said("---@param a number\n---@param c string\nlocal function f(a, b)\n\treturn a, b\nend\n"),
		"`c` is not a parameter of this function")
	test.equal(said("---@param a number\n---@param b string\nlocal function f(a, b)\n\treturn a, b\nend\n"),
		"", "a name that is one of them is left alone")
	test.equal(said("---@class T\nlocal T = {}\n---@param self T\n---@param x number\nfunction T:m(x)\n\treturn x\nend\n"),
		"", "the receiver a method takes is a parameter like any other")
	test.equal(said("---@param ... number\nlocal function f(...)\n\treturn ...\nend\n"),
		"", "the variadic parameter is annotated `...`")
end)

test.it("reads the direction a `---@cast` asserts", function()
	-- `+T` is the value being a T and `-T` is it not being one. Discarding the marker and reading
	-- every cast as `+` made `---@cast query -nil` assert the value *is* nil, which is the opposite
	-- of taking the nil out of it — and the writer sees a wrong type rather than an error.
	local function after(held, cast)
		local source = "---@param q " .. held .. "\nlocal function f(q)\n\t" .. cast
			.. "\n\tlocal here = 1\nend\n"
		local result = analyzer.analyze(source)
		local variable
		for _, one in ipairs(result.variables) do
			if one.name == "q" then variable = one end
		end
		local at = analyzer.typeAt(result, variable, source:find("local here", 1, true) + 4)
		return at and types.display(at) or nil
	end

	test.equal(after("string?", "---@cast q -nil"), "string", "the nil comes out of an optional")
	test.equal(after("string|number", "---@cast q -string"), "number", "and a member out of a union")
	test.equal(after("string|number", "---@cast q -number"), "string")
	test.equal(after("any", "---@cast q +string"), "string", "`+T` says the value is a T")
	test.equal(after("any", "---@cast q string"), "string", "and a bare type says the same thing")
	test.equal(after("string?", "---@cast q +nil"), "nil", "`+nil` says it is nil")
end)

test.it("does not widen a list when a nil write pops it", function()
	-- `t[#t] = nil` removes the last element rather than storing a nil under the key, and taking
	-- the element type to `T?` afterwards made every read of a list optional for one pop.
	local source = "---@type string[]\nlocal pending = {}\npending[#pending + 1] = \"a\"\npending[#pending] = nil\n"
	test.equal(#analyzer.analyze(source).diagnostics, 0)
	test.equal(typeOf(source, "pending"), "string[]")
end)

test.it("gives a name the value at its own position in a multi-value assignment", function()
	-- `a, b = f()` hands `b` the second value; checked against the first, every second name of a
	-- call was reported as a value of the type that came before it.
	local head = "---@return number, string\nlocal function pair() end\n"
		.. "---@type number\nlocal a\n---@type string\nlocal b\n"
	test.equal(#analyzer.analyze(head .. "a, b = pair()\n").diagnostics, 0,
		"the second name takes the second value")
	test.equal(#analyzer.analyze(head .. "a, b = 1, \"s\"\n").diagnostics, 0,
		"a name with an expression of its own takes that one")
	test.equal(#analyzer.analyze(head .. "a = 1, \"s\"\n").diagnostics, 0,
		"and a lone name before several values takes the first")
end)

test.it("keeps the class a name was assigned, not the placeholder it settled from", function()
	-- `cache = defaults` reads as the value written even while that value's type is still being
	-- worked out, so `cache` is a C and not the `C?` it was declared as.
	local source = "---@class C\nlocal C = {}\n"
		.. "---@return C\nfunction C.new() end\n"
		.. "---@type C?\nlocal cache = nil\nconst defaults = C.new()\n"
		.. "---@return C\nlocal function getConfig()\n\tcache = defaults\n\treturn cache\nend\n"
		.. "local held = cache\n"
	local result = analyzer.analyze(source)
	for _, entry in ipairs(result.diagnostics) do
		-- A hint that the `@return C` is redundant is the point: the body is read as giving one.
		test.truthy((entry.severity or 1) >= 3, "no mismatch is reported: " .. entry.message)
	end
	test.equal(typeOf(source, "held"), "C")
end)

test.it("evolves a method onto the class its table declares", function()
	-- `---@class pkg.Thing` above `local Thing = {}` names the class for a table of another name,
	-- and `function Thing:grow()` is a method of it: without the link a call through the class had
	-- no method to read, and its arguments went unchecked.
	local source = "---@class pkg.Thing\n---@field size number\nlocal Thing = {}\n"
		.. "---@param by number\nfunction Thing:grow(by) end\n"
		.. "---@param thing pkg.Thing\nlocal function use(thing)\n\tthing:grow(\"s\")\nend\n"
	local bad = analyzer.analyze(source)
	test.equal(#bad.diagnostics, 1)
	test.truthy(bad.diagnostics[1].message:match("expects number"))
	test.equal(#analyzer.analyze((source:gsub(':grow%("s"%)', ":grow(1)"))).diagnostics, 0)
end)

test.it("narrows after a guard that returns a table literal", function()
	-- The members of a literal belong to it, not to the chunk: taken for statements they made the
	-- clause look like it fell through, and nothing after the guard was narrowed.
	local source = "---@return string?\nlocal function find() end\n"
		.. "local function f()\n\tlocal tag = find()\n"
		.. "\tif not tag then return { error = \"none\" } end\n"
		.. "\tlocal held = tag\n\treturn held\nend\n"
	test.equal(typeOf(source, "held"), "string")
end)

test.it("keeps a class when a fallback is written for it", function()
	-- `opts or {}` is the class when there is one and an empty table otherwise; the fact that the
	-- right operand only runs when `opts` was falsy must not reach back over the left one.
	local source = "---@class Opts\n---@field name string?\n"
		.. "---@param opts Opts?\nlocal function f(opts)\n\topts = opts or {}\n"
		.. "\tlocal held = opts\n\treturn held\nend\n"
	test.equal(typeOf(source, "held"), "Opts")
end)

test.it("types a field of a literal from the name as it is narrowed there", function()
	-- The field is read where the condition holds, so it is the narrowed type and not the optional
	-- one the name was declared with.
	local source = "---@return string?\nlocal function find() end\n"
		.. "local function f()\n\tlocal dir = find()\n\tif dir then\n"
		.. "\t\t---@type { archive: string }\n\t\tlocal entry = { archive = dir }\n"
		.. "\t\treturn entry\n\tend\nend\n"
	test.equal(#analyzer.analyze(source).diagnostics, 0)
end)

test.it("reads a string key in brackets as a field", function()
	-- `["end"] = v` holds what `{ end = v }` holds; leaving it out made the literal miss a member
	-- the annotation that describes it asked for.
	local source = "---@return { duration: number, [\"end\"]: number }\n"
		.. "local function f()\n\tlocal out = { name = \"x\", [\"end\"] = 2, duration = 1 }\n"
		.. "\treturn out\nend\n"
	test.equal(#analyzer.analyze(source).diagnostics, 0)
end)

test.it("does not cast an expression of another branch from a trailing `@cast`", function()
	-- `else ---@cast flag string` has no expression before it: the node ending just above the
	-- annotation belongs to the branch that came before, and casting it turned that branch's
	-- literal into a string.
	local source = "---@param flag boolean\n---@return { a: number }\n"
		.. "local function f(flag)\n\tif flag then\n\t\treturn { a = 1 }\n"
		.. "\telse ---@cast flag string\n\t\treturn { a = 2 }\n\tend\nend\n"
	test.equal(#analyzer.analyze(source).diagnostics, 0)
end)

test.it("reads an `and`/`or` chain as the table it picks", function()
	-- The falsy side of the middle `and` is a value of its own — `false`, not a whole boolean —
	-- and the `or` that follows has to be able to tell it apart from the truthy side.
	local prelude = analyzer.prelude({
		lib = "---@param v any\n---@return string\nfunction type(v) end\n",
	})
	local source = "---@class Port\n---@field versions table<string, string>?\n"
		.. "---@param existing Port?\n---@param fallback table<string, string>\n"
		.. "local function f(existing, fallback)\n"
		.. "\tlocal held = (existing and type(existing.versions) == \"table\") and existing.versions or fallback\n"
		.. "\treturn held\nend\n"
	local result = analyzer.analyze(source, prelude)
	test.equal(#result.diagnostics, 0)
	for _, variable in ipairs(result.variables) do
		if variable.name == "held" then
			test.equal(types.display(analyzer.typeAt(result, variable, #source)), "table<string, string>")
		end
	end
end)

return true
