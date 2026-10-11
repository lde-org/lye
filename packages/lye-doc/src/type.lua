--[[
	Type system: variants, subtyping, narrowing and display.

	A type is a table with a `variant`, so everything is data rather than a string re-parsed on each
	question. `unknown` is the honest answer when inference cannot tell, and it satisfies everything.
]]

local types = {}

--- A type table, discriminated by `variant`.
---@alias lye.doc.Type
---| { variant: "number" }
---| { variant: "string" }
---| { variant: "boolean" }
---| { variant: "nil" }
---| { variant: "table" }
---| { variant: "fn", params: lye.doc.Type[], returns: lye.doc.Type, isVariadic: boolean?, values: lye.doc.Type[]? }
---| { variant: "any" }
---| { variant: "unknown" }
---| { variant: "extern", name: string }
---| { variant: "array", type: lye.doc.Type }
---| { variant: "object", fields: table<string, lye.doc.Type> }
---| { variant: "union", types: lye.doc.Type[] }
---| { variant: "class", name: string, args: lye.doc.Type[], fields: table<string, lye.doc.Type>, parents: lye.doc.Type[] }
---| { variant: "never" }

types.UNKNOWN = "unknown"
types.ANY = "any"
types.NIL = "nil"

-- The names that are a type on their own; `bool` and `void` are LuaLS's spellings for a
-- boolean and for nothing at all.
local SIMPLE = {
	number = true, string = true, boolean = true, ["nil"] = true, any = true, unknown = true,
	thread = true, userdata = true, lightuserdata = true, cdata = true, bool = true, void = true,
}

---@param variant string
---@param fields table?
---@return lye.doc.Type
local function make(variant, fields)
	local out = { variant = variant }
	if fields then
		for key, value in pairs(fields) do out[key] = value end
	end
	return out
end

--- An `unknown` that can still be promoted: a later assignment may tell us what it is.
--- That is the difference between "not known yet" and "genuinely unknown".
---@return lye.doc.Type
function types.mutable()
	return { variant = "unknown", isMutable = true }
end

---@param type lye.doc.Type
function types.isMutable(type)
	return type.isMutable == true
end

--- Promote a mutable unknown to a known type, in the same table, so every holder sees it.
--- Returns whether the promotion happened.
---@param target lye.doc.Type
---@param actual lye.doc.Type
---@return boolean
function types.promote(target, actual)
	if not types.isMutable(target) then return false end
	if actual.variant == "unknown" then return false end
	target.variant = actual.variant
	target.isMutable = nil
	for key, value in pairs(actual) do target[key] = value end
	return true
end

function types.base(name) return make(name) end

types.NUMBER = make("number")
types.STRING = make("string")
types.BOOLEAN = make("boolean")
types.NIL_TYPE = make("nil")
types.TABLE = make("table")
--- A boolean written out: `true` in a `---@field ok: true` is that value, not a name, which is
--- what makes it usable as the discriminant of a union.
---@param value boolean
function types.booleanValue(value)
	return make("boolean", { value = value })
end

--- The number a literal spells. Without one it is any number; with one it is that number and
--- no other, which is what a `---@type 2149 | 231` a comparison can be checked against is.
---@param value number
---@param text string? the number as written, so `0x10` reads back as it was typed
function types.numberValue(value, text)
	return make("number", { value = value, text = text or tostring(value) })
end

--- The number a type is, when it is one number rather than any.
---@param type lye.doc.Type?
---@return number? value
function types.numericValue(type)
	return type and type.variant == "number" and type.value or nil
end

--- A function that hands back no value at all: not `nil`, which a caller can read, but
--- nothing to read. Anywhere a `nil` would fit, so does this.
types.VOID = make("void")

--- The bottom type: a call that does not come back, as `error` does. Nothing is a `never`, and a
--- `never` is everything, so it sits under every other type in the lattice.
types.NEVER = make("never")
--- A class this file declares. It is nominal: `Foo<number>` is not `Foo<string>`, and a class
--- satisfies what it extends. The fields are already resolved, so reading one costs nothing.
---@param name string
---@param args lye.doc.Type[]?
---@param fields table<string, lye.doc.Type>?
---@param parents lye.doc.Type[]?
---@param visibility table<string, string>? who may read each field
function types.classType(name, args, fields, parents, visibility)
	return make("class", {
		name = name, args = args or {}, fields = fields or {}, parents = parents or {},
		visibility = visibility or {},
	})
end

--- A callable. The parameters and the return type are types, so a function is as hard typed as
--- anything else: `fn(a: number) -> string` does not accept a function that takes a string.
---@param params lye.doc.Type[]
---@param returns lye.doc.Type
---@param isVariadic boolean? accepts any number of arguments
---@param isSpread boolean? returns a sequence, so every call result is that type
function types.fn(params, returns, isVariadic, isSpread)
	return make("fn", {
		params = params, returns = returns, isVariadic = isVariadic, isSpread = isSpread,
	})
end

---@param type lye.doc.Type
function types.isFn(type)
	return type.variant == "fn"
end

--- The permissive callable, the one a `function` literal has until something says otherwise.
---@param type lye.doc.Type
---@return boolean
function types.isAnyFn(type)
	-- A variadic function whose parameters are all `any` and whose return is `any` says nothing
	-- about how it is called, which is what `fn(...) -> ...` and a bare `function` both mean.
	if type.variant ~= "fn" or type.isVariadic ~= true then return false end
	if type.returns.variant ~= "any" then return false end
	for _, param in ipairs(type.params) do
		if param.variant ~= "any" then return false end
	end
	return true
end
types.UNKNOWN_TYPE = make("unknown")
types.ANY_TYPE = make("any")

--- What a bare `function` means: `fn(...any) -> ...any`, so annotations written before
--- signatures keep working. Built here because it is made of them.
types.FUNCTION = types.fn({}, types.ANY_TYPE, true)

---@param name string
function types.extern(name) return make("extern", { name = name }) end

---@param inner lye.doc.Type
function types.array(inner) return make("array", { type = inner }) end

---@param fields table<string, lye.doc.Type>
---@param indexed { key: string, type: lye.doc.Type }? what any other key holds
function types.object(fields, indexed) return make("object", { fields = fields, indexed = indexed }) end

--- Flatten nested unions and drop duplicates. An unknown member absorbs the whole union,
--- since `string | unknown` tells us no more than the unknown did.
---@param members lye.doc.Type[]
---@return lye.doc.Type
function types.union(members)
	for _, member in ipairs(members) do
		if member.variant == "unknown" or member.variant == "any" then return member end
	end

	local flat, seen = {}, {}
	local function add(member)
		if member.variant == "union" then
			for _, inner in ipairs(member.types) do add(inner) end
			return
		end
		-- A member that cannot exist adds nothing to the set of what a value may be.
		if member.variant == "never" then return end
		local key = types.display(member)
		if not seen[key] then
			seen[key] = true
			flat[#flat + 1] = member
		end
	end
	for _, member in ipairs(members) do add(member) end
	if #flat == 1 then return flat[1] end
	return make("union", { types = flat })
end

--- Combine two types. An unknown operand contributes nothing, so evolving a variable from
--- its first assignment does not have to special-case the unknown it started as.
---@param left lye.doc.Type
---@param right lye.doc.Type
---@return lye.doc.Type
function types.combine(left, right)
	-- A *mutable* unknown is a promise rather than an answer: it holds the place of a value not yet
	-- typed. Taking the other side throws the promise away and turns a guard into a contradiction.
	if types.isMutable(left) then return left end
	if types.isMutable(right) then return right end
	if left.variant == "unknown" then return right end
	if right.variant == "unknown" then return left end
	if types.display(left) == types.display(right) then return left end
	-- An empty table is a container waiting to be filled, so where the other side is one too it takes
	-- that shape instead of widening it. Asked of the other side, so `nil` still combines with it.
	if types.isUnknownShape(left) and types.satisfies(left, right) then return right end
	if types.isUnknownShape(right) and types.satisfies(right, left) then return left end
	return types.union({ left, right })
end

--- Whether every possible value of `type` fits `constraint`.
---@param type lye.doc.Type
local function stringValueOf(type)
	if type.variant ~= "extern" then return nil end
	local first, last = type.name:sub(1, 1), type.name:sub(-1)
	if (first == '"' or first == "'") and last == first then return type.name:sub(2, -2) end
end

---@param type lye.doc.Type
---@param constraint lye.doc.Type
---@return boolean
function types.satisfies(type, constraint)
	if types.isMutable(constraint) then types.promote(constraint, type) end

	-- A boolean written out is that value too, which is what a discriminant is compared against.
	if constraint.variant == "boolean" and constraint.value ~= nil then
		return type.variant == "boolean" and type.value == constraint.value
	end

	-- One number is an exact value and nothing is known cannot be shown to be it: `---@return 521`
	-- asks for 521, not any number. Every other constraint accepts an unknown.
	if constraint.variant == "number" and constraint.value then
		return type.variant == "number" and type.value == constraint.value
	end

	if constraint.variant == "any" or constraint.variant == "unknown" then return true end
	if type.variant == "unknown" or type.variant == "any" then return true end

	-- A C number is a cdata the engine converts wherever a number is wanted, so refusing it would
	-- report code the engine runs. The class keeps the name it was written with, marker and all.
	local function isCNumber(candidate)
		local function named(one)
			return one and one.name and (one.name:gsub("%*$", "")) == "ffi.cnum" or false
		end
		if named(candidate) then return true end
		for _, parent in ipairs(candidate and candidate.parents or {}) do
			if named(parent) then return true end
		end
		return false
	end
	if isCNumber(type) and (constraint.variant == "number" or constraint.variant == "integer"
		or isCNumber(constraint)) then
		return true
	end

	-- And the other way: a Lua number written into a C number is converted by the engine, which is
	-- what assigning `32` to a `size_t` does. The difference shows in what a value *is*.
	if isCNumber(constraint) and (type.variant == "number" or type.variant == "integer") then
		return true
	end

	-- A quoted name is a string value rather than a name to look up, so it is one of the strings and
	-- only that same string fits it. A `never` fits every constraint, and nothing else fits a `never`.
	if type.variant == "never" then return true end
	if constraint.variant == "never" then return false end

	-- Returning nothing is not returning nil, but a caller cannot tell the two apart, so either
	-- spelling fits the other.
	if constraint.variant == "void" then return type.variant == "void" or type.variant == "nil" end
	if type.variant == "void" then return constraint.variant == "nil" end

	local wanted = stringValueOf(constraint)
	-- A string value names one string and any string satisfies it, because a literal in a table
	-- is typed as the string it is. A number value is exact, since a literal is its own value.
	if wanted then
		local have = stringValueOf(type)
		if have then return have == wanted end
		return type.variant == "string"
	end
	if constraint.variant == "string" and stringValueOf(type) then return true end

	-- A union fits only when every member does, and this is asked first: `A|B` fits `A|B`, while
	-- the other order would ask whether one member accepts the whole union.
	if type.variant == "union" then
		for _, member in ipairs(type.types) do
			if not types.satisfies(member, constraint) then return false end
		end
		return true
	end

	if constraint.variant == "union" then
		for _, member in ipairs(constraint.types) do
			if types.satisfies(type, member) then return true end
		end
		return false
	end

	-- In Lua every structured value is a table: an instance of a class, a table literal and a list
	-- all are, so all of them fit the `table` the definitions write where one is expected.
	if constraint.variant == "table" then
		return type.variant == "table" or type.variant == "object" or type.variant == "class"
			or type.variant == "array"
	end

	if constraint.variant == "extern" then
		-- The other direction of the same thing: a class fits a name written for it.
		if type.name == constraint.name then return true end
		return false
	end

	if constraint.variant == "class" then
		-- A table is how a class is built, so a table fits. Only the fields it does have are
		-- checked: an instance is routinely built in pieces.
		if type.variant == "table" then return true end
		if type.variant == "object" then
			for name, have in pairs(type.fields) do
				local wanted = constraint.fields[name]
				if wanted and not types.satisfies(have, wanted) then return false end
			end
			return true
		end
		-- A class named after a builtin type *is* that type: `builtin.lua` declares
		-- `---@class string`, which is what makes `ffi.new("Vec")` fit the `ffi.cdecl*` extending it.
		if SIMPLE[constraint.name] then
			return types.satisfies(type, types.base(constraint.name))
		end
		-- A value that fits what the class extends fits the class: the definitions write
		-- `---@class ffi.cdecl*: string`, and a string is exactly what a parameter of it takes.
		for _, parent in ipairs(constraint.parents or {}) do
			if types.satisfies(type, parent) then return true end
		end
		-- A name this document never resolved is that name's class when the class is called the
		-- same thing, and the file that declares it is what makes it the class.
		if type.variant == "extern" and type.name == constraint.name then return true end
		if type.variant ~= "class" then return false end
		-- A class whose every field is optional describes a shape rather than a name, so a class fits it
		-- by carrying those fields. What makes a table a metatable is which metamethods it has.
		local shaped, some = true, false
		for _, wanted in pairs(constraint.fields) do
			some = true
			if not types.satisfies(types.NIL_TYPE, wanted) then
				shaped = false
				break
			end
		end
		if shaped and some then
			for name, wanted in pairs(constraint.fields) do
				local have = type.fields[name]
				if have and not types.satisfies(have, wanted) then return false end
			end
			return true
		end
		if type.name ~= constraint.name then
			for _, parent in ipairs(type.parents) do
				if types.satisfies(parent, constraint) then return true end
			end
			return false
		end
		for index, wanted in ipairs(constraint.args or {}) do
			local have = type.args[index] or types.UNKNOWN_TYPE
			if not types.satisfies(have, wanted) then return false end
		end
		return true
	end

	if constraint.variant == "fn" then
		if type.variant ~= "fn" then return false end
		-- A callable that takes anything accepts any callable, which is what a bare `function`
		-- means and what keeps unannotated literals out of trouble.
		if types.isAnyFn(constraint) then return true end
		-- A variadic constraint asks for a callable that accepts at least what it names, which a
		-- fixed signature does when its own parameters fit.
		if #type.params ~= #constraint.params and not type.isVariadic and not constraint.isVariadic then
			return false
		end
		for index, wanted in ipairs(constraint.params or {}) do
			local have = type.params[index] or types.UNKNOWN_TYPE
			-- Contravariant: the value has to accept what the constraint will pass it.
			if not types.satisfies(wanted, have) then return false end
		end
		return types.satisfies(type.returns, constraint.returns)
	end

	if constraint.variant == "array" then
		-- `local names = {}` declares a list before it holds anything, so a table fits.
		if types.isUnknownShape(type) then return true end
		-- A list literal is an object with an integer index, so whichever way the list was written,
		-- the elements are what has to fit.
		if type.variant == "object" and type.indexed
			and (type.indexed.key == "integer" or type.indexed.key == "number") then
			return types.satisfies(type.indexed.type, constraint.type)
		end
		if type.variant ~= "array" then return false end
		return types.satisfies(type.type, constraint.type)
	end

	if constraint.variant == "object" then
		-- A list is what `{ [integer]: T }` describes, so an array fits it when its elements do.
		if type.variant == "array" and constraint.indexed then
			return types.satisfies(type.type, constraint.indexed.type)
		end
		if type.variant == "table" and next(constraint.fields) == nil then return true end
		-- A class is a table as well, and the fields it declares are the ones a shape asks about:
		-- a class is routinely built in pieces, so a field it does not name is not held against it.
		if type.variant == "class" then
			for name, wanted in pairs(constraint.fields) do
				local have = type.fields[name]
				if have and not types.satisfies(have, wanted) then return false end
			end
			return true
		end
		if type.variant ~= "object" then return false end
		for name, wanted in pairs(constraint.fields) do
			-- A field the literal leaves out is nil, which is what an optional field accepts:
			-- `---@field weight? number` does not ask the caller to write it down.
			local have = type.fields[name] or types.NIL_TYPE
			if not types.satisfies(have, wanted) then return false end
		end
		if constraint.indexed then
			local have = type.indexed and type.indexed.type
			if have then
				if not types.satisfies(have, constraint.indexed.type) then return false end
			else
				-- A table of named fields is a map as well: `{ a = 1 }` fits `table<string,
				-- number>` when each value in it does. That is what the literal's fields say.
				for _, field in pairs(type.fields) do
					if not types.satisfies(field, constraint.indexed.type) then return false end
				end
			end
		end
		return true
	end

	if constraint.variant == "table" then
		-- A table is the shape every Lua container has, so a list, an object and a class are all
		-- tables to it: the standard library writes `table` where it does not care what is inside.
		return type.variant == "table" or type.variant == "array"
			or type.variant == "object" or type.variant == "class"
	end

	if SIMPLE[constraint.variant] or SIMPLE[type.variant] then
		return type.variant == constraint.variant
	end

	-- A container or a name the checker does not model: decline rather than guess.
	return type.variant == constraint.variant
end

--- A table nothing is known about: a fresh literal is its own object so its shape can grow, and
--- it fits wherever a bare table fits because there is no shape yet to disagree with.
---@param type lye.doc.Type
---@return boolean
function types.isUnknownShape(type)
	if type.variant == "table" then return true end
	return type.variant == "object" and type.indexed == nil and next(type.fields or {}) == nil
end

--- Whether the value is definitely truthy, definitely falsy, or either.
---@param type lye.doc.Type
---@return boolean? truthy
function types.truthiness(type)
	if type.variant == "nil" then return false end
	if type.variant == "never" then return nil end
	-- `true` and `false` written in a type are those values, so a discriminant carries its own
	-- answer; a plain boolean could be either.
	if type.variant == "boolean" then
		if type.value ~= nil then return type.value end
		return nil
	end
	if type.variant == "any" or type.variant == "unknown" then return nil end
	if type.variant == "union" then
		local first
		for _, member in ipairs(type.types) do
			local known = types.truthiness(member)
			if known == nil then return nil end
			if first == nil then first = known elseif first ~= known then return nil end
		end
		return first
	end
	-- Only nil and false are falsy, so everything else is definitely truthy.
	return true
end

--- Keep the members that can be truthy, or the ones that can be falsy. This is condition
--- narrowing: `if y then` on `string|nil` leaves `string` in the branch.
---@param type lye.doc.Type
---@param wantTruthy boolean
function types.narrowTruthiness(type, wantTruthy)
	-- A plain boolean is either of its two values, so asking which one a branch holds answers with
	-- that value rather than with "a boolean".
	if type.variant == "boolean" and type.value == nil then
		return types.booleanValue(wantTruthy)
	end
	if type.variant ~= "union" then
		local known = types.truthiness(type)
		if known == nil or known == wantTruthy then return type end
		return nil
	end

	local kept = {}
	for _, member in ipairs(type.types) do
		local known = types.truthiness(member)
		if known == nil or known == wantTruthy then kept[#kept + 1] = member end
	end
	if #kept == 0 then return nil end
	if #kept == #type.types then return type end
	return types.union(kept)
end

--- Keep the members that do, or do not, carry a field. This narrows a discriminated union:
--- testing `x.foo` on `{ foo: number } | { bar: string }` selects the member with `foo`.
---@param type lye.doc.Type
--- Keep only the members that are nil, or only those that are not.
---@param type lye.doc.Type
---@param wantNil boolean
---@return lye.doc.Type? narrowed
function types.narrowNil(type, wantNil)
	if type.variant ~= "union" then
		local isNil = type.variant == "nil"
		return isNil == wantNil and type or nil
	end
	local kept = {}
	for _, member in ipairs(type.types) do
		if (member.variant == "nil") == wantNil then kept[#kept + 1] = member end
	end
	if #kept == 0 then return nil end
	return types.union(kept)
end

--- Keep only the members that fit a type, which is what a predicate or a `type(x) == "number"`
--- test asserts. A name that resolves to nothing keeps the type unchanged rather than emptying it.
---@param type lye.doc.Type
---@param wanted lye.doc.Type?
function types.narrowToType(type, wanted)
	if not wanted then return type end
	if type.variant ~= "union" then
		return types.satisfies(type, wanted) and type or nil
	end
	local kept = {}
	for _, member in ipairs(type.types) do
		if types.satisfies(member, wanted) then kept[#kept + 1] = member end
	end
	if #kept == 0 then return nil end
	return types.union(kept)
end

---@param type lye.doc.Type
---@param typeName string
function types.narrowTo(type, typeName)
	return types.narrowToType(type, types.parse(typeName))
end

--- Whether every value of a type is that one. `satisfies` is loose about a string value on
--- purpose, but ruling something out needs the strict reading: a `string` is not *only* `""`.
---@param type lye.doc.Type
---@param value lye.doc.Type
function types.isExactly(type, value)
	local wanted = stringValueOf(value)
	if wanted then return stringValueOf(type) == wanted end
	return types.satisfies(type, value)
end

--- Keep only the members that do not fit a type.
---@param type lye.doc.Type
---@param unwanted lye.doc.Type?
function types.excludeType(type, unwanted)
	if not unwanted then return type end
	if type.variant ~= "union" then
		-- `and nil or type` cannot yield nil, so ruling the type out has to be explicit.
		if types.isExactly(type, unwanted) then return nil end
		return type
	end
	local kept = {}
	for _, member in ipairs(type.types) do
		if not types.isExactly(member, unwanted) then kept[#kept + 1] = member end
	end
	if #kept == 0 then return nil end
	return types.union(kept)
end

---@param type lye.doc.Type
---@param typeName string
function types.exclude(type, typeName)
	return types.excludeType(type, types.parse(typeName))
end

---@param field string
---@param want boolean
---@return lye.doc.Type? narrowed
function types.narrowField(type, field, want)
	--- Whether a member survives the condition. A field whose truth is written down decides it,
	--- which is what makes `{ ok: true, v: T } | { ok: false, e: string }` narrow on `parsed.ok`.
	---@param member lye.doc.Type
	---@return boolean
	local function survives(member)
		if member.variant ~= "object" and member.variant ~= "class" then return false end
		local held = member.fields[field]
		if held == nil then return not want end
		local known = types.truthiness(held)
		if known == nil then return want end
		return known == want
	end

	if type.variant ~= "union" then
		if type.variant ~= "object" and type.variant ~= "class" then return type end
		return survives(type) and type or nil
	end

	local kept = {}
	for _, member in ipairs(type.types) do
		if survives(member) then kept[#kept + 1] = member end
	end
	if #kept == 0 then return nil end
	return types.union(kept)
end

--- Keep only the members whose own `field` could hold what a condition compared it against:
--- `if kind ~= "fn" then return end` is how a tagged union is read. A member without the
--- field reads it as nil, so it only survives the negative form.
---@param type lye.doc.Type
---@param field string
---@param wanted lye.doc.Type the value the condition compared against
---@param want boolean whether the condition was the equality
---@return lye.doc.Type? narrowed
function types.narrowDiscriminant(type, field, wanted, want)
	---@param member lye.doc.Type
	local function couldBe(member)
		local held = member.variant == "object" and member.fields[field] or nil
		if not held then
			-- A class is built at runtime, so a field it does not name may still be there; an
			-- object literal says what it holds and nothing else.
			return member.variant == "class"
		end
		return types.satisfies(wanted, held)
	end

	if type.variant ~= "union" then return couldBe(type) == want and type or nil end
	local kept = {}
	for _, member in ipairs(type.types) do
		if couldBe(member) == want then kept[#kept + 1] = member end
	end
	if #kept == 0 then return nil end
	return types.union(kept)
end

--- The type an arithmetic or logical operator produces, and whether every value of a type is a
--- number. An `any` is not: it could be a table whose metamethod returns anything at all.
---@param type lye.doc.Type
---@return boolean
local function isNumeric(type)
	if type.variant == "number" then return true end
	if type.variant == "union" then
		for _, member in ipairs(type.types) do
			if not isNumeric(member) then return false end
		end
		return true
	end
	return false
end

--- The arithmetic itself, so a folded literal is the number the engine would have produced rather
--- than an approximation of it.
local ARITHMETIC_RESULT = {
	["+"] = function(a, b) return a + b end,
	["-"] = function(a, b) return a - b end,
	["*"] = function(a, b) return a * b end,
	["/"] = function(a, b) return a / b end,
	["%"] = function(a, b) return a % b end,
	["^"] = function(a, b) return a ^ b end,
}

function types.binaryResult(op, left, right)
	-- Lua asks the operands' metamethods about an operation before it does anything itself, so a
	-- table that defines one decides what the operator gives.
	local metamethod = types.metamethodFor(op, left, right)
	if metamethod then
		-- A comparison answers a boolean whatever the metamethod hands back: Lua coerces it.
		if op == "==" or op == "~=" or op == "<" or op == ">" or op == "<=" or op == ">=" then
			return types.BOOLEAN
		end
		return metamethod.returns
	end

	if left.variant == "unknown" or right.variant == "unknown" then return types.mutable() end

	-- `..` coerces numbers, so it is a string whenever either side is one.
	if op == ".." then
		if left.variant == "string" or right.variant == "string" then return types.STRING end
		if left.variant == "number" and right.variant == "number" then return types.STRING end
		return types.mutable()
	end

	if op == "==" or op == "~=" or op == "<" or op == ">" or op == "<=" or op == ">=" then
		return types.BOOLEAN
	end
	if op == "and" or op == "&&" or op == "or" or op == "||" then
		-- `a and b` is `a` when `a` is falsy and `b` otherwise; `or` the other way round. When the
		-- left side is definitely one of the two, the answer is one of the operands, not a union.
		local isAnd = op == "and" or op == "&&"
		-- An `any` on the left answers with itself: nothing can be said about which side it takes,
		-- so combining it with the right side lets the right side stand for the answer.
		if left.variant == "any" or left.variant == "unknown" then return left end
		local known = types.truthiness(left)
		if known ~= nil then
			if isAnd == known then return right end
			return left
		end
		-- Nothing is known about which side answers, and the union of both operands is not the answer
		-- either: `a` cannot be here twice. `x and x.field` is the field or nothing.
		if isAnd then
			local absent = types.narrowTruthiness(left, false)
			-- When the right side already covers what the left is when it is absent — a `boolean`
			-- covers the `false` a boolean becomes — the answer is just the right side.
			if not absent or types.satisfies(absent, right) then return right end
			return types.combine(absent, right)
		end
		local present = types.excludeType(left, types.NIL_TYPE)
		if present then present = types.excludeType(present, types.booleanValue(false)) end
		if not present then return right end
		return types.combine(present, right)
	end
	if op == "??" then return types.combine(left, right) end

	local isArithmetic = op == "+" or op == "-" or op == "*" or op == "/" or op == "%"
		or op == "^" or op == "&" or op == "|" or op == "~" or op == "<<" or op == ">>" or op == "~>>"
	if isArithmetic then
		-- Two numbers written down are a number this file already knows. Anything it does not know
		-- leaves the result a plain number, the wider type the literal was always usable as.
		local leftValue, rightValue = types.numericValue(left), types.numericValue(right)
		if leftValue and rightValue then
			local ok, folded = pcall(ARITHMETIC_RESULT[op], leftValue, rightValue)
			if ok and type(folded) == "number" then return types.numberValue(folded) end
		end
		if isNumeric(left) and isNumeric(right) then return types.NUMBER end
		-- Anything else could be a table with a metamethod, so the result is not claimed. `any` is
		-- in that group: satisfying a constraint is not a guarantee that it is one.
		return types.mutable()
	end
	return types.mutable()
end

---@param op string
---@param operand lye.doc.Type
---@return lye.doc.Type
function types.unaryResult(op, operand)
	if op == "not" or op == "!" then return types.BOOLEAN end
	local value = types.numericValue(operand)
	if value and op == "-" then return types.numberValue(-value) end
	-- `#` is the length of a table whatever its metatable says: LuaJIT honours `__len` only for
	-- userdata, which lye does not model. Every other unary operator asks the metamethod.
	if op ~= "#" then
		local metamethod = types.metamethodFor("unary-", operand, operand)
		if metamethod then return metamethod.returns end
	end
	if op == "#" then return types.NUMBER end
	if operand.variant == "unknown" then return types.mutable() end
	if op == "-" or op == "~" then
		return types.satisfies(operand, types.NUMBER) and types.NUMBER or types.mutable()
	end
	return types.mutable()
end

--- The metamethod Lua consults for an operator. The engine asks for these by name, and a table
--- that defines one changes what the operator does with it.
local METAMETHODS = {
	["+"] = "__add", ["-"] = "__sub", ["*"] = "__mul", ["/"] = "__div", ["%"] = "__mod",
	["^"] = "__pow", [".."] = "__concat", ["=="] = "__eq", ["<"] = "__lt", ["<="] = "__le",
	["unary-"] = "__unm",
}

--- The same type, with the metatable Lua consults for what it does not define itself. A copy,
--- because a class type is shared and one `setmetatable` must not reach every other reader.
---@param type lye.doc.Type
---@param metatable lye.doc.Type?
function types.withMetatable(type, metatable)
	if not metatable or types.isMutable(type) then return type end
	local copy = {}
	for key, value in pairs(type) do copy[key] = value end
	copy.metatable = metatable
	-- The copy carries every field the original has, which a table built in a loop cannot say: it is
	-- the same type, with the metatable beside it.
	---@cast copy lye.doc.Type
	return copy
end

--- The metatable a type carries, when it carries one.
---@param type lye.doc.Type?
---@return lye.doc.Type?
function types.metatableOf(type)
	return type and type.metatable
end

--- The metamethod a value answers an operation with: the field of its metatable, read the way Lua
--- reads it. A metatable that names no `__index` is read as the table itself, which is what a
--- class written `Point.__index = Point` means.
---@param type lye.doc.Type?
---@param name string
---@return lye.doc.Type?
function types.metamethod(type, name)
	local metatable = type and type.metatable
	local carried = metatable and metatable.fields and metatable.fields[name]
	if carried then return carried end
	-- A type may also declare the metamethod it answers with as a field of its own, which is how
	-- the definitions describe a C number: it is cdata the engine gives `__add` and the rest to,
	-- and a check for "this operand has to be a number" has to see that rather than report it.
	return type and type.fields and type.fields[name] or nil
end

--- The type a field read gives, following the metatable when the type does not carry the field.
--- A table's `__index` sends the read somewhere else; a function there answers it with what it
--- returns. Nil when nothing in the chain declares the field at all, which is different from a
--- field that is there and nil.
---@param type lye.doc.Type?
---@param name string
---@return lye.doc.Type?
function types.fieldOf(type, name)
	local depth = 0
	while type and depth < 8 do
		if type.variant == "union" then
			for _, member in ipairs(type.types) do
				local found = types.fieldOf(member, name)
				if found then return found end
			end
			return nil
		end
		local carried = type.fields and type.fields[name]
		if carried then return carried end

		local metatable = type.metatable
		if not metatable then return nil end
		local index = metatable.fields and metatable.fields.__index
		if index == nil then
			type = metatable
		elseif types.isFn(index) then
			return index.returns
		else
			type = index
		end
		depth = depth + 1
	end
	return nil
end

--- The metamethod an operator runs for these operands, when either side declares one. Lua asks the
--- first operand first, then the second.
---@param op string
---@param left lye.doc.Type
---@param right lye.doc.Type
function types.metamethodFor(op, left, right)
	local name = METAMETHODS[op]
	if not name then return nil end
	local found = types.metamethod(left, name) or types.metamethod(right, name)
	if found and types.isFn(found) then return found end
	return nil
end

--- Indexing a table gives its field, an array its element. Anything else is unknown, and a
--- field lookup on a union is the union of that field across the members that have it.
---@param target lye.doc.Type
---@param field string?
---@return lye.doc.Type
function types.indexResult(target, field)
	if target.variant == "unknown" or target.variant == "any" then return types.mutable() end
	if target.variant == "object" and field then
		return types.fieldOf(target, field) or types.NIL_TYPE
	end
	-- A key that is not a name, as `list[i]` writes one, is what an index signature describes.
	if target.variant == "object" and target.indexed and not field then
		return target.indexed.type
	end
	-- A class may declare what indexing it gives: `ffi.array<T>` and `ffi.ptr<T>` both do, which is
	-- what makes `a[1]` the element rather than nothing at all.
	if target.variant == "class" and not field and target.indexed then
		return target.indexed.type
	end
	if target.variant == "class" and field then
		-- A field a class does not declare is unknown rather than nil: the class is built at
		-- runtime and a method may have added it. A metatable may say where to read it instead.
		local found = types.fieldOf(target, field)
		if found then return found end
		return types.mutable()
	end
	if target.variant == "array" then return target.type end
	if target.variant == "string" then return types.STRING end
	if target.variant == "union" then
		local parts = {}
		for _, member in ipairs(target.types) do
			parts[#parts + 1] = types.indexResult(member, field)
		end
		return types.union(parts)
	end
	return types.mutable()
end

--- Where a text splits at the separators that are not inside brackets. The pieces are the text
--- between them, so they are strings however the text they came from is spelled.
---@param text string
---@param separator integer the byte to split at
---@return string[]
local function splitTopLevel(text, separator)
	local parts, depth, from = {}, 0, 1
	for at = 1, #text do
		local byte = text:byte(at)
		if byte == 40 or byte == 123 or byte == 60 then
			depth += 1
		elseif byte == 41 or byte == 125 or byte == 62 then
			-- `->` carries a `>`, so the depth never goes below the text it was read from.
			if depth > 0 then depth -= 1 end
		elseif byte == separator and depth == 0 then
			parts[#parts + 1] = text:sub(from, at - 1)
			from = at + 1
		end
	end
	parts[#parts + 1] = text:sub(from)
	return parts
end

--- Split a parameter list on the commas that are not inside a nested shape.
---@param text string
local function splitParams(text)
	return splitTopLevel(text, 44)
end

types.splitAt = splitTopLevel

--- Characters a space may precede inside a type: a marker that continues it, rather than the
--- description a writer put after it. A closing bracket is not one: `string[] the names it takes`
--- is a type and a description, and `)` and `]` here made the whole sentence part of the type.
local CONTINUES = {
	["-"] = true, [":"] = true, ["|"] = true, [","] = true,
	["<"] = true, ["["] = true, ["{"] = true,
}

--- Where the type ends in annotation text. A space inside `<...>`, `{...}` or `(...)` is part of
--- the type, and so is one before a marker that continues it; anywhere else a description
--- follows, as in `---@param y integer y`. Without this the prose becomes a type nothing knows,
--- which then disagrees with every argument.
---@param text string
---@return integer? stop
local function typeEnd(text)
	local depth = 0
	for at = 1, #text do
		local char = text:sub(at, at)
		-- A `--` is never part of a type, wherever it appears: what follows one is prose. The two hyphens
		-- otherwise read as the arrow of a signature, and the sentence's first words became the type.
		if char == "-" and text:sub(at + 1, at + 1) == "-" and depth == 0 then return at - 1 end
		if char == "<" or char == "{" or char == "(" or char == "[" then
			depth += 1
		elseif char == ">" or char == "}" or char == ")" or char == "]" then
			depth -= 1
		elseif char == " " and depth == 0 then
			-- A marker on either side of the space keeps the type going: `fun(a): string` has one
			-- after the colon, `nil | string` one before the bar.
			local after = text:sub(at + 1):match("^(%S)")
			local before = text:sub(at - 1, at - 1)
			if not (CONTINUES[before] or (after and CONTINUES[after])) then return at - 1 end
		end
	end
end

--- The values a multi-value type text names, split where the commas are not inside brackets.
--- `integer, V` is two values; `fun(a: number, b: string) -> nil` is one. Only the type itself is
--- read: a description after it may hold a comma of its own — `---@return string? kind "number" or
--- "string"` is one value — and splitting the sentence made a value named `or`.
---@param text string
function types.splitValues(text)
	local stop = typeEnd(text)
	return splitTopLevel(stop and text:sub(1, stop) or text, 44)
end

--- The names a signature declares for itself, and what each is limited to: `T, U: number`.
---@param text string the text between the angle brackets
---@return table<string, boolean> names
---@return table<string, string> constraints
local function readGenericNames(text)
	local names, constraints = {}, {}
	local depth, from = 0, 1
	for index = 1, #text + 1 do
		local char = text:sub(index, index)
		if char == "<" or char == "{" or char == "(" then
			depth += 1
		elseif char == ">" or char == "}" or char == ")" then
			depth -= 1
		elseif (char == "," or char == "") and depth == 0 then
			local part = (text:sub(from, index - 1):gsub("^%s+", ""):gsub("%s+$", ""))
			local colon = part:find(":", 1, true)
			if colon then
				constraints[(part:sub(1, colon - 1):gsub("%s+$", ""))] = (part:sub(colon + 1):gsub("^%s+", ""))
				part = (part:sub(1, colon - 1):gsub("%s+$", ""))
			end
			if part ~= "" then names[part] = true end
			from = index + 1
		end
	end
	return names, constraints
end

--- Where a signature's parameter list is. `fn(` or the `fun(` spelling; `f?un` would read as "un"
--- or "fun", which is neither. A signature may declare parameters of its own — `fn<T>(x: T) -> T` —
--- which are bound where the function is called, the way a declaration's `---@generic` names are,
--- and they are read on the way because they sit before the list rather than in it.
---@param text string
---@return integer? closeAt
---@return string? declared the names between the angle brackets, when it declares any
local function fnParams(text)
	local head = text:match("^fu?n%s*%(")
	local declared
	if not head then
		local from = text:find("<", 1, true)
		local openAt = text:match("^fu?n%s*<") and from or nil
		local closeAt, depth
		if openAt then
			depth = 0
			for index = openAt, #text do
				local char = text:sub(index, index)
				if char == "<" then
					depth += 1
				elseif char == ">" then
					depth -= 1
					if depth == 0 then
						closeAt = index
						break
					end
				end
			end
		end
		if not openAt or not closeAt or not text:sub(closeAt + 1):match("^%s*%(") then return nil end
		declared = text:sub(openAt + 1, closeAt - 1)
	end

	-- The parameter list ends at its own closing parenthesis: a parameter's type can be a
	-- signature itself, so parens nest.
	local openAt = text:find("(", 1, true)
	local depth, closeAt = 0, nil
	for index = openAt, #text do
		local char = text:sub(index, index)
		if char == "(" then
			depth += 1
		elseif char == ")" then
			depth -= 1
			if depth == 0 then
				closeAt = index
				break
			end
		end
	end
	if not closeAt then return nil end
	return openAt, closeAt, declared
end

--- Whether a written type is a signature with a return of its own. A `?` at the end of one belongs
--- to that return — `fun(x): T?` hands back an optional `T` — while the `?` of `fun(x)?` is the
--- function that may be absent. Read inside a parameter list the two are one character apart, and
--- taking the wrong one made a callback's return optional instead of what it returns.
---@param text string
local function hasReturn(text)
	local openAt, closeAt = fnParams(text)
	local tail = closeAt and text:sub(closeAt + 1) or ""
	return openAt ~= nil and (tail:match("^%s*[-:]?>") ~= nil or tail:match("^%s*:") ~= nil)
end

--- `fn(a: number, b: string) -> boolean`, and the `fun(a): boolean` spelling LuaLS uses.
--- A parameter may be named or not, may be optional, and `...` stands for the rest.
---@param text string
---@param resolve fun(text: string): lye.doc.Type? a class or alias, where the annotations declare one
local function parseFn(text, resolve)
	local openAt, closeAt, declared = fnParams(text)
	if not openAt then return nil end

	local returns = types.ANY_TYPE
	local rest = text:sub(closeAt + 1):gsub("^%s*", "")
	local returned = rest:match("^[-:]?>%s*(.*)$") or rest:match("^:%s*(.*)$")
	if returned and returned ~= "" then
		-- Several values are written `integer, V`. A signature carries one, so the first is read
		-- and the rest are dropped rather than glued into one name that means nothing. A `...`
		-- return says several values of no particular type, which is `any`.
		local first = types.splitValues(returned)[1]
		if first ~= "..." then returns = types.parse(first, resolve) or types.ANY_TYPE end
	end

	local params, isVariadic = {}, false
	for _, part in ipairs(splitParams(text:sub(openAt + 1, closeAt - 1))) do
		local one = part:gsub("^%s+", ""):gsub("%s+$", "")
		if one == "..." or one:match("^%.%.%.[%s:]*") then
			isVariadic = true
		elseif one ~= "" then
			-- `name: type` names the parameter; a bare type is the type itself. Either the
			-- name or the type may carry the `?` that makes it optional, and on a signature it is
			-- the return that carries it.
			local _, marker, named = one:match("^([%w_]+)(%??)%s*:%s*(.*)$")
			local typeText = named or one
			local hasMarker = typeText:sub(-1) == "?" and not hasReturn(typeText)
			if hasMarker then typeText = typeText:sub(1, -2) end
			local optional = marker == "?" or hasMarker
			local paramType = types.parse(typeText, resolve) or types.UNKNOWN_TYPE
			if optional then paramType = types.union({ paramType, types.NIL_TYPE }) end
			params[#params + 1] = paramType
		end
	end
	local signature = types.fn(params, returns, isVariadic)
	if declared then
		signature.generics, signature.constraints = readGenericNames(declared)
	end
	return signature
end

--- Write a string value the way an annotation would, choosing quotes the text does not use.
---@param text string
local function quoted(text)
	if text:find('"', 1, true) and not text:find("'", 1, true) then return "'" .. text .. "'" end
	return '"' .. (text:gsub('"', '\\"')) .. '"'
end

--- An expression of literals, worked out the way the engine would: `5 + 2` is 7, `"a" .. "b"` is
--- `"ab"`, and `#"abc"` is 3. Nil when anything else appears — a name still unbound, a suffix the
--- engine would make a cdata of, a description after the type — because a type that cannot be
--- worked out is left as the expression that was written.
---@param text string
local function foldExpression(text)
	local rest = (text:gsub("^%s+", ""):gsub("%s+$", ""))

	---@return number|string? value
	local function operand()
		local number = rest:match("^%-?%d[%d%.]*")
		if number then
			rest = rest:sub(#number + 1)
			return "number", tonumber(number)
		end
		local quote = rest:sub(1, 1)
		if quote == '"' or quote == "'" then
			local closeAt = rest:find(quote, 2, true)
			if not closeAt then return nil end
			local inner = rest:sub(2, closeAt - 1)
			rest = rest:sub(closeAt + 1)
			return "string", inner
		end
	end

	-- `#"abc"` is how many bytes the string is, which is a number like any other.
	local length = rest:match("^#%s*(.*)$")
	if length then
		rest = length
		local kind, value = operand()
		if kind == "string" and rest:match("^%s*$") then return "number", #value end
		return nil
	end

	local kind, value = operand()
	if not kind then return nil end
	while true do
		local op, remaining = rest:match("^%s*(%.%.)%s*(.*)$")
		if not op then op, remaining = rest:match("^%s*([%+%-%*/%%%^])%s*(.*)$") end
		if not op then break end
		rest = remaining
		local rightKind, rightValue = operand()
		if not rightKind then return nil end
		if op == ".." then
			-- The engine writes a number out as its own text, so `1 .. 2` is "12".
			local left = kind == "number" and tostring(value) or value
			local right = rightKind == "number" and tostring(rightValue) or rightValue
			kind, value = "string", left .. right
		else
			if kind ~= "number" or rightKind ~= "number" or not ARITHMETIC_RESULT[op] then return nil end
			local ok, folded = pcall(ARITHMETIC_RESULT[op], value, rightValue)
			if not ok or type(folded) ~= "number" then return nil end
			kind, value = "number", folded
		end
	end
	if not rest:match("^%s*$") then return nil end
	return kind, value
end

--- Replace the type variables a signature declares with what a call bound them to. A name bound
--- to nothing is left as it was, so an unbound `T` reads as the variable it is rather than as a
--- type nobody declared.
---@param type lye.doc.Type
---@param bindings table<string, lye.doc.Type>
function types.substitute(type, bindings)
	if type.variant == "extern" then return bindings[type.name] or type end
	if type.variant == "fn" then
		local params = {}
		for index, param in ipairs(type.params) do params[index] = types.substitute(param, bindings) end
		local out = types.fn(params, types.substitute(type.returns, bindings), type.isVariadic, type.isSpread)
		out.generics, out.constraints = type.generics, type.constraints
		-- A generic call substitutes into every value it gives back, not only the first: reading
		-- `---@return T...` through a binding otherwise lost that it was a spread at all.
		if type.values then
			local values = {}
			for index, value in ipairs(type.values) do
				values[index] = types.substitute(value, bindings)
			end
			out.values = values
		end
		return out
	end
	if type.variant == "array" then return types.array(types.substitute(type.type, bindings)) end
	if type.variant == "union" then
		local members = {}
		for index, member in ipairs(type.types) do
			members[index] = types.substitute(member, bindings)
		end
		return types.union(members)
	end
	if type.variant == "object" then
		local fields = {}
		for name, field in pairs(type.fields) do fields[name] = types.substitute(field, bindings) end
		local indexed = type.indexed
			and { key = type.indexed.key, type = types.substitute(type.indexed.type, bindings) }
		local out = types.object(fields, indexed)
		out.metatable = type.metatable
		return out
	end
	return type
end

--- A string written out in an annotation or in code, quoted the way the annotation language
--- writes one: the value of a literal, so `"a" .. "b"` and `"ab"` are the same string.
---@param text string the text of the string, without quotes
function types.stringValue(text)
	return types.extern(quoted(text))
end

--- An expression folded back into the text an annotation would write, or nil when it cannot be
--- worked out. Substituting a folded argument keeps its value: `B * 2` with `B` given `3 + 4` is
--- 14 rather than `3 + 4 * 2`, which is 11.
---@param text string
function types.foldToText(text)
	local kind, value = foldExpression(text)
	if kind == "number" and type(value) == "number" then return tostring(value) end
	if kind == "string" and type(value) == "string" then return quoted(value) end
	return nil
end

--- What kind of value a type text is, when it is one: a number, a quoted string or a boolean, with
--- an expression of literals folded first, so `5 + 2` is a number and `"a" .. "b"` a string.
---@param text string
function types.literalKind(text)
	local trimmed = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed == "true" or trimmed == "false" then return "boolean" end
	local kind = foldExpression(trimmed)
	if kind then return kind end
	if trimmed:sub(1, 1) == '"' or trimmed:sub(1, 1) == "'" then return "string" end
	return nil
end

function types.parse(text, resolve)
	local trimmed = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed == "" then return nil end

	-- A signature is read before the bar and the marker that may follow its return, because both
	-- follow the *return type* and belong to it: `fun(): T?` returns a `T?` rather than being a
	-- function that may be absent. `fun()?` writes no return at all, so that stays the optional function.
	local shaped = trimmed:sub(1, 6) == "async " and trimmed:sub(7) or trimmed
	local stop = typeEnd(shaped)
	if stop then shaped = (shaped:sub(1, stop):gsub("%s+$", "")) end
	if hasReturn(shaped) then
		local signature = parseFn(shaped, resolve)
		if signature then return signature end
	end

	-- A union is split before anything else the text may carry, so `nil|string[]` is nil or a
	-- list of strings rather than a list of `nil|string`, and a description or a marker inside
	-- one member belongs to that member alone. Each is read on its own from here.
	local members = splitTopLevel(trimmed, 124)
	if #members > 1 then
		local parsed = {}
		for _, member in ipairs(members) do
			local one = types.parse(member, resolve)
			if one then parsed[#parsed + 1] = one end
		end
		return #parsed > 0 and types.union(parsed) or nil
	end

	-- `async` marks a function that may yield. It says nothing about the type, so the definition
	-- reads the same as the callable it stands for: `async fun(...):...` is a function.
	if trimmed:sub(1, 6) == "async " then return types.parse(trimmed:sub(7), resolve) end

	-- A member written in parentheses is the type it encloses: `(async fun(...):...)|integer` is
	-- how the definitions group one, and the parentheses are grammar rather than a type of their own.
	if trimmed:sub(1, 1) == "(" then
		local depth = 0
		for index = 1, #trimmed do
			local char = trimmed:sub(index, index)
			if char == "(" then
				depth += 1
			elseif char == ")" then
				depth -= 1
				if depth == 0 then
					if index == #trimmed then return types.parse(trimmed:sub(2, -2), resolve) end
					break
				end
			end
		end
	end

	-- Arithmetic written in a type: a const parameter substituted with what it was given leaves `5 + 2`
	-- behind, and the type says what that is. A name still unbound leaves the expression alone.
	local kind, value = foldExpression(trimmed)
	if kind == "number" and type(value) == "number" then return types.numberValue(value) end
	if kind == "string" and type(value) == "string" then return types.extern(quoted(value)) end

	-- Annotations often carry a description after the type. Everything past where the type ends
	-- is prose, and reading it as part of the type would make the annotation mean nothing.
	local stop = typeEnd(trimmed)
	if stop then trimmed = (trimmed:sub(1, stop):gsub("%s+$", "")) end

	if trimmed:sub(-1) == "?" then
		-- An annotation says what may arrive, so an optional type is the union of the two: a name
		-- nothing is known about stays unknown rather than collapsing to nil.
		local inner = types.parse(trimmed:sub(1, -2), resolve)
		return inner and types.union({ inner, types.NIL_TYPE }) or nil
	end
	if trimmed:sub(-2) == "[]" then
		local inner = types.parse(trimmed:sub(1, -3), resolve)
		return inner and types.array(inner) or nil
	end

	if trimmed:sub(1, 6) == "table<" and trimmed:sub(-1) == ">" then
		-- `table<K, V>` is how the definitions write a map of keys to values. It is a table whose
		-- index signature holds V, so `t[k]` is a V and the value still fits a `table` parameter.
		local parts = splitTopLevel(trimmed:sub(7, -2), 44)
		return types.object({}, {
			key = parts[1] or "any",
			type = types.parse(parts[2], resolve) or types.UNKNOWN_TYPE,
		})
	end

	if trimmed:sub(1, 1) == "{" and trimmed:sub(-1) == "}" then
		local fields, indexed = {}, nil
		-- Split at the commas that separate fields, not at every comma there is: a field whose type
		-- is `table<string, number>` carries one of its own, and cutting there leaves two fields —
		-- `fields: table<string` and `number>` — which is a shape nothing can use.
		for _, field in ipairs(splitTopLevel(trimmed:sub(2, -2), 44)) do
			-- `[integer]: T` is an index signature: every key of that kind holds T, which is how
			-- a list is written. It is the only thing that makes a generic element reachable.
			local key, value = field:match("^%s*%[%s*([%w_]+)%s*%]%s*:?%s*(.*)$")
			if key then
				indexed = { key = key, type = types.parse(value, resolve) or types.UNKNOWN_TYPE }
			else
				local name, held = field:match("^%s*([%w_]+)%s*:?%s*(.*)$")
				if name then fields[name] = types.parse(held, resolve) or types.UNKNOWN_TYPE end
			end
		end
		return types.object(fields, indexed)
	end

	-- A number written in a type is that number: `---@type 2149 | 231 | 26` lists the values a
	-- variable may hold, and `---@type 1` is one of them rather than the whole of `number`.
	local number = trimmed:match("^%-?%d[%d%.]*$") or trimmed:match("^0[xX]%x+$")
	local value = number and tonumber(trimmed)
	if value then return types.numberValue(value, trimmed) end

	-- `true` and `false` written in a type are those values, so a member of a union can be told
	-- from another by what its discriminant holds.
	if trimmed == "true" then return types.booleanValue(true) end
	if trimmed == "false" then return types.booleanValue(false) end

	-- The standard library's annotations say `integer`; there is one numeric type here.
	if trimmed == "integer" then return types.base("number") end
	if trimmed == "never" then return types.NEVER end
	if SIMPLE[trimmed] then return types.base(trimmed) end
	if trimmed == "table" then return types.TABLE end
	if trimmed == "function" then return types.FUNCTION end

	local parsedFn = parseFn(trimmed, resolve)
	if parsedFn then return parsedFn end
	if resolve then
		local declared = resolve(trimmed)
		if declared then return declared end
	end
	return types.extern(trimmed)
end

--- The types being written out right now. A type may contain itself, and a value can only be
--- printed by printing what it holds, so the walk stops where it came in — a class already
--- being written is printed as its name.
local displaying = {}

---@param type lye.doc.Type
---@return string
function types.display(type)
	if displaying[type] then
		return type.variant == "class" and type.name or type.variant
	end
	displaying[type] = true
	local shown = types.displayOf(type)
	displaying[type] = nil
	return shown
end

---@param type lye.doc.Type
---@return string
function types.displayOf(type)
	if type.variant == "class" then
		if #type.args == 0 then return type.name end
		local parts = {}
		for _, arg in ipairs(type.args) do parts[#parts + 1] = types.display(arg) end
		return type.name .. "<" .. table.concat(parts, ", ") .. ">"
	end
	if type.variant == "boolean" and type.value ~= nil then return tostring(type.value) end
	if type.variant == "number" and type.text then return type.text end
	if type.variant == "fn" then
		if types.isAnyFn(type) then return "function" end
		local parts = {}
		for _, param in ipairs(type.params or {}) do parts[#parts + 1] = types.display(param) end
		if type.isVariadic then parts[#parts + 1] = "..." end
		-- Every value it gives back, not only the first: a caller writing `local a, b = find(x)`
		-- takes both, and a signature that named one of them was the shape of the bug.
		if type.values and #type.values > 1 and not type.isSpread then
			local values = {}
			for _, value in ipairs(type.values) do values[#values + 1] = types.display(value) end
			return string.format("fn(%s) -> %s", table.concat(parts, ", "), table.concat(values, ", "))
		end
		local spread = type.isSpread and "..." or ""
		-- A function that returns nothing has no result to write down, so the arrow goes too.
		if type.returns == types.VOID then
			return "fn(" .. table.concat(parts, ", ") .. ")" .. spread
		end
		return "fn(" .. table.concat(parts, ", ") .. ") -> " .. types.display(type.returns) .. spread
	end
	if type.variant == "array" then
		-- A union and a signature need their own brackets, or `(number|string)[]` reads as
		-- `number|string[]` and `(fn() -> number)[]` reads as a function that returns a list.
		local inner = types.display(type.type)
		if type.type.variant == "union" or type.type.variant == "fn" then inner = "(" .. inner .. ")" end
		return inner .. "[]"
	end
	if type.variant == "object" then
		local parts = {}
		for name, field in pairs(type.fields) do
			parts[#parts + 1] = name .. ": " .. types.display(field)
		end
		if type.indexed then
			parts[#parts + 1] = "[" .. type.indexed.key .. "]: " .. types.display(type.indexed.type)
		end
		-- A table whose shape is not known *yet* is a table, not an empty one: `local t = {}` reads
		-- as `table` until something gives it a field, which is what a reader expects to see.
		if #parts == 0 and not type.metatable then return "table" end
		-- A table that is only what it holds at a key reads the way an annotation writes one:
		-- `string[]` for a list, `table<string, true>` for a set built by marking keys.
		if next(type.fields) == nil and type.indexed and not type.metatable then
			if type.indexed.key == "integer" or type.indexed.key == "number" then
				return types.display(type.indexed.type) .. "[]"
			end
			return "table<" .. type.indexed.key .. ", " .. types.display(type.indexed.type) .. ">"
		end
		table.sort(parts)
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	if type.variant == "union" then
		-- Sorted so two unions of the same members compare equal as strings.
		local parts = {}
		for _, member in ipairs(type.types) do parts[#parts + 1] = types.display(member) end
		table.sort(parts)
		-- `nil` and one other member is the `T?` the annotations already write, and reading it back
		-- as one is what a writer expects to see. Three members stay written out: `string|number?`
		-- reads as though the optional part were the number, and `(string|number)?` is worse.
		if #parts == 2 then
			local other, hasNil = nil, false
			for _, part in ipairs(parts) do
				if part == "nil" then hasNil = true else other = part end
			end
			-- A signature is bracketed first, because `fn() -> number?` reads as a function that
			-- returns a number — a different type from one that may be absent — while
			-- `(fn() -> number)?` is exactly the two things this union holds.
			if hasNil and other then
				if other:sub(1, 2) == "fn" then return "(" .. other .. ")?" end
				return other .. "?"
			end
		end
		return table.concat(parts, "|")
	end
	if type.variant == "extern" then return type.name end
	return type.variant
end

--- A message for a mismatch, or nil when the value fits.
---@param declared lye.doc.Type
---@param actual lye.doc.Type
---@param name string
function types.mismatch(declared, actual, name)
	if types.satisfies(actual, declared) then return nil end
	return string.format("%s is declared as %s but is assigned %s", name, types.display(declared), types.display(actual))
end

return types
