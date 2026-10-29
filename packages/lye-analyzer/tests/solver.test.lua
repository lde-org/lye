--[[
	The type solver against shapes a small inference pass gets wrong.

	Every test here is a program whose errors are about types rather than about unused names, so
	the analyzer's unused-local hint is filtered out. The assertions compare the message or the
	inferred type a reader would see, not an internal table.
]]

local test = require("lde-test")
local lye = require("lye-analyzer")
local types = require("lye-doc.type")

local URI = "file:///tmp/solver.lua"
local PRELUDE = lye.prelude({
	defs = table.concat({
		"---@class tablelib\n",
		"---@field sort fun<T>(list: T[], comp?: fun(a: T, b: T):boolean)\n",
		"table = {}\n",
		"---@class stringlib\n",
		"---@field gsub fun(s: string|number, pattern: string|number, ",
		"repl: string|number|fun(...: string|number): string|number|false|nil, n?: integer): string, integer\n",
		"---@field upper fun(s: string): string\n",
		"string = {}\n",
		"function select(index: integer|\"#\", ...: any): any end\n",
		"function pcall(f: function, ...: any): boolean, any end\n",
		"function tostring(v: any): string end\n",
	}, ""),
})

---@param source string
---@return lye.analyzer.Result
local function analyze(source)
	local result = lye.analyze(source, PRELUDE, nil, nil, nil, nil, nil, nil, nil, nil, { uri = URI })
	local kept = {}
	for _, entry in ipairs(result.diagnostics) do
		if (entry.severity or 1) <= 2
			and not entry.message:match("^unused local")
			and not entry.message:match("^undefined global") then
			kept[#kept + 1] = entry
		end
	end
	result.diagnostics = kept
	return result
end

---@param result lye.analyzer.Result
---@param name string
---@return string? type
local function typeOf(result, name)
	local found
	for _, variable in ipairs(result.variables) do
		if variable.name == name then found = variable end
	end
	return found and types.display(lye.typeAt(result, found, #result.parser.source))
end

---@param result lye.analyzer.Result
---@return string
local function messages(result)
	local list = {}
	for _, entry in ipairs(result.diagnostics) do list[#list + 1] = entry.message end
	return table.concat(list, "\n")
end

test.it("reports a value nothing is known about where a promise is made", function()
	-- `any` is the lattice's top, so `satisfies` accepts it everywhere; a promise is not a use
	-- that may be passed along, and storing one in a declared type has to be reported.
	local result = analyze([[
---@return any
local function nothing() return 1 end
---@type number
local n = nothing()
]])
	test.truthy(messages(result):match("n is declared as number"), messages(result))

	result = analyze([[
---@param x any
local function f(x)
	local y = x + 1
	return y
end
]])
	test.truthy(messages(result):match("cannot use an unknown value with `%+`"), messages(result))
end)

test.it("reports a read of a value that may be nil, and lets `?.` through", function()
	local class = "---@class Maybe\n---@field value number\n"
	local result = analyze(class .. "---@type Maybe?\nlocal m\nlocal x = m.value\n")
	test.truthy(messages(result):match("may be nil"), messages(result))

	local safe = analyze(class .. "---@type Maybe?\nlocal m\nlocal x = m?.value\n")
	test.equal(#safe.diagnostics, 0, messages(safe))
end)

test.it("binds a generic class's arguments at the constructor and keeps them on methods", function()
	local result = analyze([[
---@class Box<T>
---@field value T
local Box = {}
---@generic T
---@param v T
---@return Box<T>
function Box.new(v) return setmetatable({ value = v }, { __index = Box }) end
---@return T
function Box:get() return self.value end
local b = Box.new(2)
local n = b:get()
local s = b:get() .. "x"
]])
	test.equal(typeOf(result, "b"), "Box<2>")
	test.equal(typeOf(result, "n"), "2")
	test.equal(typeOf(result, "s"), "string")
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("builds a recursive alias instead of replacing the recursion with any", function()
	local result = analyze([[
---@alias Tree { value: number, children: Tree[] }
---@type Tree
local tree
local held = tree.children[1].value
]])
	test.equal(typeOf(result, "held"), "number")
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("types a callback from the signature it is handed to", function()
	local sorted = analyze([[
local list = { 3, 1, 2 }
table.sort(list, function(a, b) return a < b end)
]])
	test.equal(#sorted.diagnostics, 0, messages(sorted))

	local replaced = analyze([[
local s = "a"
local r = s:gsub("%a", function(c) return c:upper() end)
]])
	test.equal(#replaced.diagnostics, 0, messages(replaced))
end)

test.it("checks a generic constraint and a function's declared return", function()
	local result = analyze([[
---@generic T: number
---@param x T
---@return T
local function id(x) return x end
local a = id("s")
]])
	test.truthy(messages(result):match("id expects number"), messages(result))

	local returned = analyze([[
---@param cb fun(x: number): string
local function use(cb) return cb(1) end
use(function(x) return 1 end)
]])
	test.truthy(messages(returned):match("use expects"), messages(returned))
end)

test.it("reads select, pcall and typed varargs", function()
	local result = analyze([[
local function pick(...)
	return select("#", ...), select(2, ...)
end
local count, second = pick("a", "b")
local total = count + 1
]])
	test.equal(#result.diagnostics, 0, messages(result))

	local pcalled = analyze([[
local ok, value = pcall(function() return 1 end)
if not ok then return end
local doubled = value + 1
]])
	test.equal(#pcalled.diagnostics, 0, messages(pcalled))
end)

test.it("narrows a discriminated union on the branch that holds the field", function()
	local result = analyze([[
---@alias Result { ok: true, value: number } | { ok: false, error: string }
---@param r Result
local function f(r)
	if r.ok then
		return r.value
	end
	return r.error
end
]])
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("accepts an optional parameter and a callback of the right shape", function()
	local result = analyze([[
---@param cb fun(a: number, b: number): boolean
local function use(cb)
	table.sort({ 3, 1, 2 }, cb)
end
use(function(a, b) return a < b end)
]])
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("reads an overload by the literal that selects it", function()
	local result = analyze([[
---@overload fun(kind: "a"): string
---@overload fun(kind: "b"): number
---@param kind string
---@return boolean
local function f(kind) return true end
local a = f("a")
local b = f("b")
local c = f("c")
]])
	test.equal(typeOf(result, "a"), "string")
	test.equal(typeOf(result, "b"), "number")
	test.equal(typeOf(result, "c"), "boolean")
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("substitutes the arguments of a generic alias", function()
	local result = analyze([[
---@alias Pair<A, B> { first: A, second: B }
---@type Pair<string, number>
local p
local first = p.first
local second = p.second
]])
	test.equal(typeOf(result, "first"), "string")
	test.equal(typeOf(result, "second"), "number")
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("checks both directions of a function parameter's type", function()
	local result = analyze([[
---@param cb fun(x: number): string
local function use(cb) end
---@param x string
---@return string
local function wide(x) return "s" end
---@param x number
---@return number
local function wrong(x) return 1 end
use(wide)
use(wrong)
]])
	local text = messages(result)
	test.truthy(text:match("use expects"), text)
	test.equal(select(2, text:gsub("use expects", "")), 2, text)
end)

test.it("narrows a field a name writes", function()
	local result = analyze([[
---@class Counter
---@field count number?
local counter = {}
counter.count = 1
local total = counter.count + 1
]])
	test.equal(typeOf(result, "total"), "2")
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("rejects any against a union or a table", function()
	local union = analyze([[
---@param x string|number
local function f(x) end
---@param v any
local function g(v) f(v) end
]])
	test.truthy(messages(union):match("f expects number|string"), messages(union))

	local tableWanted = analyze([[
---@param x table<string, number>
local function f(x) end
---@param v any
local function g(v) f(v) end
]])
	test.truthy(messages(tableWanted):match("f expects table"), messages(tableWanted))
end)

test.it("refuses a field a union member does not have, and a shape missing a class field", function()
	local union = analyze([[
---@type { a: number } | { b: string }
local u
local y = u.a
]])
	test.truthy(messages(union):match("`a` is not a field of every member"), messages(union))

	local shape = analyze([[
---@class C
---@field x number
---@param c C
local function f(c) end
f({})
]])
	test.truthy(messages(shape):match("is missing x"), messages(shape))
end)

test.it("correlates pcall's status with its value", function()
	local failure = analyze([[
local ok, value = pcall(function() return 1 end)
if not ok then return value:upper() end
]])
	test.truthy(messages(failure):match("cannot index a value of unknown type"), messages(failure))

	local success = analyze([[
local ok, value = pcall(function() return 1 end)
if ok then
	local n = value + 1
end
]])
	test.equal(#success.diagnostics, 0, messages(success))

	local guarded = analyze([[
local ok, value = pcall(function() return 1 end)
if not ok then return end
local n = value + 1
]])
	test.equal(#guarded.diagnostics, 0, messages(guarded))
end)

test.it("reads negative select indices", function()
	local result = analyze([[
local a = select(-1, 1, 2, 3)
local b = select(-2, 1, 2, 3)
local c = select(2, 1, 2, 3)
]])
	test.equal(typeOf(result, "a"), "3")
	test.equal(typeOf(result, "b"), "2")
	test.equal(typeOf(result, "c"), "2")
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("binds a class variable and a method variable together, and settles returned callables", function()
	local generic = analyze([[
---@class Box<T>
---@field value T
local Box = {}
---@generic T
---@param v T
---@return Box<T>
function Box.new(v) return setmetatable({ value = v }, { __index = Box }) end
---@generic U
---@param f fun(v: T): U
---@return Box<U>
function Box:map(f) return Box.new(f(self.value)) end
local b = Box.new(2):map(function(v) return tostring(v) end)
local s = b.value:upper()
]])
	test.equal(typeOf(generic, "b"), "Box<string>")
	test.equal(typeOf(generic, "s"), "string")
	test.equal(#generic.diagnostics, 0, messages(generic))

	local nested = analyze([[
local function outer(x)
	local function inner(y) return y + x end
	return inner
end
local f = outer(2)
local n = f(3)
]])
	test.equal(typeOf(nested, "f"), "fn(number) -> number")
	test.equal(typeOf(nested, "n"), "number")
	test.equal(#nested.diagnostics, 0, messages(nested))
end)

test.it("reads intersection, keyof, indexed, conditional and mapped types", function()
	local result = analyze([[
---@class A
---@field a number
---@class B
---@field b string
---@type A & B
local both
local a = both.a
local b = both.b
---@type keyof { x: number, y: string }
local key
local chosen = key == "x"
---@type { x: number, y: string }["y"]
local indexed
---@type number extends number ? string : boolean
local conditional
---@type { [K in "m" | "n"]: K }
local mapped
local member = mapped.m
]])
	test.equal(typeOf(result, "a"), "number")
	test.equal(typeOf(result, "b"), "string")
	test.equal(typeOf(result, "key"), '"x"|"y"')
	test.equal(typeOf(result, "indexed"), "string")
	test.equal(typeOf(result, "conditional"), "string")
	test.equal(typeOf(result, "member"), '"m"')
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("reads a template literal type", function()
	local result = analyze([[
---@type `id-${number}`
local identifier
]])
	test.equal(typeOf(result, "identifier"), "`id-${number}`")
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("reads multiple returns and typed varargs as values", function()
	local result = analyze([[
---@return string, number
local function pair() return "a", 1 end
local name, count = pair()
local nextCount = count + 1

---@param ... number
---@return number
local function sum(...)
	local total = 0
	for index = 1, select("#", ...) do
		total = total + select(index, ...)
	end
	return total
end
local total = sum(1, 2, 3)
]])
	test.equal(typeOf(result, "nextCount"), "number")
	test.equal(typeOf(result, "total"), "number")
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("displays a named union by its name", function()
	local result = analyze([[
---@alias Held { ok: true, value: number } | { ok: false, error: string } | { ok: true, skipped: true } | { ok: false, retry: true } | string
---@type Held?
local held
]])
	test.equal(typeOf(result, "held"), "Held?")
	local message = messages(result)
	test.falsy(message:match("variant"), message)
end)

test.it("narrows unknown through equality, type tests and named type() aliases", function()
	local result = analyze([[
---@param value unknown
local function f(value)
	if value == nil then
		local isNil = value
		return
	end
	if value == true then
		local isTrue = value
		return
	end
	if type(value) == "string" then
		local narrowed = value:upper()
	end
end
---@param value any
local function g(value)
	if type(value) == "string" then
		local untouched = value:upper()
	end
end
]])
	test.equal(typeOf(result, "narrowed"), "string")
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("narrows through a named type() local and an assert", function()
	local result = analyze([[
---@param value any
---@param takeNumber fun(n: number)
---@param takeTable fun(t: table)
local function f(value, takeNumber, takeTable)
	local t = type(value)
	if t == "number" then
		takeNumber(value)
		return
	end
	if t == "string" then
		local upper = value:upper()
	end
	assert(t == "table", "not a table")
	takeTable(value)
	local count = #value
end
]])
	test.equal(#result.diagnostics, 0, messages(result))
end)

test.it("does not keep a type() alias after the local is reassigned", function()
	local result = analyze([[
---@param value any
---@param takeString fun(s: string)
local function f(value, takeString)
	local t = type(value)
	t = "number"
	if t == "number" then
		takeString(value)
	end
end
]])
	test.truthy(messages(result):match("takeString expects string, got any"), messages(result))
end)
