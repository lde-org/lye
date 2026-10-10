--[[
	Tests for LuaLS annotation parsing and type comparison.
]]

local test = require("lde-test")
local doc = require("lye-doc")
local doctype = require("lye-doc.type")

---@param source string
---@param tag string
---@return lye.doc.Annotation?
local function annotation(source, tag)
	return doc.first(doc.parse(source), tag)
end

test.it("reads a type annotation", function()
	local found = annotation("---@type string\nlocal x = 5", "type")
	test.truthy(found)
	test.equal(found.type, "string")
end)

test.it("reads a parameter with its name and type", function()
	local found = annotation("---@param a number\nlocal function f(a) end", "param")
	test.equal(found.name, "a")
	test.equal(found.type, "number")
end)

test.it("treats a trailing hash as a description, not part of the type", function()
	local found = annotation("---@param a number # the first\nlocal function f(a) end", "param")
	test.equal(found.type, "number")
	test.equal(found.comment, "the first")
end)

test.it("handles a nullable parameter name", function()
	local found = annotation("---@param a? string\nlocal function f(a) end", "param")
	test.equal(found.name, "a", "the optional marker is not part of the name")
	-- The marker moves to the type: an optional parameter may be nil.
	test.equal(found.type, "string?")
	test.equal(doctype.satisfies(doctype.parse("nil"), doctype.parse(found.type)), true)
end)

test.it("reads class, field and alias tags", function()
	local file = doc.parse(table.concat({
		"---@class Point\n",
		"---@field x number\n",
		"---@field y number\n",
		"---@alias Name string|number\n",
	}, ""))
	test.equal(#file.annotations, 4)
	test.equal(file.annotations[1].name, "Point")
	test.equal(file.annotations[2].name, "x")
	test.equal(file.annotations[2].type, "number")
	test.equal(file.annotations[4].name, "Name")
	test.equal(file.annotations[4].type, "string|number")
end)

test.it("records an unknown tag rather than dropping it", function()
	local found = annotation("---@somethingNew whatever\nlocal x = 1", "unknown")
	test.truthy(found, "an unrecognised tag is kept so a later pass can see it")
end)

test.it("reports spans that point at the annotation", function()
	local source = "---@type string\nlocal x = 5"
	local found = doc.first(doc.parse(source), "type")
	test.equal(source:sub(found.start, found.stop), "---@type string")
end)

test.it("reads annotations from inside a block comment", function()
	-- Multi-line offsets are easy to get wrong, so the span is checked exactly.
	local source = "--[[\n---@type number\n]]\nlocal x = 1"
	local found = doc.first(doc.parse(source), "type")
	test.truthy(found)
	test.equal(source:sub(found.start, found.stop), "---@type number")
end)

test.it("accepts a value whose type matches", function()
	test.equal(doctype.satisfies(doctype.parse("string"), doctype.parse("string")), true)
	test.equal(doctype.satisfies(doctype.parse("number"), doctype.parse("number")), true)
	test.equal(doctype.satisfies(doctype.parse("table"), doctype.parse("table")), true)
	test.equal(doctype.satisfies(doctype.parse("nil"), doctype.parse("number?")), true)
end)

test.it("rejects a value whose type cannot fit", function()
	test.equal(doctype.satisfies(doctype.parse("number"), doctype.parse("string")), false)
	test.equal(doctype.satisfies(doctype.parse("number"), doctype.parse("boolean")), false)
	test.equal(doctype.satisfies(doctype.parse("nil"), doctype.parse("string")), false)
	test.equal(doctype.satisfies(doctype.parse("string"), doctype.parse("number?")), false)
	test.equal(doctype.satisfies(doctype.parse("number"), doctype.parse("table")), false)
end)

test.it("decides a union by its members", function()
	test.equal(doctype.satisfies(doctype.parse("number"), doctype.parse("string|number")), true)
	test.equal(doctype.satisfies(doctype.parse("string"), doctype.parse("string|number")), true)
	test.equal(doctype.satisfies(doctype.parse("boolean"), doctype.parse("string|number")), false)
	test.equal(doctype.satisfies(doctype.parse("nil"), doctype.parse("string|number|nil")), true)
end)

test.it("keeps the members a narrowing rule allows", function()
	test.equal(doctype.display(doctype.narrowTruthiness(doctype.parse("string?"), true)), "string")
	test.equal(doctype.display(doctype.narrowTo(doctype.parse("string|number"), "number")), "number")
	test.equal(doctype.display(doctype.exclude(doctype.parse("string|number"), "string")), "number")
end)

test.it("narrows to nothing when a rule rules every member out", function()
	-- A single type the rule removes leaves nothing, and `and nil or type` would hand the
	-- type back instead of saying so.
	test.equal(doctype.exclude(doctype.parse("number"), "number"), nil)
	test.equal(doctype.exclude(doctype.parse("string|number"), "number|string"), nil)
	test.equal(doctype.narrowTo(doctype.parse("string"), "number"), nil)
	test.equal(doctype.narrowNil(doctype.parse("string"), true), nil)
end)

test.it("reads a function signature", function()
	test.equal(doctype.display(doctype.parse("fn(a: number, b: string) -> boolean")),
		"fn(number, string) -> boolean")
	test.equal(doctype.display(doctype.parse("fn() -> nil")), "fn() -> nil")
	test.equal(doctype.display(doctype.parse("fn(a?: number) -> nil")), "fn(nil|number) -> nil")
	test.equal(doctype.display(doctype.parse("fn(a: number, ...) -> nil")), "fn(number, ...) -> nil")
	test.equal(doctype.display(doctype.parse("fun(a: number): string")), "fn(number) -> string",
		"the spelling LuaLS uses reads the same")
end)

test.it("treats a bare function as any signature", function()
	local signature = doctype.parse("fn(a: number) -> string")
	test.equal(doctype.display(doctype.parse("function")), "function")
	test.equal(doctype.satisfies(doctype.FUNCTION, signature), true,
		"a function literal says nothing about its parameters, so it fits")
	test.equal(doctype.satisfies(doctype.NUMBER, signature), false, "a number is not callable")
end)

test.it("compares two signatures by parameters and return", function()
	local wants = doctype.parse("fn(a: number) -> string")
	test.equal(doctype.satisfies(doctype.parse("fn(a: number) -> string"), wants), true)
	test.equal(doctype.satisfies(doctype.parse("fn(a: string) -> string"), wants), false,
		"a parameter is contravariant: it has to accept what the constraint passes")
	test.equal(doctype.satisfies(doctype.parse("fn(a: number) -> number"), wants), false,
		"a return is covariant")
	test.equal(doctype.satisfies(doctype.parse("fn() -> string"), wants), false, "arity counts")
	test.equal(doctype.satisfies(doctype.parse("fn(a: number, ...) -> string"), wants), true,
		"a variadic accepts the constraint's arguments")
end)

test.it("claims a number only when both operands are numbers", function()
	local number, any = doctype.parse("number"), doctype.parse("any")
	test.equal(doctype.display(doctype.binaryResult("*", number, number)), "number")
	test.equal(doctype.display(doctype.binaryResult("*", any, number)), "unknown",
		"an `any` could be a table with a metamethod, so the result is not a number")
	test.equal(doctype.display(doctype.binaryResult("*", doctype.parse("string"), number)), "unknown")
end)

test.it("never reports against a wildcard or an unresolved type", function()
	test.equal(doctype.satisfies(doctype.parse("number"), doctype.parse("any")), true)
	test.equal(doctype.satisfies(doctype.parse("number"), doctype.parse("unknown")), true)
	test.equal(doctype.satisfies(doctype.parse("unknown"), doctype.parse("number")), true)
	-- An unresolved name is not a wildcard: it does not fit `number`. What keeps it quiet is
	-- that inference yields `unknown` for anything it cannot type, and nothing is reported
	-- against an unknown.
	test.equal(doctype.satisfies(doctype.parse("unknown"), doctype.parse("my.Class")), true)
	test.equal(doctype.mismatch(doctype.parse("my.Class"), doctype.parse("unknown"), "x"), nil,
		"nothing is reported against an unknown")
	test.equal(doctype.mismatch(doctype.parse("number"), doctype.parse("unknown"), "x"), nil)
end)

test.it("describes a mismatch in the message", function()
	local message = doctype.mismatch(doctype.parse("string"), doctype.parse("number"), "x")
	test.truthy(message)
	test.truthy(message:match("string"))
	test.truthy(message:match("number"))
	test.equal(doctype.mismatch(doctype.parse("string"), doctype.parse("string"), "x"), nil)
end)

test.it("keeps an optional name unknown rather than making it nil", function()
	-- `---@param v? T` on a name nothing is known about says the value may be anything, nil
	-- included: collapsing it to nil would report every argument passed to it.
	local unknown = function() return doctype.UNKNOWN_TYPE end
	test.equal(doctype.display(doctype.parse("T?", unknown)), "unknown")
	test.equal(doctype.display(doctype.parse("number?", unknown)), "nil|number")
	test.equal(doctype.display(doctype.parse("T[]?", unknown)), "nil|unknown[]")
	test.equal(doctype.display(doctype.parse("nil|string[]")), "nil|string[]",
		"a suffix belongs to its own member rather than to the union")
end)

test.it("takes any container for a table", function()
	-- The standard library writes `table` where it does not care what is inside.
	test.equal(doctype.satisfies(doctype.parse("string[]"), doctype.TABLE), true)
	test.equal(doctype.satisfies(doctype.parse("{ a: number }"), doctype.TABLE), true)
	test.equal(doctype.satisfies(doctype.parse("string"), doctype.TABLE), false)
	test.equal(doctype.satisfies(doctype.parse("nil|string[]"), doctype.TABLE), false,
		"every member of a union has to fit")
end)

test.it("reads never as the type that has no value", function()
	local never = doctype.parse("never")
	test.equal(doctype.display(never), "never")
	test.equal(doctype.satisfies(never, doctype.parse("number")), true,
		"a call that never returns has no value to be wrong")
	test.equal(doctype.satisfies(doctype.parse("number"), never), false,
		"and nothing is a value that cannot exist")
	test.equal(doctype.display(doctype.union({ never, doctype.parse("number") })), "number",
		"a member that cannot exist adds nothing to what a value may be")
	test.equal(doctype.display(doctype.parse("never|string")), "string")
end)

test.it("narrows to a class or an alias by the parsed type", function()
	-- A predicate names a type its writer chose: `x is Point` has to narrow to the class, which a
	-- name parsed without a resolver cannot reach.
	local point = doctype.classType("Point", nil, { x = doctype.NUMBER })
	test.equal(doctype.display(doctype.narrowToType(doctype.union({ point, doctype.NIL_TYPE }), point)),
		"Point")
	test.equal(doctype.display(doctype.excludeType(doctype.union({ point, doctype.NIL_TYPE }), point)),
		"nil")
end)

return true
