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
---| { variant: "fn", params: lye.doc.Type[], returns: lye.doc.Type, isVariadic: boolean?, variadic: lye.doc.Type?, values: lye.doc.Type[]?, overloads: lye.doc.Type[]?, generics: table<string, boolean>?, constraints: table<string, string>?, isMethod: boolean?, isSpread: boolean? }
---| { variant: "any" }
---| { variant: "unknown" }
---| { variant: "extern", name: string }
---| { variant: "array", type: lye.doc.Type }
---| { variant: "object", fields: table<string, lye.doc.Type> }
---| { variant: "union", types: lye.doc.Type[] }
---| { variant: "intersection", types: lye.doc.Type[] }
---| { variant: "keyof", type: lye.doc.Type }
---| { variant: "indexed", object: lye.doc.Type, key: lye.doc.Type }
---| { variant: "conditional", check: lye.doc.Type, extends: lye.doc.Type, thenType: lye.doc.Type, elseType: lye.doc.Type }
---| { variant: "mapped", key: string, source: lye.doc.Type, value: lye.doc.Type }
---| { variant: "template", parts: (string|lye.doc.Type)[] }
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
---@param fields table? the fields the type carries, which become the type itself
---@return lye.doc.Type
local function make(variant, fields)
	-- The caller's table *is* the type: every call site writes a fresh literal, and copying it
	-- into a second table was an allocation and a walk per type. It also kept this loop from
	-- compiling, and types are made more than anything else in a document.
	if fields then
		fields.variant = variant
		return fields
	end
	return { variant = variant }
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

---@param name string
---@return lye.doc.Type
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
--- The name a value's fields are found under, which is what says whether a field is a function of
--- the standard library: a string reads `string`'s fields, and a class is its own name. A value
--- that may be absent still names what it is where it is one — which is the case a `?.` is written
--- for — so a union answers with the first of its members that names something.
---@param held lye.doc.Type?
---@return string?
function types.ownerOf(held)
	if not held then return nil end
	if held.variant == "union" then
		for _, member in ipairs(held.types) do
			local owner = types.ownerOf(member)
			if owner then return owner end
		end
		return nil
	end
	if held.variant == "class" then return held.name end
	if held.variant == "string" then return "string" end
	-- A value written as a string literal is a string: `("a b"):gsub("%s+", "-")` reads `string`'s
	-- fields the same way a variable holding one does, and the literal is not a class to be named.
	if held.variant == "extern" and held.name and held.name:match("^[\"']") then return "string" end
end

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
---@param variadic lye.doc.Type? what the extra arguments have to be, from `---@param ... string`
function types.fn(params, returns, isVariadic, isSpread, variadic)
	return make("fn", {
		params = params, returns = returns, isVariadic = isVariadic, isSpread = isSpread,
		variadic = variadic,
	})
end

---@param type lye.doc.Type
---@return type is fn
function types.isFn(type)
	return type.variant == "fn"
end

--- The permissive callable, the one a `function` literal has until something says otherwise.
---@param type lye.doc.Type
---@return type is fn
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

--- What an unknown may be once a condition has ruled some possibilities out. `unknown` is the
--- union of every type, but unlike `any` it narrows: the branch that knows a value is not nil
--- holds one of the other shapes, and a reader can act on that. The set is deliberately coarse —
--- it names the families a Lua value belongs to, not every class that exists.
local truthyUnknown, nonNilUnknown, unknownSetsBuilt
local function buildUnknownSets()
	if unknownSetsBuilt then return end
	unknownSetsBuilt = true
	truthyUnknown = types.union({
		types.NUMBER, types.STRING, types.TABLE, types.FUNCTION, types.booleanValue(true),
	})
	nonNilUnknown = types.union({
		types.NUMBER, types.STRING, types.BOOLEAN, types.TABLE, types.FUNCTION,
	})
end

---@return lye.doc.Type
function types.truthyUnknown()
	buildUnknownSets()
	return truthyUnknown
end

---@return lye.doc.Type
function types.nonNilUnknown()
	buildUnknownSets()
	return nonNilUnknown
end

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

--- The base type a literal is a value of, when it is one. A number or boolean literal carries its
--- value; a string literal is the quoted extern the parser builds. A literal is already a member of
--- its base type, so a union naming both says no more than the base.
---@param held lye.doc.Type
---@return lye.doc.Type? base
local function baseOfLiteral(held)
	if held.variant == "number" and held.value ~= nil then return types.NUMBER end
	if held.variant == "boolean" and held.value ~= nil then return types.BOOLEAN end
	if held.variant == "extern" and type(held.name) == "string" then
		local first, last = held.name:sub(1, 1), held.name:sub(-1)
		if (first == '"' or first == "'") and last == first then return types.STRING end
	end
end

--- Whether `held` is the base type a literal belongs to. Compared by shape rather than identity:
--- `number` parsed from text and the `types.NUMBER` singleton answer the same question.
---@param held lye.doc.Type
---@param base lye.doc.Type
---@return boolean
local function isLiteralBase(held, base)
	if base == types.NUMBER then return held.variant == "number" and held.value == nil end
	if base == types.BOOLEAN then return held.variant == "boolean" and held.value == nil end
	if base == types.STRING then return held.variant == "string" end
	return false
end

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
		-- A named union is a type in its own right: `lye.doc.Type?` has to stay a name beside
		-- nil, rather than expanding the alias body into this union and losing what it is called.
		if member.variant == "union" and not member.aliasName then
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

	-- A literal is a value of its base type, so a union that names both is the base:
	-- `20261024 | number` is number, `true | boolean` is boolean, `"s" | string` is string. Only the
	-- base absorbs a literal; literals alone keep their exact values, which is what a discriminant
	-- needs. This cannot be a general subtype sweep: a string intentionally satisfies a string
	-- literal, so `satisfies` would let the literal absorb the base in the other direction.
	local absorbed = {}
	for index, member in ipairs(flat) do
		local base = baseOfLiteral(member)
		if base then
			for otherIndex, other in ipairs(flat) do
				if otherIndex ~= index and isLiteralBase(other, base) then
					absorbed[index] = true
					break
				end
			end
		end
	end
	if next(absorbed) then
		local kept = {}
		for index, member in ipairs(flat) do
			if not absorbed[index] then kept[#kept + 1] = member end
		end
		flat = kept
	end

	if #flat == 1 then return flat[1] end
	return make("union", { types = flat })
end

--- Flatten an intersection, dropping the names that constrain nothing: `unknown & T` is T,
--- while `any & T` is any because `any` names every operation already. `never` absorbs everything.
---@param members lye.doc.Type[]
---@return lye.doc.Type
function types.intersection(members)
	local flat, seen = {}, {}
	local function add(member)
		if member.variant == "intersection" then
			for _, inner in ipairs(member.types) do add(inner) end
			return
		end
		if member.variant == "never" then
			flat = { member }
			return
		end
		if member.variant == "unknown" then return end
		if member.variant == "any" then flat = { member } return end
		local key = types.display(member)
		if not seen[key] then
			seen[key] = true
			flat[#flat + 1] = member
		end
	end
	for _, member in ipairs(members) do add(member) end
	if #flat == 0 then return types.UNKNOWN_TYPE end
	if #flat == 1 then return flat[1] end
	return make("intersection", { types = flat })
end

--- Whether a type still contains a name nothing has resolved: a generic variable, or a name a
--- file did not declare. A conditional or a mapped shape waits for that name.
---@param type lye.doc.Type?
---@return boolean
function types.isSymbolic(type)
	if not type then return true end
	if type.variant == "extern" then
		-- A quoted name is a string literal, not a name to resolve: `"a" | "b"` is a known set.
		local first, last = type.name:sub(1, 1), type.name:sub(-1)
		return not ((first == '"' or first == "'") and last == first)
	end
	if type.variant == "union" or type.variant == "intersection" then
		for _, member in ipairs(type.types) do
			if types.isSymbolic(member) then return true end
		end
		return false
	end
	if type.variant == "array" then return types.isSymbolic(type.type) end
	if type.variant == "keyof" then return types.isSymbolic(type.type) end
	if type.variant == "indexed" then return types.isSymbolic(type.object) or types.isSymbolic(type.key) end
	if type.variant == "conditional" then
		return types.isSymbolic(type.check) or types.isSymbolic(type.extends)
	end
	if type.variant == "mapped" then return types.isSymbolic(type.source) end
	return false
end

--- The keys of a value, as the union of the names it holds. An unresolved name keeps the
--- operation for the substitution that gives it a class.
---@param type lye.doc.Type
---@return lye.doc.Type
function types.keyof(type)
	if type.variant == "union" then
		local members = {}
		for index, member in ipairs(type.types) do members[index] = types.keyof(member) end
		return types.union(members)
	end
	if type.variant == "object" or type.variant == "class" then
		local keys = {}
		for name in pairs(type.fields or {}) do keys[#keys + 1] = types.stringValue(name) end
		if type.indexed and type.indexed.key == "string" then
			keys[#keys + 1] = types.STRING
		end
		return types.union(keys)
	end
	if type.variant == "array" then return types.NUMBER end
	if type.variant == "string" then return types.NUMBER end
	return make("keyof", { type = type })
end

--- The value a type holds at a key. A quoted key is a field name, a union of keys indexes each
--- member, and a `keyof` names every value the object holds. An unresolved key keeps the
--- operation, the way `keyof` does.
---@param object lye.doc.Type
---@param key lye.doc.Type
---@return lye.doc.Type
function types.indexedAccess(object, key)
	if key.variant == "union" then
		local members = {}
		for index, member in ipairs(key.types) do
			members[index] = types.indexedAccess(object, member)
		end
		return types.union(members)
	end
	local name
	if key.variant == "extern" and type(key.name) == "string" then
		local first, last = key.name:sub(1, 1), key.name:sub(-1)
		if (first == '"' or first == "'") and last == first then name = key.name:sub(2, -2) end
	end
	if name then return types.indexResult(object, name) end
	if key.variant == "keyof" then
		local values = {}
		for _, member in ipairs((object.variant == "union" and object.types) or { object }) do
			if member.variant == "object" or member.variant == "class" then
				for _, field in pairs(member.fields or {}) do values[#values + 1] = field end
			elseif member.variant == "array" then
				values[#values + 1] = member.type
			end
		end
		return types.union(values)
	end
	return make("indexed", { object = object, key = key })
end

--- One mapped shape, expanded when the source's keys are known. A value is parsed with the key
--- variable standing for the key literal, so `{ [K in "a"|"b"]: K }` holds the names.
---@param key string
---@param source lye.doc.Type
---@param value lye.doc.Type
---@return lye.doc.Type
function types.mapped(key, source, value)
	if types.isSymbolic(source) then
		return make("mapped", { key = key, source = source, value = value })
	end
	local fields = {}
	local keys = source.variant == "union" and source.types or { source }
	for _, one in ipairs(keys) do
		if one.variant == "extern" then
			local first, last = one.name:sub(1, 1), one.name:sub(-1)
			if (first == '"' or first == "'") and last == first then
				local name = one.name:sub(2, -2)
				fields[name] = types.substitute(value, { [key] = one })
			end
		elseif one.variant == "string" then
			-- A string index signature maps every name; a shape cannot spell them, so the mapped
			-- type stays open with that value under a string key.
			return types.object({}, { key = "string", type = value })
		end
	end
	return types.object(fields)
end

--- A template literal type: the static text around its substitutions, or the string it spells
--- when every part is known. It is a string either way; a template that names a generic stays a
--- template until the substitution arrives.
---@param parts (string|lye.doc.Type)[]
---@return lye.doc.Type
function types.template(parts)
	local text, symbolic = "", false
	for _, part in ipairs(parts) do
		if _G.type(part) == "string" then
			text = text .. part
		elseif part.variant == "number" and part.value ~= nil then
			text = text .. tostring(part.value)
		elseif part.variant == "boolean" and part.value ~= nil then
			text = text .. tostring(part.value)
		elseif part.variant == "extern" and part.name then
			local first, last = part.name:sub(1, 1), part.name:sub(-1)
			if (first == '"' or first == "'") and last == first then
				text = text .. part.name:sub(2, -2)
			else
				symbolic = true
			end
		else
			symbolic = true
		end
	end
	if not symbolic then return types.stringValue(text) end
	return make("template", { parts = parts })
end

--- A conditional type, evaluated as soon as both sides are known.
---@param check lye.doc.Type
---@param extends lye.doc.Type
---@param thenType lye.doc.Type
---@param elseType lye.doc.Type
---@return lye.doc.Type
function types.conditional(check, extends, thenType, elseType)
	if not types.isSymbolic(check) and not types.isSymbolic(extends) then
		return types.satisfies(check, extends) and thenType or elseType
	end
	return make("conditional", {
		check = check, extends = extends, thenType = thenType, elseType = elseType,
	})
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

--- Whether a value of this type is one of these variants, or a union holding one. This is the
--- question a builtin's fields are read with: a value that may be absent is still a string wherever
--- it is one, so `string?` reads the string library while the nil member contributes nothing.
--- `satisfies` is the wrong question there — it accepts an unknown for every constraint, so asking
--- it made every untyped name a string and read `symbol.len` off the string library.
---@param type lye.doc.Type
---@param variant string
function types.mayBe(type, variant)
	if type.variant == "union" then
		for _, member in ipairs(type.types) do
			if member.variant == variant then return true end
		end
		return false
	end
	return type.variant == variant
end

--- How deep a comparison walks before it stops asking. A type can hold itself — a class with a
--- `---@field target lye.cdef.Type` field is one — and two of those walk each other without end.
local MAX_COMPARE_DEPTH = 64

--- The comparison itself, at a depth. Declared before the wrapper so `methodFits` can walk into it
--- without starting the count over.
---@type fun(type: lye.doc.Type, constraint: lye.doc.Type, depth: integer): boolean
local fits

--- A method written without its receiver fits one written with it, which is how a field declared
--- `fun(self: P, label: string)` and a body declared `function p:set(label)` describe the same
--- callable. The extra parameter has to be what the method is called on, or it is not a receiver.
---@param have lye.doc.Type
---@param wanted lye.doc.Type
---@param owner lye.doc.Type the class the field belongs to
---@param depth integer
---@param seen table<lye.doc.Type, table<lye.doc.Type, boolean>>
---@return boolean
local function methodFits(have, wanted, owner, depth, seen)
	if not types.isFn(have) then return false end
	-- A field written optional is that signature with `nil` beside it, and a body that is a callable
	-- fits it: the member to compare against is the signature, not the union.
	if wanted.variant == "union" then
		for _, member in ipairs(wanted.types) do
			if types.isFn(member) and methodFits(have, member, owner, depth + 1, seen) then return true end
		end
		return false
	end
	if not types.isFn(wanted) then return false end
	if #wanted.params ~= #have.params + 1 then return false end
	if not fits(wanted.params[1], owner, depth + 1, seen) then return false end
	local rest = {}
	for index = 2, #wanted.params do rest[#rest + 1] = wanted.params[index] end
	return fits(have, types.fn(rest, wanted.returns, wanted.isVariadic, wanted.isSpread, wanted.variadic),
		depth + 1, seen)
end

---@param type lye.doc.Type
---@param constraint lye.doc.Type
---@return boolean
function types.satisfies(type, constraint)
	return fits(type, constraint, 0, {})
end

--- The required data fields a class shape asks for and an object literal does not carry. A
--- method is not counted: it comes from the metatable the literal is given, as `setmetatable`
--- does. An empty literal is exactly the case a call has to refuse, where a declaration may be
--- building its table over several statements.
---@param constraint lye.doc.Type
---@param actual lye.doc.Type
---@return string[] missing
function types.missingRequiredFields(constraint, actual)
	local missing = {}
	if constraint.variant ~= "class" or actual.variant ~= "object" then return missing end
	for name, wanted in pairs(constraint.fields or {}) do
		if not types.isFn(wanted) and actual.fields[name] == nil
			and not types.satisfies(types.NIL_TYPE, wanted) then
			missing[#missing + 1] = name
		end
	end
	table.sort(missing)
	return missing
end

---@param candidate table?
local function isCNumber(candidate)
	local name = candidate and candidate.name
	if name == "ffi.cnum" or name == "ffi.cnum*" then return true end
	local parents = candidate and candidate.parents
	if parents then
		for _, parent in ipairs(parents) do
			name = parent.name
			if name == "ffi.cnum" or name == "ffi.cnum*" then return true end
		end
	end
	return false
end

--- The comparison, at a depth: past the cap the same pair is being asked again, and the answer it
--- is being worked out for is what the outer ask returns, so it fits.
---@param type lye.doc.Type
---@param constraint lye.doc.Type
---@param depth integer
---@param seen table<lye.doc.Type, table<lye.doc.Type, boolean>>
---@return boolean
function fits(type, constraint, depth, seen)
	if depth >= MAX_COMPARE_DEPTH then return true end
	-- Two recursive types — a class holding itself, an alias whose body names it — would otherwise
	-- be asked the same pair again and again, branch by branch. A pair already being compared is
	-- assumed to fit the way the depth cap assumes it, which is what makes the walk terminate in
	-- time as well as in depth.
	local compared = seen[type]
	if not compared then
		compared = {}
		seen[type] = compared
	end
	if compared[constraint] then return true end
	compared[constraint] = true
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

	-- An intersection is every one of its members: a value fits it only when it fits each, and a
	-- value that is an intersection fits a constraint when one of its members already does.
	if constraint.variant == "intersection" then
		for _, member in ipairs(constraint.types) do
			if not fits(type, member, depth + 1, seen) then return false end
		end
		return true
	end
	if type.variant == "intersection" then
		for _, member in ipairs(type.types) do
			if fits(member, constraint, depth + 1, seen) then return true end
		end
		return false
	end
	-- The type-level operations. Their answers are strings/keys/values; when a name is still
	-- unresolved the operation is what both sides share, so it is accepted rather than guessed.
	if constraint.variant == "keyof" or type.variant == "keyof" then
		return type.variant == "string" or type.variant == "number" or type.variant == "boolean"
			or type.variant == "union" or type.variant == "keyof"
	end
	if constraint.variant == "indexed" or type.variant == "indexed" then
		local wanted = constraint.variant == "indexed" and constraint or nil
		local have = type.variant == "indexed" and type or nil
		if wanted and have then return fits(wanted.object, have.object, depth + 1, seen) end
		if have then
			local value = types.indexedAccess(have.object, have.key)
			if value.variant ~= "indexed" then return fits(value, constraint, depth + 1, seen) end
		end
		if wanted then
			local value = types.indexedAccess(wanted.object, wanted.key)
			if value.variant ~= "indexed" then return fits(type, value, depth + 1, seen) end
		end
		return true
	end
	if constraint.variant == "conditional" or type.variant == "conditional" then
		local decided = constraint.variant == "conditional" and constraint or type
		if not types.isSymbolic(decided.check) and not types.isSymbolic(decided.extends) then
			local answer = types.satisfies(decided.check, decided.extends)
				and decided.thenType or decided.elseType
			if constraint.variant == "conditional" then return fits(type, answer, depth + 1, seen) end
			return fits(answer, constraint, depth + 1, seen)
		end
		return true
	end
	if constraint.variant == "template" or type.variant == "template" then
		return type.variant == "string" or type.variant == "template"
			or constraint.variant == "string" or constraint.variant == "template"
	end
	-- A union fits only when every member does, and this is asked first: `A|B` fits `A|B`, while
	-- the other order would ask whether one member accepts the whole union.
	if type.variant == "union" then
		for _, member in ipairs(type.types) do
			if not fits(member, constraint, depth + 1, seen) then return false end
		end
		return true
	end

	if constraint.variant == "union" then
		for _, member in ipairs(constraint.types) do
			if fits(type, member, depth + 1, seen) then return true end
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
		-- A table is how a class is built, so a bare `table` fits. An object literal is a shape
		-- that says exactly what it holds: every required field of the class has to be there, or
		-- `f({})` would satisfy any class at all. A class is built in pieces on the table that
		-- declares it, and that is a `table`, not an object literal with no fields.
		if type.variant == "table" then return true end
		if type.variant == "object" then
			if types.isUnknownShape(type) then
				-- `local c = {}` followed by writes is how a class table is built. A literal handed
				-- to a call is checked separately: there is no later write to complete it.
				return true
			end
			for name, wanted in pairs(constraint.fields) do
				local have = type.fields[name]
				if have then
					if not fits(have, wanted, depth + 1, seen)
						and not methodFits(have, wanted, constraint, depth + 1, seen) then return false end
				elseif not types.isFn(wanted) and not fits(types.NIL_TYPE, wanted, depth + 1, seen) then
					-- A method comes from the metatable an instance is built with, not from the
					-- literal that holds its data; a data field has to be written.
					return false
				end
			end
			return true
		end
		-- A class named after a builtin type *is* that type: `builtin.lua` declares
		-- `---@class string`, which is what makes `ffi.new("Vec")` fit the `ffi.cdecl*` extending it.
		if SIMPLE[constraint.name] then
			return fits(type, types.base(constraint.name), depth + 1, seen)
		end
		-- A value that fits what the class extends fits the class: the definitions write
		-- `---@class ffi.cdecl*: string`, and a string is exactly what a parameter of it takes.
		for _, parent in ipairs(constraint.parents or {}) do
			if fits(type, parent, depth + 1, seen) then return true end
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
			if not fits(types.NIL_TYPE, wanted, depth + 1, seen) then
				shaped = false
				break
			end
		end
		if shaped and some then
			for name, wanted in pairs(constraint.fields) do
				local have = type.fields[name]
				if have and not fits(have, wanted, depth + 1, seen) and not methodFits(have, wanted, constraint, depth + 1, seen) then
					return false
				end
			end
			return true
		end
		if type.name ~= constraint.name then
			for _, parent in ipairs(type.parents) do
				if fits(parent, constraint, depth + 1, seen) then return true end
			end
			return false
		end
		for index, wanted in ipairs(constraint.args or {}) do
			local have = type.args[index] or types.UNKNOWN_TYPE
			if not fits(have, wanted, depth + 1, seen) then return false end
		end
		return true
	end

	if constraint.variant == "fn" then
		if type.variant ~= "fn" then return false end
		-- A callable that takes anything accepts any callable, which is what a bare `function`
		-- means and what keeps unannotated literals out of trouble.
		if types.isAnyFn(constraint) then return true end
		-- A variadic constraint asks for a callable that accepts at least what it names, which a
		-- fixed signature does when its own parameters fit. Parameters past the ones a signature
		-- names are discarded by the engine, so a callable with fewer fits — `function() end` is
		-- what a handler that ignores its arguments is written as. A signature that takes *more*
		-- than the constraint hands it has to make each extra one optional: the caller omits it,
		-- and `raise(message, info?)` is a `fun(message: string)`.
		if not type.isVariadic and not constraint.isVariadic and #type.params > #constraint.params then
			for index = #constraint.params + 1, #type.params do
				if not fits(types.NIL_TYPE, type.params[index], depth + 1, seen) then return false end
			end
		end
		for index, wanted in ipairs(constraint.params or {}) do
			local have = type.params[index] or types.UNKNOWN_TYPE
			-- Contravariant: the value has to accept what the constraint will pass it.
			if not fits(wanted, have, depth + 1, seen) then return false end
		end
		return fits(type.returns, constraint.returns, depth + 1, seen)
	end

	if constraint.variant == "array" then
		-- `local names = {}` declares a list before it holds anything, so a table fits.
		if types.isUnknownShape(type) then return true end
		-- A list literal is an object with an integer index, so whichever way the list was written,
		-- the elements are what has to fit.
		if type.variant == "object" and type.indexed
			and (type.indexed.key == "integer" or type.indexed.key == "number") then
			return fits(type.indexed.type, constraint.type, depth + 1, seen)
		end
		if type.variant ~= "array" then return false end
		return fits(type.type, constraint.type, depth + 1, seen)
	end

	if constraint.variant == "object" then
		-- A bare `table` is the `any` of tables: nothing was said about what is in it, so it fits
		-- any shape — a table literal, an empty table, an array, a class. It fits nothing else,
		-- which is the whole difference from `any`.
		if type.variant == "table" then return true end
		-- A list is what `{ [integer]: T }` describes, so an array fits it when its elements do.
		if type.variant == "array" and constraint.indexed then
			return fits(type.type, constraint.indexed.type, depth + 1, seen)
		end
		-- A class is a table as well, and the fields it declares are the ones a shape asks about:
		-- a class is routinely built in pieces, so a field it does not name is not held against it.
		if type.variant == "class" then
			for name, wanted in pairs(constraint.fields) do
				local have = type.fields[name]
				if have and not fits(have, wanted, depth + 1, seen) then return false end
			end
			return true
		end
		if type.variant ~= "object" then return false end
		for name, wanted in pairs(constraint.fields) do
			-- A field the literal leaves out is nil, which is what an optional field accepts:
			-- `---@field weight? number` does not ask the caller to write it down.
			local have = type.fields[name] or types.NIL_TYPE
			if not fits(have, wanted, depth + 1, seen) then return false end
		end
		if constraint.indexed then
			local have = type.indexed and type.indexed.type
			if have then
				if not fits(have, constraint.indexed.type, depth + 1, seen) then return false end
			else
				-- A table of named fields is a map as well: `{ a = 1 }` fits `table<string,
				-- number>` when each value in it does. That is what the literal's fields say.
				for _, field in pairs(type.fields) do
					if not fits(field, constraint.indexed.type, depth + 1, seen) then return false end
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
	if type.variant == "any" then return type end
	if type.variant == "unknown" then
		return wantTruthy and types.truthyUnknown()
			or types.union({ types.NIL_TYPE, types.booleanValue(false) })
	end
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

	local kept, changed = {}, false
	for _, member in ipairs(type.types) do
		-- Each member is narrowed by the same question, so a plain `boolean` in a union becomes the
		-- value the branch holds — `false` on the falsy side — rather than staying a whole boolean
		-- that a later `or` cannot tell apart from its truthy half.
		local one = types.narrowTruthiness(member, wantTruthy)
		if one then
			kept[#kept + 1] = one
			if one ~= member then changed = true end
		else
			changed = true
		end
	end
	if #kept == 0 then return nil end
	if not changed then return type end
	return types.union(kept)
end

--- Keep the members that do, or do not, carry a field. This narrows a discriminated union:
--- testing `x.foo` on `{ foo: number } | { bar: string }` selects the member with `foo`.
---@param type lye.doc.Type
--- Keep only the members that are nil, or only those that are not.
---@param type lye.doc.Type
---@param wantNil boolean
function types.narrowNil(type, wantNil)
	if type.variant == "any" then return type end
	if type.variant == "unknown" then
		return wantNil and types.NIL_TYPE or types.nonNilUnknown()
	end
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
	-- `type(x) == "table"` is exactly the information an unknown or `any` lacks, so the test
	-- replaces it with the type it names instead of letting `satisfies` accept the unknown as-is.
	if type.variant == "any" or type.variant == "unknown" then return wanted end
	if type.variant == "boolean" and type.value == nil and wanted.variant == "boolean"
		and wanted.value ~= nil then
		return wanted
	end
	if type.variant ~= "union" then
		return types.satisfies(type, wanted) and type or nil
	end
	local kept = {}
	for _, member in ipairs(type.types) do
		if member.variant == "boolean" and member.value == nil and wanted.variant == "boolean"
			and wanted.value ~= nil then
			kept[#kept + 1] = wanted
		elseif types.satisfies(member, wanted) then
			kept[#kept + 1] = member
		end
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
	if type.variant == "unknown" then return value.variant == "unknown" end
	local wanted = stringValueOf(value)
	if wanted then return stringValueOf(type) == wanted end
	return types.satisfies(type, value)
end

--- Keep only the members that do not fit a type.
---@param type lye.doc.Type
---@param unwanted lye.doc.Type?
function types.excludeType(type, unwanted)
	if not unwanted then return type end
	if type.variant == "any" then return type end
	if type.variant == "unknown" then
		if unwanted.variant == "nil" then return types.nonNilUnknown() end
		if unwanted.variant == "boolean" and unwanted.value == true then
			return types.union({ types.NIL_TYPE, types.booleanValue(false), types.NUMBER,
				types.STRING, types.TABLE, types.FUNCTION })
		end
		if unwanted.variant == "boolean" and unwanted.value == false then
			return types.union({ types.NIL_TYPE, types.booleanValue(true), types.NUMBER,
				types.STRING, types.TABLE, types.FUNCTION })
		end
		return type
	end
	if type.variant ~= "union" then
		-- A whole boolean ruled against one of its values is the other value, not "not exactly
		-- this boolean": the branch that is not `true` is `false`.
		if type.variant == "boolean" and type.value == nil and unwanted.variant == "boolean"
			and unwanted.value ~= nil then
			return types.booleanValue(not unwanted.value)
		end
		-- `and nil or type` cannot yield nil, so ruling the type out has to be explicit.
		if types.isExactly(type, unwanted) then return nil end
		return type
	end
	local kept = {}
	for _, member in ipairs(type.types) do
		if member.variant == "boolean" and member.value == nil and unwanted.variant == "boolean"
			and unwanted.value ~= nil then
			kept[#kept + 1] = types.booleanValue(not unwanted.value)
		elseif not types.isExactly(member, unwanted) then
			kept[#kept + 1] = member
		end
	end
	if #kept == 0 then return nil end
	return types.union(kept)
end

---@param type lye.doc.Type
---@param typeName string
function types.exclude(type, typeName)
	return types.excludeType(type, types.parse(typeName))
end

--- Whether a member survives a condition on one of its fields. A field whose truth is written
--- down decides it, which is what makes `{ ok: true, v: T } | { ok: false, e: string }` narrow on
--- `parsed.ok`.
---
--- A function of its arguments rather than a closure over them: a closure written where this is
--- asked is created inside the loops that ask it, and a function that makes one never compiles.
---@param member lye.doc.Type
---@param field string
---@param want boolean
local function survivesField(member, field, want)
	if member.variant ~= "object" and member.variant ~= "class" then return false end
	local held = member.fields[field]
	if held == nil then return not want end
	local known = types.truthiness(held)
	if known == nil then return want end
	return known == want
end

---@param type lye.doc.Type
---@param field string
---@param want boolean
---@return lye.doc.Type? narrowed
function types.narrowField(type, field, want)
	if type.variant ~= "union" then
		if type.variant ~= "object" and type.variant ~= "class" then return type end
		return survivesField(type, field, want) and type or nil
	end

	local kept = {}
	for _, member in ipairs(type.types) do
		if survivesField(member, field, want) then kept[#kept + 1] = member end
	end
	if #kept == 0 then return nil end
	return types.union(kept)
end

--- Whether a member could hold what a condition compared its `field` against. A function of its
--- arguments rather than a closure, for the reason `survivesField` is.
---@param member lye.doc.Type
---@param field string
---@param wanted lye.doc.Type
local function couldBeDiscriminant(member, field, wanted)
	local held = member.variant == "object" and member.fields[field] or nil
	if not held then
		-- A class is built at runtime, so a field it does not name may still be there; an
		-- object literal says what it holds and nothing else.
		return member.variant == "class"
	end
	return types.satisfies(wanted, held)
end

--- Keep only the members whose own `field` could hold what a condition compared it against:
--- `if kind ~= "fn" then return end` is how a tagged union is read. A member without the
--- field reads it as nil, so it only survives the negative form.
---@param type lye.doc.Type
---@param field string
---@param wanted lye.doc.Type the value the condition compared against
---@param want boolean whether the condition was the equality
function types.narrowDiscriminant(type, field, wanted, want)
	if type.variant ~= "union" then return couldBeDiscriminant(type, field, wanted) == want and type or nil end
	local kept = {}
	for _, member in ipairs(type.types) do
		if couldBeDiscriminant(member, field, wanted) == want then kept[#kept + 1] = member end
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
---@param a number
---@param b number
---@return number
local function add(a, b) return a + b end
---@param a number
---@param b number
---@return number
local function subtract(a, b) return a - b end
---@param a number
---@param b number
---@return number
local function multiply(a, b) return a * b end
---@param a number
---@param b number
---@return number
local function divide(a, b) return a / b end
---@param a number
---@param b number
---@return number
local function modulo(a, b) return a % b end
---@param a number
---@param b number
---@return number
local function power(a, b) return a ^ b end

local ARITHMETIC_RESULT = {
	["+"] = add, ["-"] = subtract, ["*"] = multiply, ["/"] = divide, ["%"] = modulo, ["^"] = power,
}

---@param op string
---@param left lye.doc.Type
---@param right lye.doc.Type
---@return lye.doc.Type
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
		if type.variant == "intersection" then
			local parts = {}
			for _, member in ipairs(type.types) do
				local found = types.fieldOf(member, name)
				if found then parts[#parts + 1] = found end
			end
			if #parts > 0 then return types.intersection(parts) end
			return nil
		end
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
	if target.variant == "intersection" then
		if field then
			local parts = {}
			for _, member in ipairs(target.types) do
				local found = types.fieldOf(member, field)
				if found then parts[#parts + 1] = found end
			end
			return #parts > 0 and types.intersection(parts) or types.mutable()
		end
		local parts = {}
		for _, member in ipairs(target.types) do
			parts[#parts + 1] = types.indexResult(member, field)
		end
		return types.intersection(parts)
	end
	-- A value that may be more than one thing reads the field off every member that has it, and the
	-- answer is the union of what they hold: a discriminated union's `type` is every literal its
	-- members spell, not just the first one's. A member without the field cannot answer, so it adds
	-- nothing rather than making the read unknown — `local raw = onWindows and require("a.windows")
	-- or require("a.posix")` is a union of two modules, and one of them lacking a field the other
	-- has is not a reason to forget the one that does.
	if target.variant == "union" and field then
		local parts = {}
		for _, member in ipairs(target.types) do
			local found = types.fieldOf(member, field)
			if not found and member.variant == "object" and member.indexed and member.indexed.key == "string" then
				found = member.indexed.type
			end
			if found then parts[#parts + 1] = found end
		end
		if #parts > 0 then return types.union(parts) end
	end
	if target.variant == "object" and field then
		local found = types.fieldOf(target, field)
		if found then return found end
		-- A string index signature answers for a name as well as for a key: `table<string, integer>`
		-- says what reading one gives, so a field the table does not list holds that rather than
		-- nil — reading one as nil reported every `flags.anything` as a number that was not there.
		if target.indexed and target.indexed.key == "string" then return target.indexed.type end
		return types.NIL_TYPE
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
	["-"] = true, [":"] = true, ["|"] = true, [","] = true, ["&"] = true,
	["<"] = true, ["["] = true, ["{"] = true,
}

--- Where the type ends in annotation text. A space inside `<...>`, `{...}` or `(...)` is part of
--- the type, and so is one before a marker that continues it; anywhere else a description
--- follows, as in `---@param y integer y`. Without this the prose becomes a type nothing knows,
--- which then disagrees with every argument.
---@param text string
---@return integer? stop
local function typeEndScan(text)
	local depth, template = 0, false
	-- A conditional is a type for its whole length: `A extends B ? X : Y` has spaces at every
	-- keyword, and cutting at the first one left the annotation meaning `A`.
	local conditional = text:find("%f[%w_]extends%f[^%w_]") ~= nil
	for at = 1, #text do
		local char = text:sub(at, at)
		-- A `--` is never part of a type, wherever it appears: what follows one is prose. The two hyphens
		-- otherwise read as the arrow of a signature, and the sentence's first words became the type.
		if char == "-" and text:sub(at + 1, at + 1) == "-" and depth == 0 and not template then return at - 1 end
		if char == "`" then
			template = not template
		elseif template then
			-- Everything inside a template literal is text, including its spaces.
		elseif char == "<" or char == "{" or char == "(" or char == "[" then
			depth += 1
		elseif char == ">" or char == "}" or char == ")" or char == "]" then
			depth -= 1
		elseif char == " " and depth == 0 then
			-- A marker on either side of the space keeps the type going: `fun(a): string` has one
			-- after the colon, `nil | string` one before the bar.
			local after = text:sub(at + 1):match("^(%S)")
			local before = text:sub(at - 1, at - 1)
			if not (conditional or CONTINUES[before] or (after and CONTINUES[after])) then return at - 1 end
		end
	end
end

--- Text read over and over — a signature's parameters at every call site, an annotation at every
--- analysis — costs its scan each time, and the scans answer with plain text and numbers that
--- nothing writes to. The first answer is kept for the same text; the keys are weak, so the text
--- of an annotation that left the document is collected rather than kept for the life of the
--- process. `false` records an answer that was nil, which a table cannot hold.
local typeEnds = setmetatable({}, { __mode = "k" })

---@param text string
---@return integer? stop
local function typeEnd(text)
	local held = typeEnds[text]
	if held ~= nil then
		if held == false then return nil end
		return held
	end
	local stop = typeEndScan(text)
	typeEnds[text] = stop or false
	return stop
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
local function fnParamsScan(text)
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

local fnShapes = setmetatable({}, { __mode = "k" })

--- The parentheses and declared names of a signature, scanned once per text.
---@param text string
---@return integer? openAt
---@return integer? closeAt
---@return string? declared
local function fnParams(text)
	local held = fnShapes[text]
	if held ~= nil then
		if held == false then return nil end
		return held[1], held[2], held[3]
	end
	local openAt, closeAt, declared = fnParamsScan(text)
	fnShapes[text] = openAt and { openAt, closeAt, declared } or false
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

	local params, isVariadic, variadic, method = {}, false, nil, false
	for index, part in ipairs(splitParams(text:sub(openAt + 1, closeAt - 1))) do
		local one = part:gsub("^%s+", ""):gsub("%s+$", "")
		if index == 1 and one:match("^self[%s%?:]") then method = true end
		if one == "..." or one:match("^%.%.%.[%s:]*") then
			isVariadic = true
			-- `fun(...: string|number)` says what the extra arguments take, which is what a
			-- callback written for it needs to know: `s:gsub("%a", function(c) … end)` is handed
			-- a string, not an unknown.
			local written = one:match("^%.%.%.[%s]*:?%s*(.*)$")
			if written and written ~= "" then variadic = types.parse(written, resolve) end
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
	local signature = types.fn(params, returns, isVariadic, nil, variadic)
	if method then signature.isMethod = true end
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
local function foldExpressionScan(text)
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

local foldedExpressions = setmetatable({}, { __mode = "k" })

--- An expression of literals, worked out once per text: the same type text is read at every call
--- site of the function it belongs to.
---@param text string
---@return string? kind
---@return number|string? value
local function foldExpression(text)
	local held = foldedExpressions[text]
	if held ~= nil then
		if held == false then return nil end
		return held[1], held[2]
	end
	local kind, value = foldExpressionScan(text)
	foldedExpressions[text] = kind and { kind, value } or false
	return kind, value
end

--- Replace the type variables a signature declares with what a call bound them to. A name bound
--- to nothing is left as it was, so an unbound `T` reads as the variable it is rather than as a
--- type nobody declared.
---@param type lye.doc.Type
---@param bindings table<string, lye.doc.Type>
--- The walk behind `types.substitute`. A type can contain itself — a class with a field of its
--- own class, an alias whose body names it — so the output is registered before its contents are
--- walked and a type met again answers with the copy already being built.
---@param type lye.doc.Type
---@param bindings table<string, lye.doc.Type>
---@param seen table<lye.doc.Type, lye.doc.Type>
---@return lye.doc.Type
local function substituted(type, bindings, seen)
	if type.variant == "extern" then return bindings[type.name] or type end
	if type.variant == "fn" then
		local seenHere = seen[type]
		if seenHere then return seenHere end
		local out = types.fn({}, types.UNKNOWN_TYPE, type.isVariadic, type.isSpread)
		seen[type] = out
		for index, param in ipairs(type.params) do
			out.params[index] = substituted(param, bindings, seen)
		end
		out.returns = substituted(type.returns, bindings, seen)
		out.variadic = type.variadic and substituted(type.variadic, bindings, seen)
		out.generics, out.constraints = type.generics, type.constraints
		out.isMethod = type.isMethod
		-- A generic call substitutes into every value it gives back, not only the first: reading
		-- `---@return T...` through a binding otherwise lost that it was a spread at all.
		if type.values then
			local values = {}
			for index, value in ipairs(type.values) do
				values[index] = substituted(value, bindings, seen)
			end
			out.values = values
		end
		return out
	end
	if type.variant == "array" then
		local seenHere = seen[type]
		if seenHere then return seenHere end
		local out = types.array(types.UNKNOWN_TYPE)
		seen[type] = out
		out.type = substituted(type.type, bindings, seen)
		return out
	end
	if type.variant == "union" then
		local seenHere = seen[type]
		if seenHere then return seenHere end
		local out = types.mutable()
		seen[type] = out
		local members = {}
		for index, member in ipairs(type.types) do
			members[index] = substituted(member, bindings, seen)
		end
		types.promote(out, types.union(members))
		return out
	end
	if type.variant == "object" then
		local seenHere = seen[type]
		if seenHere then return seenHere end
		local out = types.object({})
		seen[type] = out
		for name, field in pairs(type.fields) do
			out.fields[name] = substituted(field, bindings, seen)
		end
		if type.indexed then
			out.indexed = {
				key = type.indexed.key,
				type = substituted(type.indexed.type, bindings, seen),
			}
		end
		out.metatable = type.metatable and substituted(type.metatable, bindings, seen)
		return out
	end
	if type.variant == "intersection" then
		local members = {}
		for index, member in ipairs(type.types) do
			members[index] = substituted(member, bindings, seen)
		end
		return types.intersection(members)
	end
	if type.variant == "keyof" then
		return types.keyof(substituted(type.type, bindings, seen))
	end
	if type.variant == "indexed" then
		return types.indexedAccess(substituted(type.object, bindings, seen),
			substituted(type.key, bindings, seen))
	end
	if type.variant == "conditional" then
		return types.conditional(substituted(type.check, bindings, seen),
			substituted(type.extends, bindings, seen),
			substituted(type.thenType, bindings, seen),
			substituted(type.elseType, bindings, seen))
	end
	if type.variant == "mapped" then
		return types.mapped(type.key, substituted(type.source, bindings, seen),
			substituted(type.value, bindings, seen))
	end
	if type.variant == "template" then
		local parts = {}
		for index, part in ipairs(type.parts) do
			if type(part) == "string" then
				parts[index] = part
			else
				parts[index] = substituted(part, bindings, seen)
			end
		end
		return types.template(parts)
	end
	-- A class carries its arguments, so a generic class instantiated by a call has to substitute
	-- into them and into the fields: `Box<T>` returned by `Box.new(2)` is `Box<2>`, and `get` on
	-- it gives the value the box holds rather than the type variable the class was written with.
	if type.variant == "class" then
		local seenHere = seen[type]
		if seenHere then return seenHere end
		local out = types.classType(type.name, {}, {}, {}, type.visibility)
		seen[type] = out
		for index, arg in ipairs(type.args or {}) do
			out.args[index] = substituted(arg, bindings, seen)
		end
		for name, field in pairs(type.fields or {}) do
			out.fields[name] = substituted(field, bindings, seen)
		end
		for index, parent in ipairs(type.parents or {}) do
			out.parents[index] = substituted(parent, bindings, seen)
		end
		if type.indexed then
			out.indexed = {
				key = type.indexed.key,
				type = substituted(type.indexed.type, bindings, seen),
			}
		end
		out.metatable = type.metatable and substituted(type.metatable, bindings, seen)
		return out
	end
	return type
end

---@param type lye.doc.Type
---@param bindings table<string, lye.doc.Type>
---@return lye.doc.Type
function types.substitute(type, bindings)
	return substituted(type, bindings, {})
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

--- Split `T extends U ? X : Y` at the `?` and `:` that belong to it. A `?` already written in
--- a branch — an optional type, or a nested conditional — is counted so the colon that matches
--- this conditional is not one of theirs.
---@param text string
---@return string? check
---@return string? extends
---@return string? thenText
---@return string? elseText
local function conditionalParts(text)
	local depth, extendsAt, extendsStop = 0, nil, nil
	for at = 1, #text do
		local char = text:sub(at, at)
		if char == "<" or char == "{" or char == "(" or char == "[" then depth += 1
		elseif char == ">" or char == "}" or char == ")" or char == "]" then depth -= 1
		elseif depth == 0 and text:sub(at, at + 8) == " extends " then
			extendsAt, extendsStop = at, at + 8
			break
		end
	end
	if not extendsAt then return nil end
	local question, condDepth
	for at = extendsStop + 1, #text do
		local char = text:sub(at, at)
		if char == "<" or char == "{" or char == "(" or char == "[" then depth += 1
		elseif char == ">" or char == "}" or char == ")" or char == "]" then depth -= 1
		elseif depth == 0 and char == "?" then
			question = at
			break
		end
	end
	if not question then return nil end
	local colon
	condDepth = 0
	for at = question + 1, #text do
		local char = text:sub(at, at)
		if char == "<" or char == "{" or char == "(" or char == "[" then depth += 1
		elseif char == ">" or char == "}" or char == ")" or char == "]" then depth -= 1
		elseif depth == 0 and char == "?" then condDepth += 1
		elseif depth == 0 and char == ":" then
			if condDepth == 0 then colon = at break end
			condDepth -= 1
		end
	end
	if not colon then return nil end
	return (text:sub(1, extendsAt - 1):gsub("^%s+", ""):gsub("%s+$", "")),
		(text:sub(extendsStop + 1, question - 1):gsub("^%s+", ""):gsub("%s+$", "")),
		(text:sub(question + 1, colon - 1):gsub("^%s+", ""):gsub("%s+$", "")),
		(text:sub(colon + 1):gsub("^%s+", ""):gsub("%s+$", ""))
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

	-- A conditional is read before the bar: its branches may be unions, so splitting the whole
	-- text at `|` first would cut the conditional in half. A name still unresolved keeps the
	-- conditional until a substitution supplies it.
	local checkText, extendsText, thenText, elseText = conditionalParts(trimmed)
	if checkText and extendsText and thenText and elseText then
		local check = types.parse(checkText, resolve)
		local wanted = types.parse(extendsText, resolve)
		local thenType = types.parse(thenText, resolve)
		local elseType = types.parse(elseText, resolve)
		if check and wanted and thenType and elseType then
			return types.conditional(check, wanted, thenType, elseType)
		end
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

	-- Intersection binds tighter than union, so `A | B & C` is A or (B and C).
	local parts = splitTopLevel(trimmed, 38)
	if #parts > 1 then
		local parsed = {}
		for _, part in ipairs(parts) do
			local one = types.parse(part, resolve)
			if one then parsed[#parsed + 1] = one end
		end
		return #parsed > 0 and types.intersection(parsed) or nil
	end

	-- `async` marks a function that may yield. It says nothing about the type, so the definition
	-- reads the same as the callable it stands for: `async fun(...):...` is a function.
	if trimmed:sub(1, 6) == "async " then return types.parse(trimmed:sub(7), resolve) end

	-- `keyof T` is the union of the names T holds. A name that is still unresolved keeps the
	-- operation, so a generic substitution can answer it later.
	local keysOf = trimmed:match("^keyof%s+(.+)$")
	if keysOf then
		local operand = types.parse(keysOf, resolve)
		return operand and types.keyof(operand) or nil
	end

	-- A template literal type: backticked static text with `${T}` substitutions. Every part that
	-- is known is folded into the string; a name keeps the template until it is bound.
	if trimmed:sub(1, 1) == "`" and trimmed:sub(-1) == "`" then
		local content = trimmed:sub(2, -2)
		local parts, at = {}, 1
		while true do
			local open, close = content:find("%${", at)
			if not open then
				parts[#parts + 1] = content:sub(at)
				break
			end
			parts[#parts + 1] = content:sub(at, open - 1)
			local stop = content:find("}", close + 1, true)
			if not stop then parts[#parts + 1] = content:sub(open) break end
			local inner = types.parse(content:sub(close + 1, stop - 1), resolve)
			if inner then parts[#parts + 1] = inner end
			at = stop + 1
		end
		return types.template(parts)
	end

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

	-- `T["field"]`, `T[K]` and `keyof T`: an indexed access is the value at that key. A key that
	-- is still a name keeps the access until the substitution answers both sides.
	local baseText, keyText = trimmed:match("^(.-)%[(.-)%]$")
	if baseText and keyText ~= "" then
		local object = types.parse(baseText, resolve)
		local key = types.parse(keyText, resolve)
		if object and key then return types.indexedAccess(object, key) end
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
		-- `{ [K in keyof T]: U }` maps every key of T. The value is read with K standing for the
		-- key a member is built for, so `{ [K in "a"|"b"]: K }` is `{ a: "a", b: "b" }`.
		local keyVar, sourceText, valueText =
			trimmed:match("^{%s*%[%s*([%w_]+)%s+in%s+(.-)%]%s*:?%s*(.*)%s*}$")
		if keyVar then
			local source = types.parse(sourceText, resolve) or types.UNKNOWN_TYPE
			local value = types.parse(valueText, function(text)
				if text == keyVar then return types.extern(keyVar) end
				return resolve and resolve(text)
			end) or types.UNKNOWN_TYPE
			return types.mapped(keyVar, source, value)
		end
		local fields, indexed = {}, nil
		-- Split at the commas that separate fields, not at every comma there is: a field whose type
		-- is `table<string, number>` carries one of its own, and cutting there leaves two fields —
		-- `fields: table<string` and `number>` — which is a shape nothing can use.
		for _, field in ipairs(splitTopLevel(trimmed:sub(2, -2), 44)) do
			-- `[integer]: T` is an index signature: every key of that kind holds T, which is how
			-- a list is written. It is the only thing that makes a generic element reachable.
			-- The capture is trimmed: a field's text carries the spaces around it, and one left
			-- on the end of a type becomes part of it — `string ?` ends where the space is, so the
			-- marker a caller appended was dropped.
			local key, value = field:match("^%s*%[%s*([%w_]+)%s*%]%s*:?%s*(.-)%s*$")
			if key then
				indexed = { key = key, type = types.parse(value, resolve) or types.UNKNOWN_TYPE }
			else
				-- `kind?: string` marks the field optional with a `?` on its own name, which is
				-- how LuaLS writes it and what the definitions use; `kind: string?` says the same
				-- thing with the marker on the type. Reading the name's marker as part of the type
				-- left the field required and its type spelled `?: string`.
				local name, marker, held = field:match("^%s*([%w_]+)%s*(%??)%s*:?%s*(.-)%s*$")
				if name then
					fields[name] = types.parse(marker == "?" and (held .. "?") or held, resolve)
						or types.UNKNOWN_TYPE
				end
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
--- A type as a person reads a diagnostic: the display, cut when the shape is larger than a
--- message should be. A whole function signature or a context table is not the point of the
--- error; the name or the first part of it is.
local MAX_DESCRIBE = 220
---@param type lye.doc.Type
---@return string
function types.describe(type)
	local text = types.display(type)
	if #text > MAX_DESCRIBE then return text:sub(1, MAX_DESCRIBE - 1) .. "…" end
	return text
end

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
	-- An alias is its name where a reader is concerned. The body remains the type every check
	-- uses; only the rendering stops at the name, which is what keeps a recursive alias such as
	-- `lye.doc.Type` from expanding into the union of its own members.
	if type.aliasName then return type.aliasName end
	if type.variant == "intersection" then
		local parts = {}
		for _, member in ipairs(type.types) do
			local shown = types.display(member)
			if member.variant == "union" then shown = "(" .. shown .. ")" end
			parts[#parts + 1] = shown
		end
		return table.concat(parts, " & ")
	end
	if type.variant == "keyof" then return "keyof " .. types.display(type.type) end
	if type.variant == "indexed" then
		return types.display(type.object) .. "[" .. types.display(type.key) .. "]"
	end
	if type.variant == "conditional" then
		return types.display(type.check) .. " extends " .. types.display(type.extends)
			.. " ? " .. types.display(type.thenType) .. " : " .. types.display(type.elseType)
	end
	if type.variant == "mapped" then
		return "{ [" .. type.key .. " in " .. types.display(type.source) .. "]: "
			.. types.display(type.value) .. " }"
	end
	if type.variant == "template" then
		local parts = {}
		for _, part in ipairs(type.parts) do
			parts[#parts + 1] = _G.type(part) == "string" and part
				or ("${" .. types.display(part) .. "}")
		end
		return "`" .. table.concat(parts) .. "`"
	end
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
		local params = type.params or {}
		local shown = math.min(#params, 6)
		for index = 1, shown do parts[#parts + 1] = types.display(params[index]) end
		if #params > shown then parts[#parts + 1] = "..." end
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
		local names = {}
		for name in pairs(type.fields) do names[#names + 1] = name end
		table.sort(names)
		local parts = {}
		-- A table literal can gather a dozen fields — a context object, a definition — and printing
		-- all of them turns one diagnostic into a screenful nobody reads. The first eight and an
		-- ellipsis say the shape without doing that.
		local shown = math.min(#names, 4)
		for index = 1, shown do
			local name = names[index]
			parts[#parts + 1] = name .. ": " .. types.display(type.fields[name])
		end
		if #names > shown then parts[#parts + 1] = "..." end
		if type.indexed then
			parts[#parts + 1] = "[" .. type.indexed.key .. "]: " .. types.display(type.indexed.type)
		end
		-- A table whose shape is not known *yet* is a table, not an empty one: `local t = {}` reads
		-- as `table` until something gives it a field, which is what a reader expects to see.
		if #parts == 0 and not type.metatable then return "table" end
		-- A table that is only what it holds at a key reads the way an annotation writes one:
		-- `string[]` for a list, `table<string, true>` for a set built by marking keys.
		if next(type.fields) == nil and type.indexed and not type.metatable then
			local inner = types.display(type.indexed.type)
			if type.indexed.key == "integer" or type.indexed.key == "number" then
				-- A union and a signature are bracketed here for the same reason the `array`
				-- variant brackets them: `A|B[]` reads as an `B` array beside an `A`.
				if type.indexed.type.variant == "union" or type.indexed.type.variant == "fn" then
					inner = "(" .. inner .. ")"
				end
				return inner .. "[]"
			end
			return "table<" .. type.indexed.key .. ", " .. inner .. ">"
		end
		table.sort(parts)
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	if type.variant == "union" then
		-- Sorted so two unions of the same members compare equal as strings.
		local parts = {}
		local shown = math.min(#type.types, 12)
		for index = 1, shown do parts[index] = types.display(type.types[index]) end
		if #type.types > shown then parts[#parts + 1] = "..." end
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

--- Whether a value is one the analysis cannot see into: `any` it was handed, or a value nothing
--- is known about. A mutable unknown is a placeholder rather than an answer, and is not one.
---@param type lye.doc.Type?
---@return boolean
function types.isOpaque(type)
	if not type then return false end
	if type.variant == "any" then return true end
	if type.variant == "unknown" then return not types.isMutable(type) end
	if type.variant == "union" or type.variant == "intersection" then
		for _, member in ipairs(type.types) do
			if types.isOpaque(member) then return true end
		end
	end
	return false
end

--- Where an expectation is compared against a value nothing is known about. `satisfies` answers
--- yes for such a value — it is the lattice's top — which is right for asking whether a value may
--- be passed along and wrong for asking whether it meets a promise. This walks the shape the
--- promise describes, so `---@return number` over a body returning `any` and `---@type { n: number }`
--- over a literal holding `any` are both reported.
---@param declared lye.doc.Type
---@param actual lye.doc.Type
---@param seen table<lye.doc.Type, table<lye.doc.Type, boolean>>
---@param depth integer
---@return lye.doc.Type? opaque the value that has no type to check
---@return string? at where it is, for the message
local function opaqueWhere(declared, actual, seen, depth)
	if types.isOpaque(actual) and not types.isOpaque(declared) then return actual, nil end
	if not declared or not actual or depth > 16 then return nil end
	-- The pair, not just the value: a class graph is not self-similar, and walking every pair of
	-- fields in two large classes is quadratic per level while a pair already asked adds nothing.
	local pair = seen[declared]
	if not pair then
		pair = {}
		seen[declared] = pair
	end
	if pair[actual] then return nil end
	pair[actual] = true
	if declared.variant == "fn" and actual.variant == "fn" then
		local found, at = opaqueWhere(declared.returns, actual.returns, seen, depth + 1)
		if found then return found, at or "the result" end
		return nil
	end
	if declared.variant == "array" and actual.variant == "array" then
		local found, at = opaqueWhere(declared.type, actual.type, seen, depth + 1)
		if found then return found, at or "the element" end
		return nil
	end
	if (declared.variant == "object" or declared.variant == "class")
		and (actual.variant == "object" or actual.variant == "class") then
		for name, wanted in pairs(declared.fields or {}) do
			local have = actual.fields and actual.fields[name]
			if have then
				local found, at = opaqueWhere(wanted, have, seen, depth + 1)
				if found then return found, at or ("`" .. name .. "`") end
			end
		end
	end
	return nil
end

--- A message for a mismatch, or nil when the value fits. The lattice's answer: `any` and
--- `unknown` fit every constraint, which is what passing a value along needs.
---@param declared lye.doc.Type
---@param actual lye.doc.Type
---@param name string
function types.mismatch(declared, actual, name)
	if types.satisfies(actual, declared) then return nil end
	return string.format("%s is declared as %s but is assigned %s", name, types.describe(declared), types.describe(actual))
end

--- The comparison a written expectation makes: `satisfies` accepts `any` and `unknown` for every
--- constraint, which is right for a value passed along and wrong for a value stored in, returned
--- from or handed to a place that named what it takes. Reports the opaque value and where in the
--- shape it was, so a function returning `any` and a table holding one read differently.
---@param declared lye.doc.Type
---@param actual lye.doc.Type
---@param name string
function types.strictMismatch(declared, actual, name)
	local opaque, at = opaqueWhere(declared, actual, {}, 0)
	if opaque then
		return string.format("%s is declared as %s but is assigned %s%s", name,
			types.describe(declared), at and (at .. " of ") or "", types.describe(opaque))
	end
	return types.mismatch(declared, actual, name)
end

return types
