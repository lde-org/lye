--[[
	Type system: variants, subtyping, narrowing and display.

	A type is a table with a `variant`, so everything is data rather than a string re-parsed
	on each question. `nil` is its own variant, which is what lets `number?` reject a string
	while still accepting nil.

	`unknown` is the honest answer when inference cannot tell, and it satisfies everything:
	reporting an error against an unknown is how a checker becomes noise.
]]

local types = {}

--- A type table, discriminated by `variant`.
---@alias lye.doc.Type
---| { variant: "number" }
---| { variant: "string" }
---| { variant: "boolean" }
---| { variant: "nil" }
---| { variant: "table" }
---| { variant: "fn", params: lye.doc.Type[], returns: lye.doc.Type, isVariadic: boolean? }
---| { variant: "any" }
---| { variant: "unknown" }
---| { variant: "extern", name: string }
---| { variant: "array", type: lye.doc.Type }
---| { variant: "object", fields: table<string, lye.doc.Type> }
---| { variant: "union", types: lye.doc.Type[] }

types.UNKNOWN = "unknown"
types.ANY = "any"
types.NIL = "nil"

local SIMPLE = { number = true, string = true, boolean = true, ["nil"] = true, any = true, unknown = true }

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

--- An `unknown` that can still be promoted. A type is mutable when a later assignment may
--- tell us what it actually is, which is the difference between "we do not know yet" and
--- "this is genuinely unknown".
---@return lye.doc.Type
function types.mutable()
	return { variant = "unknown", isMutable = true }
end

---@param type lye.doc.Type
---@return boolean
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
--- A callable. The parameters and the return type are types, so a function is as hard typed as
--- anything else: `fn(a: number) -> string` does not accept a function that takes a string.
---@param params lye.doc.Type[]
---@param returns lye.doc.Type
---@param isVariadic boolean? accepts any number of arguments
---@return lye.doc.Type
function types.fn(params, returns, isVariadic)
	return make("fn", { params = params, returns = returns, isVariadic = isVariadic })
end

---@param type lye.doc.Type
---@return boolean
function types.isFn(type)
	return type.variant == "fn"
end

--- The permissive callable, the one a `function` literal has until something says otherwise.
---@param type lye.doc.Type
---@return boolean
function types.isAnyFn(type)
	return type.variant == "fn"
		and #type.params == 0
		and type.isVariadic == true
		and type.returns.variant == "any"
end
types.UNKNOWN_TYPE = make("unknown")
types.ANY_TYPE = make("any")

--- What a bare `function` means: `fn(...any) -> ...any`, so annotations written before
--- signatures keep working and a function literal satisfies any signature it is given. It is
--- built here because it is made of them.
types.FUNCTION = types.fn({}, types.ANY_TYPE, true)

---@param name string
---@return lye.doc.Type
function types.extern(name) return make("extern", { name = name }) end

---@param inner lye.doc.Type
---@return lye.doc.Type
function types.array(inner) return make("array", { type = inner }) end

---@param fields table<string, lye.doc.Type>
---@return lye.doc.Type
function types.object(fields) return make("object", { fields = fields }) end

--- Flatten nested unions and drop duplicates, so `a | (b | c)` is one flat set. An unknown
--- member absorbs the whole union: `string | unknown` is unknown, since it tells us no more
--- than the unknown did.
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
	if left.variant == "unknown" then return right end
	if right.variant == "unknown" then return left end
	if types.display(left) == types.display(right) then return left end
	return types.union({ left, right })
end

--- Whether every possible value of `type` fits `constraint`.
---@param type lye.doc.Type
---@param constraint lye.doc.Type
---@return boolean
function types.satisfies(type, constraint)
	if types.isMutable(constraint) then types.promote(constraint, type) end
	if constraint.variant == "any" or constraint.variant == "unknown" then return true end
	if type.variant == "unknown" or type.variant == "any" then return true end

	if constraint.variant == "union" then
		for _, member in ipairs(constraint.types) do
			if types.satisfies(type, member) then return true end
		end
		return false
	end

	-- A union fits only when every member does.
	if type.variant == "union" then
		for _, member in ipairs(type.types) do
			if not types.satisfies(member, constraint) then return false end
		end
		return true
	end

	if constraint.variant == "fn" then
		if type.variant ~= "fn" then return false end
		-- A callable that takes anything accepts any callable, which is what a bare `function`
		-- means and what keeps unannotated literals out of trouble.
		if types.isAnyFn(constraint) then return true end
		if #type.params ~= #constraint.params and not type.isVariadic then return false end
		for index, wanted in ipairs(constraint.params) do
			local have = type.params[index] or types.UNKNOWN_TYPE
			-- Contravariant: the value has to accept what the constraint will pass it.
			if not types.satisfies(wanted, have) then return false end
		end
		return types.satisfies(type.returns, constraint.returns)
	end

	if constraint.variant == "array" then
		if type.variant ~= "array" then return false end
		return types.satisfies(type.type, constraint.type)
	end

	if constraint.variant == "object" then
		if type.variant ~= "object" then return false end
		for name, wanted in pairs(constraint.fields) do
			local have = type.fields[name]
			if not have or not types.satisfies(have, wanted) then return false end
		end
		return true
	end

	if SIMPLE[constraint.variant] or SIMPLE[type.variant] then
		return type.variant == constraint.variant
	end

	-- A container or a name the checker does not model: decline rather than guess.
	return type.variant == constraint.variant
end

--- Whether the value is definitely truthy, definitely falsy, or either.
---@param type lye.doc.Type
---@return boolean? truthy
function types.truthiness(type)
	if type.variant == "nil" then return false end
	if type.variant == "boolean" then return nil end
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
---@return lye.doc.Type? narrowed
function types.narrowTruthiness(type, wantTruthy)
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

--- Keep only the members that fit a named type, which is what `type(x) == "number"` asserts.
--- A name that resolves to nothing keeps the type unchanged rather than emptying it.
---@param type lye.doc.Type
---@param typeName string
---@return lye.doc.Type? narrowed
function types.narrowTo(type, typeName)
	local wanted = types.parse(typeName)
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

--- Keep only the members that do not fit a named type.
---@param type lye.doc.Type
---@param typeName string
---@return lye.doc.Type? narrowed
function types.exclude(type, typeName)
	local unwanted = types.parse(typeName)
	if not unwanted then return type end
	if type.variant ~= "union" then
		-- `and nil or type` cannot yield nil, so ruling the type out has to be explicit.
		if types.satisfies(type, unwanted) then return nil end
		return type
	end
	local kept = {}
	for _, member in ipairs(type.types) do
		if not types.satisfies(member, unwanted) then kept[#kept + 1] = member end
	end
	if #kept == 0 then return nil end
	return types.union(kept)
end

---@param field string
---@param want boolean
---@return lye.doc.Type? narrowed
function types.narrowField(type, field, want)
	if type.variant ~= "union" then
		if type.variant ~= "object" then return type end
		return (type.fields[field] ~= nil) == want and type or nil
	end

	local kept = {}
	for _, member in ipairs(type.types) do
		if member.variant == "object" then
			if (member.fields[field] ~= nil) == want then kept[#kept + 1] = member end
		elseif not want then
			kept[#kept + 1] = member
		end
	end
	if #kept == 0 then return nil end
	return types.union(kept)
end

--- The type an arithmetic or logical operator produces from its operands. `unknown` on
--- either side yields unknown, which is what keeps a chain from inventing a type.
---@param op string
---@param left lye.doc.Type
---@param right lye.doc.Type
---@return lye.doc.Type
--- Whether every value of this type is a number, which is what makes arithmetic a number. An
--- `any` is not: it could be a table whose metamethod returns anything at all.
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

function types.binaryResult(op, left, right)
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
	if op == "and" or op == "or" or op == "??" or op == "&&" or op == "||" then
		return types.combine(left, right)
	end

	local isArithmetic = op == "+" or op == "-" or op == "*" or op == "/" or op == "%"
		or op == "^" or op == "&" or op == "|" or op == "~" or op == "<<" or op == ">>" or op == "~>>"
	if isArithmetic then
		if isNumeric(left) and isNumeric(right) then return types.NUMBER end
		-- Anything else could be a table with a metamethod, so the result is not claimed. `any`
		-- is in that group: it satisfies `number`, and a value that satisfies a constraint is not
		-- a guarantee that the constraint is what it is.
		return types.mutable()
	end
	return types.mutable()
end

---@param op string
---@param operand lye.doc.Type
---@return lye.doc.Type
function types.unaryResult(op, operand)
	if op == "not" or op == "!" then return types.BOOLEAN end
	if op == "#" then return types.NUMBER end
	if operand.variant == "unknown" then return types.mutable() end
	if op == "-" or op == "~" then
		return types.satisfies(operand, types.NUMBER) and types.NUMBER or types.mutable()
	end
	return types.mutable()
end

--- Indexing a table gives its field, an array its element. Anything else is unknown, and a
--- field lookup on a union is the union of that field across the members that have it.
---@param target lye.doc.Type
---@param field string?
---@return lye.doc.Type
function types.indexResult(target, field)
	if target.variant == "unknown" or target.variant == "any" then return types.mutable() end
	if target.variant == "object" and field then
		return target.fields[field] or types.NIL_TYPE
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

---@param text string
---@return lye.doc.Type[]
local function splitTopLevel(text, separator)
	local parts, depth, from = {}, 0, 1
	for at = 1, #text do
		local byte = text:byte(at)
		if byte == 40 or byte == 123 then
			depth += 1
		elseif byte == 41 or byte == 125 then
			depth -= 1
		elseif byte == separator and depth == 0 then
			parts[#parts + 1] = text:sub(from, at - 1)
			from = at + 1
		end
	end
	parts[#parts + 1] = text:sub(from)
	return parts
end

---@param text string
---@return lye.doc.Type?
--- Split a parameter list on the commas that are not inside a nested shape.
---@param text string
---@return string[]
local function splitParams(text)
	local parts, depth, from = {}, 0, 1
	for index = 1, #text do
		local char = text:sub(index, index)
		if char == "(" or char == "{" or char == "<" then
			depth += 1
		elseif char == ")" or char == "}" or char == ">" then
			depth -= 1
		elseif char == "," and depth == 0 then
			parts[#parts + 1] = text:sub(from, index - 1)
			from = index + 1
		end
	end
	parts[#parts + 1] = text:sub(from)
	return parts
end

--- `fn(a: number, b: string) -> boolean`, and the `fun(a): boolean` spelling LuaLS uses.
--- A parameter may be named or not, may be optional, and `...` stands for the rest.
---@param text string
---@return lye.doc.Type?
local function parseFn(text)
	-- `fn(` or the `fun(` spelling; `f?un` would read as "un" or "fun", which is neither.
	local head = text:match("^fu?n%s*%(")
	if not head then return nil end

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

	local returns = types.ANY_TYPE
	local rest = text:sub(closeAt + 1):gsub("^%s*", "")
	local returned = rest:match("^[-:]?>%s*(.*)$") or rest:match("^:%s*(.*)$")
	if returned and returned ~= "" then returns = types.parse(returned) or types.ANY_TYPE end

	local params, isVariadic = {}, false
	for _, part in ipairs(splitParams(text:sub(openAt + 1, closeAt - 1))) do
		local one = part:gsub("^%s+", ""):gsub("%s+$", "")
		if one == "..." or one:match("^%.%.%.[%s:]*") then
			isVariadic = true
		elseif one ~= "" then
			-- `name: type` names the parameter; a bare type is the type itself. Either the
			-- name or the type may carry the `?` that makes it optional.
			local name, marker, named = one:match("^([%w_]+)(%??)%s*:%s*(.*)$")
			local typeText = named or one
			local hasMarker = typeText:sub(-1) == "?"
			if hasMarker then typeText = typeText:sub(1, -2) end
			local optional = marker == "?" or hasMarker
			local paramType = types.parse(typeText) or types.UNKNOWN_TYPE
			if optional then paramType = types.combine(paramType, types.NIL_TYPE) end
			params[#params + 1] = paramType
		end
	end
	return types.fn(params, returns, isVariadic)
end

function types.parse(text)
	local trimmed = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed == "" then return nil end

	if trimmed:sub(-1) == "?" then
		local inner = types.parse(trimmed:sub(1, -2))
		return inner and types.combine(inner, types.NIL_TYPE) or nil
	end
	if trimmed:sub(-2) == "[]" then
		local inner = types.parse(trimmed:sub(1, -3))
		return inner and types.array(inner) or nil
	end

	local members = splitTopLevel(trimmed, 124)
	if #members > 1 then
		local parsed = {}
		for _, member in ipairs(members) do
			local one = types.parse(member)
			if one then parsed[#parsed + 1] = one end
		end
		return #parsed > 0 and types.union(parsed) or nil
	end

	if trimmed:sub(1, 1) == "{" and trimmed:sub(-1) == "}" then
		local fields = {}
		for field in trimmed:sub(2, -2):gmatch("[^,;]+") do
			local key, value = field:match("^%s*([%w_]+)%s*:?%s*(.*)$")
			if key then fields[key] = types.parse(value) or types.UNKNOWN_TYPE end
		end
		return types.object(fields)
	end

	if SIMPLE[trimmed] then return types.base(trimmed) end
	if trimmed == "table" then return types.TABLE end
	if trimmed == "function" then return types.FUNCTION end

	local parsedFn = parseFn(trimmed)
	if parsedFn then return parsedFn end
	return types.extern(trimmed)
end

---@param type lye.doc.Type
---@return string
function types.display(type)
	if type.variant == "fn" then
		if types.isAnyFn(type) then return "function" end
		local parts = {}
		for _, param in ipairs(type.params) do parts[#parts + 1] = types.display(param) end
		if type.isVariadic then parts[#parts + 1] = "..." end
		return "fn(" .. table.concat(parts, ", ") .. ") -> " .. types.display(type.returns)
	end
	if type.variant == "array" then return types.display(type.type) .. "[]" end
	if type.variant == "object" then
		local parts = {}
		for name, field in pairs(type.fields) do
			parts[#parts + 1] = name .. ": " .. types.display(field)
		end
		table.sort(parts)
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	if type.variant == "union" then
		-- Sorted so two unions of the same members compare equal as strings.
		local parts = {}
		for _, member in ipairs(type.types) do parts[#parts + 1] = types.display(member) end
		table.sort(parts)
		return table.concat(parts, "|")
	end
	if type.variant == "extern" then return type.name end
	return type.variant
end

--- A message for a mismatch, or nil when the value fits.
---@param declared lye.doc.Type
---@param actual lye.doc.Type
---@param name string
---@return string?
function types.mismatch(declared, actual, name)
	if types.satisfies(actual, declared) then return nil end
	return string.format("%s is declared as %s but is assigned %s", name, types.display(declared), types.display(actual))
end

return types
