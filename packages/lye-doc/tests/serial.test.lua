--[[
	Tests for writing a type graph out and reading it back.
]]

local test = require("lde-test")
local sequel = require("lye-doc.serial")

local types = require("lye-doc.type")

---@param value unknown
---@return unknown
local function roundTrip(value)
	local text = assert(sequel.write(value))
	return assert(sequel.read(text))
end

test.it("gives back a type as the type it was", function()
	local class = types.classType("Vec", {}, { x = types.NUMBER, y = types.NUMBER }, {}, {})
	local written = roundTrip(class)
	test.equal(types.display(written), "Vec")
	test.equal(types.display(written.fields.x), "number")
	test.equal(written.variant, "class")
end)

test.it("keeps a type that holds itself in one piece", function()
	-- A class with a field of its own type is a cycle, and the chunk has to make every table
	-- before it points one at another.
	local node = types.classType("Node", {}, {}, {}, {})
	node.fields.next = node
	local written = roundTrip(node)
	test.equal(written.fields.next, written)
end)

test.it("gives a builtin back as the very table the type system uses", function()
	-- `returns == types.VOID` is asked by the checks, so a copy would not do.
	test.equal(roundTrip(types.VOID), types.VOID)
	test.equal(roundTrip(types.NIL_TYPE), types.NIL_TYPE)
	test.equal(roundTrip(types.ANY_TYPE), types.ANY_TYPE)
	local fn = types.fn({ types.STRING }, types.VOID, false, false)
	local written = roundTrip(fn)
	test.equal(written.returns, types.VOID)
	test.equal(written.params[1], types.STRING)
end)

test.it("keeps a shared table shared", function()
	local point = types.classType("Point", {}, { x = types.NUMBER }, {}, {})
	local pair = types.classType("Pair", {}, { left = point, right = point }, {}, {})
	local written = roundTrip(pair)
	test.equal(written.fields.left, written.fields.right, "one table, not two")
end)

test.it("gives a named table back as the caller's own", function()
	-- The definitions' methods are looked up by the type they were built for, so a graph holding
	-- one has to come back holding the very table the caller named, not a copy of it.
	local held = types.fn({ types.STRING }, types.VOID, false, false)
	local known = { names = { [held] = "field:ffi.cdef" }, tables = { ["field:ffi.cdef"] = held } }
	local holder = types.classType("Holder", {}, { cdef = held }, {}, {})
	local written = assert(sequel.read(assert(sequel.write(holder, known)), known))
	test.equal(written.fields.cdef, held, "the caller's own table")
	test.equal(sequel.SINGLETONS.void, written.fields.cdef.returns, "beside the singletons it knows")
end)

test.it("reads nothing when a named table is gone", function()
	local held = types.fn({}, types.VOID, false, false)
	local holder = types.classType("Holder", {}, { cdef = held }, {}, {})
	local text = assert(sequel.write(holder, { names = { [held] = "field:gone" } }))
	local value, err = sequel.read(text, { tables = {} })
	test.equal(value, nil, "an answer naming a type the reader does not have")
	test.truthy(err, "is not an answer")
end)

test.it("keeps text as text", function()
	local fn = types.fn({}, types.extern("a\\\"b\nc"), false, false)
	local written = roundTrip(fn)
	test.equal(written.returns.name, "a\\\"b\nc")
end)

return true
