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
---@field mutables integer[] the nodes whose cached type is a placeholder still, in cache order
---@field fnTypes table<integer, lye.doc.Type> one callable per function node, filled from its body
---@field callTypes table<integer, lye.doc.Type> what a generic call was bound to, by node
---@field callValues table<integer, lye.doc.Type[]> every value a call gives, when more than its signature says
---@field building table<integer, boolean> the nodes being typed now, so a self-reach ends
---@field modules fun(name: string): lye.doc.Type? what `require("name")` is, when the caller can say
---@field ctypes fun(node: lye.parser.Node): lye.doc.Type? what a call naming a C type is worth
---@field varargAt table<integer, lye.doc.Type> the `...` type of each literal `...`, by node index
---@field narrowed table<integer, boolean>? the reads narrowed while a condition was read
---@field casts table<integer, lye.doc.Type|{ exclude: lye.doc.Type }>? an inline cast written beside an expression, by node index

local KNOWN = {
	number = true, string = true, literal = true, table = true, ["function"] = true,
	call = true, binary = true, unary = true, ternary = true, index = true, name = true, prefix = true,
}

--- The type a literal kind stands for. The parser records what a table field holds as the kind
--- of the value, and only some of those kinds are types: a field holding a call or a sum is a
--- node whose type typing works out separately, so it stays unknown here.
---@param kind string
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
local function stringFieldOf(ctx, base, field, start)
	if not field or not ctx.typeOfName or not types.mayBe(base, "string") then return nil end
	local library = ctx.typeOfName("string", start)
	if not library then return nil end
	return types.fieldOf(library, field)
end

--- Whether a cached type is the narrowed shape of an unknown — the truthy or non-nil set — which
--- is not a placeholder itself, so promoting a placeholder never reaches it, even though it was
--- worked out from one.
---@param held lye.doc.Type
---@return boolean
local function narrowedUnknown(held)
	if held == types.truthyUnknown() or held == types.nonNilUnknown() then return true end
	if held.variant == "union" then
		for _, member in ipairs(held.types) do
			if member == types.truthyUnknown() or member == types.nonNilUnknown() then return true end
		end
	end
	return false
end

--- Remember where a placeholder was cached: refinement reads those nodes again, and a walk of
--- every node to find them costs more than the list does.
---@param ctx lye.infer.Context
---@param idx integer
---@param value lye.doc.Type
local function cache(ctx, idx, value)
	ctx.cache[idx] = value
	if value.isMutable then
		-- One entry per node: a placeholder is read again and again while it is unknown, and a
		-- list carrying every read made refinement walk the arena once per read.
		local seen = ctx.mutableSet
		if seen == nil then
			seen = {}
			ctx.mutableSet = seen
		end
		if not seen[idx] then
			seen[idx] = true
			local list = ctx.mutables
			list[#list + 1] = idx
		end
	elseif narrowedUnknown(value) then
		-- A narrowing of an unknown is not a placeholder, so promotion never revisits it: the
		-- list says which reads refinement has to make again once the name they narrow settled.
		local list = ctx.narrowed
		if list == nil then
			list = {}
			ctx.narrowed = list
		end
		list[idx] = true
	end
	return value
end

--- The identity of a value a type names exactly, or nil when it names a family. Used to match an
--- overload parameter written `"*a"` against the argument actually written: lye deliberately lets
--- any string satisfy a string literal, which is right for annotations and wrong for choosing
--- between overloads.
---@param type lye.doc.Type
---@return string?
local function literalKey(type)
	if type.variant == "number" and type.value ~= nil then return "n:" .. tostring(type.value) end
	if type.variant == "boolean" and type.value ~= nil then return "b:" .. tostring(type.value) end
	if type.variant == "extern" and type.name then
		local first, last = type.name:sub(1, 1), type.name:sub(-1)
		if (first == '"' or first == "'") and last == first then return "s:" .. type.name end
	end
end

--- Whether an argument cannot be the shape a chosen overload names.
---@param wanted lye.doc.Type
---@param actual lye.doc.Type
local function overloadMismatch(wanted, actual)
	if wanted.variant == "union" then
		for _, member in ipairs(wanted.types) do
			if not overloadMismatch(member, actual) then return nil end
		end
		return "argument"
	end
	local key = literalKey(wanted)
	if key then
		if literalKey(actual) == key then return nil end
		return "argument"
	end
	return types.mismatch(wanted, actual, "argument")
end

--- The argument's type as the call wrote it: a string literal is the one string it spells, which
--- is what an overload parameter names.
---@param ctx lye.infer.Context
---@param idx integer
---@param valueOf fun(ctx: lye.infer.Context, idx: integer): lye.doc.Type
local function argumentValue(ctx, idx, valueOf)
	local node = ctx.parser.nodes[idx]
	if node and node.kind == "string" then
		local value = node.value
		return types.stringValue(type(value) == "string" and value or "")
	end
	return valueOf(ctx, idx)
end

--- How exact a parameter is: a literal names one value, a union of literals names a few, and a
--- type names a family. The most specific shape a call fits is the one whose answer it gets.
---@param wanted lye.doc.Type
---@return integer
local function specificity(wanted)
	if literalKey(wanted) then return 2 end
	if wanted.variant == "union" then
		for _, member in ipairs(wanted.types) do
			if literalKey(member) then return 1 end
		end
	end
	return 0
end

--- The overload a call fits, when its callee carries overloads. A shape matches when the receiver
--- and every argument fit its parameters and it is not handed more values than it declares; the
--- most specific match decides the return, so `read("*a")` prefers the `"*a"` shape over a generic
--- `string` one.
---@param ctx lye.infer.Context
---@param node lye.parser.Node
---@param calleeType lye.doc.Type
---@param valueOf fun(ctx: lye.infer.Context, idx: integer): lye.doc.Type
---@return lye.doc.Type? shape
local function overloadOf(ctx, node, calleeType, valueOf)
	local shapes = calleeType.overloads
	if not shapes then return nil end
	local args = node.args or {}
	local receiver
	if node.isMethod and node.target then receiver = valueOf(ctx, node.target) end
	-- A method is only called on a value that is there, so an optional receiver is narrowed for
	-- the shape it is matched against.
	if receiver ~= nil then
		---@cast receiver lye.doc.Type
		receiver = types.narrowTruthiness(receiver, true) or receiver
	end

	local best, bestScore
	for _, shape in ipairs(shapes or {}) do
		local fits = true
		local shift = 0
		local score = 0
		if receiver ~= nil then
			---@cast receiver lye.doc.Type
			local wanted = shape.params[1]
			if wanted == nil then
				shift = 1
			elseif not overloadMismatch(wanted, receiver) then
				shift = 1
				score += specificity(wanted)
			else
				fits = false
			end
		end
		if fits then
			local count = #args + (receiver ~= nil and shape.params[1] ~= nil and 1 or 0)
			if not shape.variadic and count > #shape.params then fits = false end
		end
		if fits then
			for index, argIdx in ipairs(args) do
				local wanted = shape.params[index + shift]
				if not wanted and shape.variadic and index + shift > #shape.params then
					wanted = shape.variadic
				end
				if wanted ~= nil then
					---@cast wanted lye.doc.Type
					if overloadMismatch(wanted, argumentValue(ctx, argIdx, valueOf)) then
						fits = false
						break
					end
					score += specificity(wanted)
				end
			end
		end
		if fits and (not best or score > bestScore) then
			best, bestScore = shape, score
		end
	end
	return best
end

--- What an overload shape's generic variables are bound to at this call. It is the same walk a
--- generic primary signature uses, but the shape's parameter list is the one to match: `read("*a")`
--- and `pcall(f)` pick their own signatures' names.
---@param ctx lye.infer.Context
---@param node lye.parser.Node
---@param shape lye.doc.Type
---@param valueOf fun(ctx: lye.infer.Context, idx: integer): lye.doc.Type
---@return table<string, lye.doc.Type>
local function overloadBindings(ctx, node, shape, valueOf)
	local bindings = {}
	if not shape.generics or not next(shape.generics) then return bindings end
	for index, argIdx in ipairs(node.args or {}) do
		local wanted = shape.params[index]
		local actual = wanted and valueOf(ctx, argIdx)
		if wanted and actual then infer.bind(wanted, actual, shape.generics, bindings) end
	end
	return bindings
end

---@param ctx lye.infer.Context
---@param idx integer?
local function of(ctx, idx)
	if not idx then return types.mutable() end
	local cached = ctx.cache[idx]
	if cached then return cached end

	local node = ctx.parser.nodes[idx]
	if not node then return types.mutable() end

	-- A cast written beside the expression stands for it: `f --[[@as Vec]].x` reads `f` as a Vec,
	-- which is the only way to say what a value is where nothing declares it.
	local casts = ctx.casts
	local cast = casts and casts[idx]
	if casts ~= nil and cast ~= nil then
		---@cast cast lye.doc.Type|{ exclude: lye.doc.Type }
		local exclude = cast.exclude
		if exclude ~= nil then
			-- `x ---@cast x -T` keeps what the expression already was, without T. Read by asking
			-- for the expression's own type with the cast set aside, which is why it is removed
			-- for the call and put back after: asking again would find the cast and not end.
			casts[idx] = nil
			local held = of(ctx, idx)
			casts[idx] = cast
			cast = types.excludeType(held, exclude) or held
		end
		---@cast cast lye.doc.Type
		return cache(ctx, idx, cast)
	end

	local result
	local kind = node.kind

	if kind == "number" then
		-- A literal is the number it spells: `local n = 2149` is 2149, which fits `number`
		-- wherever a number is wanted and reads back as what was written.
		result = type(node.value) == "number" and types.numberValue(node.value, node.text) or types.NUMBER
	elseif kind == "string" then
		result = types.STRING
	elseif kind == "literal" then
		-- A boolean literal is the value it spells, the way a number literal is its number: that is
		-- what a discriminant is compared against when a tagged union is built in code.
		-- `...` is emitted as a literal too, and reading it as a boolean made every vararg the
		-- value `false`: `{ ... }` held `false`, the second name of `for _, v in ipairs({ ... })`
		-- was declared `false`, and every use of it was reported as a value that was not one.
		if node.text == "..." then
			result = (ctx.varargAt and ctx.varargAt[idx]) or types.ANY_TYPE
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
			if elementType ~= nil then
				---@cast elementType lye.doc.Type
				elementType = types.combine(elementType, one)
			else
				elementType = one
			end
		end

		local kinds = ctx.parser.tableFields[node.index]
		if not kinds then
			-- `{}` has no shape *yet*, and the shape it grows belongs to this literal alone: a
			-- module is written `local M = {}` and given its fields below, so the type cannot be
			-- the shared `table` every other literal would then be given fields on.
			if elementType ~= nil then
				---@cast elementType lye.doc.Type
				result = types.array(elementType)
			else
				result = types.object({})
			end
		else
			local values = ctx.parser.tableFieldValues[node.index]
			local fields = {}
			for name, fieldKind in pairs(kinds) do
				-- The value itself when the parser kept its node, so a field holding a name or a
				-- nested table is that type rather than the kind of thing it looked like.
				local valueIdx = values and values[name]
				if valueIdx ~= nil then
					---@cast valueIdx integer
					fields[name] = of(ctx, valueIdx)
				else
					fields[name] = literalType(fieldKind)
				end
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
		local field = node.field
		---@cast field string
		result = node.isDynamic ~= true and stringFieldOf(ctx, base, field, node.start)
			or ctx.typeOfField and ctx.typeOfField(base, baseName, field, node.start)
			or types.indexResult(base, field)
		-- A `?.` read of a value that may be nil is that value's field or nil: it does not fail,
		-- so the result is optional the way the access is.
		if node.isSafe then result = types.union({ result, types.NIL_TYPE }) end
	elseif kind == "call" then
		-- `require("a.b")` is the module that file returns: asking the caller for it is what turns a
		-- path into a type, and the caller is whoever can read the file.
		-- A C type named by a string is known before the program runs: `ffi.new("Vec")` is a Vec
		-- whose members came from the `ffi.cdef` in the same file, so the constructor is typed
		-- rather than a bare cdata.
		if ctx.ctypes then
			local held = ctx.ctypes(node)
			if held then
				-- A call whose result the analyzer worked out is also what a reader asks for at
				-- this node: `ffi.new("Vec").x` is read through the call, not through a variable.
				ctx.callTypes[node.index] = held
				return cache(ctx, idx, held)
			end
		end
		if node.callee == "require" and ctx.modules then
			local argument = node.args and node.args[1] and ctx.parser.nodes[node.args[1]]
			if argument and argument.kind == "string" and type(argument.value) == "string" then
				local held = ctx.modules(argument.value)
				if held then
					-- A completion or hover after `require("ffi")` asks the call node what it is,
					-- and `callTypes` is how the analyzer publishes that.
					ctx.callTypes[node.index] = held
					return cache(ctx, idx, held)
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
			return cache(ctx, idx, result)
		end

		-- `select("#", ...)` is how many values the rest of the call gave, and `select(n, ...)`
		-- is the nth of them: the language's own way of working with a tuple, which the type of
		-- `...` otherwise cannot express.
		if node.callee == "select" and node.args and node.args[1] then
			local first = ctx.parser.nodes[node.args[1]]
			if first and first.kind == "string" and first.value == "#" then
				result = types.NUMBER
				return cache(ctx, idx, result)
			end
			local index
			if first and first.kind == "number" and type(first.value) == "number" then
				index = first.value
			elseif first and first.kind == "unary" and first.op == "-" then
				local operand = first.operand and ctx.parser.nodes[first.operand]
				if operand and operand.kind == "number" and type(operand.value) == "number" then
					index = -operand.value
				end
			end
			if index then
				---@type integer?
				local source
				if index >= 1 then
					source = node.args[1 + index]
				else
					-- A negative index counts from the end of the values written after it. With
					-- `...` as the only one, the count is unknown and the varargs' own type is the
					-- answer; with explicit arguments the position is exact.
					local count = #node.args - 1
					local position = count + index + 1
					if position >= 1 then source = node.args[1 + position] end
				end
				if source ~= nil then
					---@cast source integer
					local sourceNode = ctx.parser.nodes[source]
					result = sourceNode and sourceNode.kind == "call"
						and infer.valuesAt(ctx, source, 1) or of(ctx, source)
				else
					result = types.NIL_TYPE
				end
				return cache(ctx, idx, result)
			end
			-- A computed index selects any of the values, so the second argument's own type is the
			-- honest answer; `select(i, ...)` in a generic loop reads the varargs' annotation.
			if node.args[2] then
				result = of(ctx, node.args[2])
				return cache(ctx, idx, result)
			end
		end

		-- `pcall` and `xpcall` hand back the function's own results when it succeeds, after the
		-- status. The definitions can only write `any` for the rest, and a caller then cannot use
		-- what it just called. Reading the callable's results here is what makes the common
		-- `local ok, value = pcall(decode, text)` usable.
		if (node.callee == "pcall" or node.callee == "xpcall") and node.args and node.args[1] then
			local called = of(ctx, node.args[1])
			if types.isFn(called) then
				-- The results after the status are read by `valuesAt` when they are wanted: the
				-- function's body may be typed after this call, and caching the answer here froze
				-- `local ok, value = pcall(f)` as an unknown value.
				result = types.BOOLEAN
				return cache(ctx, idx, result)
			end
		end

		-- A pattern call is typed from the pattern written at the call site: `s:match("(%d+)")`
		-- is a string, not the `any ...` the definitions can only write for a capture. The
		-- pattern module already knows the values; reading it here keeps a name bound to the
		-- call from staying `any` through every later use.
		if node.args then
			local target = node.target and ctx.parser.nodes[node.target]
			local field = node.field or (target and target.field)
			local subject = field and field:match("([%w_]+)$")
			local at = subject and pattern.CALLS[subject] and node.args[node.isMethod and 1 or 2]
			local literal = at and ctx.parser.nodes[at]
			if subject and literal and literal.kind == "string" and type(literal.value) == "string" then
				local values = pattern.values(subject, literal.value)
				if values then
					ctx.callValues[node.index] = values
					ctx.callTypes[node.index] = values[1]
					return cache(ctx, idx, values[1])
				end
			end
		end

		-- A call yields what its callee returns, whether that came from an annotation or from the
		-- callee's own body. While that is still unknown the answer is a mutable unknown, so the
		-- refinement pass can fill it in rather than this being cached as settled.
		-- A result the generic pass worked out from the arguments beats anything inferred by name.
		local bound = ctx.callTypes[node.index]
		local calleeType = not bound and infer.calleeTypeOf(ctx, node)
		local overload = calleeType and overloadOf(ctx, node, calleeType, of)
		if bound then
			result = bound
		elseif overload then
			-- The shape this call fits says what it gives back; the primary signature may only be
			-- able to say `any` because the arguments decide.
			result = overload.returns or types.ANY_TYPE
			local bindings = overloadBindings(ctx, node, overload, of)
			if next(bindings) then result = types.substitute(result, bindings) end
			ctx.callTypes[node.index] = result
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
		-- A guarded call — `f?.()`, `obj?.:method()` — gives nothing when the value is absent.
		if node.isSafe then result = types.union({ result, types.NIL_TYPE }) end
	else
		result = types.mutable()
	end

	return cache(ctx, idx, result)
end

---@param parser lye.parser.Result
---@param typeOfName fun(name: string, offset: integer): lye.doc.Type
---@param returns table<string, lye.doc.Type>?
---@param typeOfField fun(base: lye.doc.Type, baseName: string?, field: string, offset: integer): lye.doc.Type?
---@param modules fun(name: string): lye.doc.Type?
---@param ctypes fun(node: lye.parser.Node): lye.doc.Type?
---@return lye.infer.Context
function infer.context(parser, typeOfName, returns, typeOfField, modules, ctypes)
	return {
		parser = parser, typeOfName = typeOfName, returns = returns or {}, typeOfField = typeOfField,
		cache = {}, mutables = {}, narrowed = {}, fnTypes = {},
		callTypes = {},
		callValues = {},
		varargAt = {},
		building = {},
		modules = modules,
		ctypes = ctypes,
	}
end

--- The type of the expression at an arena index.
---@param ctx lye.infer.Context
---@param idx integer?
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
function infer.valuesAt(ctx, idx, position)
	if position <= 1 then return of(ctx, idx) end
	local node = idx and ctx.parser.nodes[idx]
	if not node or node.kind ~= "call" then return types.NIL_TYPE end
	-- What this very call gives back, when the analyzer worked it out from something the signature
	-- cannot know — a pattern written at the call site, most of all.
	local callValues = ctx.callValues[node.index]
	if callValues then return callValues[position] or types.NIL_TYPE end
	-- `pcall` and `xpcall` give the status and then what the function gave. The callable's own
	-- result is read here rather than only where the call was typed: the literal's body may have
	-- been typed after that.
	if (node.callee == "pcall" or node.callee == "xpcall") and position > 1 and node.args
		and node.args[1] then
		local called = of(ctx, node.args[1])
		if types.isFn(called) then
			local given = called.values or { called.returns }
			local value = given[position - 1]
			if not value and called.isSpread then value = called.returns end
			if value then return value end
		end
	end
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
		if subject and literal and literal.kind == "string" and type(literal.value) == "string" then
			local values = pattern.values(subject, literal.value)
			if values and values[position] then return values[position] end
		end
	end
	local calleeType = infer.calleeTypeOf(ctx, node)
	if calleeType and types.isFn(calleeType) then
		-- The chosen overload's own result list comes first: `pcall(f)`'s success shape is
		-- `boolean, T`, and T belongs to that shape rather than to the primary signature.
		local overload = overloadOf(ctx, node, calleeType, of)
		if overload and overload.values then
			local value = overload.values[position]
				or (overload.isSpread and overload.values[#overload.values])
			if value then
				local bindings = overloadBindings(ctx, node, overload, of)
				if next(bindings) then value = types.substitute(value, bindings) end
				return value
			end
		end
		-- Several values written down: `---@return A, B` gives A first and B second, and a body
		-- that returns two values is read the same way. A name of the signature's own binds from
		-- this call, so the second value is as substituted as the first.
		if calleeType.values then
			-- A spread gives every value after the last one it names, so a position past the list
			-- still has the type of that last value rather than nil.
			local value = calleeType.values[position]
				or (calleeType.isSpread and calleeType.values[#calleeType.values])
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
---@param pattern lye.doc.Type? the parameter's type, as written
---@param actual lye.doc.Type? the argument's type
---@param generics table<string, boolean> the names the function declares
---@param bindings table<string, lye.doc.Type> what has been learned, filled in place
function infer.bind(pattern, actual, generics, bindings)
	if not pattern or not actual then return end
	pattern = pattern --[[@as lye.doc.Type]]
	actual = actual --[[@as lye.doc.Type]]
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
		if variable ~= nil then
			---@cast variable lye.doc.Type
			infer.bind(variable, actual, generics, bindings)
		end
		return
	end
	if pattern.variant == "extern" and generics[pattern.name] ~= nil then
		-- The first argument to say what T is decides it; a later one that disagrees is ignored
		-- rather than turned into a union, which would claim more than was proven.
		if not bindings[pattern.name] then bindings[pattern.name] = actual end
		return
	end
	if pattern.variant == "array" then
		-- A list written `T[]` and one written `{ [integer]: T }` are the same shape, and a
		-- `table.sort(names, …)` argument is typed the second way by inference.
		if actual.variant == "array" then
			return infer.bind(pattern.type, actual.type, generics, bindings)
		elseif actual.variant == "object" and actual.indexed
			and (actual.indexed.key == "integer" or actual.indexed.key == "number") then
			return infer.bind(pattern.type, actual.indexed.type, generics, bindings)
		end
		return
	end
	if pattern.variant == "fn" and actual.variant == "fn" then
		for index, param in ipairs(pattern.params or {}) do
			if actual.params[index] then
				infer.bind(param, actual.params[index], generics, bindings)
			end
		end
		return infer.bind(pattern.returns, actual.returns, generics, bindings)
	end
	if pattern.variant ~= "object" then return end
	if actual.variant == "object" or actual.variant == "class" then
		for name, field in pairs(pattern.fields) do
			if actual.fields and actual.fields[name] then
				infer.bind(field, actual.fields[name], generics, bindings)
			end
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
	local parser = ctx.parser
	local mutables = ctx.mutables
	-- Only the nodes holding a placeholder are read again; every other node has an answer that
	-- cannot change. A table literal whose fields were read before the value settled is the other
	-- case, and table literals are a fraction of the nodes.
	local count = #mutables
	for at = 1, count do
		local node = parser.nodes[mutables[at]]
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
		end
	end

	-- `held and held.field` caches the truthy narrowing of the unknown while `held` was still a
	-- placeholder, and that narrowing is not itself a placeholder: the promotion never reaches it,
	-- and `self.doc and self.doc.annotations` kept an unknown element type long after `self.doc`
	-- settled. Only the reads recorded when they were cached are read again, in arena order so
	-- what a node was built from is fresh first.
	local narrowed = ctx.narrowed
	if narrowed ~= nil and next(narrowed) ~= nil then
		local order = {}
		for index in pairs(narrowed) do order[#order + 1] = index end
		table.sort(order)
		-- A read that is narrowed again from the settled names belongs to the next pass, not this
		-- one, so the list it lands in is a fresh one.
		ctx.narrowed = {}
		for _, index in ipairs(order) do
			local cached = ctx.cache[index]
			if cached and not types.isMutable(cached) and narrowedUnknown(cached) then
				ctx.cache[index] = nil
				of(ctx, index)
			end
		end
	end

	-- A field read while the value it read was unsettled was cached without the narrowing the
	-- conditions around it ask for: `{ archive = dir }` under `if dir then` kept a `string?` even
	-- after `dir` settled. Only a table holding one of those reads is worked out again; the rest
	-- of the table literals hold answers that cannot have changed.
	local tableFieldValues = parser.tableFieldValues
	if tableFieldValues ~= nil and next(tableFieldValues) ~= nil then
		-- Which table declares each node as one of its fields, indexed once per analysis.
		local owner = ctx.tableFieldOwner
		if owner == nil then
			owner = {}
			for tableIndex, values in pairs(tableFieldValues) do
				for _, valueIdx in pairs(values) do
					---@cast valueIdx integer
					owner[valueIdx] = tableIndex
				end
			end
			ctx.tableFieldOwner = owner
		end
		-- The tables whose values were built from a placeholder or a narrowing of one: walking
		-- each such node's parents marks the literals it is written into, however deeply.
		local stale = {}
		for index in pairs(ctx.narrowed or {}) do stale[index] = true end
		for position = 1, #mutables do stale[mutables[position]] = true end
		local tables = {}
		for index in pairs(stale) do
			local node = parser.nodes[index]
			while node ~= nil do
				local tableIndex = owner[node.index]
				if tableIndex ~= nil then tables[tableIndex] = true end
				node = node.parent and parser.nodes[node.parent]
			end
		end
		-- The children each dirty value is worked out from, indexed once: clearing the value node
		-- alone is not enough, `{ a = xs and xs[1] }` cached the narrowing of the placeholder for
		-- `xs` below it.
		local children = ctx.children
		if children == nil then
			children = {}
			for _, child in ipairs(parser.nodes) do
				local parent = child.parent
				if parent then
					local list = children[parent]
					if not list then
						list = {}
						children[parent] = list
					end
					list[#list + 1] = child.index
				end
			end
			ctx.children = children
		end
		for tableIndex in pairs(tables) do
			local node = parser.nodes[tableIndex]
			local cached = ctx.cache[tableIndex]
			if node ~= nil and cached and not types.isMutable(cached) and cached.variant == "object" then
				local values = tableFieldValues[tableIndex]
				if values then
					-- Clear only the descendants of the values that changed.
					local stack = {}
					for _, valueIdx in pairs(values) do stack[#stack + 1] = valueIdx end
					while #stack > 0 do
						local index = stack[#stack]
						stack[#stack] = nil
						ctx.cache[index] = nil
						for _, child in ipairs(children[index] or {}) do stack[#stack + 1] = child end
					end
					for name, valueIdx in pairs(values) do
						ctx.cache[valueIdx] = nil
						local fresh = of(ctx, valueIdx)
						if fresh and fresh.variant ~= "unknown" then cached.fields[name] = fresh end
					end
				end
			end
		end
	end
end

infer.KNOWN = KNOWN

return infer
