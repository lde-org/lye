--[[
	What every variable holds, worked out from the arena.

	The pass runs twice: a call may be typed before its callee's return is known, so a mutable unknown
	stands in and is promoted in place.
]]

local types = require("lye-doc.type")
local memo = require("lye-analyzer.memo")
local infer = require("lye-analyzer.infer")
local annotations = require("lye-analyzer.annotations")
local kindToType = annotations.kindToType
local pattern = require("lye-doc.pattern")
local withGenerics = annotations.withGenerics

--- Everything the rounds share, built by `analyzer.analyze` after the signatures are known.
---@class lye.analyzer.TypingContext
---@field parsed lye.parser.Result
---@field self lye.analyzer.Result
---@field inferCtx lye.infer.Context the memoising context `infer` reads
---@field signatures table<string, lye.analyzer.Signature>
---@field returns table<string, lye.doc.Type>
---@field resolve fun(text: string): lye.doc.Type?
---@field typeOfText fun(text: string): lye.doc.Type? a written type, parsed once per document
---@field fieldReturns table<lye.doc.Type, lye.doc.Type>
---@field loopOf fun(variable: lye.analyzer.Variable): lye.parser.Node?
---@field signatureOfCall fun(node: lye.parser.Node): lye.doc.Type?
---@field returnsOf table<integer, lye.parser.Node[]> the `return`s of each body, by node index
---@field bodyOwner table<lye.parser.Node, lye.parser.Declaration> the declaration each body implements
---@field annotatedBodies table<integer, boolean> the bodies whose declaration was annotated
---@field signatureOfDecl table<integer, lye.doc.Type> the signature each declaration was read as

local typing = {}


	--- What a function's body gives back, value by value: the first is the union of the first value
	--- of each of its `return`s, the second of their second values, and so on. `return found, args`
	--- gives two, and a caller writing `local a, b = find(x)` gets both — reading only the first left
	--- every second name in a project unknown. The typing rounds work this out for the functions
	--- they walk, and a callback written straight into an argument is not one of those: its result
	--- crosses back into C, so the same question is asked of it here.
	---@param ctx lye.analyzer.TypingContext
	---@param index integer
	---@return lye.doc.Type[] values
	function typing.inferredValuesOf(ctx, index)
	local parsed = ctx.parsed
	local inferCtx = ctx.inferCtx
	local returnsOf = ctx.returnsOf
		local values = {}
		local statements = returnsOf[index] or {}
		local body = parsed.nodes[index].body
		-- The body's own value is only a fallback for a function written as an expression. Once
		-- the body has `return` statements, their values are the answer: the block's type is the
		-- last statement, which for `local function inner…; return inner` is the unknown the
		-- declaration was being worked out from, and that would absorb every value returned.
		if body and #statements == 0 then
			local held = infer.at(inferCtx, body)
			if held then values[1] = held end
		end
		for _, statement in ipairs(statements) do
			for position, valueIdx in ipairs(statement.children or {}) do
				local valueType = infer.at(inferCtx, valueIdx)
				if valueType then
					-- A union, not a combination: the value at this position is one of what the
					-- body returns there, so a `return decoded` whose type is not known yet leaves
					-- the position unknown rather than reading as the nil of the `return nil` above
					-- it — `decodeJson` returns a table or says why not, and only the "why not" was
					-- ever seen.
					values[position] = values[position]
						and types.union({ values[position], valueType }) or valueType
				end
			end
		end
		return values
	end

	--- The first of them, which is what a call in an expression is worth.
	---@param ctx lye.analyzer.TypingContext
	---@param index integer
	---@return lye.doc.Type?
	function typing.inferredReturnOf(ctx, index)
		return typing.inferredValuesOf(ctx, index)[1]
	end


	--- What an unannotated parameter is, from what the body does with it and what callers hand
	--- it. Lua is written without parameter annotations most of the time, and a solver that
	--- leaves every such name `any` reports the body's own arithmetic and every caller's
	--- argument. The two questions are complementary: the body says `x + 1` needs a number, and
	--- the callers say what they pass. Where neither says anything the parameter stays `any`,
	--- and the report is against the use rather than an invented type.
	---@param ctx lye.analyzer.TypingContext
	---@param only table<lye.analyzer.Variable, boolean>?
	---@param reused fun(start: integer, stop: integer): boolean?
	---@return boolean changed
	function typing.inferParameters(ctx, only, reused)
		local parsed, self, inferCtx = ctx.parsed, ctx.self, ctx.inferCtx
		local lookupIn, scopeAt = ctx.lookupIn, ctx.scopeAt
		if not lookupIn or not scopeAt then return false end
		local changed = false

		-- A name read before the parameter's type was learned is cached as `any`; the node has to
		-- be read again or the body keeps the type the first pass invented for it. The names are
		-- collected and cleared in one walk: a parameter handed a dozen arguments would otherwise
		-- walk the arena once per argument.
		local forgotten = {}
		local function forget(name) forgotten[name] = true end

		--- A literal handed to a parameter says the family it belongs to, not one value a dozen
		--- call sites would union into: `f(1); f(2)` makes the parameter a number.
		---@param held lye.doc.Type
		---@return lye.doc.Type
		local function widen(held)
			if held.variant == "number" and held.value ~= nil then return types.NUMBER end
			if held.variant == "boolean" and held.value ~= nil then return types.BOOLEAN end
			if held.variant == "extern" and type(held.name) == "string" then
				local first, last = held.name:sub(1, 1), held.name:sub(-1)
				if (first == '"' or first == "'") and last == first then return types.STRING end
			end
			return held
		end

		---@param held lye.doc.Type
		---@return boolean
		local function simpleType(held)
			if held.variant == "number" or held.variant == "string" or held.variant == "boolean"
				or held.variant == "nil" or held.variant == "never" then
				return true
			end
			if held.variant == "union" then
				for _, member in ipairs(held.types) do
					if not simpleType(member) then return false end
				end
				return true
			end
			return false
		end

		---@param held lye.doc.Type
		local function offer(held)
			if not held or types.isOpaque(held) or types.isMutable(held) then return nil end
			return held
		end

		---@param node lye.parser.Node
		---@param name string
		---@param functionNode lye.parser.Node
		---@return lye.doc.Type?
		local function fromBody(node, name, functionNode)
			local held
			if node.kind == "binary" then
				local left = parsed.nodes[node.left]
				local right = parsed.nodes[node.right]
				local isOperand = (left and left.callee == name) or (right and right.callee == name)
				if not isOperand then return nil end
				local op = node.op or ""
				if op == "+" or op == "-" or op == "*" or op == "/" or op == "%" or op == "^"
					or op == "&" or op == "|" or op == "~" or op == "<<" or op == ">>" or op == "~>>" then
					held = types.NUMBER
				elseif op == ".." then
					held = types.union({ types.STRING, types.NUMBER })
				elseif op == "<" or op == "<=" or op == ">" or op == ">=" then
					held = types.NUMBER
				end
			elseif node.kind == "unary" then
				local operand = parsed.nodes[node.operand]
				if operand and operand.callee == name and (node.op == "-" or node.op == "~") then
					held = types.NUMBER
				elseif operand and operand.callee == name and node.op == "#" then
					held = types.union({ types.STRING, types.TABLE })
				end
			elseif node.kind == "index" then
				local target = parsed.nodes[node.target]
				if target and target.callee == name then
					-- `param.field` says the parameter is a table, but not what the field holds.
					held = nil
				end
			elseif node.kind == "call" then
				local target = parsed.nodes[node.target]
				if target and target.callee == name and not node.field then
					held = types.FUNCTION
				end
			end
			return held
		end

		-- What callers pass. A call written to the declaration's own name gives the parameter the
		-- argument at its position; a receiver written with `:` leaves the first parameter alone.
		for _, node in ipairs(parsed.byKind and parsed.byKind.call or {}) do
			if not (reused and reused(node.start, node.stop)) and node.callee then
				local variable = lookupIn(scopeAt(self, node.start), node.callee, node.start)
				local bodyIdx = variable and variable.declaration.valueIdx
				local body = bodyIdx and parsed.nodes[bodyIdx]
				if body and body.kind == "function" and body ~= node then
					local params = body.params or {}
					local shift = node.isMethod and 1 or 0
					for index, argIdx in ipairs(node.args or {}) do
						local param = params[index + shift]
						local target = param and self.byStart[param.start]
						local actual = target and infer.at(inferCtx, argIdx)
						actual = offer(actual)
						if target and actual and not target.declaredExplicit
							and (only == nil or only[target]) then
							local held = target.declared
							if not held or held.variant == "any" or types.isMutable(held) then
								if held ~= actual then changed = true end
								target.declared = widen(actual)
								target.pending = true
								forget(target.name)
							elseif simpleType(held) and simpleType(actual) then
								actual = widen(actual)
								-- A union of what callers pass is useful for numbers and strings and
								-- explosive for two classes: the first class a parameter is handed
								-- is its type, and a later argument is checked against it.
								local combined = types.combine(held, actual)
								if types.display(combined) ~= types.display(held) then
									target.declared = combined
									target.pending = true
									changed = true
									forget(target.name)
								end
							end
						end
					end
				end
			end
		end

		-- What the body does with a parameter no caller named: a local helper called through a
		-- field, or a function only handed to a callback signature this pass did not reach.
		for _, variable in ipairs(self.variables) do
			if variable.qualifier == "param" and not variable.declaredExplicit
				and (only == nil or only[variable]) then
				local owner = variable.declaration and self.byStart[variable.declaration.start]
				-- The function that declares the parameter is the one whose span holds it and
				-- whose own parameters include it.
				local functionNode
				for _, node in ipairs(parsed.byKind and parsed.byKind["function"] or {}) do
					for _, param in ipairs(node.params or {}) do
						if param == variable.declaration then functionNode = node break end
					end
					if functionNode then break end
				end
				if functionNode then
					local held
					for _, node in ipairs(parsed.nodes) do
						if node.start >= functionNode.start and node.stop <= functionNode.stop then
							local found = fromBody(node, variable.name, functionNode)
							if found then held = held and types.combine(held, found) or found end
						end
					end
					if held and not variable.declaredExplicit then
						if variable.declared.variant == "any" or types.isMutable(variable.declared)
							or variable.declared.variant == "unknown" then
							variable.declared = held
							variable.pending = true
							changed = true
							forget(variable.name)
						end
					end
				end
			end
		end
		if next(forgotten) then
			for _, node in ipairs(parsed.nodes) do
				if node.callee and forgotten[node.callee]
					or (node.kind == "name" and forgotten[node.name]) then
					inferCtx.cache[node.index] = nil
				end
			end
		end
		-- The callable a function stands for keeps the parameters this pass learned, so a call
		-- through a name sees `fn(number)`, not the `fn(any)` the body was typed with.
		for _, node in ipairs(parsed.byKind and parsed.byKind["function"] or {}) do
			local declaration = ctx.bodyOwner and ctx.bodyOwner[node.index]
			local method = declaration and declaration.name:find(":", 1, true)
			local fnType = inferCtx.fnTypes[node.index]
			if fnType and fnType.params and not method then
				local params = {}
				for index, param in ipairs(node.params or {}) do
					local variable = self.byStart[param.start]
					params[index] = (variable and variable.declared) or types.ANY_TYPE
				end
				fnType.params = params
				-- A read of the function's name cached the callable before its parameters were
				-- inferred; reading it again is what gives the returned callable its shape.
				local name = declaration and declaration.name
				if name then
					for _, read in ipairs(parsed.nodes) do
						if read.callee == name or (read.kind == "name" and read.name == name) then
							inferCtx.cache[read.index] = nil
						end
					end
				end
			end
		end
		return changed
	end


	--- What a generic `for` gives its *second* name: `for key, value in pairs(map)`, `for index,
	--- item in ipairs(list)`. The iterator's own type carries the first name and nothing about the
	--- second — `ipairs` is written as returning a function of `V[]` — so the table it walks is
	--- asked instead, which is what makes `for _, name in ipairs(names)` a string.
	---@param ctx lye.analyzer.TypingContext
	---@param node lye.parser.Node
	---@return lye.doc.Type?
	function typing.iteratedValueOf(ctx, node)
	local parsed = ctx.parsed
	local inferCtx = ctx.inferCtx
		local iterator = node.children and node.children[1]
		local call = iterator and parsed.nodes[iterator]
		if not call or call.kind ~= "call" or not call.callee then return nil end
		if call.callee ~= "ipairs" and call.callee ~= "pairs" and call.callee ~= "next" then return nil end
		local walked = call.args and call.args[1] and infer.at(inferCtx, call.args[1])
		if not walked then return nil end
		-- A list or an index signature says what it holds; a table of named fields is what `pairs`
		-- walks, and its values are what the second name gets.
		local held = types.indexResult(walked, nil)
		if held and held.variant ~= "unknown" and held.variant ~= "any" then return held end
		if walked.variant == "object" and next(walked.fields) then
			local union
			for _, field in pairs(walked.fields) do
				union = union and types.combine(union, field) or field
			end
			return union
		end
	end

	--- Whether a value may still be settled by another pass: a placeholder nothing filled in, a
	--- type nothing is known about, and the permissive `any` an unannotated `@return` gives. All
	--- three are read before what they depend on was typed, and all three can change.
	---@param held lye.doc.Type
	---@return boolean
	local function unsettled(held)
		return types.isMutable(held) or held.variant == "unknown" or held.variant == "any"
	end

	--- Whether a function was written with a body at all.
	---
	--- A definition file declares the library it describes as `function file:close() end`: the
	--- annotations are the whole of the function, so there is no body that could contradict them.
	--- The parser holds a body's statements as nodes of their own rather than as something the
	--- function answers for, so what says a body was written is a node inside the function's own
	--- span — a parameter is a token, not a node, which is what leaves an empty declaration with
	--- nothing in it. The span is also how a `return` was placed in the function that owns it, and
	--- what is asked here is the same question one step earlier.
	---@param parsed lye.parser.Result
	---@param index integer
	---@return boolean
	local function hasBody(parsed, index)
		local fn = parsed.nodes[index]
		for _, node in ipairs(parsed.nodes) do
			-- A node inside the span is a statement of the body, a nested function, or the body
			-- of an arrow, which is the expression itself.
			if node.index ~= index and node.start >= fn.start and node.stop <= fn.stop then
				return true
			end
		end
		return false
	end

	--- Type every variable from the arena. Run until it settles: a call can be met before
	--- its callee's `@return` is known, which leaves a mutable unknown for `refine` to
	--- promote in place, so one pass is not enough on its own.
	---@param ctx lye.analyzer.TypingContext
	---@param only table<lye.analyzer.Variable, boolean>? the names a later pass has to read again
	---@param reused fun(start: integer, stop: integer): boolean? whether a span belongs to an item
	--- whose cached result is being reused — its nodes are not typed and its diagnostics are copied
	function typing.typeAll(ctx, only, reused)
	local parsed, self = ctx.parsed, ctx.self
	local inferCtx, signatures = ctx.inferCtx, ctx.signatures
	-- Every function body has a callable before the walk asks for one. Inference makes these
	-- lazily, and a callback written straight into a call may only be reached at a point after
	-- the loop over bodies, which left its result `any` for every check that read the call.
	for _, node in ipairs(parsed.byKind and parsed.byKind["function"] or {}) do
		local called = inferCtx.fnTypes[node.index]
		if not called then
			called = types.fn({}, types.mutable(), node.isVariadic == true)
			inferCtx.fnTypes[node.index] = called
		end
		if not called.paramsFilled then
			local params = {}
			for _, param in ipairs(node.params or {}) do
				local variable = self.byStart[param.start]
				params[#params + 1] = (variable and variable.declared) or types.ANY_TYPE
			end
			called.params = params
			called.paramsFilled = true
		end
		called.isVariadic = node.isVariadic == true
	end
	local returns, resolve = ctx.returns, ctx.resolve
	local fieldReturns, loopOf = ctx.fieldReturns, ctx.loopOf
	local signatureOfCall = ctx.signatureOfCall
	local bodyOwner, annotatedBodies = ctx.bodyOwner, ctx.annotatedBodies
	local signatureOfDecl = ctx.signatureOfDecl
	-- What a function's `...` holds, where its declaration said. Every `...` node inside the body
	-- is that type, so `select(i, ...)` and `{ ... }` stop being a use of an unknown value.
	local varargTypes = {}
	for index, declaration in pairs(bodyOwner) do
		local signature = signatureOfDecl[declaration]
		for _, annotation in ipairs(signature and signature.params or {}) do
			if annotation.name == "..." and annotation.type then
				local resolved = memo.parse(annotation.type,
					withGenerics(signature.generics, signature.constraints, resolve, true))
				if resolved then varargTypes[index] = resolved end
				break
			end
		end
	end
	for _, node in ipairs(parsed.byKind and parsed.byKind.literal or {}) do
		if node.text == "..." then
			local owner
			for _, body in ipairs(parsed.byKind and parsed.byKind["function"] or {}) do
				if body.start <= node.start and body.stop >= node.stop
					and (not owner or body.start > owner.start) then
					owner = body
				end
			end
			if owner and varargTypes[owner.index] then
				inferCtx.varargAt[node.index] = varargTypes[owner.index]
			end
		end
	end
	local checkMetatable = ctx.checkMetatable
	-- A written type, read once per document where the analysis gave a cache for it: a context
	-- built by hand — a test's — has none, and parses as it always did.
	---@param text string
	---@return lye.doc.Type?
	local function parseOne(text) return memo.parse(text, resolve) end
	local parseType = ctx.typeOfText or parseOne

	--- A node that reads `name` through any number of field accesses. When a variable's type is
	--- replaced after a later pass bound a generic, every read of it cached the old answer.
	---@param name string
	---@param idx integer?
	---@return boolean
	local function readsName(name, idx)
		local node = idx and parsed.nodes[idx]
		if not node then return false end
		if (node.kind == "prefix" and node.callee == name)
			or (node.kind == "name" and node.name == name) then
			return true
		end
		return node.target ~= nil and readsName(name, node.target)
	end

	-- A value after the first from a signature that names several. A local's callable already
	-- carries them, but a definition file's function is reached by name and its signature values
	-- are the only record of the second and later results.
	---@param signature lye.analyzer.Signature
	---@param node lye.parser.Node
	---@param position integer
	---@return lye.doc.Type?
	local function signatureValue(signature, node, position)
		local written = signature.values and signature.values[position]
		if not written then return nil end
		local generics = signature.generics
		if not generics or not next(generics) then return parseType(written) end
		local bindings = {}
		for index, argIdx in ipairs(node.args or {}) do
			local wanted = signature.params[index]
			local actual = infer.at(inferCtx, argIdx)
			if wanted and wanted.type and actual then
				infer.bind(parseType(wanted.type), actual, generics, bindings)
			end
		end
		local fallback = withGenerics(generics, signature.constraints, resolve)
		return types.parse(written, function(text) return bindings[text] or fallback(text) end)
	end

	-- The resolver a generic return is read with at a call: the bindings from that call's
	-- arguments first, the signature's own limits behind them. The state is what the loop sets,
	-- so the function is made once rather than per call site — a closure made in the loop stops
	-- the loop from compiling.
	local bindingsNow, fallbackNow
	local function boundResolver(text)
		local held = bindingsNow and bindingsNow[text]
		if held then return held end
		return fallbackNow and fallbackNow(text) or nil
	end
		-- A loop declares its own control variables: a numeric `for` counts, and a generic `for` takes its
		-- first name from what the iterator yields. The pass runs twice, so the slot is claimed either way.
			local claimed = {}
		for _, variable in ipairs(self.variables) do
			local node = variable.qualifier == "loop"
				and not (reused and reused(variable.start, variable.stop or variable.start))
				and loopOf(variable)
			-- Two names are typed: the first takes the iterator's value, the second what the table it walks
			-- holds. A third is left alone, because Lua's `for` makes no promise about it.
			if node and (claimed[node.index] or 0) < 2 then
				local position = (claimed[node.index] or 0) + 1
				claimed[node.index] = position
				if not variable.declared then
					if node.isNumeric then
						variable.declared = types.NUMBER
					elseif position == 1 then
						local first = node.children and node.children[1]
						local held = first and infer.at(inferCtx, first)
						if held and types.isFn(held) then variable.declared = held.returns end
					else
						variable.declared = typing.iteratedValueOf(ctx, node)
					end
				end
			end
		end

			-- Assignments are typed before initializers, and both re-run to the fixpoint, so
		-- `local y = x` sees what `x` was assigned above it rather than what it started as.
		for _, variable in ipairs(self.variables) do
			-- A standard library constant is not this document's to type, and a later pass reads
			-- again only the names the pass before it left unsettled.
			if not variable.isPrelude and (only == nil or only[variable]) then
				local declaration = variable.declaration
				-- The initializer of a name the explicit list did not reach is the value at its position in what
				-- the last expression gives: `local a, b = find(x)` takes the second value of `find`.
				local initialPosition = declaration.valuePosition or 1
				for _, assignment in ipairs(variable.assignments) do
					local position = assignment.valueIdx == declaration.valueIdx
						and initialPosition or (assignment.valuePosition or 1)
					local settled = infer.valuesAt(inferCtx, assignment.valueIdx, position)
					-- `---@return T...` gives every value after the ones it names, so there is no
					-- end to reach: what this call was bound to is what its second name takes too.
					if position > 1 and assignment.valueIdx then
						local node = parsed.nodes[assignment.valueIdx]
						local signature = node and node.kind == "call" and signatureOfCall(node)
						local returned = signature and signature.returns and signature.returns.type
						if returned and returned:sub(-3) == "..." then
							settled = inferCtx.callTypes[node.index] or settled
						end
						if signature and (not settled or types.isMutable(settled) or settled.variant == "unknown") then
							settled = signatureValue(signature, node, position) or settled
						end
					end
					-- The placeholder an assignment started as is shared with everything that read the variable before
					-- it was typed. Filling it in where the answer arrives keeps those reads from staying unknown.
					if types.isMutable(assignment.type) and settled then types.promote(assignment.type, settled) end
					assignment.type = settled
					-- What a later pass is for: this value was read before what it depends on was
					-- known — a callee written below, a `@return` not yet read — and only the names
					-- holding one of those have to be read again.
					if settled and unsettled(settled) then
						variable.pending = true
						ctx.pending = true
					end
				end
				local position = declaration.valuePosition or 1
				variable.initializer = declaration.valueIdx
					and infer.valuesAt(inferCtx, declaration.valueIdx, position)
					or kindToType(declaration.initializer)
				-- A spread gives every value after the ones it names, so the second name of
				-- `local a, b = unpack(list)` is what the call was bound to as much as the first.
				if position > 1 and declaration.valueIdx then
					local node = parsed.nodes[declaration.valueIdx]
					local signature = node and node.kind == "call" and signatureOfCall(node)
					local returned = signature and signature.returns and signature.returns.type
					if returned and returned:sub(-3) == "..." then
						variable.initializer = inferCtx.callTypes[node.index] or variable.initializer
					end
					if signature and (not variable.initializer or types.isMutable(variable.initializer)
						or variable.initializer.variant == "unknown") then
						variable.initializer = signatureValue(signature, node, position) or variable.initializer
					end
				end
				-- A declared type says what the value is, and the initializer may say what Lua
				-- consults about it: `---@type Box local b = setmetatable({}, mt)` keeps both.
				if variable.initializer and unsettled(variable.initializer) then
					variable.pending = true
					ctx.pending = true
				end
				local metatable = types.metatableOf(variable.initializer)
				if metatable and variable.declared and not types.metatableOf(variable.declared) then
					variable.declared = types.withMetatable(variable.declared, metatable)
				end
			end
		end
			-- What a function returns is read off its body: the union of every value it returns, or nil when it
		-- returns nothing. Annotations are left alone, so a `@return` can be compared later.
		-- Innermost function bodies first: `inner` returns the value `outer` hands back, and a
		-- body read before the one it declares saw the unknown the declaration started as.
		local functionIndexes = {}
		for index in pairs(inferCtx.fnTypes) do functionIndexes[#functionIndexes + 1] = index end
		table.sort(functionIndexes, function(left, right)
			local a, b = parsed.nodes[left], parsed.nodes[right]
			local spanA = (a and a.stop or 0) - (a and a.start or 0)
			local spanB = (b and b.stop or 0) - (b and b.start or 0)
			if spanA ~= spanB then return spanA < spanB end
			return left < right
		end)
		for _, index in ipairs(functionIndexes) do
			local fnType = inferCtx.fnTypes[index]
			local body = parsed.nodes[index]
			if body and reused and reused(body.start, body.stop) then
				-- The cached callable already carries what this body returned; its dependents were
				-- seeded with it, and re-deriving it would walk a body nobody changed.
				goto continue_fn
			end
			local values = typing.inferredValuesOf(ctx, index)
			local inferred = values[1]
			if inferred then
				fnType.returns = inferred
				fnType.values = values
				-- A declaration that named its parameters but not its return takes the inferred
				-- one. `@return`, where it is written, still wins.
				local declaration = bodyOwner[index]
				local signature = declaration and signatureOfDecl[declaration]
				local variable = declaration and self.byStart[declaration.start]
				if signature and not signature.returns and variable and variable.declared then
					-- In place, so a call typed before this round reads the return the body turned
					-- out to have rather than the unknown it was given.
					if types.isFn(variable.declared) then
						types.promote(variable.declared.returns, inferred)
						variable.declared.values = values
					end
				end
				-- A field promised its callers a result, and the body written for it has to give that: compared
				-- against what the function turned out to be, once the body is typed.
				local promise = fieldReturns[index]
				if promise then
					local message = types.strictMismatch(promise, inferred, "the result")
					if message then
						self.diagnostics[#self.diagnostics + 1] = {
							message = message, severity = 1,
							start = parsed.nodes[index].start, stop = parsed.nodes[index].stop,
						}
					end
				end
			elseif not annotatedBodies[index] then
				-- No returns at all, or a bare `return`, means the caller gets nil. A declaration
				-- that says what it returns is left alone: a stub has not contradicted it yet.
				fnType.returns = types.VOID
			end
			-- The field promised its callers a result, and a body that gives none at all is the
			-- same contradiction as one that gives the wrong type. A function written with no body
			-- — a definition file's `function file:close() end` — promises nothing yet, the way
			-- an annotated `local function g() end` is left alone above: there is nothing there to
			-- contradict the annotation, and only a body that exists can be held to it.
			local promised = fieldReturns[index]
			-- A field that says nothing about a return promises nothing: only a written one can be
			-- contradicted by a body that returns nothing.
			local written = promised and promised ~= types.VOID and promised.variant ~= "unknown"
				and promised.variant ~= "any"
			if written and not inferred and not self.isDefinition and hasBody(parsed, index) then
				self.diagnostics[#self.diagnostics + 1] = {
					message = string.format("the type says this returns %s, but nothing is returned",
						types.display(promised)),
					severity = 1,
					start = parsed.nodes[index].start, stop = parsed.nodes[index].stop,
				}
			end
			::continue_fn::
		end
			-- Generic names are bound from the arguments before the results are read, so `id(5)` is
		-- number and `unpack(t)` is whatever `t` holds.
		for _, node in ipairs(parsed.nodes) do
			if not (reused and reused(node.start, node.stop)) then
			local signature = node.kind == "call" and signatureOfCall(node)
			-- A metatable is a relationship of the value it is set on rather than a replacement for its type,
			-- but a class used as one is how a Lua object is written, so `setmetatable({}, Point)` is a `Point`.
			if node.kind == "call" and node.args then
				-- `s:find("%d+")` gives positions and `s:match` gives captures, and a pattern anchored at both
				-- ends cannot fail. The pattern is written at the call, which is what makes this knowable.
				-- The field the call reads is what `subject` was, taken straight rather than written out
				-- with its owner: building `string.find` to throw the owner away was a string per call.
				local target = node.target and parsed.nodes[node.target]
				local subject = node.field or (target and target.field)
				local argument = pattern.CALLS[subject or ""]
				local patternIdx = argument and node.args[node.isMethod and 1 or 2]
				local literal = patternIdx and parsed.nodes[patternIdx]
				if literal and literal.kind == "string" and type(literal.value) == "string" then
					local values = pattern.values(subject, literal.value)
					if values then
						local cached = inferCtx.cache[node.index]
						if cached and types.isMutable(cached) then types.promote(cached, values[1]) end
						inferCtx.callValues[node.index] = values
						inferCtx.callTypes[node.index] = values[1]
						inferCtx.cache[node.index] = nil
					end
				end
			end
			-- A method declared on a generic class carries variables of its own — `Box<T>` whose
			-- `map` is `---@generic U` — and the call binds those from the arguments the same way
			-- a named generic function binds its own. The first pass read the callback before its
			-- body was typed; this is where the result is bound again once the body settled.
			if node.kind == "call" then
				local signature, calleeType = signatureOfCall(node)
				if not signature and calleeType and calleeType.generics and next(calleeType.generics) then
					local bindings = {}
					-- A method's own parameters leave the receiver out; a plain library
					-- function written `gsub(s, pattern, …)` keeps it in first. Arity decides.
					local shift = (#calleeType.params == #(node.args or {}) + 1) and 1 or 0
					for index, argIdx in ipairs(node.args or {}) do
						local wanted = calleeType.params[index + shift]
						local actual = infer.at(inferCtx, argIdx)
						if wanted and actual then
							infer.bind(wanted, actual, calleeType.generics, bindings)
						end
					end
					if next(bindings) then
						local bound = types.substitute(calleeType.returns, bindings)
						local cached = inferCtx.cache[node.index]
						if bound and (not cached or types.display(cached) ~= types.display(bound)) then
							inferCtx.callTypes[node.index] = bound
							inferCtx.cache[node.index] = nil
							for _, variable in ipairs(self.variables) do
								if variable.declaration.valueIdx == node.index
									and (variable.declaration.valuePosition or 1) == 1 then
									variable.initializer = bound
									variable.pending = true
									ctx.callsChanged = true
									for _, read in ipairs(parsed.nodes) do
										if readsName(variable.name, read.index) then
											inferCtx.cache[read.index] = nil
										end
									end
								end
							end
						end
					end
				end
			end
			if node.kind == "call" and node.callee == "setmetatable" and node.args then
				local held = infer.at(inferCtx, node.args[1])
				local metatable = infer.at(inferCtx, node.args[2])
				checkMetatable(self, parsed, metatable, held, node.args[2])
				local base = held and metatable and (metatable.variant == "class" and metatable or held)
				local bound = base and types.withMetatable(base, metatable)
				if bound then
					local cached = inferCtx.cache[node.index]
					if cached and types.isMutable(cached) then types.promote(cached, bound) end
					inferCtx.callTypes[node.index] = bound
					inferCtx.cache[node.index] = nil
				end
			elseif signature and signature.generics and next(signature.generics) then
				local returned = signature.returns and signature.returns.type
				local bindings = {}
				for index, argIdx in ipairs(node.args or {}) do
					local wanted = signature.params[index]
					if wanted and wanted.type then
						infer.bind(parseType(wanted.type), infer.at(inferCtx, argIdx),
							signature.generics, bindings)
					end
				end
				if returned then
					local bare = returned:sub(-3) == "..." and (returned:sub(1, -4):gsub("%s+$", "")) or returned
					-- A binding from the arguments beats the name's own limit, which is what is
					-- left when nothing was bound: `math.max(1, 2)` is a number either way.
					local fallback = withGenerics(signature.generics, signature.constraints, resolve)
					bindingsNow, fallbackNow = bindings, fallback
					local bound = types.parse(bare, boundResolver)
					bindingsNow, fallbackNow = nil, nil
					-- What was cached before the binding was known has to be recomputed.
					if bound then
						local cached = inferCtx.cache[node.index]
						if cached and types.isMutable(cached) then types.promote(cached, bound) end
						inferCtx.callTypes[node.index] = bound
						inferCtx.cache[node.index] = nil
					end
				end
			end
			end
		end
			-- `local a, b = unpack(list)` gives every name the spread's type. The model links one
		-- value to a statement, so the names after the first would otherwise have none.
		local spreads = {}
		for _, declaration in ipairs(parsed.declarations) do
			if not (reused and reused(declaration.start, declaration.stop or declaration.start)) then
			local node = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
			local signature = node and node.kind == "call" and node.callee and signatures[node.callee]
			local returned = signature and signature.returns
			if declaration.anchorIdx and returned and returned.type and returned.type:sub(-3) == "..." then
				spreads[declaration.anchorIdx] = inferCtx.callTypes[node.index]
			end
			end
		end
		for _, variable in ipairs(self.variables) do
			local declaration = variable.declaration
			local spread = declaration.anchorIdx and spreads[declaration.anchorIdx]
			if spread and not declaration.valueIdx then variable.initializer = spread end
		end
			infer.refine(inferCtx, returns)
			-- A call typed before its callee's body settled still holds the unknown the first
			-- pass cached, while the callable now names a result. Rebind those calls, and let the
			-- caller type the declarations reading them once more.
			for _, node in ipairs(parsed.byKind and parsed.byKind.call or {}) do
				local cached = inferCtx.cache[node.index]
				if cached and (types.isMutable(cached) or cached.variant == "unknown") then
					local calleeType = infer.calleeTypeOf(inferCtx, node)
					local known = inferCtx.callTypes[node.index]
						or (calleeType and types.isFn(calleeType) and calleeType.returns)
					if known and known.variant ~= "unknown" and not types.isMutable(known) then
						inferCtx.cache[node.index] = known
						ctx.callsChanged = true
						for _, variable in ipairs(self.variables) do
							if variable.declaration.valueIdx == node.index
								and (variable.declaration.valuePosition or 1) == 1 then
								variable.initializer = known
								variable.pending = true
							end
						end
					end
				end
			end
	end

	--- The callback a call expects is the body it is written with. A function literal passed
	--- straight to `table.sort`, `string.gsub`, `pcall` or a project's own signature has
	--- parameters the signature already names, and every `function(a, b)` written for one would
	--- otherwise be `any`: `a < b` and `c:upper()` would be uses of a value nothing is known
	--- about. The literal's unannotated parameters take the expected types, and the callable the
	--- literal stands for keeps them, so a later check reads the same signature the call did.
	--- Runs after the first typing pass, because the argument a variable is written as — the
	--- element type of `list` — has to be known before `T` can be bound to it. Returns whether
	--- anything changed, so the caller can type the bodies again.
	---@param ctx lye.analyzer.TypingContext
	---@param only table<lye.analyzer.Variable, boolean>?
	---@param reused fun(start: integer, stop: integer): boolean?
	---@return boolean changed
	function typing.contextualize(ctx, only, reused)
		local parsed, self, inferCtx, resolve = ctx.parsed, ctx.self, ctx.inferCtx, ctx.resolve
		local changed = false

		--- The callable member of an expected type: many callbacks are written optional, and a
		--- union says the same signature as the member that is there.
		---@param expected lye.doc.Type?
		---@return lye.doc.Type?
		local function callableOf(expected)
			if not expected then return nil end
			if expected.variant == "fn" then return expected end
			if expected.variant == "union" then
				for _, member in ipairs(expected.types) do
					if member.variant == "fn" then return member end
				end
			end
		end

		---@param fnNode lye.parser.Node
		---@param expected lye.doc.Type
		local function apply(fnNode, expected)
			local fnType = inferCtx.fnTypes[fnNode.index]
				or infer.at(inferCtx, fnNode.index)
			if not fnType or fnType.variant ~= "fn" then return end
			local params = {}
			for index, param in ipairs(fnNode.params or {}) do
				local variable = self.byStart[param.start]
				local wanted = expected.params[index]
				if not wanted and expected.isVariadic then wanted = expected.variadic end
				if variable and wanted and not variable.declaredExplicit then
					if variable.declared ~= wanted then changed = true end
					variable.declared = wanted
					variable.pending = true
				end
				params[index] = (variable and variable.declared) or types.ANY_TYPE
			end
			fnType.params = params
			fnType.variadic = expected.variadic
			fnType.isVariadic = fnNode.isVariadic == true
		end

		-- A function written as a result is typed by the result the enclosing declaration
		-- promised: `---@return fun(text: string)` over `return function(text) … end` gives
		-- `text` its string even though no call hands the literal its signature.
		for _, node in ipairs(parsed.byKind and parsed.byKind["return"] or {}) do
			local valueIdx = node.children and node.children[1]
			local value = valueIdx and parsed.nodes[valueIdx]
			if value and value.kind == "function" and not (reused and reused(value.start, value.stop)) then
				local owner
				for _, fn in ipairs(parsed.byKind and parsed.byKind["function"] or {}) do
					if fn.start <= node.start and fn.stop >= node.stop
						and (not owner or fn.start > owner.start) then
						owner = fn
					end
				end
				local fnType = owner and inferCtx.fnTypes[owner.index]
				local expected = fnType and callableOf(fnType.returns)
				if expected then apply(value, expected) end
			end
		end

		for _, node in ipairs(parsed.byKind and parsed.byKind.call or {}) do
			if not (reused and reused(node.start, node.stop)) then
				-- Only a call that has a function body written into it has anything to type here.
				-- Walking every call for a callback that is not there was most of a full check.
				local hasBody = false
				for _, argIdx in ipairs(node.args or {}) do
					local argument = parsed.nodes[argIdx]
					if argument and argument.kind == "function" then
						hasBody = true
						break
					end
				end
				if not hasBody then goto continue_call end
				local calleeType = infer.calleeTypeOf(inferCtx, node)
				if calleeType and types.isFn(calleeType) then
					local params = calleeType.params or {}
					-- A receiver written with `:` occupies the first parameter when the callable
					-- is a plain function (`s:gsub(pattern, repl)` is `string.gsub(s, pattern,
					-- repl)`); a method declared on a class already leaves it out.
					local shift = 0
					if node.isMethod then
						local receiver = node.target and infer.at(inferCtx, node.target)
						local first = params[1]
						if first and receiver and types.satisfies(receiver, first) then shift = 1 end
					end
					local bindings = {}
					if calleeType.generics and next(calleeType.generics) then
						for index, argIdx in ipairs(node.args or {}) do
							local wanted = params[index + shift] or calleeType.variadic
							local actual = infer.at(inferCtx, argIdx)
							if wanted and actual then
								infer.bind(wanted, actual, calleeType.generics, bindings)
							end
						end
					end
					for index, argIdx in ipairs(node.args or {}) do
						local argument = parsed.nodes[argIdx]
						if argument and argument.kind == "function" then
							local wanted = params[index + shift]
							if not wanted and calleeType.isVariadic and index + shift > #params then
								wanted = calleeType.variadic
							end
							if wanted and next(bindings) then
								wanted = types.substitute(wanted, bindings)
							end
							local expected = callableOf(wanted)
							if expected then apply(argument, expected) end
						end
					end
				end
				::continue_call::
			end
		end
		return changed
	end

return typing
