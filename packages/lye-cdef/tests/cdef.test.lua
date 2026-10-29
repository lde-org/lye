--[[
	Tests for `lye-cdef`.

	The corpus is the C LuaJIT's own `ffi.cdef` accepts, and the assertions are about what a reader
	of the declarations needs: the members of a struct, what a typedef stands for, and which of
	`int *f(void)` and `int (*f)(void)` a declarator is.
]]

local test = require("lde-test")
local cdef = require("lye-cdef")

--- Parse a block and hand back the namespace.
---@param text string
local function parse(text)
	return cdef.parse(text)
end

--- The annotation type of a member, which is what a `---@field` would say.
---@param namespace lye.cdef.Namespace
---@param type string
---@param field string
---@return string?
local function memberType(namespace, type, field)
	local found = cdef.resolve(namespace, type)
	---@type { name: string, type: lye.cdef.Type, bits: integer? }[]
	local members = found and found.fields or {}
	for _, member in ipairs(members) do
		if member.name == field then return cdef.notation(namespace, member.type) end
	end
end

test.it("reads a struct and its members", function()
	local namespace = parse("struct Vec { double x, y; };")
	local vec = assert(cdef.resolve(namespace, "Vec"))
	test.equal(vec.kind, "struct")
	test.equal(#assert(vec.fields), 2)
	test.equal(memberType(namespace, "Vec", "x"), "number")
	test.equal(memberType(namespace, "Vec", "y"), "number")
end)

test.it("reads a typedef of an anonymous struct", function()
	-- The tag has no name, so the members belong to the typedef and a reader writes `Point`.
	local namespace = parse("typedef struct { int x; int y; } Point;")
	test.equal(assert(cdef.resolve(namespace, "Point")).kind, "struct")
	test.equal(memberType(namespace, "Point", "x"), "number", "an int is a Lua number")
end)

test.it("keeps the typedef name a member was written with", function()
	local namespace = parse("typedef struct { int x; } Point;\nstruct Line { Point from, to; };")
	test.equal(memberType(namespace, "Line", "from"), "Point")
end)

test.it("tells a function returning a pointer from a pointer to a function", function()
	-- The whole reason a declarator is parsed as a chain: the parentheses decide which it is.
	local namespace = parse("int *make(void);\nint (*callback)(void);")
	local make = assert(cdef.resolve(namespace, "make"))
	test.equal(make.kind, "function")
	test.equal(assert(make.returns).kind, "pointer")
	local callback = assert(cdef.resolve(namespace, "callback"))
	test.equal(callback.kind, "pointer")
	test.equal(assert(callback.target).kind, "function")
end)

test.it("reads a function pointer typedef as a callback", function()
	local namespace = parse("typedef int (*cmp)(const void *, const void *);")
	test.equal(cdef.notation(namespace, assert(cdef.resolve(namespace, "cmp"))), "ffi.cb",
		"a pointer to a function is the callback it is")
	test.truthy(cdef.annotations(namespace):match("---@class cmp: ffi%.cb"))
end)

test.it("reads arrays, of a known and an unknown length", function()
	local namespace = parse("struct Buf { char name[32]; int data[]; };")
	test.equal(memberType(namespace, "Buf", "name"), "ffi.array<ffi.char, 32>",
		"an array is indexed and knows its length")
	test.equal(memberType(namespace, "Buf", "data"), "ffi.array<ffi.int>",
		"an array whose length the header left out is still an array")
	local fields = assert(assert(cdef.resolve(namespace, "Buf")).fields)
	test.equal(fields[2].type.length, nil)
	test.equal(fields[1].type.length, 32)
end)

test.it("reads an array of pointers as pointers, not as an array of values", function()
	local namespace = parse("struct T { int *items[4]; };")
	local field = assert(assert(cdef.resolve(namespace, "T")).fields)[1]
	test.equal(field.type.kind, "array")
	test.equal(assert(field.type.target).kind, "pointer")
end)

test.it("reads an enum and its constants", function()
	local namespace = parse("enum Color { RED, GREEN = 5, BLUE };")
	test.equal(namespace.constants.RED, 0)
	test.equal(namespace.constants.GREEN, 5)
	test.equal(namespace.constants.BLUE, 6)
	test.equal(cdef.notation(namespace, assert(cdef.resolve(namespace, "Color"))), "Color",
		"an enum's values are a cdata type of their own")
end)

test.it("evaluates the expressions a header writes down", function()
	local namespace = parse("enum Flags { A = 1 << 3, B = A | 4, C = (2 + 2) * 2 };")
	test.equal(namespace.constants.A, 8)
	test.equal(namespace.constants.B, 12)
	test.equal(namespace.constants.C, 8)
end)

test.it("reads a struct that holds a pointer to itself", function()
	local namespace = parse("typedef struct Node { struct Node *next; int value; } Node;")
	test.equal(memberType(namespace, "Node", "next"), "Node")
	test.equal(memberType(namespace, "Node", "value"), "number")
end)

test.it("accepts a declaration of a name whose layout is not written", function()
	local namespace = parse("struct Opaque;\nstruct Opaque *make(void);")
	test.equal(assert(cdef.resolve(namespace, "Opaque")).incomplete, true)
	local make = assert(cdef.resolve(namespace, "make"))
	test.equal(assert(assert(make.returns).target).name, "Opaque")
end)

test.it("reads bitfields, qualifiers and unnamed members", function()
	local namespace = parse("struct Bits { unsigned int a : 3; const char *name; };")
	test.equal(assert(assert(cdef.resolve(namespace, "Bits")).fields)[1].bits, 3)
	test.equal(memberType(namespace, "Bits", "name"), "ffi.ptr<ffi.char>")

	-- An anonymous member has no name to be written by, so it is written as the members it holds:
	-- a cdata here left everything reached through `inner` unknown, and Win32 headers are full of
	-- structs shaped this way.
	local nested = parse("struct Outer { struct { int x; } inner; };")
	test.equal(memberType(nested, "Outer", "inner"), "{ x: number }")
end)

test.it("reads the standard library declarations a header repeats", function()
	local namespace = parse([[
		#include <stdio.h>
		typedef unsigned long size_t;
		void *malloc(size_t size);
		int printf(const char *format, ...);
		typedef long time_t;
		time_t time(time_t *t);
	]])
	test.equal(assert(cdef.resolve(namespace, "size_t")).kind, "int")
	local printf = assert(cdef.resolve(namespace, "printf"))
	test.equal(printf.variadic, true)
	local params = assert(printf.params)
	test.equal(params[1].kind, "pointer")
	test.equal(cdef.notation(namespace, params[1]), "ffi.ptr<ffi.char>")
	local malloc = assert(cdef.resolve(namespace, "malloc"))
	test.equal(assert(assert(malloc.returns).target).kind, "void")
end)

test.it("writes the classes an analyzer reads", function()
	local namespace = parse("typedef struct { double x, y; } Vec;\ntypedef unsigned long size_t;")
	local text = cdef.annotations(namespace)
	test.truthy(text:match("---@class Vec: ffi%.cdata"))
	test.truthy(text:match("---@field x number"))
	test.truthy(text:match("---@field y number"))
	test.truthy(text:match("---@alias size_t ffi%.%w+"),
		"a 64-bit typedef is a cdata type rather than a number")
end)

test.it("reads a type written as a string", function()
	-- This is what `ffi.new("Vec *")` hands the parser, and why the answer is known ahead of time.
	local namespace = parse("typedef struct { double x, y; } Vec;")
	local vecType = cdef.typeOf(namespace, "Vec")
	---@cast vecType lye.cdef.Type
	test.equal(cdef.className(vecType), "Vec")
	local pointer = cdef.typeOf(namespace, "Vec *")
	---@cast pointer lye.cdef.Type
	test.equal(pointer.kind, "pointer")
	test.equal(cdef.className(pointer), "Vec")
	local constPointer = cdef.typeOf(namespace, "const Vec *")
	---@cast constPointer lye.cdef.Type
	test.equal(cdef.className(constPointer), "Vec")
	local array = cdef.typeOf(namespace, "unsigned char[4]")
	---@cast array lye.cdef.Type
	test.equal(array.kind, "array")
	test.equal(array.length, 4)
	test.equal(cdef.typeOf(namespace, "never_declared"), nil, "a name the block never declared")
	test.equal(cdef.typeOf(namespace, ""), nil)
end)

test.it("says nothing about a name it does not know", function()
	local namespace = parse("struct Known { int x; };")
	test.equal(cdef.resolve(namespace, "Missing"), nil)
	local count = 0
	for _ in pairs(namespace.types) do count += 1 end
	test.equal(count, 1)
end)

test.it("reports what it could not read, and keeps reading", function()
	-- A header is usually mostly right and a reader wants to know *where* it is wrong, so nothing
	-- is raised: the problem is reported at the token that caused it and the rest is still read.
	local text = "struct Broken { int x }\nstruct Good { int y; };\ntypedef int MyInt;\n"
	local namespace = parse(text)
	test.equal(#namespace.problems, 1, "one problem")
	local problem = namespace.problems[1]
	test.equal(problem.message, "expected `;`, found `}`")
	test.equal(text:sub(problem.start, problem.stop), "}", "pointing at what was found")
	test.equal(assert(cdef.resolve(namespace, "Good")).kind, "struct", "and the rest of the header is read")
	test.equal(assert(cdef.resolve(namespace, "MyInt")).kind, "int")
end)

test.it("reports a type it was never told about", function()
	local namespace = parse("void take(Missing *thing);\ntypedef int Fine;\n")
	test.equal(namespace.problems[1].message, "unknown type `Missing`")
	test.equal(namespace.problems[1].start, 11, "at the name that is not a type")
	test.equal(assert(cdef.resolve(namespace, "Fine")).kind, "int", "and nothing after it is lost")
end)

test.it("reads a header that is right without reporting anything", function()
	local namespace = parse("typedef struct { int x; } Point;\nenum E { A, B };\nint f(void);\n")
	test.equal(#namespace.problems, 0)
end)

return true
