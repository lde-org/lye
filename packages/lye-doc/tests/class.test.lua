--[[
	Tests for reading classes and aliases out of annotations.
]]

local test = require("lde-test")
local doc = require("lye-doc")

local classes = doc.classes
local doctype = require("lye-doc.type")

---@param source string
---@return lye.doc.Namespace
local function read(source)
	local file = doc.parse(source)
	---@cast file lye.doc.File
	return classes.read(file)
end

--- The fields of a class as `name: type` strings, sorted, so a test can compare them.
---@param namespace lye.doc.Namespace
---@param text string
---@return string[]
local function fields(namespace, text)
	local found = classes.fieldsOf(namespace, text)
	---@cast found table<string, lye.doc.Field>
	local out = {}
	for name, field in pairs(found) do
		---@cast name string
		---@cast field lye.doc.Field
		out[#out + 1] = name .. ": " .. field.type
	end
	table.sort(out)
	return out
end

test.it("reads a class and its fields", function()
	local namespace = read(table.concat({
		"---@class Point\n",
		"---@field x number\n",
		"---@field y number\n",
		"local Point = {}\n",
	}, ""))
	test.equal(namespace.classes.Point.name, "Point")
	test.equal(#namespace.classes.Point.params, 0)
	test.equal(table.concat(fields(namespace, "Point"), ", "), "x: number, y: number")
end)

test.it("stops a class at the next declaration", function()
	local namespace = read(table.concat({
		"---@class Point\n",
		"---@field x number\n",
		"local Point = {}\n",
		"---@param v number\n",
		"---@field stray number\n",
		"local function f(v) end\n",
	}, ""))
	test.equal(#namespace.classes.Point.fields, 1, "a field after another declaration is not the class's")
end)

test.it("substitutes a type parameter with the argument given", function()
	local namespace = read(table.concat({
		"---@class Box<T>\n",
		"---@field item T\n",
		"local Box = {}\n",
	}, ""))
	test.equal(table.concat(fields(namespace, "Box<number>"), ", "), "item: number")
	test.equal(table.concat(fields(namespace, "Box<string>"), ", "), "item: string")
end)

test.it("reads a bare generic name as unknown", function()
	-- `Box` on its own has to mean something, so its parameter is unknown.
	local namespace = read("---@class Box<T>\n---@field item T\nlocal Box = {}\n")
	test.equal(table.concat(fields(namespace, "Box"), ", "), "item: unknown")
end)

test.it("substitutes every parameter of a multi-parameter class", function()
	local namespace = read("---@class Pair<K, V>:\nlocal Pair = {}\n")
	test.equal(#namespace.classes.Pair.params, 2)
	test.equal(namespace.classes.Pair.params[1], "K")
	test.equal(namespace.classes.Pair.params[2], "V")
end)

test.it("does not rewrite a parameter inside a longer name", function()
	-- `T` must not turn `Table` into `numberable`.
	local namespace = read(table.concat({
		"---@class Box<T>\n",
		"---@field kind string\n",
		"---@field items T\n",
		"---@field name T\n",
		"local Box = {}\n",
	}, ""))
	local text = table.concat(fields(namespace, "Box<number>"), ", ")
	test.equal(text, "items: number, kind: string, name: number")
end)

test.it("keeps a nested generic argument whole", function()
	local namespace = read("---@class Map<K, V>\n---@field value V\nlocal Map = {}\n")
	test.equal(table.concat(fields(namespace, "Map<string, List<number>>"), ", "), "value: List<number>")
end)

test.it("extends a class, parent arguments included", function()
	local namespace = read(table.concat({
		"---@class Animal<T>\n",
		"---@field sound T\n",
		"local Animal = {}\n",
		"---@class Dog: Animal<string>\n",
		"---@field name string\n",
		"local Dog = {}\n",
	}, ""))
	test.equal(namespace.classes.Dog.parent, "Animal<string>")
	test.equal(table.concat(fields(namespace, "Dog"), ", "), "name: string, sound: string")
end)

test.it("lets a child override a parent's field", function()
	local namespace = read(table.concat({
		"---@class Base\n",
		"---@field id number\n",
		"local Base = {}\n",
		"---@class Child: Base\n",
		"---@field id string\n",
		"local Child = {}\n",
	}, ""))
	test.equal(table.concat(fields(namespace, "Child"), ", "), "id: string")
end)

test.it("reads a field's visibility, inline and on its own line", function()
	local namespace = read(table.concat({
		"---@class Account\n",
		"---@field public name string\n",
		"---@field private balance number\n",
		"---@protected\n",
		"---@field secret boolean\n",
		"local Account = {}\n",
	}, ""))
	local found = classes.fieldsOf(namespace, "Account")
	---@cast found table<string, lye.doc.Field>
	test.equal(found.name.visibility, "public")
	test.equal(found.balance.visibility, "private")
	test.equal(found.secret.visibility, "protected")
end)

test.it("carries visibility through extension", function()
	local namespace = read(table.concat({
		"---@class Base\n",
		"---@field private id number\n",
		"local Base = {}\n",
		"---@class Child: Base\n",
		"---@field name string\n",
		"local Child = {}\n",
	}, ""))
	local childFields = classes.fieldsOf(namespace, "Child")
	---@cast childFields table<string, lye.doc.Field>
	test.equal(childFields.id.visibility, "private")
end)

test.it("reads an optional field", function()
	local namespace = read("---@class Ref\n---@field value? number\nlocal Ref = {}\n")
	local found = classes.fieldsOf(namespace, "Ref").value
	test.equal(found.type, "number", "the type it says, without the marker in the text")
	test.equal(found.optional, true, "and a value may leave it out")
end)

test.it("reads an enum as a number and a table on the class that holds it", function()
	local namespace = read(table.concat({
		"---@class Enums\n",
		"---@enum Enums.Format\n",
		"Enums.Format = { RGBA = 1, BGRA = 2 }\n",
		"---@enum Enums.PresentMode\n",
		"Enums.PresentMode = { FIFO = 1 }\n",
	}, ""))
	test.equal(table.concat(fields(namespace, "Enums"), ", "),
		"Format: table<string, number>, PresentMode: table<string, number>")
	local resolve = classes.resolver(namespace)
	---@cast resolve fun(name: string): lye.doc.Type
	test.equal(doctype.display(resolve("Enums.Format")), "number",
		"the enum's own type is the value it holds")
end)

test.it("reads the default marker on the first alias member", function()
	-- The definitions copied from LuaLS write the first member with `|>`; the `>` marks its
	-- default, and it is not part of the text to compare against.
	local namespace = read(table.concat({
		"---@alias openmode\n",
		'---|>"r" # Read mode.\n',
		'---| "w" # Write mode.\n',
	}, ""))
	local resolve = classes.resolver(namespace)
	---@cast resolve fun(name: string): lye.doc.Type
	test.equal(doctype.display(resolve("openmode")), '"r"|"w"')
end)

test.it("reads an alias", function()
	local namespace = read("---@alias Id number|string\n")
	test.equal(namespace.aliases.Id.body, "number|string")
	test.equal(#namespace.aliases.Id.params, 0)
end)

test.it("substitutes the arguments of a generic alias", function()
	local namespace = read("---@alias ArrayOfNumberLike<T: number> T[]\n")
	test.equal(namespace.aliases.ArrayOfNumberLike.body, "T[]", "the limit is not part of the body")
	local resolve = classes.resolver(namespace)
	---@cast resolve fun(name: string): lye.doc.Type
	test.equal(doctype.display(resolve("ArrayOfNumberLike<number>")), "number[]")
	test.equal(doctype.display(resolve("ArrayOfNumberLike<string>")), "string[]")
	test.equal(doctype.display(resolve("ArrayOfNumberLike")), "unknown[]",
		"an alias with no argument holds unknown, as a class does")
end)

test.it("reads an alias that names a class declared below it", function()
	local namespace = read(table.concat({
		"---@alias Ids Point[]\n",
		"---@class Point\n",
		"---@field x number\n",
		"local Point = {}\n",
	}, ""))
	local resolve = classes.resolver(namespace)
	---@cast resolve fun(name: string): lye.doc.Type
	test.equal(doctype.display(resolve("Ids")), "Point[]",
		"the body is resolved where it is used, so a class below it is found")
end)

test.it("answers nothing for a class it does not know", function()
	local namespace = read("---@class Point\nlocal Point = {}\n")
	test.equal(next(classes.fieldsOf(namespace, "Missing")), nil)
end)

test.it("resolves every name a run of files declares against the whole run", function()
	-- A class another file declares is what its fields are, not its name: a reader that merges the
	-- run — `lye check` reads a batch this way and the LSP reads the workspace this way — hands an
	-- analysis these types rather than the names alone, so a table built for one is checked
	-- against what the class says.
	local point = doc.parse("---@class Point\n---@field x number\nlocal Point = {}\n")
	---@cast point lye.doc.File
	local aliases = doc.parse("---@alias Points Point[]\n")
	---@cast aliases lye.doc.File
	local declared = classes.declare({ point, aliases })
	---@cast declared table<string, lye.doc.Type>
	local classType = declared.Point
	---@cast classType { variant: string, fields: table<string, lye.doc.Type> }
	test.equal(classType.variant, "class", "the class is the class")
	test.equal(doctype.display(classType.fields.x), "number", "with the field it declares")
	local aliasType = declared.Points
	---@cast aliasType { type: { variant: string, name: string } }
	test.equal(aliasType.type.variant, "class", "and the alias read the other file's class")
	test.equal(aliasType.type.name, "Point")
end)

test.it("keeps the name of a parameter that carries a limit", function()
	local namespace = read("---@class Box<T: number>\n---@field item T\nlocal Box = {}\n")
	test.equal(namespace.classes.Box.name, "Box")
	test.equal(table.concat(namespace.classes.Box.params, ","), "T",
		"the limit is not part of the parameter's name")
	local resolve = classes.resolver(namespace)
	local boxType = resolve("Box<string>")
	---@cast boxType { fields: table<string, lye.doc.Type> }
	test.equal(doctype.display(boxType.fields.item), "string")
end)

test.it("reads a class whose name carries the internal marker", function()
	-- The marker says how a name is used, not what it is called, so the class is the one named
	-- `file`: a definition writing `ffi.cdata*` and a reader writing `ffi.cdata` have to mean the
	-- same class, or a value of one is not a value of the other.
	local namespace = read("---@class file*\nlocal file = {}\n")
	test.equal(namespace.classes["file"] ~= nil, true, "`file*` is a class the definitions declare")
	test.equal(namespace.classes["file*"], nil, "and it is not a second class of its own")
	test.equal(classes.resolve(namespace, "file*") ~= nil, true, "either spelling resolves")
	test.equal(classes.resolve(namespace, "file") ~= nil, true)
end)

test.it("reads a const parameter and what limits it", function()
	local params, constraints, consts = classes.readParams("A, const B: number")
	test.equal(table.concat(params, ","), "A,B")
	test.equal(consts.B, true, "the marked one takes a value")
	test.equal(consts.A, nil, "and the other takes a type")
	test.equal(constraints.B, "number")
end)

test.it("substitutes an argument into arithmetic in a type", function()
	local namespace = read("---@alias F<A, const B: number> { x: A[], y: B + 2 }\n")
	local resolve = classes.resolver(namespace)
	---@cast resolve fun(name: string): lye.doc.Type
	local types = doctype
	test.equal(types.display(resolve("F<string, 5>")), "{ x: string[], y: 7 }",
		"the arithmetic is worked out where the type is used")
	test.equal(types.display(resolve("F<string, 40 + 2>")), "{ x: string[], y: 44 }",
		"and an argument may be an expression itself")
end)
