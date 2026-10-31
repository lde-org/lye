--[[
	Tests for LuaLS annotation parsing and type comparison.
]]

local test = require("lde-test")
local doc = require("lye-doc")
local doctype = require("lye-doc.type")

--- Parse a type that is written in a test and must be one: every text here is a type, so the
--- optional `nil` `doctype.parse` returns for an empty one would only be a lie about the fixture.
---@param text string
---@param resolve? fun(text: string): lye.doc.Type?
local function parse(text, resolve)
	local held = doctype.parse(text, resolve)
	---@cast held lye.doc.Type
	return held
end

---@param source string
---@param tag string
---@return lye.doc.Annotation?
local function annotation(source, tag)
	local file = doc.parse(source)
	---@cast file lye.doc.File
	return doc.first(file, tag)
end

test.it("reads an index signature as a key type and a value type", function()
	-- `---@field [integer] T` is what a value indexed with that kind of key gives: the bracket is
	-- the key's type rather than a field name, and the type after it is the value's.
	local source = "---@field [integer] string\n"
	local found = annotation(source, "field")
	test.equal(found.name, "[integer]")
	test.equal(found.type, "string")
	test.equal(source:sub(assert(found.nameStart), assert(found.nameStop)), "[integer]", "the span is the key")
end)

test.it("says a file is a definition when it carries ---@meta", function()
	test.equal(doc.parse("---@meta\nlocal x = 1\n").isDefinition, true)
	test.equal(doc.parse("---@meta bit\n").isDefinition, true, "the name it may carry does not matter")
	test.equal(doc.parse("local x = 1\n").isDefinition, false)
end)

test.it("keeps a class's parameters and drops the sentence after them", function()
	-- `---@class Metatable<T: table> the fields Lua consults ...` writes its parameters and then a
	-- sentence about them. The sentence is documentation; a parent type would follow a colon.
	local found = annotation("---@class lye.Metatable<T: table> the fields Lua consults\n", "class")
	test.equal(found.name, "lye.Metatable")
	test.equal(found.type, "<T: table>", "the parameters are the body, and the sentence is not")

	local withParent = annotation("---@class Box<T>: Container<T> a box\n", "class")
	test.equal(withParent.type, "<T>: Container<T>", "a parent after the colon is the body")
end)

test.it("reads the same annotations with or without the tokens of a full lex", function()
	-- `doc.parse` scans the comments itself when it is not handed tokens, and that scan has to see
	-- the comments a full lex sees: a `--` inside a string is text, and a long bracket that opens a
	-- string is not a comment.
	local lexer = require("lye-lexer")
	local cases = {
		"---@class Point\nlocal x = 1",
		"local s = \"-- not a comment\" ---@type string\nlocal y = 1",
		"local s = [[\n---@type number\n]] ---@type boolean\nlocal z = true",
		"---@alias X\n--- | \"a\"\n--- | \"b\"\nlocal a = 1",
		"local f = function() return 1 end --[[@as number]]",
		"---@param a Vec ---@param b Vec\nlocal function g(a, b) end",
	}
	for _, source in ipairs(cases) do
		local scanned, full = doc.parse(source), doc.parse(source, lexer.tokenize(source))
		test.equal(#scanned.annotations, #full.annotations, "count for " .. string.format("%q", source))
		for index, one in ipairs(scanned.annotations) do
			test.equal(one.tag, full.annotations[index].tag, "tag " .. index)
			test.equal(one.typeText or "", full.annotations[index].typeText or "", "type " .. index)
			test.equal(one.start, full.annotations[index].start, "offset " .. index)
		end
	end
end)

test.it("reads an annotation with a space before the tag", function()
	-- `--- @class` is how a writer who thinks of the annotation as prose writes it, and LuaLS reads
	-- it: insisting on the tight form would silently ignore half of someone's file.
	local found = annotation("--- @type string\nlocal x = 5", "type")
	test.truthy(found, "the tag is read")
	test.equal(found.type, "string")

	local file = doc.parse("--- @class Point\n--- @field x number\n--- @field y number\n")
	test.equal(#file.annotations, 3, "every line of the run")
	test.equal(file.annotations[1].tag, "class")
	test.equal(file.annotations[1].name, "Point")
	test.equal(file.annotations[2].tag, "field")

	-- Prose that mentions one is prose: the dashes have to start the annotation, not appear in it.
	local prose = doc.parse("--- this is @me talking\nlocal x = 1\n")
	test.equal(#prose.annotations, 0)
end)

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

test.it("cuts the prose written after a parameter's type", function()
	-- A type is one expression, so the words a writer puts after it are a sentence, not part of
	-- the type: the type ends at the first space that no operator binds, and the span follows.
	local source = "---@param x string some prose here\nlocal function f(x) end"
	local found = annotation(source, "param")
	test.equal(found.typeText, "string")
	test.equal(found.type, "string")
	test.equal(found.typeStop, source:find("string", 1, true) + #"string" - 1,
		"the span still ends on the `g` of `string`")
	test.equal(source:sub(assert(found.typeStart), assert(found.typeStop)), "string")
end)

test.it("keeps a spaced union whole", function()
	local found = annotation("---@param x string | nil\nlocal function f(x) end", "param")
	test.equal(found.typeText, "string | nil", "the bars are the type, not prose")
end)

test.it("keeps a function type with spaces whole", function()
	local found = annotation("---@param x fun(a: string): boolean\nlocal function f(x) end", "param")
	test.equal(found.typeText, "fun(a: string): boolean",
		"the spaces inside the signature belong to the type")
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
	test.equal(doctype.satisfies(parse("nil"), parse(assert(found.type))), true)
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
	local file = doc.parse(source)
	---@cast file lye.doc.File
	local found = doc.first(file, "type")
	test.equal(source:sub(found.start, found.stop), "---@type string")
end)

test.it("reads annotations from inside a block comment", function()
	-- Multi-line offsets are easy to get wrong, so the span is checked exactly.
	local source = "--[[\n---@type number\n]]\nlocal x = 1"
	local file = doc.parse(source)
	---@cast file lye.doc.File
	local found = doc.first(file, "type")
	test.truthy(found)
	test.equal(source:sub(found.start, found.stop), "---@type number")
end)

test.it("accepts a value whose type matches", function()
	test.equal(doctype.satisfies(parse("string"), parse("string")), true)
	test.equal(doctype.satisfies(parse("number"), parse("number")), true)
	test.equal(doctype.satisfies(parse("table"), parse("table")), true)
	test.equal(doctype.satisfies(parse("nil"), parse("number?")), true)
end)

test.it("rejects a value whose type cannot fit", function()
	test.equal(doctype.satisfies(parse("number"), parse("string")), false)
	test.equal(doctype.satisfies(parse("number"), parse("boolean")), false)
	test.equal(doctype.satisfies(parse("nil"), parse("string")), false)
	test.equal(doctype.satisfies(parse("string"), parse("number?")), false)
	test.equal(doctype.satisfies(parse("number"), parse("table")), false)
end)

test.it("decides a union by its members", function()
	test.equal(doctype.satisfies(parse("number"), parse("string|number")), true)
	test.equal(doctype.satisfies(parse("string"), parse("string|number")), true)
	test.equal(doctype.satisfies(parse("boolean"), parse("string|number")), false)
	test.equal(doctype.satisfies(parse("nil"), parse("string|number|nil")), true)
end)

test.it("keeps the members a narrowing rule allows", function()
	test.equal(doctype.display(doctype.narrowTruthiness(parse("string?"), true) --[[@as lye.doc.Type]]), "string")
	test.equal(doctype.display(doctype.narrowTo(parse("string|number"), "number") --[[@as lye.doc.Type]]), "number")
	test.equal(doctype.display(doctype.exclude(parse("string|number"), "string") --[[@as lye.doc.Type]]), "number")
	test.equal(doctype.display(doctype.narrowTo(doctype.UNKNOWN_TYPE, "table") --[[@as lye.doc.Type]]), "table",
		"a type test is the information an unknown lacks")
	test.equal(doctype.display(doctype.narrowTo(doctype.ANY_TYPE, "table") --[[@as lye.doc.Type]]), "table",
		"and the same for any")
end)

test.it("reads a field of a union as the union of the fields its members hold", function()
	-- A discriminant is the field every member holds, and the read has to name all of them:
	-- taking the first member's value made every comparison against another member's value look
	-- impossible, which is what broke a chain of `elseif node.type == ...`.
	local node = parse('{ type: "ident", value: string } | { type: "bool", value: boolean }'
		.. ' | { type: "number", value: number }')
	local heldType = doctype.indexResult(node, "type")
	---@cast heldType lye.doc.Type
	test.equal(doctype.display(heldType), '"bool"|"ident"|"number"')
	local heldValue = doctype.indexResult(node, "value")
	---@cast heldValue lye.doc.Type
	test.equal(doctype.display(heldValue), "boolean|number|string")
	local heldFoo = doctype.indexResult(parse('{ foo: number } | { bar: string }'), "foo")
	---@cast heldFoo lye.doc.Type
	test.equal(doctype.display(heldFoo), "number", "a member without the field adds nothing")
end)

test.it("narrows to nothing when a rule rules every member out", function()
	-- A single type the rule removes leaves nothing, and `and nil or type` would hand the
	-- type back instead of saying so.
	test.equal(doctype.exclude(parse("number"), "number"), nil)
	test.equal(doctype.exclude(parse("string|number"), "number|string"), nil)
	test.equal(doctype.narrowTo(parse("string"), "number"), nil)
	test.equal(doctype.narrowNil(parse("string"), true), nil)
end)

test.it("reads a function signature", function()
	test.equal(doctype.display(parse("fn(a: number, b: string) -> boolean")),
		"fn(number, string) -> boolean")
	test.equal(doctype.display(parse("fn() -> nil")), "fn() -> nil")
	test.equal(doctype.display(parse("fn(a?: number) -> nil")), "fn(number?) -> nil")
	test.equal(doctype.display(parse("fn(a: number, ...) -> nil")), "fn(number, ...) -> nil")
	test.equal(doctype.display(parse("fun(a: number): string")), "fn(number) -> string",
		"the spelling LuaLS uses reads the same")
end)

test.it("reads every value a function type gives back", function()
	-- An overload is written as a function type, so `pcall`'s success shape can say
	-- `boolean, T` rather than only the status. The parser has to keep the values after the
	-- first, and the generic that the return names.
	local signature = parse("fun<T>(f: fun(...): T): boolean, T")
	local first = assert(signature.values and signature.values[1]) --[[@as lye.doc.Type]]
	local second = assert(signature.values and signature.values[2]) --[[@as lye.doc.Type]]
	test.equal(#signature.values, 2, "both results are kept")
	test.equal(doctype.display(first), "boolean")
	test.equal(second.variant, "extern")
	test.equal(second.name, "T")
	test.truthy(signature.generics and signature.generics.T, "the overload declares T")
	test.equal(doctype.display(signature),
		"fn(fn(...) -> T) -> boolean, T", "and the display names both results")
end)

test.it("reads the marker and the bar after a signature as the return they follow", function()
	-- Both follow the return type, so both belong to it: a resolver that returns `Type?` returns
	-- one, and is not a function that may be absent. What may be absent is written without a
	-- return at all, which is the `fun()?` a parameter takes.
	test.equal(doctype.display(parse("fun(text: string): string?")), "fn(string) -> string?")
	test.equal(doctype.display(parse("fun(text: string): string|nil")), "fn(string) -> string?",
		"the two spellings are one type")
	test.equal(doctype.display(parse("fun(text: string): string[]")), "fn(string) -> string[]")
	test.equal(doctype.display(parse("fun()?")), "(fn() -> any)?",
		"with no return written the marker is the function's own")
	test.equal(doctype.display(parse("fun()[]")), "(fn() -> any)[]",
		"and a list of them is bracketed so it does not read as a function returning a list")
	local declared = parse("fun(text: string): string?")
	local inferred = parse("fun(text: string): string|nil")
	test.equal(doctype.satisfies(inferred, declared), true)
	test.equal(doctype.satisfies(declared, inferred), true, "and either satisfies the other")
end)

test.it("treats a bare function as any signature", function()
	local signature = parse("fn(a: number) -> string")
	test.equal(doctype.display(parse("function")), "function")
	test.equal(doctype.satisfies(doctype.FUNCTION, signature), true,
		"a function literal says nothing about its parameters, so it fits")
	test.equal(doctype.satisfies(doctype.NUMBER, signature), false, "a number is not callable")
end)

test.it("compares two signatures by parameters and return", function()
	local wants = parse("fn(a: number) -> string")
	test.equal(doctype.satisfies(parse("fn(a: number) -> string"), wants), true)
	test.equal(doctype.satisfies(parse("fn(a: string) -> string"), wants), false,
		"a parameter is contravariant: it has to accept what the constraint passes")
	test.equal(doctype.satisfies(parse("fn(a: number) -> number"), wants), false,
		"a return is covariant")
	test.equal(doctype.satisfies(parse("fn(a: number, b: string) -> string"), wants), false,
		"a parameter the constraint does not pass has to be optional")
	test.equal(doctype.satisfies(parse("fn() -> string"), wants), true,
		"and a callable that ignores the argument still takes it")
	test.equal(doctype.satisfies(parse("fn(a: number, ...) -> string"), wants), true,
		"a variadic accepts the constraint's arguments")
end)

test.it("claims a number only when both operands are numbers", function()
	local number, any = parse("number"), parse("any")
	test.equal(doctype.display(doctype.binaryResult("*", number, number)), "number")
	test.equal(doctype.display(doctype.binaryResult("*", any, number)), "unknown",
		"an `any` could be a table with a metamethod, so the result is not a number")
	test.equal(doctype.display(doctype.binaryResult("*", parse("string"), number)), "unknown")
end)

test.it("treats C numeric types and their single pointer marker as numbers", function()
	local cNumber = doctype.classType("ffi.cnum")
	local pointer = doctype.classType("ffi.cnum*")
	local child = doctype.classType("pkg.Int", {}, {}, { cNumber })
	test.equal(doctype.satisfies(cNumber, doctype.NUMBER), true)
	test.equal(doctype.satisfies(pointer, doctype.NUMBER), true)
	test.equal(doctype.satisfies(child, doctype.NUMBER), true)
	test.equal(doctype.satisfies(doctype.NUMBER, pointer), true)
	test.equal(doctype.satisfies(doctype.classType("ffi.cnum**"), doctype.NUMBER), false)
end)

test.it("never reports against a wildcard or an unresolved type", function()
	test.equal(doctype.satisfies(parse("number"), parse("any")), true)
	test.equal(doctype.satisfies(parse("number"), parse("unknown")), true)
	test.equal(doctype.satisfies(parse("unknown"), parse("number")), true)
	-- An unresolved name is not a wildcard: it does not fit `number`. What keeps it quiet is
	-- that inference yields `unknown` for anything it cannot type, and nothing is reported
	-- against an unknown.
	test.equal(doctype.satisfies(parse("unknown"), parse("my.Class")), true)
	test.equal(doctype.mismatch(parse("my.Class"), parse("unknown"), "x"), nil,
		"nothing is reported against an unknown")
	test.equal(doctype.mismatch(parse("number"), parse("unknown"), "x"), nil)
end)

test.it("describes a mismatch in the message", function()
	local message = doctype.mismatch(parse("string"), parse("number"), "x")
	test.truthy(message)
	test.truthy(message:match("string"))
	test.truthy(message:match("number"))
	test.equal(doctype.mismatch(parse("string"), parse("string"), "x"), nil)
end)

test.it("keeps an optional name unknown rather than making it nil", function()
	-- `---@param v? T` on a name nothing is known about says the value may be anything, nil
	-- included: collapsing it to nil would report every argument passed to it.
	local unknown = function() return doctype.UNKNOWN_TYPE end
	test.equal(doctype.display(parse("T?", unknown)), "unknown")
	test.equal(doctype.display(parse("number?", unknown)), "number?")
	test.equal(doctype.display(parse("T[]?", unknown)), "unknown[]?")
	test.equal(doctype.display(parse("nil|string[]")), "string[]?",
		"a suffix belongs to its own member rather than to the union")
end)

test.it("takes any container for a table", function()
	-- The standard library writes `table` where it does not care what is inside.
	test.equal(doctype.satisfies(parse("string[]"), doctype.TABLE), true)
	test.equal(doctype.satisfies(parse("{ a: number }"), doctype.TABLE), true)
	test.equal(doctype.satisfies(parse("string"), doctype.TABLE), false)
	test.equal(doctype.satisfies(parse("nil|string[]"), doctype.TABLE), false,
		"every member of a union has to fit")
end)

test.it("reads never as the type that has no value", function()
	local never = parse("never")
	test.equal(doctype.display(never), "never")
	test.equal(doctype.satisfies(never, parse("number")), true,
		"a call that never returns has no value to be wrong")
	test.equal(doctype.satisfies(parse("number"), never), false,
		"and nothing is a value that cannot exist")
	test.equal(doctype.display(doctype.union({ never, parse("number") })), "number",
		"a member that cannot exist adds nothing to what a value may be")
	test.equal(doctype.display(parse("never|string")), "string")
end)

test.it("narrows to a class or an alias by the parsed type", function()
	-- A predicate names a type its writer chose: `x is Point` has to narrow to the class, which a
	-- name parsed without a resolver cannot reach.
	local point = doctype.classType("Point", nil, { x = doctype.NUMBER })
	test.equal(doctype.display(doctype.narrowToType(doctype.union({ point, doctype.NIL_TYPE }), point) --[[@as lye.doc.Type]]),
		"Point")
	test.equal(doctype.display(doctype.excludeType(doctype.union({ point, doctype.NIL_TYPE }), point) --[[@as lye.doc.Type]]),
		"nil")
end)

test.it("absorbs a literal into the type it belongs to", function()
	-- A literal is already a member of its base type, so `20261024 | number` says exactly what
	-- `number` says. The order it was written in must not matter, and two literals with no base
	-- beside them keep their exact values.
	local seed = doctype.numberValue(20261024, "20261024")
	test.equal(doctype.display(doctype.union({ seed, doctype.NUMBER })), "number")
	test.equal(doctype.display(doctype.union({ doctype.NUMBER, seed })), "number",
		"the order it was written in does not matter")
	local yes = doctype.booleanValue(true)
	test.equal(doctype.display(doctype.union({ yes, doctype.BOOLEAN })), "boolean")
	test.equal(doctype.display(doctype.union({ doctype.BOOLEAN, yes })), "boolean")
	local word = parse('"seed"')
	test.equal(doctype.display(doctype.union({ word, doctype.STRING })), "string")
	test.equal(doctype.display(doctype.union({ doctype.STRING, word })), "string")
	test.equal(doctype.display(doctype.union({ seed, parse("string") })), "20261024|string",
		"a literal with no base of its own keeps its value")
end)

test.it("reads a field marked optional on its own name", function()
	-- `kind?: string` and `kind: string?` say the same thing, and LuaLS's own definitions write
	-- both. The marker used to end up inside the type — the field printed as `kind: ?: string` and
	-- stayed required — so every call passing a table without it was reported as a disagreement.
	local function field(text, name)
		local parsed = parse(text, function(called)
			if called == "string" then return doctype.STRING end
		end)
		return (parsed.fields or {})[name]
	end

	test.equal(doctype.display(field("{ kind?: string }", "kind")), "string?")
	test.equal(doctype.display(field("{ kind: string? }", "kind")), "string?",
		"the marker on the type says the same thing")
	test.equal(doctype.display(field("{ name: string }", "name")), "string",
		"a field with no marker keeps its type")
	test.equal(doctype.display(field("{ name: string, age?: number }", "age")), "number?",
		"and a later field in the list is read the same way")
end)

test.it("takes a bare table for any shape it could hold", function()
	-- `table` is the `any` of tables: nothing was said about what is in one, so it fits a shape, a
	-- list or a map. It fits nothing that is not a table, which is the whole difference from `any`.
	test.equal(doctype.satisfies(doctype.TABLE, parse("{ a: number }")), true)
	test.equal(doctype.satisfies(doctype.TABLE, parse("table<string, number>")), true)
	test.equal(doctype.satisfies(doctype.TABLE, parse("string[]")), true)
	test.equal(doctype.satisfies(doctype.TABLE, parse("string")), false)
	test.equal(doctype.satisfies(doctype.TABLE, parse("number")), false)
end)

test.it("reads a method written without its receiver as one written with it", function()
	-- A class field spells the receiver out — `fun(self: P, label: string): boolean` — while the
	-- body declared `function p:set(label)` takes it from the caller, so a table holding that body
	-- is a P.
	local P
	P = doctype.classType("P", {}, {
		set = parse("fun(self: P, label: string): boolean", function(name)
			if name == "P" then return P end
		end),
	})
	local value = doctype.object({ set = parse("fn(label: string) -> boolean") })
	test.equal(doctype.satisfies(value, P), true)
	local wrong = doctype.object({ set = parse("fn(label: number) -> boolean") })
	test.equal(doctype.satisfies(wrong, P), false, "the parameters still have to fit")
end)

test.it("narrows every member of a union to the value the branch holds", function()
	local optional = doctype.union({ doctype.BOOLEAN, doctype.NIL_TYPE })
	test.equal(doctype.display(doctype.narrowTruthiness(optional, false)), "false?",
		"a whole boolean in a union becomes the value that side holds")
	test.equal(doctype.display(doctype.narrowTruthiness(optional, true)), "true",
		"and the truthy side is the other one")
	test.equal(doctype.display(doctype.narrowTruthiness(doctype.BOOLEAN, false)), "false")
end)

test.it("binds the variable a conditional's extends names", function()
	-- `T extends Option<infer V> ? V : never` is how a descriptor's value type is read. The
	-- variable is bound by the match, and an optional marker in the branch belongs to `V`, not to
	-- a nested conditional's question mark.
	local resolver = function(text)
		if text == "T" then return doctype.extern("T") end
		if text == "Option<infer V>" then
			return doctype.classType("Option", { doctype.infer("V") })
		end
	end
	local condition = parse("T extends Option<infer V> ? V? : never", resolver)
	local option = doctype.classType("Option", { doctype.NUMBER })
	local resolved = doctype.substitute(condition, { T = option })
	test.equal(doctype.display(resolved), "number?")
	test.equal(doctype.display(doctype.substitute(condition, { T = doctype.STRING })), "never")
end)

test.it("reads a mapped value indexed through two keys", function()
	-- `T[K]["value"]` is two accesses: the first is still unresolved when the mapped type is
	-- written, so it has to survive until the key substitution gives it a class to read.
	local function point(arg)
		return doctype.classType("Point", { arg }, { value = arg })
	end
	local shape = doctype.object({ name = point(doctype.STRING) })
	local mapped = doctype.mapped("K", doctype.keyof(shape),
		doctype.indexedAccess(doctype.indexedAccess(shape, doctype.extern("K")),
			doctype.stringValue("value")))
	test.equal(doctype.display(doctype.fieldOf(mapped, "name")), "string")
end)

test.it("checks a mapped shape where a parameter is declared", function()
	local shape = doctype.object({ a = doctype.NUMBER, b = doctype.STRING })
	local mapped = doctype.mapped("K", doctype.keyof(shape), doctype.NUMBER)
	test.equal(doctype.satisfies(doctype.object({ a = doctype.NUMBER, b = doctype.NUMBER }), mapped), true)
	test.equal(doctype.satisfies(doctype.object({ a = doctype.NUMBER, b = doctype.STRING }), mapped), false)
end)

test.it("brackets a union an array display holds", function()
	local element = doctype.union({ parse("{ a: number }"), parse("{ b: string }") })
	test.equal(doctype.display(doctype.array(element)), "({ a: number }|{ b: string })[]")
	test.equal(doctype.display(doctype.object({}, { key = "integer", type = element })),
		"({ a: number }|{ b: string })[]", "a table of elements reads as the list it is")
end)

return true
