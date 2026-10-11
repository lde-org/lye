--[[
	What each condition asserts, and where that holds.

	A fact covers the region its guarded block covers, and is cut where something could have changed
	what it is about.
]]

local types = require("lye-doc.type")
local names = require("lye-analyzer.names")
local writtenNameOf, readSubject, readTypeSubject, callName =
	names.writtenNameOf, names.readSubject, names.readTypeSubject, names.callName

local CONJUNCTIONS = { ["and"] = true, ["&&"] = true }
local DISJUNCTIONS = { ["or"] = true, ["||"] = true }
local NEGATIONS = { ["not"] = true, ["!"] = true }

--- The narrowing a predicate asserts about a call's argument, and the parameter it names.
--- `v is T` narrows where the call's value is truthy; `v is -T` narrows to what is *not* a T,
--- which holds wherever the call returned at all.
---@param parsed lye.parser.Result
---@param node lye.parser.Node
---@param signature lye.analyzer.Signature
---@param predicate lye.analyzer.Predicate
---@return string? name
---@return string? field
---@return string kind
local function predicateSubject(parsed, node, signature, predicate)
	local target
	for index, annotation in ipairs(signature.params) do
		if annotation.name == predicate.param then target = index end
	end
	local argIdx = target and node.args and node.args[target]
	local name, field = argIdx and readSubject(parsed, argIdx)
	if not name then return nil end
	local isNil = predicate.type == "nil"
	if predicate.negated then return name, field, isNil and "notnil" or "nottype" end
	return name, field, isNil and "nil" or "type"
end

--- What a condition asserts, read from the arena. Only forms that say something definite are
--- recognised; anything else narrows nothing, which is safer than guessing.
---
--- `invert` says the assertion holds where the expression is *false*, which is how an `else`
--- and a `not` are read. Every shape below states its own inversion, so nothing else has to.
--- The value a comparison is about, when it is a name with one field on it. A fact carries a name
--- and a field, so `a.b.c` cannot be said with one: `readSubject` reads the first two and would
--- claim something false about `a.b`. Worse than losing the fact, that claim is a contradiction —
--- no member's `b` is the string compared against — and a contradiction throws away every narrowing
--- gathered before it, which is how a guard three lines up stopped holding.
---@param parsed lye.parser.Result
---@param idx integer?
---@return boolean
local function oneFieldOn(parsed, idx)
	local node = idx and parsed.nodes[idx]
	if not node or node.kind ~= "index" or not node.field or node.isDynamic then return false end
	local base = parsed.nodes[node.target]
	if not base then return false end
	return base.kind == "prefix" and (base.callee ~= nil or base.group ~= nil)
end

---@param parsed lye.parser.Result
---@param idx integer? arena index of the condition expression, absent when there is none
---@param invert boolean
---@param signatures table<string, lye.analyzer.Signature>
---@return lye.analyzer.Condition?
local function readCondition(parsed, idx, invert, signatures)
	local node = parsed.nodes[idx]
	if not node then return nil end

	if node.kind == "unary" and NEGATIONS[node.op] then
		return readCondition(parsed, node.operand, not invert, signatures)
	end

	-- `if isString(x) then`: a call whose declaration carries a predicate proves something about
	-- the argument it names. The negative form is read as a statement instead, since it holds
	-- wherever the call came back rather than only where its value is truthy.
	if node.kind == "call" and node.callee then
		local signature = signatures[node.callee]
		local predicate = signature and signature.predicates and signature.predicates[1]
		if not predicate or predicate.negated then return nil end
		local name, field, kind = predicateSubject(parsed, node, signature, predicate)
		if not name then return nil end
		local wanted = not invert
		if kind == "type" or kind == "nottype" then
			if not wanted then kind = kind == "type" and "nottype" or "type" end
		elseif not wanted then
			kind = kind == "nil" and "notnil" or "nil"
		end
		return {
			name = name, field = field, kind = kind, wantTruthy = wanted,
			typeName = predicate.type, type = predicate.parsed,
		}
	end

	if node.kind == "prefix" or node.kind == "index" then
		local name, field = readSubject(parsed, idx)
		if not name then return nil end
		return { name = name, field = field, kind = "truthy", wantTruthy = not invert }
	end

	if node.kind == "binary" then
		local op = node.op
		if op ~= "==" and op ~= "~=" and op ~= "!=" then return nil end
		local isEqual = op == "=="
		local left, right = parsed.nodes[node.left], parsed.nodes[node.right]

		-- `x == nil`, and `x ~= nil` where the negation flips which branch keeps what.
		local subjectIdx = left and left.kind == "literal" and left.text == "nil" and node.right or node.left
		local other = subjectIdx == node.left and right or left
		if other and other.kind == "literal" and other.text == "nil" then
			local name, field = readSubject(parsed, subjectIdx)
			if not name then return nil end
			local excludesNil = isEqual == invert
			return {
				name = name, field = field, kind = excludesNil and "notnil" or "nil",
				wantTruthy = excludesNil,
			}
		end

		-- `type(x) == "T"`: a call to `type` compared against a string literal.
		for _, pair in ipairs({ { node.left, right }, { node.right, left } }) do
			local callIdx, literal = pair[1], pair[2]
			local name, field = readTypeSubject(parsed, callIdx)
			if name and literal and literal.kind == "string" and literal.value then
				local wantsType = isEqual ~= invert
				return {
					name = name, field = field, kind = wantsType and "type" or "nottype",
					wantTruthy = wantsType, typeName = literal.value,
				}
			end
		end

		-- `x.kind == "fn"`: a field compared against a value, which is how a tagged union is read.
		-- `if type.variant ~= "fn" then return false end` says the rest of the block holds a `fn`,
		-- and what that rules out is every member that cannot hold the value.
		for _, pair in ipairs({ { node.left, right }, { node.right, left } }) do
			local subjectIdx, literal = pair[1], pair[2]
			if literal and subjectIdx and (literal.kind == "string" or literal.kind == "number")
				and oneFieldOn(parsed, subjectIdx) then
				local name, field = readSubject(parsed, subjectIdx)
				local source = parsed.source
				local text = source and literal.start and source:sub(literal.start, literal.stop) or nil
				local written = text and types.parse(text)
				if name and field and written then
						local wants = isEqual ~= invert
					return {
						name = name, field = field, kind = wants and "field" or "notfield",
						wantTruthy = wants, type = written,
					}
				end
			end
		end
	end
end

---@param parsed lye.parser.Result
---@param conditionIdx integer? arena index of the guarding expression
---@param invert boolean the assertions hold where the condition is false
---@param signatures table<string, lye.analyzer.Signature>
local function readConditions(parsed, conditionIdx, invert, signatures)
	local node = conditionIdx and parsed.nodes[conditionIdx]
	if not node then return {} end
	local op = node.kind == "binary" and node.op
	local isConjunction, isDisjunction = CONJUNCTIONS[op] == true, DISJUNCTIONS[op] == true
	if isConjunction or isDisjunction then
		-- Only one of the two keeps asserting the same operands once inverted.
		if invert ~= isDisjunction then return {} end
		local conditions = readConditions(parsed, node.left, invert, signatures)
		for _, condition in ipairs(readConditions(parsed, node.right, invert, signatures)) do
			conditions[#conditions + 1] = condition
		end
		return conditions
	end
	local condition = readCondition(parsed, conditionIdx, invert, signatures)
	if not condition then return {} end
	return { condition }
end

--- Every condition that narrows, from `if`, `while` and `repeat`.
---
--- A fact holds over the region its guarded block covers, so a construct nested inside that
--- block narrows further on top of what already holds: facts intersect by applying in turn,
--- outermost region first. A `while` condition holds throughout its body, since the body only
--- runs while it is true. A `repeat` condition is tested after the body, so it cannot hold on
--- the first pass; the inverse is asserted over the body instead, which a nil comparison makes
--- sound from the second pass on.
--- Facts are attached to the scope each condition guards, so typing walks outwards from where
--- a name is read and only ever sees the conditions that cover it.
---@param parsed lye.parser.Result
---@param byRecord table<lye.parser.Scope, lye.analyzer.Scope>
---@param signatures table<string, lye.analyzer.Signature>
---@param resolve fun(text: string): lye.doc.Type?
local function collectNarrowing(parsed, byRecord, signatures, resolve, annotations)
	local ordered = {}
	for _, scope in ipairs(parsed.scopes) do ordered[#ordered + 1] = scope end
	table.sort(ordered, function(a, b) return a.start < b.start end)

	--- The innermost scope holding an offset: the block a statement is written in.
	---@param offset integer
	---@return lye.parser.Scope?
	local function scopeAtOffset(offset)
		local low, high = 1, #ordered
		while low <= high do
			local mid = math.floor((low + high) / 2)
			if ordered[mid].start <= offset then low = mid + 1 else high = mid - 1 end
		end
		for index = high, 1, -1 do
			if ordered[index].stop >= offset then return ordered[index] end
		end
	end

	---@param condition lye.analyzer.Condition
	---@param record lye.parser.Scope
	---@param from integer? where the fact starts, which is the scope's own start by default
	---@param until_ integer? where it stops, which is the end of the scope by default
	-- Everything that could change a field between a condition and a read: a call, because the callee
	-- may hold the same table and a `__newindex` may run, and a write through the same name. Gathered
	-- once and sorted, so a fact finds the first one after it by bisection rather than by walking the
	-- arena — which is what made a file with many conditions cost the square of its size.
	-- A declared function that assigns to nothing, and calls only such functions, cannot change what
	-- a fact said — which is what makes `if type.isFn(t) then t.fields` readable across the call.
	---@type table<string, boolean>
	local pure = {}
	local function bodyOf(declaration)
		local node = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
		if not node then return nil end
		if node.kind == "function" then return node end
		if node.kind == "call" and node.args then
			local first = parsed.nodes[node.args[1]]
			if first and first.kind == "function" then return first end
		end
		return node.kind == "function" and node or nil
	end
	local declaredFunctions = {}
	for _, declaration in ipairs(parsed.declarations) do
		local body = declaration.isFunction and bodyOf(declaration)
		if declaration.name and body then declaredFunctions[declaration.name] = body end
	end

	-- A body holds the bodies declared inside it, so a statement marks every function it is written
	-- in, and asking that per function by walking the arena is the square of the file.
	---@type lye.analyzer.BodySpan[]
	local spans = {}
	---@type table<lye.parser.Node, lye.analyzer.BodySpan>
	local bodySpans = {}
	for name, body in pairs(declaredFunctions) do
		local span = bodySpans[body]
		if not span then
			span = { start = body.start, stop = body.stop, names = {}, calls = {}, writes = false, pure = true }
			bodySpans[body] = span
			spans[#spans + 1] = span
		end
		span.names[#span.names + 1] = name
	end
	table.sort(spans, function(left, right) return left.start < right.start end)
	local open = {}
	for index = 1, #spans do
		local span = spans[index]
		while #open > 0 and open[#open].stop < span.start do open[#open] = nil end
		span.parent = open[#open]
		open[#open + 1] = span
	end

	--- The innermost declared function a node is written in: the last span to start before it is
	--- either that one or a finished sibling, so its parents are the only other candidates.
	---@param node lye.parser.Node
	---@return lye.analyzer.BodySpan?
	local function holderOf(node)
		local low, high = 1, #spans
		while low <= high do
			local mid = math.floor((low + high) / 2)
			if spans[mid].start <= node.start then low = mid + 1 else high = mid - 1 end
		end
		local span = spans[high]
		while span and span.stop < node.stop do span = span.parent end
		return span
	end

	-- Assigning anything at all is enough to make a function not a reader, and a call is only allowed
	-- when it is to another reader: `types.isFn(type)` is written with the field on the node it
	-- targets, so the whole name is asked for rather than the receiver's.
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "assignment" or node.kind == "call" then
			local called = node.kind == "call" and callName(parsed, node) or nil
			local span = holderOf(node)
			while span do
				if node.kind == "assignment" then
					span.writes = true
				else
					span.calls[#span.calls + 1] = called
				end
				span = span.parent
			end
		end
	end

	---@type table<string, lye.analyzer.BodySpan>
	local spanByName = {}
	for index = 1, #spans do
		local span = spans[index]
		for _, name in ipairs(span.names) do spanByName[name] = span end
	end
	for _ = 1, 4 do
		local changed = false
		for index = 1, #spans do
			local span = spans[index]
			if span.pure then
				if span.writes then
					span.pure = false
					changed = true
				else
					for _, called in ipairs(span.calls) do
						local target = called and spanByName[called]
						if not (target and target.pure) then
							span.pure = false
							changed = true
							break
						end
					end
				end
			end
		end
		if not changed then break end
	end
	for index = 1, #spans do
		local span = spans[index]
		for _, name in ipairs(span.names) do pure[name] = span.pure end
	end

	---@type { start: integer, stop: integer, name: string, field: string?, kind: string }[]
	local interfering = {}
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "call" then
			-- What a call can change is what it is handed. `touch(config)` may write `config`, while
			-- `pairs(config.fields)` is handed the map rather than the record and cannot change
			-- which record it is — and treating every call as a disturbance made each guard useless
			-- in the code that reads type tables, which is exactly this shape. A call to a function
			-- that only reads is left out entirely, handed anything or not. What a callee reaches
			-- through a global or an upvalue is beyond this, which is the assumption every Lua tool
			-- of this kind makes rather than refusing to narrow anything at all.
			if not pure[callName(parsed, node) or ""] then
				for _, argIdx in ipairs(node.args or {}) do
					local arg = parsed.nodes[argIdx]
					if arg and arg.kind == "prefix" and arg.callee then
						interfering[#interfering + 1] = {
							start = node.start, stop = node.stop, name = arg.callee, kind = "hand",
						}
					elseif arg and arg.kind == "index" and arg.field and not arg.isDynamic then
						local base = writtenNameOf(parsed, arg.target)
						if base then
							interfering[#interfering + 1] = {
								start = node.start, stop = node.stop, name = base, field = arg.field,
								kind = "hand",
							}
						end
					end
				end
			end
		elseif node.kind == "assignment" and node.target then
			local target = parsed.nodes[node.target]
			local base = target
			local field
			if target and target.field then
				base = parsed.nodes[target.target]
				field = target.field
			end
			local name = base and (base.callee or base.name) or nil
			if name then
				interfering[#interfering + 1] = {
					start = node.start, stop = node.stop, name = name, field = field, kind = "write",
				}
			end
		end
	end
	table.sort(interfering, function(left, right) return left.start < right.start end)

	--- The first offset at or after `from` where something could disturb the name, or nil. The
	--- span of that disturbance comes back too, because a read written *inside* it is a read that
	--- happens before the disturbance does.
	---@param from integer
	---@param until_ integer
	---@param name string
	---@param field string?
	local function firstDisturbance(from, until_, name, field)
		local low, high, best = 1, #interfering, nil
		while low <= high do
			local mid = math.floor((low + high) / 2)
			if interfering[mid].start > from then
				best = mid
				high = mid - 1
			else
				low = mid + 1
			end
		end
		while best and best <= #interfering do
			local node = interfering[best]
			if node.start > until_ then return nil end
			-- A write disturbs whatever the fact said, including a write to another field of it: the
			-- object is the same object and what is known about one field says nothing about the
			-- others. Being handed a *field* only disturbs a fact about that same field.
			local hit = node.name == name
				and (node.kind == "write" or not node.field or node.field == field)
			if hit then return node.start, node.stop end
			best = best + 1
		end
		return nil
	end

	local function add(condition, record, from, until_)
		local guarded = byRecord[record].facts
		local list = guarded[condition.name]
		if not list then
			list = {}
			guarded[condition.name] = list
		end
		local start = from or record.start
		local stop = until_ or record.stop
		-- A fact about a field holds only until something could have changed what it was about:
		-- any call, because the callee may hold the same table, or a write to that field or to
		-- the whole object. When the disturbance is found, its own span comes with it — a read
		-- written *inside* that call is evaluated before the call runs, and `ipairs(shape.params)`
		-- is the very read the fact was gathered for. Cutting the span here and remembering the
		-- disturbance is the whole of the invalidation.
		local disturbance, disturbanceStop
		if condition.field then
			disturbance, disturbanceStop = firstDisturbance(start, stop, condition.name, condition.field)
			if disturbance then stop = disturbance - 1 end
		end
		list[#list + 1] = {
			name = condition.name, field = condition.field, kind = condition.kind,
			wantTruthy = condition.wantTruthy, typeName = condition.typeName,
			type = condition.type, start = start, stop = stop,
			disturbance = disturbance, disturbanceStop = disturbanceStop,
		}
	end


	--- The scopes inside a node. They are contiguous in start order, so bisection finds the
	--- first of them instead of every construct walking every scope in the document.
	---@param node lye.parser.Node
	---@return lye.parser.Scope[]
	local function scopesIn(node)
		local low, high = 1, #ordered
		while low <= high do
			local mid = math.floor((low + high) / 2)
			if ordered[mid].start < node.start then low = mid + 1 else high = mid - 1 end
		end
		local found = {}
		for index = low, #ordered do
			local scope = ordered[index]
			if scope.start > node.stop then break end
			if scope.stop <= node.stop then found[#found + 1] = scope end
		end
		return found
	end

	--- The clauses of an `if`, in source order and outermost only: an `if` nested in one of
	--- them is its own construct, and its conditions are none of this one's business.
	---@param node lye.parser.Node
	---@return lye.parser.Scope[]
	local function clausesOf(node)
		local clauses = {}
		for _, scope in ipairs(scopesIn(node)) do
			-- Only `if` clauses carry a branch; a `do` block or a body has none.
			local outer = clauses[#clauses]
			if scope.branch and (not outer or scope.start >= outer.stop) then
				clauses[#clauses + 1] = scope
			end
		end
		return clauses
	end

	--- The scope whose body a `while` or `repeat` condition guards: the one carrying the
	--- condition, which opens before anything inside it does.
	---@param node lye.parser.Node
	---@return lye.parser.Scope?
	local function guardedScope(node)
		local guarded
		for _, scope in ipairs(scopesIn(node)) do
			if scope.conditionIdx and (not guarded or scope.start < guarded.start) then
				guarded = scope
			end
		end
		return guarded
	end

	-- The statements of the document, in source order: an expression statement is an unparented
	-- node, so the arena already says which nodes are statements and which are parts of one.
	local statements = {}
	for _, node in ipairs(parsed.nodes) do
		if node.parent == parsed.root then statements[#statements + 1] = node end
	end
	table.sort(statements, function(a, b) return a.start < b.start end)

	--- Whether a declaration is the `never` type, which is how a call that cannot come back is
	--- written down: `error` is, in the definitions.
	---@param signature lye.analyzer.Signature?
	local function declaresNever(signature)
		local written = signature and signature.returns and signature.returns.type
		return written ~= nil and (written:gsub("%s+", "")) == "never"
	end

	--- Whether a block can reach its end. `return` and `break` leave it, and a call that never
	--- comes back does too, so a clause ending in one passes nothing on.
	---@param scope lye.parser.Scope
	---@return boolean
	local function fallsThrough(scope)
		-- Bisection, since this is asked once per `if` clause and the list is every statement in
		-- the document: the last one that starts inside the clause is the one that decides.
		local low, high = 1, #statements
		while low <= high do
			local mid = math.floor((low + high) / 2)
			if statements[mid].start <= scope.stop then low = mid + 1 else high = mid - 1 end
		end
		local last = statements[high]
		if not last or last.start < scope.start then return true end
		if last.kind == "return" or last.kind == "break" then return false end
		if last.kind == "call" and declaresNever(last.callee and signatures[last.callee]) then
			return false
		end
		return true
	end

	-- `inner and types.array(inner)` reads the name because it is known there: the right operand of
	-- an `and` only runs when the left one was truthy, and of an `or` only when it was falsy. The
	-- fact covers the right operand alone, which is what its own span says.
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "binary" and (node.op == "and" or node.op == "or") then
			local left = parsed.nodes[node.left]
			local right = parsed.nodes[node.right]
			local scope = left and scopeAtOffset(left.stop)
			if scope and right then
				for _, condition in ipairs(readConditions(parsed, node.left, node.op == "or", signatures)) do
					-- The fact holds while the right operand runs, so it starts where that operand
					-- starts. Starting at the left operand's own `stop` covered its name: a prefix
					-- node's span is a point, so `opts or {}` read the left `opts` as already falsy.
					add(condition, scope, right.start, node.stop)
				end
			end
		end
	end

	-- `---@cast name +T`: from this line on, the name is a T. It is an unconditional assertion — a
	-- writer saying what they know and the analyzer cannot work out, which is why the directive
	-- exists — so it is applied as a fact over the rest of the scope rather than checked.
	for _, annotation in ipairs(annotations or {}) do
		if annotation.tag == "cast" then
			local written = (annotation.type or ""):gsub("^%s*", "")
			local subject, rest = written:match("^([%w_%.]+)%s*(.*)$")
			-- Which way the assertion goes, which the marker says: `+T` is the value being a T and
			-- `-T` is it not being one. Reading every cast as `+` made `---@cast query -nil` assert
			-- the value *is* nil, the opposite of taking the nil out of it.
			local marker = rest and rest:match("^%s*([%+%-])")
			local wanted = rest and (rest:gsub("^%s*[%+%-!%?]%s*", ""))
			local scope = scopeAtOffset(annotation.stop)
			local held = wanted and wanted ~= "" and types.parse(wanted, resolve)
			if subject and held and scope then
				add({ name = subject, kind = marker == "-" and "nottype" or "cast",
					type = held, wantTruthy = true }, scope, annotation.stop)
			end
		end
	end

	for _, node in ipairs(parsed.nodes) do
		if node.kind == "if" then
			-- Each branch also knows every earlier condition is false, which is what narrows
			-- `elseif` and `else` bodies.
			local knownIdxs = {}
			for _, scope in ipairs(clausesOf(node)) do
				for _, knownIdx in ipairs(knownIdxs) do
					for _, condition in ipairs(readConditions(parsed, knownIdx, true, signatures)) do
						add(condition, scope)
					end
				end
				for _, condition in ipairs(readConditions(parsed, scope.conditionIdx, false, signatures)) do
					add(condition, scope)
				end
				-- A clause that cannot fall through leaves its own condition false afterwards:
				-- the code past the `if` is only reached when the condition was false, since the
				-- other way in ends in `return`, `break` or a call that never comes back. This is
				-- what narrows `if not handle then error("...") end` for the rest of the block.
				local enclosing = scope.branch ~= "else" and not fallsThrough(scope) and scopeAtOffset(node.stop)
				if enclosing then
					for _, condition in ipairs(readConditions(parsed, scope.conditionIdx, true, signatures)) do
						add(condition, enclosing, node.stop)
					end
				end
				if scope.conditionIdx then knownIdxs[#knownIdxs + 1] = scope.conditionIdx end
			end
		elseif node.kind == "while" or node.kind == "repeat" then
			local scope = guardedScope(node)
			-- `repeat` tests after the body, so only a nil comparison is worth asserting.
			local isInverted = node.kind == "repeat"
			if scope then
				for _, condition in ipairs(readConditions(parsed, scope.conditionIdx, isInverted, signatures)) do
					if not isInverted or condition.kind == "nil" or condition.kind == "notnil" then
						add(condition, scope)
					end
				end
			end
		end
	end

	-- `assert(x)` on its own line narrows `x` for the rest of the block it is written in. What
	-- makes that sound is the negative form's meaning: the call either does not come back or it
	-- comes back with the parameter narrowed, so everything after it may rely on that. The
	-- positive form says nothing until its value is tested, so a discarded one narrows nothing.
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "call" and node.callee then
			local signature = signatures[node.callee]
			for _, predicate in ipairs(signature and signature.predicates or {}) do
				if predicate.negated then
					local scope = scopeAtOffset(node.stop)
					local name, field, kind = predicateSubject(parsed, node, signature, predicate)
					if scope and name then
						-- Cheap to parse once: the predicate belongs to the declaration, so every
						-- call to it shares this.
						if not predicate.parsed then
							predicate.parsed = types.parse(predicate.type, resolve)
						end
						-- From the end of the call: a fact is only about what comes after it, and
						-- a name is looked up where the fact starts, which is past the argument.
						add({ name = name, field = field, kind = kind, wantTruthy = true,
							typeName = predicate.type, type = predicate.parsed }, scope, node.stop)
					end
				end
			end
		end
	end
end

local narrow = {}
narrow.collect = collectNarrowing
return narrow
