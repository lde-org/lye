--[[
	Name resolution, evolving types and narrowing.

	The parser says where a name was declared; this says what it holds. A variable's type is
	the union of every value assigned to it up to a given offset, so it evolves:

	    local x = 5
	    x = "foo"   -- x is number|string from here on

	An explicit `---@type` fixes the type instead, and an assignment that does not fit is an
	error rather than an evolution. Conditions narrow: `if y then` on `string?` leaves `string`
	inside the branch, and testing a field selects the union member that carries it.
]]

local Parser = require("lye-parser")
local lexer = require("lye-lexer")
local KIND = lexer.KIND
local doc = require("lye-doc")
local types = require("lye-doc.type")
local infer = require("lye-analyzer.infer")

local analyzer = {}

---@class lye.analyzer.Variable
---@field declaration lye.parser.Declaration
---@field name string
---@field qualifier lye.parser.Qualifier
---@field start integer
---@field stop integer
---@field scope lye.analyzer.Scope
---@field declared lye.doc.Type? the type an annotation fixed, if any
---@field initializer lye.doc.Type
---@field assignments { at: integer, type: lye.doc.Type }[]
---@field references integer[]

---@class lye.analyzer.Scope
---@field start integer
---@field stop integer
---@field parent lye.analyzer.Scope?
---@field depth integer
---@field variables table<string, lye.analyzer.Variable>
---@field children lye.analyzer.Scope[]
---@field facts table<string, lye.analyzer.Narrowing[]> conditions that hold over this scope

--- What a condition says about its subject, read from the expression node guarding a block.
---@class lye.analyzer.Condition
---@field name string
---@field field string?
---@field kind string "truthy"|"nil"|"notnil"|"type"|"nottype"
---@field wantTruthy boolean
---@field typeName string? for a `type(x) == "T"` test
---@field type lye.doc.Type? the parsed type, for a predicate that names a class or an alias

--- A condition that narrows a name, or a field of one, over a span of source.
---@class lye.analyzer.Narrowing
---@field name string
---@field field string?
---@field kind string "truthy"|"nil"|"notnil"|"type"|"nottype"
---@field wantTruthy boolean
---@field typeName string? for a `type(x) == "T"` test
---@field type lye.doc.Type? the parsed type, for a predicate that names a class or an alias
---@field start integer
---@field stop integer

---@class lye.analyzer.Diagnostic
---@field message string
---@field start integer
---@field stop integer
---@field severity integer

--- What the annotations above a declaration say about it. The generic names a declaration
--- introduces are recorded by name, with whether each stands for a sequence and what it is
--- limited to, so a call site can check an argument against the limit.
--- A `---@return v is -nil` line: the call narrows a parameter rather than returning a type.
--- `v is T` narrows `v` where the call's value is truthy, and `v is -T` narrows it to what is
--- *not* a T wherever the call came back at all — which is what `assert` does, since the other
--- path raises.
---@class lye.analyzer.Predicate
---@field param string the parameter the call says something about
---@field type string the type, as written
---@field negated boolean whether the annotation carries the `-` marker

---@class lye.analyzer.Signature
---@field params lye.doc.Annotation[]
---@field returns lye.doc.Annotation?
---@field generics table<string, boolean>
---@field constraints table<string, string>
---@field predicates lye.analyzer.Predicate[]
---@field overloads string[] the shapes a call may take besides the parameters, as written
---@field doc string? the prose written above the declaration, as markdown

---@class lye.analyzer.Prelude
---@field classes table<string, lye.doc.Class>
---@field aliases table<string, string>
---@field signatures table<string, lye.analyzer.Signature>
---@field fields table<lye.doc.Type, lye.analyzer.Signature> the annotations a field's type was built from
---@field returns table<string, lye.doc.Type>
---@field globalNames table<string, boolean> the globals the definitions declare, `arg` among them

---@class lye.analyzer.Result
---@field parser lye.parser.Result
---@field doc lye.doc.File the annotations the analysis read
---@field root lye.analyzer.Scope
---@field variables lye.analyzer.Variable[]
---@field byStart table<integer, lye.analyzer.Variable>
---@field diagnostics lye.analyzer.Diagnostic[]
---@field signatures table<string, lye.analyzer.Signature>
---@field returns table<string, lye.doc.Type>
---@field callTypes table<integer, lye.doc.Type> what each call was bound to, by node index

---@param result lye.parser.Result
---@return lye.analyzer.Scope
local ARITHMETIC = {
	["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true, ["^"] = true,
	["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true, ["~>>"] = true,
}

--- A type arithmetic cannot work on at all. `any`, an unresolved name and a class are not:
--- whatever they hold may have a metamethod, which is what makes `cdata + 1` and a vector class
--- work, so nothing is claimed about them.
---@param type lye.doc.Type
---@return boolean
local function isNeverNumeric(type)
	if type.variant == "union" then
		if #type.types == 0 then return false end
		for _, member in ipairs(type.types) do
			if not isNeverNumeric(member) then return false end
		end
		return true
	end
	return type.variant ~= "number" and type.variant ~= "any" and type.variant ~= "unknown"
		and type.variant ~= "extern" and type.variant ~= "class"
end

local function buildScopes(result)
	local root = { start = 1, stop = math.huge, depth = 0, variables = {}, children = {}, facts = {} }
	local byRecord = {}
	local scopes = {}
	for _, node in ipairs(result.scopes) do scopes[#scopes + 1] = node end
	table.sort(scopes, function(a, b)
		if a.start ~= b.start then return a.start < b.start end
		return a.stop > b.stop
	end)

	-- Children are appended in start order, so the innermost scope holding an offset is
	-- found by bisection rather than a walk of every sibling.
	---@param scope lye.analyzer.Scope
	---@param from integer
	---@param stop integer
	---@return lye.analyzer.Scope
	local function innermost(scope, from, stop)
		local children = scope.children
		local low, high = 1, #children
		while low <= high do
			local mid = math.floor((low + high) / 2)
			if children[mid].start <= from then low = mid + 1 else high = mid - 1 end
		end
		local candidate = children[high]
		if candidate and stop <= candidate.stop then return innermost(candidate, from, stop) end
		return scope
	end

	for _, node in ipairs(scopes) do
		local parent = innermost(root, node.start, node.stop)
		local scope = {
			start = node.start, stop = node.stop, parent = parent, depth = parent.depth + 1,
			variables = {}, children = {}, facts = {},
		}
		parent.children[#parent.children + 1] = scope
		byRecord[node] = scope
	end
	return root, byRecord
end

---@param self lye.analyzer.Result
---@param offset integer
---@return lye.analyzer.Scope
local function scopeAt(self, offset)
	local scope = self.root
	while true do
		local children = scope.children
		local low, high = 1, #children
		while low <= high do
			local mid = math.floor((low + high) / 2)
			if children[mid].start <= offset then low = mid + 1 else high = mid - 1 end
		end
		local candidate = children[high]
		if not candidate or offset > candidate.stop then return scope end
		scope = candidate
	end
end

--- Resolve a name where it is read: an inner declaration of the same name only takes over
--- from its own offset on, which is what makes shadowing resolve rather than collide.
---@param scope lye.analyzer.Scope
---@param name string
---@param offset integer
---@return lye.analyzer.Variable?
local function lookupIn(scope, name, offset)
	local current = scope
	while current do
		-- A name declared twice in one scope shadows itself: `local x = 1` further down the same
		-- block is a different variable, and a read above it belongs to the one before. The
		-- variables are in declaration order, so the last one that starts at or before the read is
		-- the one the name means there.
		local declared = current.variables[name]
		if declared then
			for index = #declared, 1, -1 do
				local found = declared[index]
				if found.start <= offset then return found end
			end
		end
		current = current.parent
	end
end

---@param kind string
---@param returns table<string, lye.doc.Type>?
---@return lye.doc.Type
local function kindToType(kind, returns)
	if kind == "string" then return types.STRING end
	if kind == "number" then return types.NUMBER end
	if kind == "boolean" then return types.BOOLEAN end
	if kind == "function" then return types.FUNCTION end
	if kind == "table" then return types.TABLE end
	if kind == "nil" then return types.NIL_TYPE end
	if kind == "true" or kind == "false" or kind == "boolean" then return types.BOOLEAN end
	-- A declared return type, keyed by the callee name.
	if returns and returns[kind] then return returns[kind] end
	return types.mutable()
end

--- Every assignment to a name, with the type of the value assigned and where it happened.
--- Each value is the expression node that starts at or after the `=`.
---@param parsed lye.parser.Result
---@return table<string, { at: integer, type: lye.doc.Type }[]>
--- The name a plain assignment writes. Only `x = v` names the variable it changes: `t.foo = v`
--- and `t[k] = v` write into a table, and reading them as an assignment to `t` would make every
--- table that is filled in a union with what was put in it.
---@param parsed lye.parser.Result
---@param targetIdx integer?
---@return string?
local function targetName(parsed, targetIdx)
	local node = targetIdx and parsed.nodes[targetIdx]
	if not node then return nil end
	if node.kind == "prefix" then return node.callee or node.name end
	if node.kind == "name" then return node.name end
end

--- The name an expression is written as, when it is one: `x`, `A.B.c`. A call or a computed
--- index is not a name, and says nothing about which table a function is written for.
---@param parsed lye.parser.Result
---@param idx integer?
---@return string?
local function writtenNameOf(parsed, idx)
	local node = idx and parsed.nodes[idx]
	if not node then return nil end
	if node.kind == "prefix" then return node.callee or node.name end
	if node.kind == "name" then return node.name end
	if node.kind == "index" and node.field then
		local base = writtenNameOf(parsed, node.target)
		if base then return base .. "." .. node.field end
	end
	return nil
end

--- Every assignment, as `name`, the offset it happened at, and the arena index of the value.
--- The tree supplies all three, so nothing is recovered by scanning spans.
---@param parsed lye.parser.Result
---@return { name: string, at: integer, valueIdx: integer }[]
local function collectAssignments(parsed)
	local found = {}
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "assignment" then
			local name = targetName(parsed, node.target)
			if name and node.value then
				found[#found + 1] = { name = name, at = node.start, valueIdx = node.value }
			end
		end
	end
	return found
end

--- The name a condition is about, and the field of it when the condition reads one. A
--- subject is an arena node: a name, a parenthesised expression, or a field of either.
---@param parsed lye.parser.Result
---@param idx integer
---@return string? name
---@return string? field
local function readSubject(parsed, idx)
	local node = parsed.nodes[idx]
	if not node then return nil end
	if node.kind == "prefix" then
		if node.group then return readSubject(parsed, node.group) end
		return node.callee
	end
	if node.kind == "index" and node.field and not node.isDynamic then
		local name = readSubject(parsed, node.target)
		if name then return name, node.field end
	end
end

--- The name a `type(x)` test is about, since the call is a node like any other.
---@param parsed lye.parser.Result
---@param idx integer
---@return string? name
---@return string? field
local function readTypeSubject(parsed, idx)
	local node = parsed.nodes[idx]
	if not node or node.kind ~= "call" or node.callee ~= "type" then return nil end
	local argIdx = node.args and node.args[1]
	if not argIdx then return nil end
	return readSubject(parsed, argIdx)
end

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

local CONJUNCTIONS = { ["and"] = true, ["&&"] = true }
local DISJUNCTIONS = { ["or"] = true, ["||"] = true }
local NEGATIONS = { ["not"] = true, ["!"] = true }

--- What a condition asserts, read from the arena. Only forms that say something definite are
--- recognised; anything else narrows nothing, which is safer than guessing.
---
--- `invert` says the assertion holds where the expression is *false*, which is how an `else`
--- and a `not` are read. Every shape below states its own inversion, so nothing else has to.
---@param parsed lye.parser.Result
---@param idx integer arena index of the condition expression
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
	end
end

--- Every assertion a guard makes about the region it guards. A conjunction asserts both of
--- its operands, and by De Morgan a disjunction asserts both only where it fails, which is
--- what narrows the `else` of `if x == nil or x == "" then`. The other two combinations say
--- nothing definite, so they assert nothing rather than guessing.
---@param parsed lye.parser.Result
---@param conditionIdx integer? arena index of the guarding expression
---@param invert boolean the assertions hold where the condition is false
---@param signatures table<string, lye.analyzer.Signature>
---@return lye.analyzer.Condition[]
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
local function collectNarrowing(parsed, byRecord, signatures, resolve)
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
	-- Everything that could change a field between a condition and a read: a call, because the callee
	-- may hold the same table and a `__newindex` may run, and a write through the same name. Gathered
	-- once and sorted, so a fact finds the first one after it by bisection rather than by walking the
	-- arena — which is what made a file with many conditions cost the square of its size.
	---@type { start: integer, name: string }[]
	local interfering = {}
	for _, node in ipairs(parsed.nodes) do
		local name
		if node.kind == "call" then
			name = "*"
		elseif node.kind == "assignment" and node.target then
			local target = parsed.nodes[node.target]
			local base = target
			if target and target.field then base = parsed.nodes[target.target] end
			name = base and (base.callee or base.name) or nil
		end
		if name then interfering[#interfering + 1] = { start = node.start, name = name } end
	end
	table.sort(interfering, function(left, right) return left.start < right.start end)

	--- The first offset at or after `from` where something could disturb the name, or nil.
	---@param from integer
	---@param until_ integer
	---@param name string
	---@return integer? offset
	local function firstDisturbance(from, until_, name)
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
			if node.name == "*" or node.name == name then return node.start end
			best = best + 1
		end
		return nil
	end

	local function add(condition, record, from)
		local guarded = byRecord[record].facts
		local list = guarded[condition.name]
		if not list then
			list = {}
			guarded[condition.name] = list
		end
		local start = from or record.start
		local stop = record.stop
		-- A fact about a field holds only until something could have changed what it was about:
		-- any call, because the callee may hold the same table, or a write to that field or to
		-- the whole object. Cutting the span here is the whole of the invalidation.
		if condition.field then
			local disturbance = firstDisturbance(start, stop, condition.name)
			if disturbance then stop = disturbance - 1 end
		end
		list[#list + 1] = {
			name = condition.name, field = condition.field, kind = condition.kind,
			wantTruthy = condition.wantTruthy, typeName = condition.typeName,
			type = condition.type, start = start, stop = stop,
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
	---@return boolean
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

--- The annotation immediately preceding a declaration, when it is a `@type`. It belongs to
--- the next declaration only, so a later one must not inherit it.
---@param file lye.doc.File
---@param declaration lye.parser.Declaration
---@return lye.doc.Type?
--- The byte span a declaration's own annotations live in: the comment lines immediately above
--- it, and nothing further back. Every line of a doc block is its own comment token, so the block
--- is the run of comment tokens ending where the declaration begins.
---@param parsed lye.parser.Result
---@param declaration lye.parser.Declaration
---@return integer? start
---@return integer? stop
local function annotationSpan(parsed, declaration)
	local anchorIdx = declaration.anchorIdx
	if not anchorIdx then return nil end

	local tokens = parsed.tokens.arena
	local first, index = nil, anchorIdx - 1
	while index >= 1 and tokens[index].kind == KIND.comment do
		first = index
		index -= 1
	end
	if not first then return nil end
	return tokens[first].start, tokens[anchorIdx - 1].stop
end

--- The prose a declaration carries, as markdown, or nil when it carries none. The `---@` lines are
--- left out: they are the signature, which a reader is shown separately, and a line of `---` is a
--- paragraph break.
---@param parsed lye.parser.Result
---@param declaration lye.parser.Declaration
---@return string?
local function documentationOf(parsed, declaration)
	local anchorIdx = declaration.anchorIdx
	if not anchorIdx then return nil end

	-- The comment block is the run of comment tokens immediately above the statement, so it is
	-- walked rather than searched: looking through every token in the file for the ones that fall
	-- before the declaration made this cost the file size for each declaration in it.
	local tokens, texts = parsed.tokens.arena, parsed.tokens.texts
	local lines = {}
	local index = anchorIdx - 1
	while index >= 1 and tokens[index].kind == KIND.comment do
		local written = texts[index]
		-- Only a triple-dash line is documentation. A `--` comment is a note to whoever reads
		-- the code, and a divider of dashes is a divider: putting either in a description is
		-- how an unrelated remark turns up in a hover.
		if written:match("^%-%-%-[^%-@]") or written:match("^%-%-%-$") then
			table.insert(lines, 1, (written:gsub("^%-%-%-%s?", "")))
		end
		index -= 1
	end
	while #lines > 0 and lines[#lines]:match("^%s*$") do
		table.remove(lines)
	end
	if #lines == 0 then return nil end
	return table.concat(lines, "\n")
end

--- The `@type` that describes a declaration, or nil when it has none.
---
--- An annotation describes a declaration when it is the comment immediately before the
--- statement that declares it. That is a question about tokens — the parser records which
--- token opens the declaration — so no gap is ever measured or copied.
---@param parsed lye.parser.Result
---@param file lye.doc.File
---@param declaration lye.parser.Declaration
---@param resolve fun(text: string): lye.doc.Type?
---@return lye.doc.Type?
function analyzer.declaredTypeFor(parsed, file, declaration, resolve)
	local spanStart = annotationSpan(parsed, declaration)
	if not spanStart then return nil end

	-- Annotations are in source order, so the candidate is the last one before the declaration.
	local annotations = file.annotations
	local low, high = 1, #annotations
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if annotations[mid].start < declaration.start then low = mid + 1 else high = mid - 1 end
	end
	local previous = annotations[high]
	if not previous or previous.start < spanStart then return nil end
	-- A class declared in the block above a declaration is that declaration's type: `---@class
	-- Point` over `local Point = {}` is how a class is written, and the standard library does the
	-- same with its own names, as `---@class mathlib` over `math = {}`. The class is looked for
	-- rather than taken from the last line, because its `---@field` lines follow it.
	-- Only where the declaration holds the class table itself. Above a `function`, a class is
	-- what the function returns, which is a different rule and is not read here.
	local holdsTable = declaration.initializer == "table"
		or (declaration.valueIdx and parsed.nodes[declaration.valueIdx]
			and parsed.nodes[declaration.valueIdx].kind == "table")
	-- Above a function the class is what it returns, which is how `---@class osdate` over
	-- `function os.date` is written.
	if declaration.isFunction then
		for index = high, 1, -1 do
			local annotation = annotations[index]
			if annotation.start < spanStart then break end
			if annotation.tag == "class" then
				local name = annotation.name or (annotation.text or ""):match("^([%w_%.]+)")
				return nil, name and resolve(name) or nil
			end
		end
	end
	if holdsTable then
		for index = high, 1, -1 do
			local annotation = annotations[index]
			if annotation.start < spanStart then break end
			if annotation.tag == "class" then
				local name = annotation.name or (annotation.text or ""):match("^([%w_%.]+)")
				return name and resolve(name) or nil
			end
		end
	end
	if previous.tag ~= "type" then return nil end
	return types.parse(previous.type, resolve)
end

--- A fact belongs to the variable its condition resolved to, so an inner `local` of the same
--- name never inherits an outer narrowing. A name that does not resolve is left alone, which is
--- the safer half of the two.
---@param self lye.analyzer.Result
---@param fact lye.analyzer.Narrowing
---@param variable lye.analyzer.Variable
---@return boolean
local function factReaches(self, fact, variable)
	return lookupIn(scopeAt(self, fact.start), fact.name, fact.start) == variable
end

--- What a condition says about a type, or nil when it cannot be said of this one.
---@param base lye.doc.Type
---@param fact lye.analyzer.Narrowing
---@return lye.doc.Type?
local function applyFact(base, fact, onField)
	if fact.kind == "type" then
		if fact.type then return types.narrowToType(base, fact.type) end
		return types.narrowTo(base, fact.typeName)
	elseif fact.kind == "nottype" then
		if fact.type then return types.excludeType(base, fact.type) end
		return types.exclude(base, fact.typeName)
	elseif fact.kind == "nil" or fact.kind == "notnil" then
		return types.narrowNil(base, fact.kind == "nil")
	elseif fact.field and not onField then
		-- A condition on `a.x` narrows that field of `a`; read *as* the field's own value, which is
		-- what a field read is asking for, the fact applies to the value instead.
		return types.narrowField(base, fact.field, fact.wantTruthy)
	end
	return types.narrowTruthiness(base, fact.wantTruthy)
end

--- The type of a field read at an offset: what the field holds, narrowed by any condition on it
--- that still holds where it is read. A condition stops holding where something could have changed
--- what it was about, which is where its span ends — see where the spans are cut.
---@param self lye.analyzer.Result
---@param base lye.doc.Type
---@param baseName string? the name the field is read off, when it is a name at all
---@param field string
---@param offset integer
---@return lye.doc.Type
function analyzer.fieldTypeAt(self, base, baseName, field, offset)
	local held = types.indexResult(base, field)
	if not baseName then return held end

	-- The same name has to be the same thing here as it was in the condition: an inner `local`
	-- of the same name ends the fact rather than inheriting it.
	local here = lookupIn(scopeAt(self, offset), baseName, offset)
	local scope, guarding = scopeAt(self, offset), {}
	while scope do
		if scope.facts[baseName] then guarding[#guarding + 1] = scope end
		scope = scope.parent
	end

	local narrowed = held
	for index = #guarding, 1, -1 do
		for _, fact in ipairs(guarding[index].facts[baseName]) do
			local same = lookupIn(scopeAt(self, fact.start), baseName, fact.start) == here
			-- Only this field's facts: a condition on `a.x` says nothing about `a.y`.
			if fact.field == field and same and offset >= fact.start and offset <= fact.stop then
				local next_ = applyFact(narrowed, fact, true)
				-- A condition that rules every member out is a contradiction, so the branch cannot
				-- run: what the field holds as declared is more honest than a made-up type.
				if not next_ then return held end
				narrowed = next_
			end
		end
	end
	return narrowed
end

--- The type of a variable as seen at an offset: its annotation when one fixed it, otherwise
--- the union of every assignment before that offset, narrowed by any covering condition.
---@param self lye.analyzer.Result
---@param variable lye.analyzer.Variable
---@param offset integer
---@return lye.doc.Type
function analyzer.typeAt(self, variable, offset)
	local base = variable.declared or variable.initializer

	if not variable.declared then
		for _, assignment in ipairs(variable.assignments) do
			if assignment.at <= offset then base = types.combine(base, assignment.type) end
		end
	end

	-- Every enclosing scope may hold a condition on this name, and the outermost holds first
	-- so a nested one narrows on top of it. The scope chain is the containment: a condition
	-- written inside a branch is not on a scope outside it, and is never consulted there.
	local guarding = {}
	local scope = scopeAt(self, offset)
	while scope do
		if scope.facts[variable.name] then guarding[#guarding + 1] = scope end
		scope = scope.parent
	end

	local narrowed = base
	for index = #guarding, 1, -1 do
		for _, fact in ipairs(guarding[index].facts[variable.name]) do
			if offset >= fact.start and offset <= fact.stop and factReaches(self, fact, variable) then
				local next
				-- A predicate names a type the writer chose, a class or an alias included, so it
				-- is used as it was parsed; a `type(x) == "T"` test names one of the base types,
				-- which is a name and not a type until something parses it.
				next = applyFact(narrowed, fact)
				-- A condition that rules every member out is a contradiction, so the branch
				-- cannot run; the un-narrowed type is more honest than a made-up one.
				if not next then return base end
				narrowed = next
			end
		end
	end
	return narrowed
end

--- A table literal with named fields is an object, which is what lets a discriminated union
--- match one of its members. The declaration names its own initializer, so the literal is read
--- from there rather than looked for after the name.
---@param parsed lye.parser.Result
---@param declaration lye.parser.Declaration
---@return lye.doc.Type?
local function objectLiteralAfter(parsed, declaration)
	if declaration.initializer ~= "table" then return nil end
	local node = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
	local kinds = node and parsed.tableFields[node.index]
	if not kinds then return nil end
	local fields = {}
	for name, kind in pairs(kinds) do fields[name] = kindToType(kind) end
	return types.object(fields)
end

--- The `@param` and `@return` annotations of a declaration, in order. They are the ones in the
--- block above it, so a `@param` written for one function is never read as another's.
---@param parsed lye.parser.Result
---@param file lye.doc.File
---@param declaration lye.parser.Declaration
---@return lye.doc.Annotation[] params
---@return lye.doc.Annotation? returns
---@return table<string, boolean> generics name to whether it stands for a sequence
---@return table<string, string> constraints what a generic name is limited to, by name
---@return lye.analyzer.Predicate[] predicates what the call narrows
local function signatureOf(parsed, file, declaration)
	local params, returned, generics, constraints, predicates, overloads = {}, nil, {}, {}, {}, {}
	local spanStart = annotationSpan(parsed, declaration)
	if not spanStart then
		return params, returned, generics, constraints, predicates, overloads
	end

	-- Annotations are in source order, so the ones in the block end where the declaration starts.
	local annotations = file.annotations
	local low, high = 1, #annotations
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if annotations[mid].start < declaration.start then low = mid + 1 else high = mid - 1 end
	end

	for index = high, 1, -1 do
		local annotation = annotations[index]
		if annotation.start < spanStart then break end
		if annotation.tag == "param" then
			table.insert(params, 1, annotation)
		elseif annotation.tag == "generic" then
			-- `---@generic T` names one type; a marker on either side (`T...` or `...T`) says it
			-- stands for any number of them; `T: table` limits it to what follows the colon. The
			-- whole body is read, since a line may name several: `---@generic T: table, V`.
			for _, part in ipairs(doc.classes.splitList(annotation.text or "")) do
				local name, isVariadic = part, false
				local colon = name:find(":", 1, true)
				if colon then
					constraints[(name:sub(1, colon - 1):gsub("%s+$", ""))] =
						(name:sub(colon + 1):gsub("^%s+", ""))
					name = name:sub(1, colon - 1)
				end
				name = name:gsub("%s+$", "")
				if name:sub(-3) == "..." then
					name, isVariadic = name:sub(1, -4), true
				elseif name:sub(1, 3) == "..." then
					name, isVariadic = name:sub(4), true
				end
				if name ~= "" then generics[name] = isVariadic end
			end
		elseif annotation.tag == "return" then
			-- `---@return v is -nil` says what the call proves about a parameter rather than what
			-- it returns, so it is read apart. Everything else about a return is unchanged:
			-- walking back, the first one written is the last met, and it is the value
			-- `local x = f()` takes; a further `@return` says what follows it.
			local param, rest = (annotation.type or ""):match("^(%w+)%s+is%s+(.+)$")
			if param then
				local negated = rest:sub(1, 1) == "-"
				predicates[#predicates + 1] = {
					param = param,
					type = ((negated and rest:sub(2) or rest):gsub("^%s+", "")),
					negated = negated,
				}
			else
				returned = annotation
			end
		elseif annotation.tag == "overload" then
			-- `---@overload fun(opt?: "collect")` is another shape the call may take, written as a
			-- signature rather than as parameters. Reading the first one only would report every
			-- call that uses another, which is what `debug.getinfo(1, "S")` and `collectgarbage`
			-- are: one entry with six overloads.
			if annotation.type then overloads[#overloads + 1] = annotation.type end
		elseif annotation.tag == "type" or annotation.tag == "class" then
			break
		end
	end
	return params, returned, generics, constraints, predicates, overloads
end

--- A generic name is a type variable, not a name to look up: `---@generic T` says the function
--- works for any T, so a reader that has none to offer sees unknown rather than a mismatch
--- against `T` itself. A constrained name stands for what it is limited to, so an argument is
--- checked against that.
---@param generics table<string, boolean>?
---@param constraints table<string, string>?
---@param resolve fun(text: string): lye.doc.Type?
---@return fun(text: string): lye.doc.Type?
local function withGenerics(generics, constraints, resolve)
	if not generics or not next(generics) then return resolve end
	return function(text)
		-- Membership, not truth: a generic that is not variadic is recorded as `false`.
		if generics[text] ~= nil then
			local constraint = constraints and constraints[text]
			local held = constraint and types.parse(constraint, resolve)
			if held then return held end
			return types.UNKNOWN_TYPE
		end
		return resolve(text)
	end
end

--- The type a `@param` gives a parameter, matched by the name the annotation carries. An
--- annotation that names nothing cannot be matched to one parameter over another.
---@param params lye.doc.Annotation[]?
---@param name string
---@return lye.doc.Type?
local function paramTypeOf(params, name, resolve)
	if not params then return nil end
	for _, annotation in ipairs(params) do
		if annotation.name == name and annotation.type then
			return types.parse(annotation.type, resolve)
		end
	end
end

--- How a call is written, for a message: `id`, `math.floor`, `Point.new`.
---@param parsed lye.parser.Result
---@param node lye.parser.Node
---@return string
local function callLabel(parsed, node)
	if node.field then
		local target = node.target and parsed.nodes[node.target]
		return (target and callLabel(parsed, target) or "call") ..
			(node.isMethod and ":" or ".") .. node.field
	end
	if node.target then return callLabel(parsed, parsed.nodes[node.target]) end
	return node.callee or "call"
end

--- Check the arguments a call passes against the parameters the callee declares, and collect
--- what a named callee returns so a later `local x = f()` can be typed.
---@param self lye.analyzer.Result
---@param parsed lye.parser.Result
---@param signatureOfCall fun(node: lye.parser.Node): lye.analyzer.Signature?, lye.doc.Type?, boolean
---@param returns table<string, lye.doc.Type>
---@param inferCtx lye.infer.Context
---@param source string the document, so a string literal can be read where it was written
local function checkCalls(self, parsed, signatureOfCall, returns, resolve, inferCtx, source)
	--- A generic name in a signature is a type variable: the argument cannot be checked against
	--- the name itself, so it is checked against what the name was limited to, if anything.
	---@param signature lye.analyzer.Signature?
	---@return fun(text: string): lye.doc.Type?
	local function resolveFor(signature)
		if not signature then return resolve end
		return withGenerics(signature.generics, signature.constraints, resolve)
	end

	-- The types a signature was written with, parsed once. A call site reads the same parameters and
	-- the same return type as every other call site of the same function, and parsing them again for
	-- each one was most of the cost of this pass — for the definitions, where a signature is shared
	-- by every call in every document, it is parsed once per process.
	---@type table<lye.analyzer.Signature, { params: (lye.doc.Type?)[], returns: lye.doc.Type? }>
	local parsedSignatures = {}
	---@param signature lye.analyzer.Signature
	---@return (lye.doc.Type?)[]
	---@return lye.doc.Type?
	local function typesOf(signature)
		local held = parsedSignatures[signature]
		if held then return held.params, held.returns end

		local local_ = resolveFor(signature)
		local params = {}
		for index, annotation in ipairs(signature.params) do
			params[index] = annotation.type and types.parse(annotation.type, local_)
		end
		local written = signature.returns and signature.returns.type
		local returned = written and types.parse(written, local_) or nil
		-- A generic signature reads differently at each call, so only the fixed ones are kept.
		if next(signature.generics) == nil then
			parsedSignatures[signature] = { params = params, returns = returned }
		end
		return params, returned
	end

	--- The type an argument has as it was written. A string literal is the one string it spells,
	--- which is what `select("#", ...)` and the option flags in the definitions ask for; a name of
	--- type `string` is not that string, so this says nothing about one passed in its place.
	---@param argIdx integer
	---@return lye.doc.Type
	local function argumentAt(argIdx)
		local argument = parsed.nodes[argIdx]
		if argument and argument.kind == "string" then
			return types.extern(source:sub(argument.start, argument.stop))
		end
		return infer.at(inferCtx, argIdx)
	end

	--- The first argument that cannot be what its parameter says, so the caller can decide whether
	--- another shape of the same call accepts what this one did not.
	---@param node lye.parser.Node
	---@param params (lye.doc.Type?)[]
	---@param receiver lye.doc.Type? the value a `:` call passes, which fills the first parameter
	---@return integer? nodeIdx the argument, or the receiver, that cannot be what it is
	---@return lye.doc.Type? wanted
	---@return lye.doc.Type? actual
	local function firstMismatch(node, params, receiver)
		---@param shift integer how many parameters the receiver already fills
		local function walk(shift)
			if shift == 1 then
				local wanted = params[1]
				if wanted and types.mismatch(wanted, receiver, "argument 1") then
					return node.target, wanted, receiver
				end
			end
			for index, argIdx in ipairs(node.args or {}) do
				local wanted = params[index + shift]
				if wanted and parsed.nodes[argIdx] then
					local actual = argumentAt(argIdx)
					if types.mismatch(wanted, actual, "argument " .. (index + shift)) then
						return argIdx, wanted, actual
					end
				end
			end
		end

		-- A `:` call passes the receiver as its first argument, and a signature may or may not
		-- write that parameter down: `fun(self: App, x: string)` names it, while a method this
		-- document declares is written here and its own type leaves `self` out. Whichever reading
		-- the receiver itself fits is the reading the call is judged by.
		if receiver then
			local wanted = params[1]
			local fits = wanted == nil or not types.mismatch(wanted, receiver, "argument 1")
			return walk(fits and 1 or 0)
		end
		return walk(0)
	end

	--- Report the arguments that cannot be what the parameters say they are. A call that fits one of
	--- the declaration's `---@overload` shapes is not reported at all: `debug.getinfo(1, "S")` and
	--- `collectgarbage("count")` are calls to functions written with overloads, and checking them
	--- against the first signature alone reports every one of them.
	---@param node lye.parser.Node
	---@param label string
	---@param params (lye.doc.Type?)[]
	---@param overloads string[]?
	---@param receiver lye.doc.Type?
	local function checkArgs(node, label, params, overloads, receiver)
		local blame, wanted, actual = firstMismatch(node, params, receiver)
		if not blame then return end

		for _, written in ipairs(overloads or {}) do
			local shape = types.parse(written, resolve)
			if shape and shape.variant == "fn" and not firstMismatch(node, shape.params, receiver) then
				return
			end
		end

		local argument = parsed.nodes[blame]
		self.diagnostics[#self.diagnostics + 1] = {
			message = string.format("%s expects %s, got %s", label,
				types.display(wanted), types.display(actual)),
			start = argument.start, stop = argument.stop, severity = 1,
		}
	end

	for _, node in ipairs(parsed.nodes) do
		if node.kind == "call" then
			local signature, calleeType, byName = signatureOfCall(node)
			local label = byName and node.callee or callLabel(parsed, node)
			-- The value a method call is written on, which the callee receives as its first
			-- argument. A `:` call passes it, and so does a `__call` metamethod, which is handed
			-- the value it was found on. A `.` call passes nothing extra.
			local target = node.target and infer.at(inferCtx, node.target)
			local callable = target and types.metamethod(target, "__call")
			local receiver = (node.isMethod or callable) and target or nil
			if signature then
				local params, returned = typesOf(signature)
				if byName and returned then returns[node.callee] = returned end
				checkArgs(node, label, params, signature.overloads, receiver)
			elseif calleeType and types.isFn(calleeType) and not types.isAnyFn(calleeType) then
				-- A callable nothing annotated, such as a method this document declares: its own
				-- type is all there is to check the arguments against. A parameter of the
				-- signature's own is bound by this very call, so what is checked is the limit it
				-- was declared with: an argument cannot be wrong against a name.
				local params = calleeType.params
				if calleeType.generics and next(calleeType.generics) then
					local bindings = {}
					for name in pairs(calleeType.generics) do
						local limit = calleeType.constraints and calleeType.constraints[name]
						bindings[name] = (limit and types.parse(limit, resolve)) or types.UNKNOWN_TYPE
					end
					local replaced = {}
					for index, param in ipairs(params) do
						replaced[index] = types.substitute(param, bindings)
					end
					params = replaced
				end
				checkArgs(node, label, params, nil, receiver)
			end
		end
	end
end

--- The call node following a declaration, for `local x = f()`.
---@param parsed lye.parser.Result
---@param declaration lye.parser.Declaration
---@return lye.parser.Node?
local function callAfter(parsed, declaration)
	if declaration.initializer ~= "call" then return nil end
	return declaration.valueIdx and parsed.nodes[declaration.valueIdx]
end

--- Everything a set of definition files says, gathered once so a document can be analysed
--- against it without reparsing them on every keystroke.
---@param sources table<string, string> definition text by name
---@return lye.analyzer.Prelude
function analyzer.prelude(sources)
	local prepared = {
		classes = {}, aliases = {}, signatures = {}, returns = {}, globals = {}, fields = {},
		globalNames = {},
	}
	-- Field functions are gathered first: a class has to exist before one is added to it.
	local classFields = {}
	-- The table each class describes, by the name it is written under. A bare `math = {}` is a
	-- global the document can read; a `local file = {}` is not, but it still names the receiver
	-- of `function file:close()`, which is a method of the class all the same.
	local backing = {}
	for _, source in pairs(sources) do
		local parsed = Parser.new(source):parse()
		local file = doc.parse(source, parsed.tokens)
		local namespace = doc.classes.read(file)

		-- `---@class mathlib` over `math = {}` names the table the class describes, and the
		-- standard library does that throughout with names that do not match. The link is read
		-- from the first line after the class's annotations, since nothing states it.
		for _, annotation in ipairs(file.annotations) do
			if annotation.tag == "class" then
				-- Read from the text rather than the name the doc reader took: a class may be
				-- written `file*`, and the name it hands over drops the marker that makes it one.
				local className = (annotation.text or annotation.name or ""):match("^([^%s:<]+)")
				local globalName, localName
				for line in source:sub(annotation.stop + 1):gmatch("([^\n]*)\n") do
					if not line:match("^%s*$") and not line:match("^%s*%-%-") then
						globalName = line:match("^%s*([%w_%.]+)%s*=%s*{%s*}%s*$")
						localName = line:match("^%s*local%s+([%w_%.]+)%s*=%s*{%s*}%s*$")
						break
					end
				end
				if className and (globalName or localName) then
					backing[globalName or localName] = className
					if globalName then prepared.globals[globalName] = className end
				end
			end
		end

		for name, class in pairs(namespace.classes) do
			prepared.classes[name] = prepared.classes[name] or class
		end
		for name, alias in pairs(namespace.aliases) do
			prepared.aliases[name] = prepared.aliases[name] or alias
		end
		local resolve = doc.classes.resolver(prepared)
		-- `arg = {}` and `_VERSION = "Lua 5.1"` are globals too, and a definition file writes
		-- them as plain assignments rather than as declarations.
		for _, assignment in ipairs(collectAssignments(parsed)) do
			prepared.globalNames[assignment.name] = true
		end
		for _, declaration in ipairs(parsed.declarations) do
			-- `function math.floor()` is a field of the table `math` describes, so it belongs to
			-- the class that table is.
			local globalName, field = declaration.name:match("^([%w_]+)[%.:]([%w_]+)$")
			local owner = globalName and backing[globalName]
			if owner and not classFields[owner] then classFields[owner] = {} end
			local params, returned, generics, constraints, predicates, overloads =
				signatureOf(parsed, file, declaration)
			if owner then
				local value = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
				classFields[owner][field] = {
					isFunction = declaration.isFunction == true or (value and value.kind == "function") == true,
					params = params, returns = returned, generics = generics, constraints = constraints,
					predicates = predicates, overloads = overloads,
					doc = documentationOf(parsed, declaration),
				}
			end
			if declaration.qualifier == "global" then
				prepared.globalNames[declaration.name] = true
			end
			if #params > 0 or returned or #predicates > 0 or #overloads > 0 then
				-- A global the definitions declare, remembered by name: the analyzer reads the
				-- signatures through the document's own table, so a pass that asks "is this name
				-- known" cannot iterate it to find them.
				if not declaration.name:find("[%.:]") then
					prepared.globalNames[declaration.name] = true
				end
				prepared.signatures[declaration.name] = {
					params = params, returns = returned, generics = generics,
					constraints = constraints, predicates = predicates, overloads = overloads,
					doc = documentationOf(parsed, declaration),
				}
				if returned and returned.type and not next(generics) then
					-- A generic return is known only once the arguments are, so it is left out: a
					-- recorded `T` would be cached as the answer and never revisited. The call is
					-- bound at the call site instead.
					local bare = returned.type:gsub("%.%.%.$", "")
					prepared.returns[declaration.name] = types.parse(bare, resolve)
				end
			end
		end
	end

	local resolveAll = doc.classes.resolver(prepared)
	for className, fields in pairs(classFields) do
		for field, entry in pairs(fields) do
			if entry.isFunction then
				-- A generic in a stdlib signature is bound at the call site, so all this knows is
				-- what the name was limited to.
				local local_ = withGenerics(entry.generics, entry.constraints, resolveAll)
				local params, isVariadic = {}, false
				for _, annotation in ipairs(entry.params) do
					if annotation.name == "..." then
						isVariadic = true
					else
						params[#params + 1] = annotation.type
							and types.parse(annotation.type, local_) or types.UNKNOWN_TYPE
					end
				end
				local returned = entry.returns and entry.returns.type
				local bare = returned and (returned:gsub("%.%.%.$", "")) or nil
				local fnType = types.fn(params,
					(bare and types.parse(bare, local_)) or types.ANY_TYPE, isVariadic)
				doc.classes.evolve(prepared, className, field, fnType)
				-- The annotations stay reachable from the type they built, so a call through the
				-- field is checked and bound exactly as a call to a named function is. A class is
				-- built from this same table, which is what makes the identity hold.
				prepared.fields[fnType] = entry
			end
		end
	end

	return prepared
end

--- The metamethods Lua has, and how many arguments each one is handed besides the value it was
--- found on: `__add` gets the other operand, `__len` gets nothing more. A `table` entry may also
--- be a table rather than a function, which is what `__index` and `__newindex` allow.
local METAMETHODS = {
	__index = { arity = 1, table = true }, __newindex = { arity = 2, table = true },
	__add = { arity = 2 }, __sub = { arity = 2 }, __mul = { arity = 2 }, __div = { arity = 2 },
	__mod = { arity = 2 }, __pow = { arity = 2 }, __idiv = { arity = 2 }, __concat = { arity = 2 },
	__eq = { arity = 2 }, __lt = { arity = 2 }, __le = { arity = 2 }, __band = { arity = 2 },
	__bor = { arity = 2 }, __bxor = { arity = 2 }, __shl = { arity = 2 }, __shr = { arity = 2 },
	__call = { arity = nil, table = false },
	__unm = { arity = 1 }, __len = { arity = 1 }, __bnot = { arity = 1 }, __tostring = { arity = 1 },
	-- Accepted but not wired to anything: LuaJIT ignores `__len` for tables and has no `__pairs`
	-- at all, and the bitwise operators are Lua 5.3, so a metatable may name them without the
	-- engine ever asking.
	__pairs = { arity = 1 }, __gc = { arity = 1 }, __close = { arity = 1 },
	__metatable = { value = true }, __mode = { value = true }, __name = { value = true },
}

--- The type a table declares for one of its fields, or nil when it declares none. The
--- difference matters: a class answers `mutable` for a field it never heard of, and that is not
--- a signature anyone wrote down.
---@param held lye.doc.Type?
---@param field string
---@return lye.doc.Type?
local function declaredField(held, field)
	if not held then return nil end
	if held.variant == "union" then
		for _, member in ipairs(held.types) do
			local found = declaredField(member, field)
			if found then return found end
		end
		return nil
	end
	local fields = held.fields
	return fields and fields[field]
end

--- A metatable is a table of metamethods, and Lua has a fixed list of them. Everything Lua will
--- ask it for has to be a function of the shape the operation calls it with, or the metatable
--- promises something the engine cannot do — which is worth saying before it happens at runtime.
---@param self lye.analyzer.Result
---@param parsed lye.parser.Result
---@param metatable lye.doc.Type?
---@param held lye.doc.Type? the value the metatable is being set on
---@param nodeIdx integer the argument, so a fault is reported where it was written
local function checkMetatable(self, parsed, metatable, held, nodeIdx)
	if not metatable or (metatable.variant ~= "object" and metatable.variant ~= "class") then return end
	local node = parsed.nodes[nodeIdx]
	for name, fieldType in pairs(metatable.fields or {}) do
		if name:sub(1, 2) == "__" then
			local known = METAMETHODS[name]
			local report
			if not known then
				report = string.format("`%s` is not a metamethod Lua has", name)
			elseif not known.value then
				-- Whether a metamethod is a function of the right shape is the `lye.Metatable`
				-- constraint's business, since the definitions say it; this checks what the
				-- annotation cannot know, which is the value it is being set on.
				local isFunction = types.isFn(fieldType)
				if isFunction and known.arity and held then
					-- The value the metamethod is found on is the first argument the engine passes,
					-- and a binary metamethod is handed the other operand second.
					local positions = known.arity == 2 and { 1, 2 } or { 1 }
					for _, position in ipairs(positions) do
						local wanted = fieldType.params[position]
						if wanted and types.mismatch(wanted, held, name) then
							report = string.format("`%s` takes %s as argument %d, but it is set on %s",
								name, types.display(wanted), position, types.display(held))
							break
						end
					end
				end
			end
			if report then
				self.diagnostics[#self.diagnostics + 1] = {
					message = report, severity = 1,
					start = node.start, stop = node.stop,
				}
			end
		end
	end
end

---@param source string
---@param prepared lye.analyzer.Prelude? what the definitions declare
---@param elsewhere table<string, boolean>? type names other files declare, which are not typos
---@param modules fun(name: string): lye.doc.Type? ? what `require("name")` is, when the caller can
--- find the file: the analyzer reads the document it is given, and a module lives elsewhere
---@return lye.analyzer.Result
function analyzer.analyze(source, prepared, elsewhere, modules)
	assert(type(source) == "string", "analyzer.analyze expects a string")

	local parsed = Parser.new(source):parse()
	local annotations = doc.parse(source, parsed.tokens)
	
	-- What this file declares, so a class name or an alias in an annotation means what it says.
	-- Read before anything parses a type. The definitions are folded in first, so the standard
	-- library's classes are known here and this file's own win where they disagree.
	local namespace = doc.classes.read(annotations)
	if prepared then
		-- The definitions are reached through the namespace rather than copied into it. Every
		-- analysis builds a namespace of its own, and copying several hundred classes and aliases
		-- into it on each keystroke is work that is thrown away with the namespace: a name the
		-- document does not declare reads from the prepared tables instead, which are already built.
		setmetatable(namespace.classes, { __index = prepared.classes })
		setmetatable(namespace.aliases, { __index = prepared.aliases })
		-- The methods the definitions added to their classes, which the resolver reads from here.
		-- This one is copied: a method declared on a definition's class has to merge with what the
		-- definitions already put there without writing into the prepared entry.
		for className, fields in pairs(prepared.evolved or {}) do
			namespace.evolved = namespace.evolved or {}
			namespace.evolved[className] = namespace.evolved[className] or {}
			for field, method in pairs(fields) do
				namespace.evolved[className][field] = method
			end
		end
	end
	local resolve = doc.classes.resolver(namespace)

		-- Declared returns are needed while typing declarations, and a `@return` belongs to the
	-- declaration below it, so this is resolved from the annotations alone.
	local returns = {}
	if prepared then
		-- Reached rather than copied, like the namespace: a returned type the document does not
		-- name itself is read from what the definitions already built.
		setmetatable(returns, { __index = prepared.returns })
	end
	for _, declaration in ipairs(parsed.declarations) do
		local _, returned, generics, constraints = signatureOf(parsed, annotations, declaration)
		if returned and returned.type then
			-- The return of a generic function is a type variable too: `@generic T` with
			-- `@return T` says the function returns whatever it was given.
			returns[declaration.name] = types.parse(returned.type,
				withGenerics(generics, constraints, resolve))
		end
	end

	-- `self` is declared before the closure that reads it, so the closure captures this
	-- table rather than an outer name.
	local self = { parser = parsed, variables = {}, byStart = {}, diagnostics = {}, doc = annotations }

		-- A name an annotation writes has to mean something. `---@return s` where nothing declares `s`
	-- is a typo, and reading it as a type nothing knows about lets it pass as one. The definitions,
	-- this file's own classes and aliases, the generics it declares and the names other files
	-- declare are what a name may be.
	local declared = {}
	-- `annotations` is the parsed doc file; the annotations themselves are on it. Reading it as the
	-- list silently sees nothing at all.
	local list = annotations.annotations

	--- `---@class Box<T>` and `---@alias List<T> T[]` carry their parameters in front of the type,
	--- in brackets. They are names a file may use, not part of what it says.
	---@param text string
	---@return string? params the text between the brackets
	---@return string rest what follows them
	local function splitParams(text)
		if text:sub(1, 1) ~= "<" then return nil, text end
		local depth = 0
		for index = 1, #text do
			local char = text:sub(index, index)
			if char == "<" then
				depth += 1
			elseif char == ">" then
				depth -= 1
				if depth == 0 then return text:sub(2, index - 1), text:sub(index + 1) end
			end
		end
		return nil, text
	end

	for _, annotation in ipairs(list) do
		if annotation.tag == "generic" then
			if annotation.name then declared[annotation.name] = true end
			-- `---@generic T: table, V` limits each name; the names are what may be used.
			for word in (annotation.text or ""):gmatch("[%a_][%w_]*") do declared[word] = true end
		elseif annotation.tag == "class" or annotation.tag == "alias" then
			local params = splitParams(annotation.typeText or "")
			for _, name in ipairs(doc.classes.readParams(params or "")) do declared[name] = true end
		end
		-- A signature may declare parameters of its own — `fn<T>(x: T) -> T` — and those names are
		-- declared by the signature, not typos in the file.
		for angle in (annotation.typeText or ""):gmatch("[%a_]+%s*<([^<>]*)>") do
			for word in angle:gmatch("[%a_][%w_]*") do declared[word] = true end
		end
	end
	for name in pairs(elsewhere or {}) do declared[name] = true end

	-- Which annotations say something about a type, and where in what they write the type is: a
	-- `---@class Dog: Animal` names a parent after a colon, a `---@cast x +T` marks the direction it
	-- moves in, a `---@generic T: table` limits a name rather than using one, and a
	--- `---@return v is -nil` proves something rather than returning a type.
	local MEANS_A_TYPE = {
		param = true, field = true, ["return"] = true, type = true, cast = true, overload = true,
		alias = true, class = true,
	}

	--- Whether the text written for a parameter is a value rather than a type: a number, a quoted
	--- string or a boolean, which is what a `const` parameter is given. An expression of literals
	--- counts, since `"a" .. "b"` is one string and `5 + 2` one number.
	---@param text string
	---@param kind string? the kind it has to be, `number` among them
	---@return boolean
	local function isValue(text, kind)
		local found = types.literalKind(text)
		return found ~= nil and (kind == nil or kind == found)
	end

	-- A `const` parameter takes a value, and what is written for it has to be one: `F<string, 5>`
	-- is what the marker asks for and `F<string, number>` is what it exists to refuse.
	for _, annotation in ipairs(list) do
		local written, from = annotation.typeText, annotation.typeStart
		if written and from and MEANS_A_TYPE[annotation.tag] then
			for owner, argsText in written:gmatch("([%a_][%w_%.]*)%s*<([^<>]*)>") do
				local held = namespace.classes[owner] or namespace.aliases[owner]
				local consts = held and held.consts
				if consts and next(consts) then
					local args = doc.classes.splitList(argsText)
					local argsAt = source:find(argsText, from, true)
					for index, param in ipairs(held.params or {}) do
						local given = args[index]
						if consts[param] and given and not isValue(given, held.constraints and held.constraints[param]) then
							local at = argsAt and source:find(given, argsAt, true)
							self.diagnostics[#self.diagnostics + 1] = {
								message = string.format(
									"`%s` is a const parameter, so it takes a literal %s rather than `%s`",
									param, (held.constraints and held.constraints[param]) or "value", given),
								start = at or annotation.start, stop = at and (at + #given - 1) or annotation.stop,
								severity = 1,
							}
						end
					end
				end
			end
		end
	end


	for _, annotation in ipairs(list) do
		local written, from = annotation.typeText, annotation.typeStart
		if written and MEANS_A_TYPE[annotation.tag] then
			if annotation.tag == "class" or annotation.tag == "alias" then
				local _, rest = splitParams(written)
				if rest ~= written then
					from = from and source:find(rest, from, true) or nil
					written = rest
				end
			end
			if annotation.tag == "class" then
				local colon = written and written:find(":", 1, true)
				if colon then
					local rest = (written:sub(colon + 1):gsub("^%s+", ""))
					from = from and source:find(rest, from, true) or nil
					written = rest
				end
			elseif annotation.tag == "field"
				and (annotation.name == "private" or annotation.name == "protected"
					or annotation.name == "public") then
				-- `---@field private balance number`: the field's own name sits between the
				-- visibility and the type, so the type is what follows it.
				local rest = written and written:match("^%s*[%w_%.]+%s+(.*)$")
				from = rest and from and source:find(rest, from, true) or nil
				written = rest
			elseif annotation.tag == "cast" then
				written = written and (written:gsub("^%s*[%+%-!%?]", ""))
			elseif annotation.tag == "return" and written:find(" is ", 1, true) then
				written = nil
			end
		else
			written = nil
		end
		if written and written ~= "" and from then
			local missing
			types.parse(written, function(name)
				-- `Box<string>` and `lye.Metatable<table>` are the class they name, and a trailing
				-- `*` is the `file*` marker rather than part of it. What is left has to look like a
				-- name at all: a description the type parser could not cut is prose, not a typo, and
				-- a quoted string is a value.
				local base = (name:match("^([^<]+)") or name):gsub("%s+$", "")
				-- `handle*` is a class whose name carries the marker, and `file*` a class named
				-- `file`, so both spellings are the name the file may have declared.
				local bare = (base:gsub("%*$", ""))
				local isName = bare:match("^[%a_][%w_%.]*$") ~= nil
				if isName and not (namespace.classes[base] or namespace.aliases[base] or declared[base]
					or namespace.classes[bare] or namespace.aliases[bare] or declared[bare]) then
					missing = missing or {}
					missing[#missing + 1] = name
				end
				return nil
			end)
			for _, name in ipairs(missing or {}) do
				local at = source:find(name, from, true)
				self.diagnostics[#self.diagnostics + 1] = {
					message = string.format("unknown type `%s`", name),
					start = at or annotation.start, stop = at and (at + #name - 1) or annotation.stop,
					severity = 1,
				}
			end
		end
	end


	local inferCtx
	---@param name string
	---@param offset integer
	---@return lye.doc.Type
	local function typeOfName(name, offset)
		local variable = lookupIn(scopeAt(self, offset), name, offset)
		if not variable then return types.mutable() end
		return analyzer.typeAt(self, variable, offset)
	end

	-- The definitions' signatures are the floor: this file's own declarations land on top.
	local signatures = {}
	if prepared then
		setmetatable(signatures, { __index = prepared.signatures })
	end
	-- What a call is checked and bound against: the name it uses where it names one, and
	-- otherwise the annotations that built the type the callee holds, which is how a function
	-- declared as a class field in a definition file is reached.
	local fieldSignatures = (prepared and prepared.fields) or {}
	-- A parameter belongs to the nearest function declared above it, which is what lets its
	-- `@param` type reach it. Declarations arrive in source order.
	local paramOwner, signatureOfDecl, annotatedBodies, bodyOwner = {}, {}, {}, {}
	-- What a field said its function returns, for the bodies written for that field: a body that
	-- gives something else, or nothing at all, contradicts the type a caller was promised.
	local fieldReturns = {}
	-- The parameters a function declares, in order. A signature built from them has the arity the
	-- function has, so a call with the wrong number of arguments can be seen.
	local declaredParams = {}
	for _, declaration in ipairs(parsed.declarations) do
		local params, returned, generics, constraints, predicates, overloads =
			signatureOf(parsed, annotations, declaration)
		if #params > 0 or returned or #predicates > 0 or #overloads > 0 then
			signatures[declaration.name] = {
				params = params, returns = returned, generics = generics, constraints = constraints,
				predicates = predicates, overloads = overloads,
				doc = documentationOf(parsed, declaration),
			}
		end
		local body = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
		if declaration.isFunction or (body and body.kind == "function") then
			if #params > 0 or returned or next(generics) or #predicates > 0 then
				signatureOfDecl[declaration] = {
					params = params, returns = returned, generics = generics, predicates = predicates,
				}
				annotatedBodies[declaration.valueIdx] = true
			end
			-- The body names the declaration it belongs to, so an inferred return can reach the
			-- signature a `@param` built.
			if body then
				bodyOwner[declaration.valueIdx] = declaration
				-- The parameters are the ones the body declares, and they belong to it alone. A
				-- function written straight into an assignment has no declaration of its own, and
				-- handing its parameters to whichever declaration came last invented arguments for
				-- a function nobody called that way.
				local list = declaredParams[declaration] or {}
				declaredParams[declaration] = list
				for _, param in ipairs(body.params or {}) do
					list[#list + 1] = param
					paramOwner[param] = declaration
				end
			end
		end
	end

	--- The parameters of a function, in order, typed by the `@param` that names them. One with no
	--- annotation is `any`: the arity is known even when the type is not.
	---@param declaration lye.parser.Declaration
	---@param signature { params: lye.doc.Annotation[] }?
	---@return lye.doc.Type[] params
	---@return boolean isVariadic
	local function paramsFor(declaration, signature, resolve)
		-- `resolve` here is the caller's, already narrowed to the function's generic names.
		local params = {}
		-- `self` is the receiver a method is called with rather than an argument a caller writes,
		-- and only the colon form makes it implicit: `function Vec.__len(self)` names a parameter
		-- the engine passes the value to, which is how a metamethod is written.
		local method = declaration.name:find(":", 1, true) ~= nil
		for _, param in ipairs(declaredParams[declaration] or {}) do
			if not (method and param.name == "self") then
				local found = paramTypeOf(signature and signature.params, param.name, resolve)
				params[#params + 1] = found or types.ANY_TYPE
			end
		end
		local body = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
		return params, (body and body.isVariadic) == true
	end

	--- The type a function's own annotations give it. A declaration with no annotation keeps the
	--- permissive callable, so only what was written down is enforced.
	---@param signature lye.analyzer.Signature
	---@return lye.doc.Type
	local function signatureTypeOf(declaration, signature)
		local local_ = withGenerics(signature.generics, signature.constraints, resolve)
		local params, isVariadic = paramsFor(declaration, signature, local_)
		for _, annotation in ipairs(signature.params) do
			if annotation.name == "..." then isVariadic = true end
		end
		local returned = signature.returns and signature.returns.type
		-- `---@return T1, T2` and `---@return T...` spread: each returned value is that type.
		local isSpread = false
		if returned and returned:sub(-3) == "..." then
			returned = (returned:sub(1, -4):gsub("%s+$", ""))
			isSpread = true
		end
		local values = returned and types.splitValues(returned)
		if values and #values > 1 then
			-- Several values: the first is the one a caller can name. The commas inside a
			-- signature are not separators, which is why this splits at the top level.
			isSpread = true
			returned = values[1]
		end
		-- A signature that names its parameters but not its return promises nothing about one, and
		-- a mutable unknown is exactly that: a caller typed before the body is read holds this same
		-- table, and the body's own return is promoted into it in place.
		return types.fn(params, (returned and types.parse(returned, local_)) or types.mutable(),
			isVariadic, isSpread)
	end

	--- The signature a call is read against, and whether it came from a name.
	---@param node lye.parser.Node
	---@return lye.analyzer.Signature? signature
	---@return lye.doc.Type? calleeType
	---@return boolean byName
	local function signatureOfCall(node)
		local named = node.callee and signatures[node.callee]
		if named then return named, nil, true end
		local calleeType = infer.calleeTypeOf(inferCtx, node)
		return calleeType and fieldSignatures[calleeType], calleeType, false
	end

	-- The loops in the document, so a control variable can find the one that declares it. A
	-- `for` declares its own names rather than receiving them from a statement, and this is how
	-- they are found again; the innermost holding one is the same containment rule `return` uses.
	local forNodes = {}
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "for" then forNodes[#forNodes + 1] = node end
	end
	---@param variable lye.analyzer.Variable
	---@return lye.parser.Node?
	local function loopOf(variable)
		local owner
		for _, node in ipairs(forNodes) do
			if node.start <= variable.start and variable.start <= node.stop
				and (not owner or node.start > owner.start) then
				owner = node
			end
		end
		return owner
	end

	local root, byRecord = buildScopes(parsed)
	self.root = root
	collectNarrowing(parsed, byRecord, signatures, resolve)
	inferCtx = infer.context(parsed, typeOfName, returns, function(base, baseName, field, offset)
		return analyzer.fieldTypeAt(self, base, baseName, field, offset)
	end, modules)
	for index, node in ipairs(parsed.nodes) do
		if node.kind == "function" then
			local declaration = bodyOwner[index]
			if declaration then
				local signature = signatureOfDecl[declaration]
				-- A declaration that says what it returns hands that to the function's type: the
				-- body is what implements the signature, not what replaces it. Without one it is a
				-- mutable unknown, so a call typed before the body settles stays promotable.
				local annotated = signature and signature.returns and signature.returns.type
				local returned = annotated
					and types.parse(annotated, withGenerics(signature.generics, signature.constraints, resolve))
					or types.mutable()
				inferCtx.fnTypes[index] = types.fn(
					paramsFor(declaration, signature, resolve),
					returned,
					(parsed.nodes[index].isVariadic == true)
				)
			end
		end
	end

	-- A method declared on a class is part of it: `function Foo:bar()` gives every `Foo` a `bar`
	-- that returns what the body returns. Done before typing so a call reads the finished class.
	for _, declaration in ipairs(parsed.declarations) do
		if declaration.valueIdx then
			local className, methodName = declaration.name:match("^([%w_%.]+)%s*[%.:]([%w_]+)$")
			-- Only the last segment names the method: `A.B.c` is a method of `A.B`.
			if className and methodName and namespace.classes[className] then
				local methodType = inferCtx.fnTypes[declaration.valueIdx]
					or (declaration.valueIdx and infer.at(inferCtx, declaration.valueIdx))
				if methodType and types.isFn(methodType) then
					doc.classes.evolve(namespace, className, methodName, methodType)
				end
			end
		end
	end
	-- Declaration first, typing second. Every name is in scope before any initializer is
	-- typed, so `local v = t.foo` can resolve `t` even though it was declared earlier.
	local byDeclaration = {}
	for _, declaration in ipairs(parsed.declarations) do
		if declaration.qualifier ~= "label" then
			local declared = analyzer.declaredTypeFor(parsed, annotations, declaration, resolve)
			if not declared then
				-- Only annotations make a declared signature: an unannotated function is typed
				-- from its own body, which already carries the parameters and the inferred return.
				local mine = signatureOfDecl[declaration]
				if mine then
					declared = signatureTypeOf(declaration, mine)
				else
					local ownerDecl = paramOwner[declaration]
					local owned = ownerDecl and signatureOfDecl[ownerDecl]
					declared = paramTypeOf(owned and owned.params, declaration.name,
						withGenerics(owned and owned.generics, owned and owned.constraints, resolve))
					-- `self` is the receiver, and a method is declared `function Foo:bar`, so the
					-- class is named right there.
					if not declared and declaration.name == "self" and ownerDecl then
						local className = ownerDecl.name:match("^(.-)%s*:")
						if className then declared = resolve(className) end
					end
					-- A parameter with no `@param` is `any`: the arity is known, the type is not.
					if not declared and declaration.qualifier == "param" then
						declared = types.ANY_TYPE
					end
				end
			end
			local variable = {
				declaration = declaration,
				name = declaration.name,
				qualifier = declaration.qualifier,
				start = declaration.start,
				stop = declaration.stop,
				scope = scopeAt(self, declaration.start),
				declared = declared,
				initializer = types.mutable(),
				assignments = {},
				references = {},
			}
			self.variables[#self.variables + 1] = variable
			self.byStart[declaration.start] = variable
			byDeclaration[declaration] = variable
			-- Every declaration is kept, not just the last: the scope is a list per name.
			local declared = variable.scope.variables[declaration.name]
			if not declared then
				declared = {}
				variable.scope.variables[declaration.name] = declared
			end
			declared[#declared + 1] = variable
		end
	end

	--- The type of the table a name is a field of: `x` in `x.call`, `A.B` in `A.B.c`. A local,
	--- a global or a class all answer, and a dotted name is walked one field at a time.
	---@param text string
	---@param offset integer
	---@return lye.doc.Type?
	local function receiverTypeOf(text, offset)
		local variable = lookupIn(scopeAt(self, offset), text, offset)
		if variable then return variable.declared or analyzer.typeAt(self, variable, offset) end

		local held = resolve(text)
		if held or not text:find(".", 1, true) then return held end
		local head, rest = text:match("^([%w_]+)%.(.+)$")
		if not head then return nil end
		local root = lookupIn(scopeAt(self, offset), head, offset)
		held = root and (root.declared or analyzer.typeAt(self, root, offset)) or resolve(head)
		for segment in rest:gmatch("[%w_]+") do held = declaredField(held, segment) end
		return held
	end

	--- Whether a field is one this document's own method declaration put on a class. A method
	--- written on a class is part of that class, so reading the field back as a promise the body
	--- has to keep would make every method its own annotation.
	---@param held lye.doc.Type?
	---@param field string
	---@return boolean
	local function declaredHere(held, field)
		local class = held and held.name and namespace.classes[held.name]
		if not class then return false end
		-- A `---@field` is a promise the body has to keep, even though the class also grew the
		-- field from this very declaration. Only a field that has *nothing* but the method
		-- declaration behind it is the document describing itself.
		for _, declared in ipairs(class.fields or {}) do
			if declared.name == field then return false end
		end
		local evolved = namespace.evolved and namespace.evolved[held.name]
		return evolved ~= nil and evolved[field] ~= nil
	end

	--- A function written for a field takes the field's type: the parameters it declares and the
	--- result it gives are the ones the field was annotated with. A field a reader typed should
	--- not have to be typed again on the body that fills it in.
	---@param name string the name it is written for, `x.call` or `x:call`
	---@param valueIdx integer the function itself
	---@param list lye.parser.Declaration[]? the parameters it declares, `self` first
	local function adoptFieldFunction(name, valueIdx, list)
		local base, field = name:match("^(.-)%s*[%.:]([%w_]+)$")
		if not (base and base ~= "" and list and list[1]) then return end

		local held = receiverTypeOf(base, parsed.nodes[valueIdx].start)
		if declaredHere(held, field) then return end
		local wanted = declaredField(held, field)
		if not wanted then
			-- `function Cache:put()` is a method of the class `Cache`, which is often a local whose
			-- own type is the table it was built from rather than the class it names. The name is
			-- the class, so the field is looked for there before this gives up.
			held = resolve(base)
			wanted = declaredField(held, field)
		end
		-- A class carries the method it evolved from this very declaration, with the parameters
		-- nothing has typed yet, and that one is merged over the field the reader wrote. When a
		-- `---@field` says what the signature is, that is the promise being implemented, so it is
		-- read from the annotation rather than from the class.
		local className = held and held.name
		local byHand = className and doc.classes.fieldsOf(namespace, className)[field]
		if byHand then wanted = types.parse(byHand.type, resolve) or wanted end
		if not wanted or not types.isFn(wanted) then return end

		-- Either side may spell the receiver out and the other may leave it implicit:
		-- `fun(self: App, x: string)` names it, `fun(x: string)` does not, and `function x:call(y)`
		-- has one that `x.call = function(y)` does not write down. A parameter list one longer than
		-- the other side's belongs to the receiver, and the receiver's own type says so.
		local shift = 0
		if #wanted.params == #list + 1 and held
			and not types.mismatch(wanted.params[1], held, "self") then
			shift = 1
		elseif #wanted.params == #list - 1 and list[1].name == "self" then
			shift = -1
		elseif #wanted.params ~= #list then
			return
		end

		local params = {}
		for index, param in ipairs(list) do
			local paramType = wanted.params[index + shift]
			if not paramType and param.name == "self" then paramType = held end
			local variable = byDeclaration[param]
			if variable and paramType then variable.declared = paramType end
			if param.name ~= "self" then params[#params + 1] = paramType or types.ANY_TYPE end
		end

		local fnType = inferCtx.fnTypes[valueIdx]
		if fnType then
			fnType.params = params
			-- The field's word on the result stands, the way a `@return` does.
			if wanted.returns then fnType.returns = wanted.returns end
		end
		if wanted.returns then fieldReturns[valueIdx] = wanted.returns end
		annotatedBodies[valueIdx] = true
	end

	-- `function x:call(y)` and `x.call = function(y)` are the same function written for the same
	-- field, so both are read the same way.
	for _, declaration in ipairs(parsed.declarations) do
		local value = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
		if value and value.kind == "function" then
			adoptFieldFunction(declaration.name, declaration.valueIdx, value.params)
		end
	end
	-- A function assigned to a value whose type was written down takes that type's parameters. The
	-- signature says what the body is, so in `---@type fn(x: number) -> number local f = |x| -> x + 1`
	-- the `x` inside the body is a number and not merely the `any` an unannotated parameter starts
	-- as — which is what makes the body's own arithmetic mean something.
	for _, declaration in ipairs(parsed.declarations) do
		local value = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
		local owner = byDeclaration[declaration]
		local held = owner and owner.declared
		local list = value and value.kind == "function" and value.params or nil
		-- A method's own receiver is not one of the signature's parameters, so the lists have to
		-- line up exactly for this to mean anything.
		if held and types.isFn(held) and list and #list == #held.params then
			for index, param in ipairs(list) do
				local variable = byDeclaration[param]
				local paramType = held.params[index]
				if variable and paramType and (variable.declared == nil or variable.declared == types.ANY_TYPE) then
					variable.declared = paramType
				end
			end
		end
	end

	-- The assignment form is not a declaration, so the parameters are the function's own and the
	-- name comes from the target: `x.call = function(y)` is read exactly like `function x:call(y)`.
	for _, node in ipairs(parsed.nodes) do
		local value = node.kind == "assignment" and node.value and parsed.nodes[node.value]
		if value and value.kind == "function" then
			local written = writtenNameOf(parsed, node.target)
			if written then adoptFieldFunction(written, node.value, value.params) end
		end
	end

	-- Collected now that names are in scope, so an assignment's value can be typed. The target
	-- belongs to the name as it resolves where the assignment is written: a map from name to
	-- declaration hands every `x = ...` to whichever `x` was declared last, which silently moved
	-- a local's assignments onto a later parameter of the same name.
	local assignments = collectAssignments(parsed)
	for _, assignment in ipairs(assignments) do
		local variable = lookupIn(scopeAt(self, assignment.at), assignment.name, assignment.at)
		if variable then
			local list = variable.assignments
			-- The type starts as a mutable unknown because typing one assignment can read the
			-- variable it writes: `current = current.parent` asks for `current` at its own
			-- offset, while its own type is still being worked out. A nil here reaches
			-- `combine` and poisons the type.
			list[#list + 1] = {
				at = assignment.at, valueIdx = assignment.valueIdx, type = types.mutable(),
			}
		end
	end
	-- Which function a `return` belongs to: the innermost function whose span holds it. Functions
	-- nest properly, so this is decided rather than guessed, and the walk back covers a literal
	-- that closed before the statement.
	local functionNodes, returnsOf = {}, {}
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "function" then functionNodes[#functionNodes + 1] = node end
	end
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "return" then
			local owner
			for _, body in ipairs(functionNodes) do
				if body.start <= node.start and body.stop >= node.stop then
					if not owner or body.start > owner.start then owner = body end
				end
			end
			if owner then
				local list = returnsOf[owner.index]
				if not list then
					list = {}
					returnsOf[owner.index] = list
				end
				list[#list + 1] = node
			end
		end
	end

	--- Type every variable from the arena. Run until it settles: a call can be met before
	--- its callee's `@return` is known, which leaves a mutable unknown for `refine` to
	--- promote in place, so one pass is not enough on its own.
	local function typeAll()
		-- A loop declares its own control variables. A numeric `for` counts, so its variable is
		-- a number; a generic `for` takes its first name from what the iterator yields. The
		-- definitions write one value per signature, so a second name stays unknown rather than
		-- being given the index type.
		-- The first variable a loop declares takes the value; the ones after it are left alone.
		-- The pass runs twice, so the slot is claimed whichever variable fills it: testing
		-- `declared` instead would hand the second name the type on the next pass.
		local claimed = {}
		for _, variable in ipairs(self.variables) do
			local node = variable.qualifier == "loop" and loopOf(variable)
			if node and not claimed[node.index] then
				claimed[node.index] = true
				if not variable.declared then
					if node.isNumeric then
						variable.declared = types.NUMBER
					else
						local first = node.children and node.children[1]
						local held = first and infer.at(inferCtx, first)
						if held and types.isFn(held) then variable.declared = held.returns end
					end
				end
			end
		end

		-- Assignments are typed before initializers, and both re-run to the fixpoint, so
		-- `local y = x` sees what `x` was assigned above it rather than what it started as.
		for _, variable in ipairs(self.variables) do
			-- A standard library constant is not this document's to type.
			if not variable.isPrelude then
				for _, assignment in ipairs(variable.assignments) do
					assignment.type = infer.at(inferCtx, assignment.valueIdx)
				end
				local declaration = variable.declaration
				variable.initializer = declaration.valueIdx
					and infer.at(inferCtx, declaration.valueIdx)
					or kindToType(declaration.initializer)
				-- A declared type says what the value is, and the initializer may say what Lua
				-- consults about it: `---@type Box local b = setmetatable({}, mt)` keeps both.
				local metatable = types.metatableOf(variable.initializer)
				if metatable and variable.declared and not types.metatableOf(variable.declared) then
					variable.declared = types.withMetatable(variable.declared, metatable)
				end
			end
		end
		-- What a function returns is read off its body: the union of every value it returns, or
		-- nil when it returns nothing at all, which is what a caller gets. Annotations are left
		-- alone here, so a `@return` and an inferred return can be compared later.
		for index, fnType in pairs(inferCtx.fnTypes) do
			local statements = returnsOf[index]
			local inferred
			local body = parsed.nodes[index].body
			if body then inferred = infer.at(inferCtx, body) end
			for _, statement in ipairs(statements or {}) do
				-- The *first* value, because that is what a caller reading one value gets: a
				-- `return name, count` gives the caller a name, and a union with the count claims
				-- it may be a number. A statement that returns nothing contributes nothing.
				local valueIdx = statement.children and statement.children[1]
				if valueIdx then
					local valueType = infer.at(inferCtx, valueIdx)
					inferred = inferred and types.combine(inferred, valueType) or valueType
				end
			end
			if inferred then
				fnType.returns = inferred
				-- A declaration that named its parameters but not its return takes the inferred
				-- one. `@return`, where it is written, still wins.
				local declaration = bodyOwner[index]
				local signature = declaration and signatureOfDecl[declaration]
				local variable = declaration and self.byStart[declaration.start]
				if signature and not signature.returns and variable and variable.declared then
					-- In place, so a call typed before this round reads the return the body turned
					-- out to have rather than the unknown it was given.
					if types.isFn(variable.declared) then types.promote(variable.declared.returns, inferred) end
				end
				-- A field promised its callers a result, and the body written for it has to give
				-- that. A `---@return` on the declaration is compared where every other declared
				-- type is: against what the function turned out to be, once the body is typed.
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
					message = string.format("the field says this returns %s, but nothing is returned",
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
			-- A metatable is a relationship of the value it is set on rather than a replacement for
			-- the value's own type. A class used as a metatable is how a Lua object is written,
			-- though, so `setmetatable({}, Point)` is a `Point` — and either way the relationship is
			-- kept, so `__add` and the rest are reachable from the value.
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

	-- The standard library's tables, typed as the classes the definitions describe, so
	-- `math.floor` reads a field of `mathlib`. They are constants with no declaration in this
	-- document, so typing leaves them alone; they must exist before it runs, or every read of
	-- `math` would resolve to nothing.
	if prepared then
		for globalName, className in pairs(prepared.globals) do
			-- `-1` so the read rule finds it before any declaration: a name the definitions put in
			-- the environment is in scope from the top of the file.
			local declared = self.root.variables[globalName]
			if not declared then
				declared = {}
				self.root.variables[globalName] = declared
			end
			local classType = resolve(className)
			if classType and #declared == 0 then
				declared[1] = {
					name = globalName, qualifier = "global", start = -1, stop = -1,
					scope = self.root, declared = classType, initializer = classType,
					assignments = {}, references = {},
				}
			end
		end
	end

	typeAll()
	typeAll()
	
	-- A fixed type does not evolve, so every assignment is checked against it. An annotation
	-- that contradicts the code is a bug in the code, hence severity 1. Each one is reported on
	-- its own span: the initializer where the variable is declared, and otherwise the value that
	-- was assigned, which is where the wrong type actually is.
	-- A `const` name holds what it was given. The engine refuses to write it, so an assignment is
	-- reported where it is written rather than quietly changing what the name holds.
	for _, variable in ipairs(self.variables) do
		if variable.declaration.isConst then
			for _, assignment in ipairs(variable.assignments) do
				self.diagnostics[#self.diagnostics + 1] = {
					message = string.format("`%s` is const, so it cannot be assigned to", variable.name),
					severity = 1,
					start = assignment.at, stop = assignment.at + #variable.name - 1,
				}
			end
		end
	end

	for _, variable in ipairs(self.variables) do
		if variable.declared then
			local declaration = variable.declaration
			local message = types.mismatch(variable.declared, variable.initializer, variable.name)
			if message then
				self.diagnostics[#self.diagnostics + 1] = {
					message = message, start = declaration.start, stop = declaration.stop, severity = 1,
				}
			end
			for _, assignment in ipairs(variable.assignments) do
				local assigned = types.mismatch(variable.declared, assignment.type, variable.name)
				if assigned then
					local value = parsed.nodes[assignment.valueIdx]
					self.diagnostics[#self.diagnostics + 1] = {
						message = assigned, severity = 1,
						start = value and value.start or assignment.at,
						stop = value and value.stop or assignment.at,
					}
				end
			end
		end
	end

	-- A value with a type does not grow fields nobody declared, and a function written for a field
	-- has to be the function that field says it is. Both are one complaint: what was written does
	-- not fit what the type already said.
	for _, node in ipairs(parsed.nodes) do
		local target = node.kind == "assignment" and parsed.nodes[node.target]
		local field = target and target.kind == "index" and target.field
		local base = field and writtenNameOf(parsed, target.target)
		local held = base and receiverTypeOf(base, node.start)
		-- Only a class says what its fields are. A table being built field by field is typed by
		-- what was put into it, so it is allowed to grow.
		-- `Foo.__index = Foo` is how a class is built, not a field somebody injected, so the
		-- metatable keys are left alone.
		local metatable = type(field) == "string" and field:sub(1, 2) == "__"
		-- A write can be redirected by the metatable, which is what makes a read-only or a
		-- computed table possible. The write lands in the `__newindex` value: a function may
		-- compute anything, but a table takes the field and has to declare it.
		local newindex = held and types.metamethod(held, "__newindex")
		-- Where the write lands: the value itself, the `__newindex` table when the value does not
		-- carry the field, and nowhere at all when a `__newindex` function computes the write.
		local destination
		if held and held.variant == "class" then
			destination = held
			if newindex and not held.fields[field] then
				-- `and nil or` would keep the function here: a `__newindex` function computes the
				-- write, so there is no field to check it against.
				if types.isFn(newindex) then
					destination = nil
				else
					destination = newindex
				end
			end
		end
		if held and held.variant == "class" and not metatable and not declaredHere(held, field)
			and destination then
			local wanted = declaredField(destination, field)
			local value = parsed.nodes[node.value]
			if not wanted then
				self.diagnostics[#self.diagnostics + 1] = {
					message = string.format("`%s` is not a field of %s", field,
						destination.name or types.display(destination)),
					start = target.start, stop = target.stop, severity = 1,
				}
			elseif value then
				local actual = infer.at(inferCtx, node.value)
				if value.kind == "function" then
					-- A bare `function` value says nothing about its parameters, so the signature
					-- is read off the body that was written: the parameters it declares and what
					-- it hands back.
					local params = {}
					for _, param in ipairs(value.params or {}) do
						if param.name ~= "self" then
							local variable = byDeclaration[param]
							params[#params + 1] = (variable and variable.declared) or types.ANY_TYPE
						end
					end
					actual = types.fn(params, infer.at(inferCtx, value.body) or types.VOID,
						value.isVariadic == true)
				end
				local expected = wanted
				-- The field's signature names the receiver and the value written for it does not,
				-- which is every method: line them up before they are compared.
				if actual and types.isFn(actual) and types.isFn(wanted)
					and #wanted.params == #actual.params + 1
					and not types.mismatch(wanted.params[1], held, "self") then
					local rest = {}
					for index = 2, #wanted.params do rest[index - 1] = wanted.params[index] end
					expected = types.fn(rest, wanted.returns, wanted.isVariadic)
				end
				local message = actual and types.mismatch(expected, actual, field)
				if message then
					self.diagnostics[#self.diagnostics + 1] = {
						message = message, start = value.start, stop = value.stop, severity = 1,
					}
				end
			end
		end
	end

	-- A field a class keeps to itself is read only from that class, or, when it is protected,
	-- from a class that extends it. The read is judged against the method it sits in.
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "index" and node.field and not node.isMethod then
			local targetType = infer.at(inferCtx, node.target)
			if targetType and targetType.variant == "class" then
				local visibility = (targetType.visibility or {})[node.field]
				if visibility == "private" or visibility == "protected" then
					local enclosing
					for _, body in ipairs(functionNodes) do
						if body.start <= node.start and body.stop >= node.stop then
							if not enclosing or body.start > enclosing.start then enclosing = body end
						end
					end
					local declaration = enclosing and bodyOwner[enclosing.index]
					local inside = declaration and declaration.name:match("^([%w_%.]+)%s*[%.:]")
					local allowed = inside == targetType.name
					if not allowed and visibility == "protected" and inside then
						local ownType = resolve(inside)
						allowed = ownType ~= nil and types.satisfies(ownType, targetType)
					end
					if not allowed then
						self.diagnostics[#self.diagnostics + 1] = {
							message = string.format("'%s' is %s to %s", node.field, visibility,
								targetType.name),
							start = node.start, stop = node.stop, severity = 1,
						}
					end
				end
			end
		end
	end

	-- A call that never comes back — `error` — makes what follows it in the same block dead. The
	-- statements of a block are the arena's unparented nodes; which block each one is written in
	-- is what the scope holding it says, so a nested `if` body is its own list.
	local dead = {}
	for _, node in ipairs(parsed.nodes) do
		if node.parent == parsed.root then
			local list = dead[scopeAt(self, node.start)]
			if not list then
				list = {}
				dead[scopeAt(self, node.start)] = list
			end
			list[#list + 1] = node
		end
	end
	--- The call a statement ends on, when that call never comes back: `error("x")`, and also
	--- `local value = error("x")`, whose declaration never finishes either.
	---@param node lye.parser.Node
	---@return string? label
	local function neverStatement(node)
		local call
		if node.kind == "call" then
			call = node
		elseif node.kind == "local" or node.kind == "assignment" then
			local valueIdx = node.value or (node.children and node.children[#node.children])
			local value = valueIdx and parsed.nodes[valueIdx]
			if not value or value.kind ~= "call" then return nil end
			call = value
		else
			return nil
		end
		if infer.at(inferCtx, call.index).variant ~= "never" then return nil end
		return callLabel(parsed, call)
	end

	for _, list in pairs(dead) do
		table.sort(list, function(a, b) return a.start < b.start end)
		local stopped = false
		for _, node in ipairs(list) do
			if stopped then
				self.diagnostics[#self.diagnostics + 1] = {
					message = string.format("%s never returns, so this cannot run", stopped),
					start = node.start, stop = node.stop, severity = 1,
				}
				break
			end
			stopped = neverStatement(node)
		end
	end

	-- Arithmetic on a type that can never be a number cannot work at all, so it is an error
	-- rather than a guess. A string is in that group: the engine coerces a numeric one, but the
	-- annotation says string, and `"3" * 2` is exactly the case a reader should be told about.
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "binary" and ARITHMETIC[node.op] then
			local left = infer.at(inferCtx, node.left)
			local right = infer.at(inferCtx, node.right)
			-- A type that answers this operator with a metamethod decides what the operands may
			-- be, so the parameters of that metamethod are what is checked — `Vec + Vec` is fine
			-- and `Vec + "x"` is not, whatever the engine would do with two numbers.
			local metamethod = left and right and types.metamethodFor(node.op, left, right)
			if metamethod then
				for position, operandIdx in ipairs({ node.left, node.right }) do
					local operand = parsed.nodes[operandIdx]
					local wanted = metamethod.params[position]
					local actual = position == 1 and left or right
					if operand and wanted and actual and types.mismatch(wanted, actual, node.op) then
						self.diagnostics[#self.diagnostics + 1] = {
							message = string.format("'%s' takes %s on the %s, but this is %s", node.op,
								types.display(wanted), position == 1 and "left" or "right",
								types.display(actual)),
							start = operand.start, stop = operand.stop, severity = 1,
						}
					end
				end
			else
				for _, operandIdx in ipairs({ node.left, node.right }) do
					local operand = parsed.nodes[operandIdx]
					local operandType = operand and infer.at(inferCtx, operandIdx)
					if operandType and isNeverNumeric(operandType) then
						self.diagnostics[#self.diagnostics + 1] = {
							message = string.format("'%s' needs numbers, but this is a %s",
								node.op, types.display(operandType)),
							start = operand.start, stop = operand.stop, severity = 1,
						}
					end
				end
			end
		end
	end

	-- A reference is a node that names something: a bare name, a call target, an index base.
	-- The arena has one for each, so this never has to decide whether a name token is a use.
	local globals = {}
	-- The document's own signatures are iterated here; the definitions' names are the list the
	-- prelude kept, because the table itself is reached through this one rather than copied.
	for name in pairs(signatures) do
		if not name:find("[%.:]") then globals[name] = true end
	end
	for name in pairs(prepared and prepared.globalNames or {}) do globals[name] = true end
	for _, variable in ipairs(self.variables) do
		if variable.qualifier == "global" or variable.qualifier == "field" then
			globals[variable.name] = true
		end
	end
	-- A name a statement assigns is a global the file makes: `_ = x` and `M = {}` both define
	-- one, and neither is a declaration the parser records.
	for _, assignment in ipairs(collectAssignments(parsed)) do globals[assignment.name] = true end
	-- The definitions declare globals of their own: `arg`, `_VERSION`, and whatever else the
	-- standard library puts in the environment.
	for name in pairs(prepared and prepared.globalNames or {}) do globals[name] = true end
	for _, node in ipairs(parsed.nodes) do
		local name = node.kind == "prefix" and node.callee
		if name then
			local found = lookupIn(scopeAt(self, node.start), name, node.start)
			if found then
				found.references[#found.references + 1] = node.start
				self.byStart[node.start] = found
			elseif not globals[name] then
				-- A name nothing declares and nothing in the definitions declares either: the
				-- reader is asking for a global that is not there. A global assigned in this file
				-- is in `self.variables`, so it is not reported.
				self.diagnostics[#self.diagnostics + 1] = {
					message = string.format("undefined global `%s`", name),
					start = node.start, stop = node.start + #name - 1, severity = 2,
				}
			end
		end
	end

	-- A local nothing reads is dead weight, which is what an editor tells a reader about: a
	-- warning, not a hint, because an unread name is usually a mistake rather than a style note.
	-- A name that starts with `_` is how a writer says they meant it, and it silences the rule.
	for _, variable in ipairs(self.variables) do
		local unused = variable.qualifier == "local" and #variable.references == 0
			and not variable.name:match("^_")
		if unused then
			local declaration = variable.declaration
			self.diagnostics[#self.diagnostics + 1] = {
				message = string.format("unused local `%s`", variable.name),
				start = declaration.start, stop = declaration.stop, severity = 2,
			}
		end
	end

	-- What this file gives a caller: `return { ... }` at the top level is what a module is, and the
	-- type of it is what `require("this.file")` means somewhere else. Read after typing, so the
	-- names it is built from are settled.

	-- What this file gives a caller. `return { ... }` at the top level is what a module is, and the
	-- type of it is what `require("this.file")` means somewhere else. Typed after the rounds, like
	-- every other read, so the names it is built from are settled.
	for _, node in ipairs(parsed.nodes) do
		-- Top level means the scope it is written in is the file's own: `parent` says which node was
		-- being built, which a statement inside a function body also answers with the root.
		if node.kind == "return" and scopeAt(self, node.start) == self.root and not self.module then
			local first = node.children and node.children[1]
			if first then self.module = infer.at(inferCtx, first) end
		end
	end

	checkCalls(self, parsed, signatureOfCall, returns, resolve, inferCtx, source)
	-- What each call was bound to, by node: a generic result is settled per call, and a reader
	-- asking what `f()` is — a completion after `f().` — has no other way to that answer.
	self.callTypes = inferCtx.callTypes
	self.signatures = signatures
	self.returns = returns

	-- Typing runs twice: once to settle what each value is, and again for the ones that could only
	-- be worked out from the first round. A check that reports while typing therefore sees the
	-- same fault twice, and a reader should be told about it once.
	local seen, unique = {}, {}
	for _, entry in ipairs(self.diagnostics) do
		local key = string.format("%d:%d:%s", entry.start, entry.stop or entry.start, entry.message)
		if not seen[key] then
			seen[key] = true
			unique[#unique + 1] = entry
		end
	end
	self.diagnostics = unique

	return self
end

--- Everything visible at an offset, innermost first.
---@param self lye.analyzer.Result
---@param offset integer
---@return lye.analyzer.Variable[]
function analyzer.visibleAt(self, offset)
	local out, seen, n = {}, {}, 0
	local scope = scopeAt(self, offset)
	while scope do
		for name, declared in pairs(scope.variables) do
			if not seen[name] then
				-- The nearest declaration of the name that has been reached: the same rule a read
				-- follows, so what is offered here is what the name means.
				for index = #declared, 1, -1 do
					if declared[index].start <= offset then
						seen[name] = true
						n += 1
						out[n] = declared[index]
						break
					end
				end
			end
		end
		scope = scope.parent
	end
	return out
end

---@param self lye.analyzer.Result
---@param name string
---@param offset integer
---@return lye.analyzer.Variable?
function analyzer.lookupAt(self, name, offset)
	return lookupIn(scopeAt(self, offset), name, offset)
end

return analyzer
