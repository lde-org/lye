--[[
	What every variable holds, worked out from the arena.

	The pass runs twice: a call may be typed before its callee's return is known, so a mutable unknown
	stands in and is promoted in place.
]]

local types = require("lye-doc.type")
local infer = require("lye-analyzer.infer")
local names = require("lye-analyzer.names")
local annotations = require("lye-analyzer.annotations")
local callName = names.callName
local kindToType = annotations.kindToType
local pattern = require("lye-doc.pattern")
local withGenerics = annotations.withGenerics

--- Everything the rounds share, built by `analyzer.analyze` after the signatures are known.
---@class lye.analyzer.TypingContext
---@field parsed lye.parser.Result
---@field self lye.analyzer.Result
---@field inferCtx table the memoising context `infer` reads
---@field signatures table<string, lye.analyzer.Signature>
---@field returns table<string, lye.doc.Type>
---@field resolve fun(text: string): lye.doc.Type?
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
	---@param index integer
	---@return lye.doc.Type[] values
	function typing.inferredValuesOf(ctx, index)
	local parsed = ctx.parsed
	local inferCtx = ctx.inferCtx
	local returnsOf = ctx.returnsOf
		local values = {}
		local body = parsed.nodes[index].body
		if body then
			local held = infer.at(inferCtx, body)
			if held then values[1] = held end
		end
		for _, statement in ipairs(returnsOf[index] or {}) do
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
	---@param index integer
	---@return lye.doc.Type?
	function typing.inferredReturnOf(ctx, index)
		return typing.inferredValuesOf(ctx, index)[1]
	end

	--- What a generic `for` gives its *second* name: `for key, value in pairs(map)`, `for index,
	--- item in ipairs(list)`. The iterator's own type carries the first name and nothing about the
	--- second — `ipairs` is written as returning a function of `V[]` — so the table it walks is
	--- asked instead, which is what makes `for _, name in ipairs(names)` a string.
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

	--- Type every variable from the arena. Run until it settles: a call can be met before
	--- its callee's `@return` is known, which leaves a mutable unknown for `refine` to
	--- promote in place, so one pass is not enough on its own.
	---@param ctx lye.typing.Context
	---@param only table<lye.analyzer.Variable, boolean>? the names a later pass has to read again
	function typing.typeAll(ctx, only)
	local parsed, self = ctx.parsed, ctx.self
	local inferCtx, signatures = ctx.inferCtx, ctx.signatures
	local returns, resolve = ctx.returns, ctx.resolve
	local fieldReturns, loopOf = ctx.fieldReturns, ctx.loopOf
	local signatureOfCall = ctx.signatureOfCall
	local bodyOwner, annotatedBodies = ctx.bodyOwner, ctx.annotatedBodies
	local signatureOfDecl = ctx.signatureOfDecl
	local checkMetatable = ctx.checkMetatable
		-- A loop declares its own control variables: a numeric `for` counts, and a generic `for` takes its
		-- first name from what the iterator yields. The pass runs twice, so the slot is claimed either way.
			local claimed = {}
		for _, variable in ipairs(self.variables) do
			local node = variable.qualifier == "loop" and loopOf(variable)
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
						local signature = node and node.kind == "call" and node.callee
							and signatures[node.callee]
						local returned = signature and signature.returns and signature.returns.type
						if returned and returned:sub(-3) == "..." then
							settled = inferCtx.callTypes[node.index] or settled
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
					local signature = node and node.kind == "call" and node.callee
						and signatures[node.callee]
					local returned = signature and signature.returns and signature.returns.type
					if returned and returned:sub(-3) == "..." then
						variable.initializer = inferCtx.callTypes[node.index] or variable.initializer
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
		for index, fnType in pairs(inferCtx.fnTypes) do
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
					local message = types.mismatch(promise, inferred, "the result")
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
			-- same contradiction as one that gives the wrong type.
			local promised = fieldReturns[index]
			-- A field that says nothing about a return promises nothing: only a written one can be
			-- contradicted by a body that returns nothing.
			local written = promised and promised ~= types.VOID and promised.variant ~= "unknown"
				and promised.variant ~= "any"
			if written and not inferred then
				self.diagnostics[#self.diagnostics + 1] = {
					message = string.format("the type says this returns %s, but nothing is returned",
						types.display(promised)),
					severity = 1,
					start = parsed.nodes[index].start, stop = parsed.nodes[index].stop,
				}
			end
		end
			-- Generic names are bound from the arguments before the results are read, so `id(5)` is
		-- number and `unpack(t)` is whatever `t` holds.
		for _, node in ipairs(parsed.nodes) do
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
						infer.bind(types.parse(wanted.type, resolve), infer.at(inferCtx, argIdx),
							signature.generics, bindings)
					end
				end
				if returned then
					local bare = returned:sub(-3) == "..." and (returned:sub(1, -4):gsub("%s+$", "")) or returned
					-- A binding from the arguments beats the name's own limit, which is what is
					-- left when nothing was bound: `math.max(1, 2)` is a number either way.
					local fallback = withGenerics(signature.generics, signature.constraints, resolve)
					local bound = types.parse(bare, function(text)
						if bindings[text] then return bindings[text] end
						return fallback(text)
					end)
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
			-- `local a, b = unpack(list)` gives every name the spread's type. The model links one
		-- value to a statement, so the names after the first would otherwise have none.
		local spreads = {}
		for _, declaration in ipairs(parsed.declarations) do
			local node = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
			local signature = node and node.kind == "call" and node.callee and signatures[node.callee]
			local returned = signature and signature.returns
			if declaration.anchorIdx and returned and returned.type and returned.type:sub(-3) == "..." then
				spreads[declaration.anchorIdx] = inferCtx.callTypes[node.index]
			end
		end
		for _, variable in ipairs(self.variables) do
			local declaration = variable.declaration
			local spread = declaration.anchorIdx and spreads[declaration.anchorIdx]
			if spread and not declaration.valueIdx then variable.initializer = spread end
		end
			infer.refine(inferCtx, returns)
	end

return typing
