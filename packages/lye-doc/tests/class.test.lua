--[[
	Tests for reading classes and aliases out of annotations.
]]

local test = require("lde-test")
local doc = require("lye-doc")

local classes = doc.classes

---@param source string
---@return lye.doc.Namespace
local function read(source)
	return classes.read(doc.parse(source))
end

--- The fields of a class as `name: type` strings, sorted, so a test can compare them.
---@param namespace lye.doc.Namespace
---@param text string
---@return string[]
local function fields(namespace, text)
	local found = classes.fieldsOf(namespace, text)
	local out = {}
	for name, field in pairs(found) do
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
	test.equal(classes.fieldsOf(namespace, "Child").id.visibility, "private")
end)

test.it("reads an optional field", function()
	local namespace = read("---@class Ref\n---@field value? number\nlocal Ref = {}\n")
	test.equal(table.concat(fields(namespace, "Ref"), ", "), "value: number?")
end)

test.it("reads an alias", function()
	local namespace = read("---@alias Id number|string\n")
	test.equal(namespace.aliases.Id, "number|string")
end)

test.it("answers nothing for a class it does not know", function()
	local namespace = read("---@class Point\nlocal Point = {}\n")
	test.equal(next(classes.fieldsOf(namespace, "Missing")), nil)
end)
