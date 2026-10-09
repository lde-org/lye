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

--- A condition that narrows a name, or a field of one, over a span of source.
---@class lye.analyzer.Narrowing
---@field name string
---@field field string?
---@field kind string "truthy"|"nil"|"notnil"|"type"|"nottype"
---@field wantTruthy boolean
---@field typeName string? for a `type(x) == "T"` test
---@field start integer
---@field stop integer

---@class lye.analyzer.Diagnostic
---@field message string
---@field start integer
---@field stop integer
---@field severity integer

---@class lye.analyzer.Result
---@field parser lye.parser.Result
---@field doc lye.doc.File the annotations the analysis read
---@field root lye.analyzer.Scope
---@field variables lye.analyzer.Variable[]
---@field byStart table<integer, lye.analyzer.Variable>
---@field diagnostics lye.analyzer.Diagnostic[]
---@field signatures table<string, { params: lye.doc.Annotation[], returns: lye.doc.Annotation? }>
---@field returns table<string, lye.doc.Type>

---@param result lye.parser.Result
---@return lye.analyzer.Scope
local ARITHMETIC = {
	["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true, ["^"] = true,
	["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true, ["~>>"] = true,
}

--- A type arithmetic cannot work on at all. `any` and an unresolved name are not: whatever they
--- hold may have a metamethod, so nothing is claimed about them.
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
		and type.variant ~= "extern"
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
		local found = current.variables[name]
		if found and found.start <= offset then return found end
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
--- The name an assignment target reads: `x` for a bare name, `t.foo` for a field.
---@param parsed lye.parser.Result
---@param targetIdx integer?
---@return string?
local function targetName(parsed, targetIdx)
	local node = targetIdx and parsed.nodes[targetIdx]
	while node do
		if node.kind == "prefix" or node.kind == "name" then return node.callee or node.name end
		node = node.target and parsed.nodes[node.target]
	end
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
---@return lye.analyzer.Condition?
local function readCondition(parsed, idx, invert)
	local node = parsed.nodes[idx]
	if not node then return nil end

	if node.kind == "unary" and NEGATIONS[node.op] then
		return readCondition(parsed, node.operand, not invert)
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
---@return lye.analyzer.Condition[]
local function readConditions(parsed, conditionIdx, invert)
	local node = conditionIdx and parsed.nodes[conditionIdx]
	if not node then return {} end
	local op = node.kind == "binary" and node.op
	local isConjunction, isDisjunction = CONJUNCTIONS[op] == true, DISJUNCTIONS[op] == true
	if isConjunction or isDisjunction then
		-- Only one of the two keeps asserting the same operands once inverted.
		if invert ~= isDisjunction then return {} end
		local conditions = readConditions(parsed, node.left, invert)
		for _, condition in ipairs(readConditions(parsed, node.right, invert)) do
			conditions[#conditions + 1] = condition
		end
		return conditions
	end
	local condition = readCondition(parsed, conditionIdx, invert)
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
local function collectNarrowing(parsed, byRecord)
	local ordered = {}
	for _, scope in ipairs(parsed.scopes) do ordered[#ordered + 1] = scope end
	table.sort(ordered, function(a, b) return a.start < b.start end)

	---@param condition lye.analyzer.Condition
	---@param record lye.parser.Scope
	local function add(condition, record)
		local guarded = byRecord[record].facts
		local list = guarded[condition.name]
		if not list then
			list = {}
			guarded[condition.name] = list
		end
		list[#list + 1] = {
			name = condition.name, field = condition.field, kind = condition.kind,
			wantTruthy = condition.wantTruthy, typeName = condition.typeName,
			start = record.start, stop = record.stop,
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

	for _, node in ipairs(parsed.nodes) do
		if node.kind == "if" then
			-- Each branch also knows every earlier condition is false, which is what narrows
			-- `elseif` and `else` bodies.
			local knownIdxs = {}
			for _, scope in ipairs(clausesOf(node)) do
				for _, knownIdx in ipairs(knownIdxs) do
					for _, condition in ipairs(readConditions(parsed, knownIdx, true)) do
						add(condition, scope)
					end
				end
				for _, condition in ipairs(readConditions(parsed, scope.conditionIdx, false)) do
					add(condition, scope)
				end
				if scope.conditionIdx then knownIdxs[#knownIdxs + 1] = scope.conditionIdx end
			end
		elseif node.kind == "while" or node.kind == "repeat" then
			local scope = guardedScope(node)
			-- `repeat` tests after the body, so only a nil comparison is worth asserting.
			local isInverted = node.kind == "repeat"
			if scope then
				for _, condition in ipairs(readConditions(parsed, scope.conditionIdx, isInverted)) do
					if not isInverted or condition.kind == "nil" or condition.kind == "notnil" then
						add(condition, scope)
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
	if not previous or previous.tag ~= "type" or previous.start < spanStart then return nil end
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
				if fact.kind == "type" then
					next = types.narrowTo(narrowed, fact.typeName)
				elseif fact.kind == "nottype" then
					next = types.exclude(narrowed, fact.typeName)
				elseif fact.kind == "nil" or fact.kind == "notnil" then
					next = types.narrowNil(narrowed, fact.kind == "nil")
				elseif fact.field then
					next = types.narrowField(narrowed, fact.field, fact.wantTruthy)
				else
					next = types.narrowTruthiness(narrowed, fact.wantTruthy)
				end
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
local function signatureOf(parsed, file, declaration)
	local params, returned = {}, nil
	local spanStart = annotationSpan(parsed, declaration)
	if not spanStart then return params, returned end

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
		elseif annotation.tag == "return" then
			-- Walking back, the first one met is the last written, which is the one that wins.
			if not returned then returned = annotation end
		elseif annotation.tag == "type" or annotation.tag == "class" then
			break
		end
	end
	return params, returned
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

--- The type an argument expression has, from its own kind and any name it mentions.
---@param parsed lye.parser.Result
---@param node lye.parser.Node
---@param result lye.analyzer.Result
---@param returns table<string, lye.doc.Type>
---@return lye.doc.Type
local function typeOfExpression(parsed, node, result, returns)
	if node.kind == "number" then return types.NUMBER end
	if node.kind == "string" then return types.STRING end
	if node.kind == "function" then return types.FUNCTION end
	if node.kind == "literal" then
		return node.text == "nil" and types.NIL_TYPE or types.BOOLEAN
	end
	if node.kind == "table" then
		local kinds = parsed.tableFields[node.index]
		if not kinds then return types.TABLE end
		local fields = {}
		for name, kind in pairs(kinds) do fields[name] = kindToType(kind) end
		return types.object(fields)
	end
	if node.kind == "call" and returns[node.callee or ""] then return returns[node.callee] end
	-- A bare name is a prefix node, and the node holds the name itself.
	if node.kind == "prefix" and node.callee and not node.group then
		local variable = analyzer.lookupAt(result, node.callee, node.start)
		if variable then return analyzer.typeAt(result, variable, node.start) end
	end
	return types.mutable()
end

--- Check the arguments a call passes against the callee's `@param` annotations, and collect
--- what it returns so a later `local x = f()` can be typed.
---@param self lye.analyzer.Result
---@param parsed lye.parser.Result
---@param annotations lye.doc.File
---@param signatures table<string, { params: lye.doc.Annotation[], returns: lye.doc.Annotation? }>
---@param returns table<string, lye.doc.Type>
local function checkCalls(self, parsed, annotations, signatures, returns, resolve)
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "call" and node.callee then
			local signature = signatures[node.callee]
			if signature then
				if signature.returns and signature.returns.type then
					returns[node.callee] = types.parse(signature.returns.type, resolve)
				end
				for index, argIdx in ipairs(node.args or {}) do
					local wanted = signature.params[index]
					local argument = parsed.nodes[argIdx]
					if wanted and wanted.type and argument then
						local declared = types.parse(wanted.type, resolve)
						local actual = typeOfExpression(parsed, argument, self, returns)
						local message = declared and types.mismatch(declared, actual, "argument " .. index)
						if message then
							self.diagnostics[#self.diagnostics + 1] = {
								message = string.format("%s expects %s, got %s",
									node.callee, types.display(declared), types.display(actual)),
								start = argument.start,
								stop = argument.stop,
								severity = 1,
							}
						end
					end
				end
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

---@param source string
---@return lye.analyzer.Result
function analyzer.analyze(source)
	assert(type(source) == "string", "analyzer.analyze expects a string")

	local parsed = Parser.new(source):parse()
	local annotations = doc.parse(source)

	-- What this file declares, so a class name or an alias in an annotation means what it says.
	-- Read before anything parses a type.
	local namespace = doc.classes.read(annotations)
	local resolve = doc.classes.resolver(namespace)

	-- Declared returns are needed while typing declarations, and a `@return` belongs to the
	-- declaration below it, so this is resolved from the annotations alone.
	local returns = {}
	for _, declaration in ipairs(parsed.declarations) do
		local _, returned = signatureOf(parsed, annotations, declaration)
		if returned and returned.type then
			returns[declaration.name] = types.parse(returned.type, resolve)
		end
	end

	-- `self` is declared before the closure that reads it, so the closure captures this
	-- table rather than an outer name.
	local self = { parser = parsed, variables = {}, byStart = {}, diagnostics = {}, doc = annotations }

	local inferCtx
	---@param name string
	---@param offset integer
	---@return lye.doc.Type
	local function typeOfName(name, offset)
		local variable = lookupIn(scopeAt(self, offset), name, offset)
		if not variable then return types.mutable() end
		return analyzer.typeAt(self, variable, offset)
	end

	local signatures = {}
	-- A parameter belongs to the nearest function declared above it, which is what lets its
	-- `@param` type reach it. Declarations arrive in source order.
	local paramOwner, signatureOfDecl, annotatedBodies, bodyOwner = {}, {}, {}, {}
	-- The parameters a function declares, in order. A signature built from them has the arity the
	-- function has, so a call with the wrong number of arguments can be seen.
	local declaredParams = {}
	local owner
	for _, declaration in ipairs(parsed.declarations) do
		local params, returned = signatureOf(parsed, annotations, declaration)
		if #params > 0 or returned then
			signatures[declaration.name] = { params = params, returns = returned }
		end
		local body = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
		if declaration.isFunction or (body and body.kind == "function") then
			owner = declaration
			if #params > 0 or returned then
				signatureOfDecl[owner] = { params = params, returns = returned }
				annotatedBodies[declaration.valueIdx] = true
			end
			-- The body names the declaration it belongs to, so an inferred return can reach the
			-- signature a `@param` built.
			if body then bodyOwner[declaration.valueIdx] = declaration end
			declaredParams[owner] = declaredParams[owner] or {}
			owner = owner
		elseif declaration.qualifier == "param" then
			paramOwner[declaration] = owner
			local list = owner and declaredParams[owner]
			if list then list[#list + 1] = declaration end
		end
	end

	--- The parameters of a function, in order, typed by the `@param` that names them. One with no
	--- annotation is `any`: the arity is known even when the type is not.
	---@param declaration lye.parser.Declaration
	---@param signature { params: lye.doc.Annotation[] }?
	---@return lye.doc.Type[] params
	---@return boolean isVariadic
	local function paramsFor(declaration, signature, resolve)
		local params = {}
		for _, param in ipairs(declaredParams[declaration] or {}) do
			-- `self` is the receiver of a method, not an argument a caller passes.
			if param.name ~= "self" then
				local found = paramTypeOf(signature and signature.params, param.name, resolve)
				params[#params + 1] = found or types.ANY_TYPE
			end
		end
		local body = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
		return params, (body and body.isVariadic) == true
	end

	--- The type a function's own annotations give it. A declaration with no annotation keeps the
	--- permissive callable, so only what was written down is enforced.
	---@param signature { params: lye.doc.Annotation[], returns: lye.doc.Annotation? }
	---@return lye.doc.Type
	local function signatureTypeOf(declaration, signature)
		local params, isVariadic = paramsFor(declaration, signature, resolve)
		for _, annotation in ipairs(signature.params) do
			if annotation.name == "..." then isVariadic = true end
		end
		local returned = signature.returns and signature.returns.type
		return types.fn(params, (returned and types.parse(returned, resolve)) or types.ANY_TYPE, isVariadic)
	end

	local root, byRecord = buildScopes(parsed)
	self.root = root
	collectNarrowing(parsed, byRecord)
	inferCtx = infer.context(parsed, typeOfName, returns)
	for index, node in ipairs(parsed.nodes) do
		if node.kind == "function" then
			local declaration = bodyOwner[index]
			if declaration then
				inferCtx.fnTypes[index] = types.fn(
					paramsFor(declaration, signatureOfDecl[declaration], resolve),
					-- A mutable unknown, so a call typed before the body settles stays promotable.
					types.mutable(),
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
					declared = paramTypeOf(owned and owned.params, declaration.name, resolve)
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
			variable.scope.variables[declaration.name] = variable
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
		-- Assignments are typed before initializers, and both re-run to the fixpoint, so
		-- `local y = x` sees what `x` was assigned above it rather than what it started as.
		for _, variable in ipairs(self.variables) do
			for _, assignment in ipairs(variable.assignments) do
				assignment.type = infer.at(inferCtx, assignment.valueIdx)
			end
			local declaration = variable.declaration
			variable.initializer = declaration.valueIdx
				and infer.at(inferCtx, declaration.valueIdx)
				or kindToType(declaration.initializer)
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
				for _, valueIdx in ipairs(statement.children or {}) do
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
					if types.isFn(variable.declared) then variable.declared.returns = inferred end
				end
			elseif not annotatedBodies[index] then
				-- No returns at all, or a bare `return`, means the caller gets nil. A declaration
				-- that says what it returns is left alone: a stub has not contradicted it yet.
				fnType.returns = types.NIL_TYPE
			end
		end
		infer.refine(inferCtx, returns)
	end

	typeAll()
	typeAll()

	-- A fixed type does not evolve, so every assignment is checked against it. An annotation
	-- that contradicts the code is a bug in the code, hence severity 1. Each one is reported on
	-- its own span: the initializer where the variable is declared, and otherwise the value that
	-- was assigned, which is where the wrong type actually is.
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

	-- Arithmetic on a type that can never be a number cannot work at all, so it is an error
	-- rather than a guess. A string is in that group: the engine coerces a numeric one, but the
	-- annotation says string, and `"3" * 2` is exactly the case a reader should be told about.
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "binary" and ARITHMETIC[node.op] then
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

	-- A reference is a node that names something: a bare name, a call target, an index base.
	-- The arena has one for each, so this never has to decide whether a name token is a use.
	for _, node in ipairs(parsed.nodes) do
		local name = node.kind == "prefix" and node.callee
		if name then
			local found = lookupIn(scopeAt(self, node.start), name, node.start)
			if found then
				found.references[#found.references + 1] = node.start
				self.byStart[node.start] = found
			end
		end
	end

	checkCalls(self, parsed, annotations, signatures, returns, resolve)
	self.signatures = signatures
	self.returns = returns

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
		for name, variable in pairs(scope.variables) do
			if not seen[name] and variable.start <= offset then
				seen[name] = true
				n += 1
				out[n] = variable
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
