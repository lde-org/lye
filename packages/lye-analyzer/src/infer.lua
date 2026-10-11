--[[
	Recursive typing over the arena: a node's type comes from its operands.

	Memoised per arena index, and a node kind nothing understands yields a mutable unknown, not a guess.
]]

local types = require("lye-doc.type")
local pattern = require("lye-doc.pattern")

local infer = {}

---@class lye.infer.Context
---@field parser lye.parser.Result
---@field typeOfName fun(name: string, offset: integer): lye.doc.Type
---@field typeOfField fun(base: lye.doc.Type, baseName: string?, field: string, offset: integer): lye.doc.Type?
---@field returns table<string, lye.doc.Type>
---@field cache table<integer, lye.doc.Type> what each node was typed as, by arena index
---@field fnTypes table<integer, lye.doc.Type> one callable per function node, filled from its body
---@field callTypes table<integer, lye.doc.Type> what a generic call was bound to, by node
---@field callValues table<integer, lye.doc.Type[]>? every value a call gives, when more than its signature says
---@field building table<integer, boolean> the nodes being typed now, so a self-reach ends
---@field modules fun(name: string): lye.doc.Type? what `require("name")` is, when the caller can say
---@field ctypes fun(node: lye.parser.Node): lye.doc.Type? what a call naming a C type is worth

local KNOWN = {
	number = true, string = true, literal = true, table = true, ["function"] = true,
	call = true, binary = true, unary = true, ternary = true, index = true, name = true, prefix = true,
}

--- The type a literal kind stands for. The parser records what a table field holds as the kind
--- of the value, and only some of those kinds are types: a field holding a call or a sum is a
--- node whose type typing works out separately, so it stays unknown here.
---@param kind string
---@return lye.doc.Type
local function literalType(kind)
	if kind == "string" then return types.STRING end
	if kind == "number" then return types.NUMBER end
	if kind == "boolean" or kind == "true" or kind == "false" then return types.BOOLEAN end
	if kind == "nil" then return types.NIL_TYPE end
	if kind == "table" then return types.TABLE end
	if kind == "function" then return types.FUNCTION end
	return types.mutable()
end

--- What a string reads a field from. Lua gives every string the `string` table as its metatable's
--- `__index`, which is measurable — `getmetatable("").__index == string` — so `s:sub(2)` calls
--- `string.sub(s, 2)` and `s.len` is a function. A type library cannot know that, because it is how
--- the environment is arranged rather than what a string is, and this is the layer that knows the
--- environment.
---@param ctx lye.infer.Context
---@param base lye.doc.Type
---@param field string?
---@param start integer
---@return lye.doc.Type?
local function stringFieldOf(ctx, base, field, start)
	if not field or not ctx.typeOfName or not types.mayBe(base, "string") then return nil end
	local library = ctx.typeOfName("string", start)
	return library and types.fieldOf(library, field) or nil
end

local function of(ctx, idx)
	if not idx then return types.mutable() end
	local cached = ctx.cache[idx]
	if cached then return cached end

	local node = ctx.parser.nodes[idx]
	if not node then return types.mutable() end

	-- A cast written beside the expression stands for it: `f --[[@as Vec]].x` reads `f` as a Vec,
	-- which is the only way to say what a value is where nothing declares it.
	local cast = ctx.casts and ctx.casts[idx]
	if cast then
		if cast.exclude then
			-- `x ---@cast x -T` keeps what the expression already was, without T. Read by asking
			-- for the expression's own type with the cast set aside, which is why it is removed
			-- for the call and put back after: asking again would find the cast and not end.
			ctx.casts[idx] = nil
			local held = of(ctx, idx)
			ctx.casts[idx] = cast
			cast = types.excludeType(held, cast.exclude) or held
		end
		ctx.cache[idx] = cast
		return cast
	end

	local result
	local kind = node.kind

	if kind == "number" then
		-- A literal is the number it spells: `local n = 2149` is 2149, which fits `number`
		-- wherever a number is wanted and reads back as what was written.
		result = node.value and types.numberValue(node.value, node.text) or types.NUMBER
	elseif kind == "string" then
		result = types.STRING
	elseif kind == "literal" then
		-- A boolean literal is the value it spells, the way a number literal is its number: that is
		-- what a discriminant is compared against when a tagged union is built in code.
		-- `...` is emitted as a literal too, and reading it as a boolean made every vararg the
		-- value `false`: `{ ... }` held `false`, the second name of `for _, v in ipairs({ ... })`
		-- was declared `false`, and every use of it was reported as a value that was not one.
		if node.text == "..." then
			result = types.ANY_TYPE
		else
			result = node.text == "nil" and types.NIL_TYPE or types.booleanValue(node.text == "true")
		end
	elseif kind == "table" then
		-- A literal can hold itself, directly or through a name, and the field being typed is then
		-- the literal being built. Nothing is known about it yet, which is what a mutable unknown
		-- says; without this the walk would not end.
		if ctx.building[idx] then return types.mutable() end
		ctx.building[idx] = true
		-- A literal keeps its shape: the elements give an element type, so `{ "x", "y" }` is a
		-- list of strings rather than a bare table, and naming any of them narrows from it.
		local elements = ctx.parser.tableIndexes[node.index]
		local elementType
		for _, elementIdx in ipairs(elements or {}) do
			local one = of(ctx, elementIdx)
			elementType = elementType and types.combine(elementType, one) or one
		end

		local kinds = ctx.parser.tableFields[node.index]
		if not kinds then
			-- `{}` has no shape *yet*, and the shape it grows belongs to this literal alone: a
			-- module is written `local M = {}` and given its fields below, so the type cannot be
			-- the shared `table` every other literal would then be given fields on.
			result = elementType and types.array(elementType) or types.object({})
		else
			local values = ctx.parser.tableFieldValues[node.index]
			local fields = {}
			for name, fieldKind in pairs(kinds) do
				-- The value itself when the parser kept its node, so a field holding a name or a
				-- nested table is that type rather than the kind of thing it looked like.
				local valueIdx = values and values[name]
				fields[name] = valueIdx and of(ctx, valueIdx) or literalType(fieldKind)
			end
			result = types.object(fields, elementType and { key = "integer", type = elementType } or nil)
		end
		ctx.building[idx] = nil
	elseif kind == "function" then
		-- One callable per function node: its return type is filled in from its own body, so it
		-- cannot be the shared one every literal starts as.
		result = ctx.fnTypes[idx]
		if not result then
			result = types.fn({}, types.ANY_TYPE, true)
			ctx.fnTypes[idx] = result
		end
	elseif kind == "name" then
		result = node.name and ctx.typeOfName(node.name, node.start) or types.mutable()
	elseif kind == "prefix" then
		-- A prefix is either a grouped expression, which keeps the inner type, or a bare
		-- name that never received a suffix.
		if node.group then
			result = of(ctx, node.group)
		elseif node.callee then
			result = ctx.typeOfName(node.callee, node.start)
		else
			result = types.mutable()
		end
	elseif kind == "binary" then
		result = types.binaryResult(node.op or "", of(ctx, node.left), of(ctx, node.right))
	elseif kind == "unary" then
		result = types.unaryResult(node.op or "not", of(ctx, node.operand))
	elseif kind == "ternary" then
		result = types.combine(of(ctx, node.right), of(ctx, node.alternative))
	elseif kind == "index" then
		-- A field read goes through the analyzer when it has a hook: a condition on `config.name`
		-- narrows it for what follows, until something could have changed it.
		local base = of(ctx, node.target)
		local target = node.target and ctx.parser.nodes[node.target]
		local baseName = node.isDynamic ~= true and target and target.callee or nil
		result = node.isDynamic ~= true and stringFieldOf(ctx, base, node.field, node.start)
			or ctx.typeOfField and ctx.typeOfField(base, baseName, node.field, node.start)
			or types.indexResult(base, node.field)
	elseif kind == "call" then
		-- `require("a.b")` is the module that file returns: asking the caller for it is what turns a
		-- path into a type, and the caller is whoever can read the file.
		-- A C type named by a string is known before the program runs: `ffi.new("Vec")` is a Vec
		-- whose members came from the `ffi.cdef` in the same file, so the constructor is typed
		-- rather than a bare cdata.
		if ctx.ctypes then
			local held = ctx.ctypes(node)
			if held then
				ctx.cache[idx] = held
				return held
			end
		end
		if node.callee == "require" and ctx.modules then
			local argument = node.args and node.args[1] and ctx.parser.nodes[node.args[1]]
			if argument and argument.kind == "string" and type(argument.value) == "string" then
				local held = ctx.modules(argument.value)
				if held then
					ctx.cache[idx] = held
					return held
				end
			end
		end
		-- `assert(x)` hands back `x`, and by returning it has said that `x` was neither nil nor
		-- false. `local found = assert(source:find(...))` is how Lua writes "this is there", so
		-- reading the call as an optional `number` made the next line a mistake the `assert` had
		-- already ruled out.
		if node.callee == "assert" and node.args and node.args[1] then
			local held = of(ctx, node.args[1])
			result = types.narrowTruthiness(held, true) or held
			ctx.cache[idx] = result
			return result
		end

		-- A call yields what its callee returns, whether that came from an annotation or from the
		-- callee's own body. While that is still unknown the answer is a mutable unknown, so the
		-- refinement pass can fill it in rather than this being cached as settled.
		-- A result the generic pass worked out from the arguments beats anything inferred by name.
		local bound = ctx.callTypes[node.index]
		local calleeType = not bound and infer.calleeTypeOf(ctx, node)
		if bound then
			result = bound
		elseif calleeType and types.isAnyFn(calleeType) then
			-- A callable that says nothing about itself — a bare `function`, or one whose own type
			-- has not been worked out yet — returns nothing this round can name. A mutable unknown
			-- says exactly that, and the second round replaces it once the callee is known.
			result = types.mutable()
		elseif calleeType and types.isFn(calleeType) then
			-- A signature with parameters of its own — `fn<T>(x: T) -> T` — binds them from the
			-- arguments of this call, so a string gives a string and a number a number.
			if calleeType.generics and next(calleeType.generics) then
				local bindings = {}
				for index, argIdx in ipairs(node.args or {}) do
					local wanted = calleeType.params[index]
					local actual = of(ctx, argIdx)
					if wanted and actual then
						infer.bind(wanted, actual, calleeType.generics, bindings)
					end
				end
				result = types.substitute(calleeType.returns, bindings)
			else
				result = calleeType.returns
			end
		else
			result = ctx.returns[node.callee or ""] or types.mutable()
		end
	else
		result = types.mutable()
	end

	ctx.cache[idx] = result
	return result
end

---@param parser lye.parser.Result
---@param typeOfName fun(name: string, offset: integer): lye.doc.Type
---@param returns table<string, lye.doc.Type>?
---@return lye.infer.Context
function infer.context(parser, typeOfName, returns, typeOfField, modules, ctypes)
	return {
		parser = parser, typeOfName = typeOfName, returns = returns or {}, typeOfField = typeOfField, cache = {}, fnTypes = {},
		callTypes = {},
		callValues = {},
		building = {},
		modules = modules,
		ctypes = ctypes,
	}
end

--- The type of the expression at an arena index.
---@param ctx lye.infer.Context
---@param idx integer?
---@return lye.doc.Type
function infer.at(ctx, idx)
	return of(ctx, idx)
end

--- The values an expression gives where several are wanted. Lua asks this of the last expression
--- of an assignment and of every expression of a `return`: `local a, b = f()` takes both from `f`,
--- and a literal gives its one value and nothing after it. A call whose values are not known answers
--- `unknown` rather than nil, so a callee that returns several values for a reason this round has
--- not worked out yet is not reported as returning nothing.
---@param ctx lye.infer.Context
---@param idx integer?
---@param position integer which value is wanted, 1 for the first
---@return lye.doc.Type
function infer.valuesAt(ctx, idx, position)
	if position <= 1 then return of(ctx, idx) end
	local node = idx and ctx.parser.nodes[idx]
	if not node or node.kind ~= "call" then return types.NIL_TYPE end
	-- What this very call gives back, when the analyzer worked it out from something the signature
	-- cannot know — a pattern written at the call site, most of all.
	local callValues = ctx.callValues[node.index]
	if callValues then return callValues[position] or types.NIL_TYPE end
	-- A pattern written at the call is read here rather than left to a later pass: a name is typed
	-- the first time round, and a value that only arrives in the second never reaches it.
	if node.args then
		-- The field a dotted call is written with is on the node it targets — `string.find(s, p)`
		-- is an index of `string` — and only a method call carries it itself.
		local target = node.target and ctx.parser.nodes[node.target]
		local field = node.field or (target and target.field)
		local subject = field and field:match("([%w_]+)$")
		local at = subject and pattern.CALLS[subject] and node.args[node.isMethod and 1 or 2]
		local literal = at and ctx.parser.nodes[at]
		if literal and literal.kind == "string" and type(literal.value) == "string" then
			local values = pattern.values(subject, literal.value)
			if values and values[position] then return values[position] end
		end
	end
	local calleeType = infer.calleeTypeOf(ctx, node)
	if calleeType and types.isFn(calleeType) then
		-- Several values written down: `---@return A, B` gives A first and B second, and a body
		-- that returns two values is read the same way. A name of the signature's own binds from
		-- this call, so the second value is as substituted as the first.
		if calleeType.values then
			local value = calleeType.values[position]
			if not value then return types.NIL_TYPE end
			if calleeType.generics and next(calleeType.generics) then
				local bindings = {}
				for index, argIdx in ipairs(node.args or {}) do
					local wanted = calleeType.params[index]
					local actual = of(ctx, argIdx)
					if wanted and actual then
						infer.bind(wanted, actual, calleeType.generics, bindings)
					end
				end
				return types.substitute(value, bindings)
			end
			return value
		end
		-- `---@return T...` gives every value after the ones it names, so there is no end to reach:
		-- what the call itself was bound to is what the second name is too.
		if calleeType.isSpread then return ctx.callTypes[node.index] or of(ctx, idx) end
	end
	return types.UNKNOWN_TYPE
end

--- The type a call's callee holds. A plain call names one; a method call names none, and calls
--- the field its target carries, which is where the signature is.
---@param ctx lye.infer.Context
---@param node lye.parser.Node
---@return lye.doc.Type?
function infer.calleeTypeOf(ctx, node)
	-- What is being called: an index node for `math.floor(...)`, the object for a method call, and
	-- the name itself for a plain call. The target is asked first because `math.floor(...)` has a
	-- callee of `math`, which is the class and not the function.
	if node.target then
		local targetType = of(ctx, node.target)
		if node.field then
			return stringFieldOf(ctx, targetType, node.field, node.start)
				or types.indexResult(targetType, node.field)
		end
		if types.isFn(targetType) then return targetType end
		-- A table with a `__call` metamethod can be called: Lua runs the metamethod, with the
		-- table itself as its first argument.
		local callable = types.metamethod(targetType, "__call")
		if callable then return callable end
	end
	return node.callee and ctx.typeOfName(node.callee, node.start) or nil
end

--- Match a written type against the type of the argument it was given, recording what each
--- generic name holds. This is what turns `---@param item T` and `id(5)` into `T = number`.
---@param pattern lye.doc.Type the parameter's type, as written
---@param actual lye.doc.Type the argument's type
---@param generics table<string, boolean> the names the function declares
---@param bindings table<string, lye.doc.Type> what has been learned, filled in place
function infer.bind(pattern, actual, generics, bindings)
	if not pattern or not actual then return end
	if pattern.variant == "union" then
		-- `---@param metatable? T` writes the type variable as one member of a union. A member
		-- that already accepts the argument decides it, and only when none does is the variable
		-- read from the argument, so `string|T` given a string leaves T alone.
		local variable
		for _, member in ipairs(pattern.types) do
			if member.variant == "extern" and generics[member.name] ~= nil then
				variable = variable or member
			elseif types.satisfies(actual, member) then
				return
			end
		end
		if variable then infer.bind(variable, actual, generics, bindings) end
		return
	end
	if pattern.variant == "extern" and generics[pattern.name] ~= nil then
		-- The first argument to say what T is decides it; a later one that disagrees is ignored
		-- rather than turned into a union, which would claim more than was proven.
		if not bindings[pattern.name] then bindings[pattern.name] = actual end
		return
	end
	if pattern.variant == "array" and actual.variant == "array" then
		return infer.bind(pattern.type, actual.type, generics, bindings)
	end
	if pattern.variant ~= "object" then return end
	if actual.variant == "object" then
		for name, field in pairs(pattern.fields) do
			if actual.fields[name] then infer.bind(field, actual.fields[name], generics, bindings) end
		end
	end
	if pattern.indexed then
		-- A list of T matches an array, and a table that carries an index signature.
		if actual.variant == "array" then
			infer.bind(pattern.indexed.type, actual.type, generics, bindings)
		elseif actual.variant == "object" and actual.indexed then
			infer.bind(pattern.indexed.type, actual.indexed.type, generics, bindings)
		end
	end
end

--- Whether typing reached a verdict for this node, which is what refinement waits on.
---@param ctx lye.infer.Context
---@param idx integer
function infer.isResolved(ctx, idx)
	local cached = ctx.cache[idx]
	return cached ~= nil and cached.variant ~= "unknown"
end

--- Promote anything still unknown that a known type now contradicts. A mutable unknown is a
--- promise that a later pass may learn more, so this is where that promise is kept.
---@param ctx lye.infer.Context
---@param returns table<string, lye.doc.Type>
function infer.refine(ctx, returns)
	for _, node in ipairs(ctx.parser.nodes) do
		local cached = ctx.cache[node.index]
		if cached and types.isMutable(cached) then
			-- Every call, not only the ones that name their callee: a method call is filled in the
			-- same way, and leaving it out cached its result as unknown for good.
			if node.kind == "call" then
				-- An annotated return, or one the callee's own body has now settled.
				local known = node.callee and returns[node.callee]
				local calleeType = infer.calleeTypeOf(ctx, node)
				if calleeType and types.isFn(calleeType) and not types.isAnyFn(calleeType) then
					known = calleeType.returns
				end
				if known then types.promote(cached, known) end
			else
				-- Anything else is a function of what it is built from: `local x = p.x` read the
				-- field while `p` was still unknown, so it is worked out again now that the names
				-- it reads have settled. Children come first in the arena, so a parent sees them.
				ctx.cache[node.index] = nil
				local fresh = of(ctx, node.index)
				if types.isMutable(cached) then
					if fresh.variant ~= "unknown" then types.promote(cached, fresh) end
					ctx.cache[node.index] = cached
				else
					-- The placeholder settled while the pass ran, from another reader of the same
					-- value: this read is the one just worked out, which may be narrower — a
					-- `dir` under `if dir then` is a string, and keeping the settled placeholder
					-- here would throw that narrowing away.
					ctx.cache[node.index] = fresh
				end
			end
		elseif cached and node.kind == "table" and cached.variant == "object" then
			-- A field read while the value it read was unsettled was cached without the narrowing
			-- the conditions around it ask for: `{ archive = dir }` under `if dir then` kept a
			-- `string?` even after `dir` settled. Each field is read again, into the same table so
			-- everything else written to it stays.
			local values = ctx.parser.tableFieldValues and ctx.parser.tableFieldValues[node.index]
			if values then
				for name, valueIdx in pairs(values) do
					ctx.cache[valueIdx] = nil
					local fresh = of(ctx, valueIdx)
					if fresh and fresh.variant ~= "unknown" then cached.fields[name] = fresh end
				end
			end
		end
	end
end

infer.KNOWN = KNOWN

return infer
