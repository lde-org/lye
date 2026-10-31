--[[
	What an analysis reports: the promises a document makes about itself, checked against the code.

	Every check runs after the typing rounds, when both sides of its comparison are known.
]]

local types = require("lye-doc.type")
local memo = require("lye-analyzer.memo")
local diagnostic = require("lye-analyzer.diagnostic")
local infer = require("lye-analyzer.infer")
local names = require("lye-analyzer.names")
local annotations = require("lye-analyzer.annotations")
local writtenNameOf = names.writtenNameOf
local isNeverNumeric, callLabel = annotations.isNeverNumeric, annotations.callLabel

--- Everything the checks share, all of it built by `analyzer.analyze` before it calls this.
---@class lye.analyzer.CheckContext
---@field prepared lye.analyzer.Prelude? the definitions, when the caller built them
---@field parsed lye.parser.Result
---@field self lye.analyzer.Result
---@field signatures table<string, lye.analyzer.Signature>
---@field returns table<string, lye.doc.Type>
---@field resolve fun(text: string): lye.doc.Type?
---@field inferCtx lye.infer.Context the memoising context `infer` reads
---@field callbackReturns table<integer, lye.doc.Type>
---@field byDeclaration table<lye.parser.Declaration, lye.analyzer.Variable>
---@field functionNodes lye.parser.Node[] every function body in the document
---@field bodyOwner table<lye.parser.Node, lye.parser.Declaration> the declaration each body implements
---@field annotatedBodies table<integer, boolean> the bodies whose declaration was annotated
---@field receiverTypeOf fun(text: string, offset: integer): lye.doc.Type?
---@field declaredHere fun(held: lye.doc.Type, field: string): boolean
---@field inferredValuesOf fun(index: integer): lye.doc.Type[]
---@field inferredReturnOf fun(index: integer): lye.doc.Type?
---@field scopeAt fun(self: lye.analyzer.Result, offset: integer): lye.analyzer.Scope
---@field lookupIn fun(scope: lye.analyzer.Scope, name: string, offset: integer): lye.analyzer.Variable?
---@field typeAt fun(self: lye.analyzer.Result, variable: lye.analyzer.Variable, offset: integer): lye.doc.Type
---@field declaredField fun(held: lye.doc.Type, field: string): lye.doc.Type?
---@field assignments { name: string, at: integer, valueIdx: integer, valuePosition: integer? }[]
---@field reusedSpan fun(from: integer, to: integer): boolean?
---@field nodes lye.parser.Node[]? the nodes outside reused items, when most of the document is reused
---@field nodesOf fun(kind: string): lye.parser.Node[] the nodes of one kind, restricted to the same
---@field arithmetic table<string, boolean>
---@field counters table<string, number>? the phase timings, when the caller asked for them

local checks = {}

--- Whether a span belongs to an item whose cached result is being reused. Its diagnostics were
--- produced by the analysis that cached it and are copied from there; running the check again
--- would either duplicate them or report a stale one.
---@param ctx lye.analyzer.CheckContext
---@param start integer
---@param stop integer
local function reused(ctx, start, stop)
	return ctx.reusedSpan ~= nil and ctx.reusedSpan(start, stop) == true
end

--- A type written `fun(...):...` is the permissive callable written the long way: every parameter
--- it names is `any`, it takes any number of them and it gives back `any` — which is exactly what
--- the name `function` says. A hint rather than a warning, because what it means is right and it is
--- only longer; and the same hint for the inline spelling a definition file uses.
---@param ctx lye.analyzer.CheckContext
local function anyFunctionHints(ctx)
	local self, parsed, resolve = ctx.self, ctx.parsed, ctx.resolve

	---@param text string?
	---@param start integer?
	---@param stop integer?
	local function check(text, start, stop)
		-- `function` itself is the answer, not the question: the name stands for the same callable
		-- and is what a reader of the hint is being asked to write.
		if not text or not start or text == "function" then return end
		---@cast start integer
		---@cast stop integer
		-- Only the spelling: `Foo` where `---@alias Foo fun(...):...` says the same callable is a
		-- name for it, and the name is what the reader is owed. The check is also what keeps this
		-- cheap — the annotations of a document are mostly names and literals.
		if not text:match("^%s*%(?%s*fu?n%s*%(") then return end
		local held = memo.parse(text, resolve)
		if held and types.isAnyFn(held) then
			diagnostic.add(self, string.format("`%s` is identical to `function`", text), start, stop, 3, "redundant-function")
		end
	end

	for _, annotation in ipairs(self.doc and self.doc.annotations or {}) do
		-- An `---@overload` is the one place a function type cannot be written as a name: it
		-- describes a call shape — `fun(...):...` says every call fits — and `function` says
		-- nothing about shape, so the advice would not apply.
		if annotation.tag ~= "overload" and not reused(ctx, annotation.start, annotation.stop) then
			check(annotation.type, annotation.typeStart or annotation.start,
				annotation.typeStop or annotation.stop)
		end
	end
	for _, declaration in ipairs(parsed.declarations) do
		if not reused(ctx, declaration.start, declaration.stop or declaration.start) then
			check(declaration.inlineType, declaration.inlineTypeStart, declaration.inlineTypeStop)
		end
	end
	for _, node in ipairs(ctx.functionNodes or {}) do
		if not reused(ctx, node.start, node.stop) then
			check(node.inlineReturns, node.inlineReturnsStart, node.inlineReturnsStop)
			check(node.inlineVariadic, node.inlineVariadicStart, node.inlineVariadicStop)
		end
	end
end

---@param first lye.parser.Node
---@param second lye.parser.Node
local function startsBefore(first, second)
	return first.start < second.start
end

---@param ctx lye.analyzer.CheckContext
local function returnHints(ctx)
	-- Explicit return annotations on exported functions are public API documentation. A local helper
	-- that is not exported is different: its annotation is a line kept in step with the body for
	-- nothing, and it should be reported by default. The environment variable forces the audit for
	-- every function, exported or not. The inferred values below are still recorded either way:
	-- hover and signature help read them.
	local forceHints = os.getenv("LYE_REDUNDANT_RETURNS") == "1"
	local parsed, self = ctx.parsed, ctx.self
	local signatures = ctx.signatures
	local resolve = ctx.resolve
	local inferredValuesOf = ctx.inferredValuesOf

	-- Where each `---@return` line is written, so a declaration can be asked how many describe it.
	-- A function returning two values writes two, and the first of them agreeing with the body is
	-- not a line to drop: the second moves up into its place and every caller then reads the wrong
	-- value, which is what deleting the `---@return string` above `---@return number excluded` did
	-- to `makeMainLua`.
	---@type integer[]
	local written = {}
	for _, annotation in ipairs(self.doc and self.doc.annotations or {}) do
		if annotation.tag == "return" then written[#written + 1] = annotation.start end
	end
	table.sort(written)

	---@param declaration lye.parser.Declaration
	---@param previous lye.parser.Declaration?
	local function returnsWritten(declaration, previous)
		local from, count = previous and previous.stop or 0, 0
		for _, start in ipairs(written) do
			if start > from and start < declaration.start then count = count + 1 end
		end
		return count
	end

	--- The local functions that become part of the module's surface. A `return helper` or a
	--- write to a field is public; one that is only called inside the file is not. Collected in
	--- one walk: asking this per local declaration was the declarations times the nodes.
	---@type table<string, boolean>
	local exportedNames = {}
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "return" then
			for _, child in ipairs(node.children or {}) do
				local value = parsed.nodes[child]
				if value and value.kind == "prefix" and value.callee then
					exportedNames[value.callee] = true
				end
			end
		elseif node.kind == "assignment" and node.valueIdx then
			local value = parsed.nodes[node.valueIdx]
			local target = node.target and parsed.nodes[node.target]
			if value and value.kind == "prefix" and value.callee
				and target and (target.kind == "index" or target.kind == "prefix") then
				exportedNames[value.callee] = true
			end
		end
	end

	local previous
	for _, declaration in ipairs(parsed.declarations) do
		---@type lye.analyzer.Signature?
		local signature
		if declaration.name then signature = signatures[declaration.name] end
		-- A signature keyed by a name belongs to the declaration it was read from: another
		-- declaration that happens to use the same name does not get to settle its return.
		local owned = signature ~= nil and signature.declaration == declaration
		---@cast signature lye.analyzer.Signature
		local annotation = owned and signature.returns
		local held = annotation and annotation.type and memo.parse(annotation.type, resolve)
		if owned and declaration.valueIdx
			and not reused(ctx, declaration.start, declaration.stop or declaration.start) then
			local values = inferredValuesOf(declaration.valueIdx)
			signature.inferred = values[1]
			-- Nothing written down, so what a reader is shown is what the body gives back — all of
			-- it, not only the value a call in an expression is worth.
			if not signature.values then signature.inferredValues = values end
		end
		if forceHints or (declaration.qualifier == "local" and not exportedNames[declaration.name or ""]) then
		-- An annotation that says exactly what the body says is a line kept in step with the code
		-- for nothing. A hint rather than a warning, since a written signature is often what a
		-- reader wants. Only a lone one: with a second line below it, the line is a position. The
		-- annotation may hang above a prose line and so sit outside the item it describes: that
		-- finding was not cached with the item and is reported here.
		local inferred = owned and signature.inferred
		-- One value only: `---@return number, string` is one signature, and its first half agreeing
		-- says nothing about the second. The shape has to match too, not just what it prints.
		-- A generic function's return is part of its contract: `---@return T` says what every call
		-- gets for the variable it bound, and the body's own inference of that variable is not a
		-- simpler spelling of the same promise.
		local generic = owned and signature.generics and next(signature.generics) ~= nil
		local single = not generic and annotation and annotation.type
			and #types.splitValues(annotation.type) == 1
			and returnsWritten(declaration, previous) == 1
		if single and held and inferred then
			---@cast held lye.doc.Type
			---@cast inferred lye.doc.Type
			if held.variant == inferred.variant
				and types.display(held) == types.display(inferred)
				and not reused(ctx, annotation.start, annotation.stop) then
				diagnostic.add(self, string.format("`---@return %s` says what the body already infers", annotation.type), annotation.start, annotation.stop, 3, "redundant-return")
			end
		end
		end
		previous = declaration
	end

	-- A fixed type does not evolve, so every assignment is checked against it, each reported on its
	-- own span. A `const` name is reported where it is written rather than quietly changing.
end

---@param ctx lye.analyzer.CheckContext
local function constWrites(ctx)
	for _, variable in ipairs(ctx.self.variables) do
		if variable.declaration.isConst
			and not reused(ctx, variable.declaration.start, variable.declaration.stop or variable.declaration.start) then
			for _, assignment in ipairs(variable.assignments) do
				diagnostic.add(ctx.self, string.format("`%s` is const, so it cannot be assigned to", variable.name),
					assignment.at, assignment.at + #variable.name - 1, nil, "const")
			end
		end
	end

end

---@param ctx lye.analyzer.CheckContext
local function declaredMismatches(ctx)
	local parsed, self = ctx.parsed, ctx.self
	-- A definition file's annotations are the library it describes, not a promise about a body:
	-- `---@return true?` over `function file:close() end` is the whole of the function.
	if self.isDefinition then return end
	for _, variable in ipairs(self.variables) do
		-- A name starting with `_` is a discard: what is written to it is not meant to be read, so
		-- the type it happens to have — often a loop's own index — is not a promise to check against.
		-- A parameter has no initializer to compare with: the type it declares is its value, and
		-- the placeholder beside it is the typing pass's, not a written one.
		local declared = variable.declared
		if declared ~= nil and variable.qualifier ~= "param" and not variable.name:match("^_")
			and not reused(ctx, variable.declaration.start, variable.declaration.stop or variable.declaration.start) then
			---@cast declared lye.doc.Type
			local declaration = variable.declaration
			-- A `:` method's body carries `self` as its first parameter while the annotation that
			-- describes it leaves the receiver implicit. Line the two up before comparing them, or
			-- every correctly written method is a function with one parameter too many.
			local declaredParams = types.isFn(declared) and #declared.params or 0
			---@param held lye.doc.Type
			local function withoutReceiver(held)
				-- The body of a method may or may not carry `self` in its inferred type, depending on
				-- how the function expression was read. Strip a leading receiver only when the value
				-- really has one more parameter than the annotation.
				if declaration.name:find(":", 1, true) and types.isFn(held)
					and #held.params > declaredParams then
					local params = {}
					for index = 2, #held.params do params[#params + 1] = held.params[index] end
					return types.fn(params, held.returns, held.isVariadic, held.isSpread, held.variadic)
				end
				return held
			end
			local message = types.strictMismatch(declared, withoutReceiver(variable.initializer), variable.name)
			if message then
				diagnostic.add(self, message, declaration.start, declaration.stop, nil, "type")
			end
			for _, assignment in ipairs(variable.assignments) do
				local assigned = types.strictMismatch(declared, withoutReceiver(assignment.type), variable.name)
				if assigned then
					local value = parsed.nodes[assignment.valueIdx]
					diagnostic.add(self, assigned, value and value.start or assignment.at,
						value and value.stop or assignment.at, nil, "type")
				end
			end
		end
	end

	--- Whether the write is on the table a class is *built* on rather than on a value of it.
	--- `---@class lde.Package` above `local Package = {}` declares the class and its table at once,
	--- and `Package.Config = require(...)` is how that table gets its fields — the same thing a
	--- method declaration does, written as an assignment. A value *of* the class still has only the
	--- fields the class names: `local one = Package.open(dir)` may not grow a field nobody declared.
end

---@param ctx lye.analyzer.CheckContext
local function fieldWrites(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local inferCtx = ctx.inferCtx
	local byDeclaration = ctx.byDeclaration
	local receiverTypeOf, declaredHere = ctx.receiverTypeOf, ctx.declaredHere
	local declaredField = ctx.declaredField
	---@param held lye.doc.Type
	---@param base string?
	local function buildsItsOwnClass(held, base)
		-- A class is named with its namespace, and the table it is built on carries the last part of that
		-- name. Either spelling counts.
		return base ~= nil and (held.name == base or held.name:match("%.([%w_]+)$") == base)
	end

	-- A value with a type does not grow fields nobody declared, and a function written for a field has
	-- to be the function that field says it is: what was written does not fit what the type said.
	for _, node in ipairs(ctx.nodesOf("assignment")) do
		if not reused(ctx, node.start, node.stop) then
		---@type lye.parser.Node?
		local target
		if node.kind == "assignment" then target = parsed.nodes[node.target] end
		---@type string?
		local field
		if target ~= nil and target.kind == "index" then field = target.field end
		---@type string?
		local base
		if field ~= nil then
			base = writtenNameOf(parsed, target.target)
			---@cast base string?
		end
		---@type lye.doc.Type?
		local held
		if base ~= nil then held = receiverTypeOf(base, node.start) end
		---@cast field string
		-- Only a class says what its fields are; a table built field by field is typed by what was put
		-- into it. `Foo.__index = Foo` is how a class is built, so the metatable keys are left alone.
		local metatable = type(field) == "string" and field:sub(1, 2) == "__"
		-- A write can be redirected by the metatable, which is what makes a read-only or computed table
		-- possible. The write lands in the `__newindex` value and has to fit it.
		local newindex = held and types.metamethod(held, "__newindex")
		-- Where the write lands: the value itself, the `__newindex` table when the value does not
		-- carry the field, and nowhere at all when a `__newindex` function computes the write.
		---@type lye.doc.Type?
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
			and not buildsItsOwnClass(held, base) and destination ~= nil then
			---@cast destination lye.doc.Type
			local wanted = declaredField(destination, field)
			local value = parsed.nodes[node.valueIdx]
			if not wanted then
				diagnostic.add(self, string.format("`%s` is not a field of %s", field,
						destination.name or types.display(destination)), target.start, target.stop, nil, "missing-field")
			elseif value then
				local actual = infer.at(inferCtx, node.valueIdx)
				if value.kind == "function" then
					-- A bare `function` value says nothing about its parameters, so the signature is read off the
					-- body: the parameters it declares and what it hands back.
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
				local message = actual and types.strictMismatch(expected, actual, field)
				if message then
					diagnostic.add(self, message, value.start, value.stop, nil, "type")
				end
			end
		end
		end
	end

	-- A field a class keeps to itself is read only from that class, or, when it is protected,
	-- from a class that extends it. The read is judged against the method it sits in.
end

---@param ctx lye.analyzer.CheckContext
local function metatableChecks(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local resolve, inferCtx = ctx.resolve, ctx.inferCtx
	local functionNodes, bodyOwner = ctx.functionNodes, ctx.bodyOwner
	for _, node in ipairs(ctx.nodes or parsed.nodes) do
		if not reused(ctx, node.start, node.stop) then
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
					if not allowed and visibility == "protected" and inside ~= nil then
						---@cast inside string
						local ownType = resolve(inside)
						allowed = ownType ~= nil and types.satisfies(ownType, targetType)
					end
					if not allowed then
						diagnostic.add(self, string.format("'%s' is %s to %s", node.field, visibility,
								targetType.name), node.start, node.stop, nil, "visibility")
					end
				end
			end
		end
		end
	end

	-- A call that never comes back makes what follows it in the same block dead. The statements of a
	-- block are the arena's unparented nodes, so a nested body is its own list.
end

---@param ctx lye.analyzer.CheckContext
local function deadCode(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local inferCtx = ctx.inferCtx
	local scopeAt = ctx.scopeAt
	---@type table<lye.analyzer.Scope, lye.parser.Node[]>
	local dead = {}
	-- The chunk's statements are listed by the parser, so the walk is over statements rather than
	-- over every node in the document, and the scope is asked once per statement.
	for _, index in ipairs(parsed.topLevel) do
		local node = parsed.nodes[index]
		-- A reused item's dead-code findings travelled with its cached result; only the statement
		-- this edit touched can add or remove one.
		if not reused(ctx, node.start, node.stop) then
		local scope = scopeAt(self, node.start)
		---@type lye.parser.Node[]?
		local list = dead[scope]
		if not list then
			list = {}
			dead[scope] = list
		end
		list[#list + 1] = node
		end
	end
	--- The call a statement ends on, when that call never comes back: `error("x")`, and also
	--- `local value = error("x")`, whose declaration never finishes either.
	---@param node lye.parser.Node
	local function neverStatement(node)
		local call
		if node.kind == "call" then
			call = node
		elseif node.kind == "local" or node.kind == "assignment" then
			local valueIdx = node.valueIdx or (node.children and node.children[#node.children])
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
		table.sort(list, startsBefore)
		---@type string?
		local stopped
		---@type lye.parser.Node?
		local stopping
		for _, node in ipairs(list) do
			if not reused(ctx, node.start, node.stop) then
			-- What cannot run is what comes *after* the call that never comes back. The call itself is
			-- not it, and a block lists a statement more than once — the call, and whatever the arena
			-- holds over the same span — so being a different node is not enough: the statement has to
			-- begin past the end of the one that stopped. Reading it by node identity reported the
			-- `error(...)` call as the thing that could not run, which is the opposite of true.
			if stopped ~= nil and stopping ~= nil then
				---@cast stopped string
				---@cast stopping lye.parser.Node
				if node.start > stopping.stop then
					diagnostic.add(self, string.format("%s never returns, so this cannot run", stopped), node.start, node.stop, 1, "dead-code")
					break
				end
			end
			stopped = neverStatement(node)
			stopping = stopped and node or nil
			end
		end
	end

	-- Arithmetic on a type that can never be a number cannot work at all, so it is an error rather
	-- than a guess — `"3" * 2` is exactly the case a reader should be told about.
end

---@param ctx lye.analyzer.CheckContext
local function arithmeticChecks(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local inferCtx = ctx.inferCtx
	local ARITHMETIC = ctx.arithmetic
	for _, node in ipairs(ctx.nodesOf("binary")) do
		if not reused(ctx, node.start, node.stop) then
		if ARITHMETIC[node.op] then
			local op = node.op
			---@cast op string
			local left = infer.at(inferCtx, node.left)
			local right = infer.at(inferCtx, node.right)
			-- A type that answers this operator with a metamethod decides what the operands may be, so the
			-- metamethod's parameters are what is checked.
			local metamethod = left and right and types.metamethodFor(op, left, right)
			if metamethod then
				-- A binary operator written with one parameter names the *other* operand:
				-- `---@operator add(number): number` is `self + number` or `number + self`, so the
				-- operand that declared the operator is the class itself and the parameter is what
				-- the operand written beside it has to be.
				local single = #metamethod.params == 1
				local name = types.metamethodName(op)
				local onLeft = name ~= nil and left ~= nil and types.metamethod(left, name) == metamethod
				for position, operandIdx in ipairs({ node.left, node.right }) do
					local operand = parsed.nodes[operandIdx]
					---@type lye.doc.Type?
					local wanted
					if single then
						local other = onLeft and 2 or 1
						if position == other then wanted = metamethod.params[1] end
					else
						wanted = metamethod.params[position]
					end
					local actual = position == 1 and left or right
					if operand and wanted and actual and types.mismatch(wanted, actual, op) then
						diagnostic.add(self, string.format("'%s' takes %s on the %s, but this is %s", node.op,
								types.display(wanted), position == 1 and "left" or "right",
								types.display(actual)), operand.start, operand.stop, 1, "operator")
					end
				end
			else
				for _, operandIdx in ipairs({ node.left, node.right }) do
					local operand = parsed.nodes[operandIdx]
					local operandType = operand and infer.at(inferCtx, operandIdx)
					if operandType and isNeverNumeric(operandType) then
						diagnostic.add(self, string.format("'%s' needs numbers, but this is a %s",
								node.op, types.display(operandType)), operand.start, operand.stop, 1, "operator")
					end
				end
			end
		end
		end
	end

	-- An index with a computed key asks a value what it holds there. A class that declares an index
	-- signature answers — `size[1]` on a `size_t` is the mistake the C types exist to catch.
end

---@param ctx lye.analyzer.CheckContext
local function indexedReads(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local inferCtx = ctx.inferCtx
	for _, node in ipairs(ctx.nodesOf("index")) do
		if not reused(ctx, node.start, node.stop) then
		if node.isDynamic == true and node.target and node.key then
			local base = infer.at(inferCtx, node.target)
			local key = infer.at(inferCtx, node.key)
			-- A value whose metatable answers `__index`/`__newindex` can be indexed whatever its
			-- class declares: `lua.Table` is written `argTbl[0] = v` for that very reason, and the
			-- metamethod is the class saying it holds things at keys.
			local parent = node.parent and parsed.nodes[node.parent]
			local isWrite = parent and parent.kind == "assignment" and parent.target == node.index
			local answers = base and types.metamethod(base, isWrite and "__newindex" or "__index")
			if base and base.variant == "class" and not base.indexed and not answers
				and key and key.variant == "number" then
				local at = parsed.nodes[node.key]
				diagnostic.add(self, string.format("%s cannot be indexed by a number", types.describe(base)),
					at.start, at.stop, nil, "index")
			end
		end
		end
	end

	-- A reference is a node that names something: a bare name, a call target, an index base.
	-- The arena has one for each, so this never has to decide whether a name token is a use.
end

---@param ctx lye.analyzer.CheckContext
local function globalNames(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local signatures = ctx.signatures
	local scopeAt, lookupIn = ctx.scopeAt, ctx.lookupIn
	local prepared = ctx.prepared
	local globals = {}
	-- The document's own signatures are iterated here; the definitions' names are the list the
	-- prelude kept, because the table itself is reached through this one rather than copied.
	for name in pairs(signatures) do
		---@cast name string
		if not name:find("[%.:]") then globals[name] = true end
	end
	for _, variable in ipairs(self.variables) do
		if variable.qualifier == "global" or variable.qualifier == "field" then
			globals[variable.name] = true
		end
	end
	-- A name a statement assigns is a global the file makes: `_ = x` and `M = {}` both define
	-- one, and neither is a declaration the parser records. The list is the one the analysis
	-- built its variables from, not a second walk of the document.
	for _, assignment in ipairs(ctx.assignments) do globals[assignment.name] = true end
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
			elseif not globals[name] and not reused(ctx, node.start, node.start + #name - 1) then
				-- A name nothing declares and nothing in the definitions declares either: the reader is asking
				-- for a global that is not there. A global assigned in this file is in `self.variables`.
				-- The reference is recorded whether or not the item is reused: an unused local is
				-- judged by all of its readers, and the reading items may be different ones.
				diagnostic.add(self, string.format("undefined global `%s`", name),
					node.start, node.start + #name - 1, 2, "undefined-global")
			end
		end
	end

	-- A local nothing reads is dead weight: a warning, not a hint, because an unread name is usually
	-- a mistake. A name starting with `_` is how a writer says they meant it.
end


--- A `---@param` has to name a parameter the function takes.
---
--- A name that is not one is a typo nothing else catches: the annotation is read, the parameter it
--- was meant for keeps whatever it would have had, and every call is then checked against a
--- signature describing a parameter the body does not have.
---@param ctx lye.analyzer.CheckContext
local function paramNames(ctx)
	local parsed, self = ctx.parsed, ctx.self
	for _, declaration in ipairs(parsed.declarations) do
		local signature = ctx.signatures[declaration.name]
		-- The signature records which declaration its annotations were read from, and a name
		-- declared twice keeps only the last: checking the others would report their annotations
		-- against the wrong body.
		if signature and signature.declaration == declaration and #signature.params > 0 then
			local body = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
			if body and body.kind == "function" then
				local taken = {}
				for _, param in ipairs(body.params or {}) do taken[param.name] = true end
				for _, annotation in ipairs(signature.params) do
					local name = annotation.name
					-- `...` is how the variadic parameter is annotated, and it has no name of its own.
					-- The annotation can hang above a prose line and sit outside the item it
					-- describes, so its own span is what decides whether it was cached.
					if name and name ~= "..." and not taken[name]
						and not reused(ctx, annotation.nameStart or annotation.start,
							annotation.nameStop or annotation.stop) then
						diagnostic.add(self, string.format("`%s` is not a parameter of this function", name),
							annotation.nameStart or annotation.start, annotation.nameStop or annotation.stop,
							nil, "unknown-param")
				end
			end
		end
		end
	end

end

---@param ctx lye.analyzer.CheckContext
local function unusedLocals(ctx)
	for _, variable in ipairs(ctx.self.variables) do
		local unused = variable.qualifier == "local" and #variable.references == 0
			and not variable.name:match("^_")
		if unused then
			local declaration = variable.declaration
			if not ctx.self.isDefinition then
				diagnostic.add(ctx.self, string.format("unused local `%s`", variable.name),
					declaration.start, declaration.stop, 2, "unused-local")
			end
		end
	end

	-- The same field written by an assignment rather than declared. A callback's result crosses back
	-- into C, so a body that gives the wrong thing is reported against the signature it was cast to.
end

---@param ctx lye.analyzer.CheckContext
local function callbackReturns(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local callbackReturns = ctx.callbackReturns
	local inferredReturnOf = ctx.inferredReturnOf
	local annotatedBodies = ctx.annotatedBodies
	for index, promised in pairs(callbackReturns) do
		---@cast index integer
		local node = parsed.nodes[index]
		if node and not reused(ctx, node.start, node.stop) then
		local inferred = inferredReturnOf(index)
		local gives = inferred and inferred ~= types.VOID
		if not gives and promised.variant ~= "nil" and promised.variant ~= "void" then
			if not annotatedBodies[index] then
				self.diagnostics[#self.diagnostics + 1] = {
					message = string.format(
						"the C signature says this returns %s, but nothing is returned",
						types.display(promised)),
					severity = 1,
					start = parsed.nodes[index].start, stop = parsed.nodes[index].stop,
				}
			end
		elseif gives and promised.variant ~= "nil" and promised.variant ~= "void" then
			-- A callback the C says returns nothing may still return a value: the engine discards
			-- it, so there is nothing to be wrong about.
			---@cast inferred lye.doc.Type
			local message = types.strictMismatch(promised, inferred, "the result")
			if message then
				self.diagnostics[#self.diagnostics + 1] = {
					message = message, severity = 1,
					start = parsed.nodes[index].start, stop = parsed.nodes[index].stop,
				}
			end
		end
		end
	end

	-- What this file gives a caller: a top-level `return { ... }` is what a module is, and its type
	-- is what `require("this.file")` means elsewhere. Read after typing, so its names are settled.

	-- The module's own type, published so a `require` of this file resolves to it. Typed after the
	-- rounds, like every other read, so the names it is built from are settled.
end

--- What this file gives a caller: a top-level `return { ... }` is what a module is, and its type
--- is what `require("this.file")` means elsewhere. Read after typing, so its names are settled.
---@param ctx lye.analyzer.CheckContext
local function moduleExport(ctx)
	for _, node in ipairs(ctx.parsed.byKind["return"] or {}) do
		-- Top level means the scope it is written in is the file's own: `parent` says which node was
		-- being built, which a statement inside a function body also answers with the root.
		if node.kind == "return" and ctx.scopeAt(ctx.self, node.start) == ctx.self.root and not ctx.self.module then
			---@type integer[]?
			local children = node.children
			local firstIdx
			if children ~= nil then
				---@cast children integer[]
				firstIdx = children[1]
			end
			if firstIdx ~= nil then
				---@cast firstIdx integer
				-- A definition file returns the table it declares, and that table is the class the
				-- annotations describe: `bit = {}` followed by `return bit` is `bitlib`. The
				-- analyzer's own typing of a global declaration is an object it grows from
				-- assignments, not the class, so the definitions' answer is asked first.
				local firstNode = ctx.parsed.nodes[firstIdx]
				---@type string?
				local name
				if firstNode ~= nil and firstNode.kind == "prefix" then name = firstNode.callee end
				-- Only a definition file's global backing table is the class: a document's own
				-- `local bit = {}` shadows the library and must answer as the value it built.
				local className = ctx.self.isDefinition and name
					and ctx.prepared and ctx.prepared.globals and ctx.prepared.globals[name]
				local classType = className and ctx.resolve(className)
				local held = classType or infer.at(ctx.inferCtx, firstIdx)
				-- A function written onto the table carries its annotation on the declaration, not
				-- in the callable the body built. The table the body grew holds the inferred one,
				-- and a caller requiring this file read the body's type as the contract: a
				-- `---@return boolean` over a body returning `1 + 1` became `2` on the other side.
				if classType == nil and name ~= nil and held ~= nil and held.variant == "object" then
					---@cast name string
					---@cast held lye.doc.Type
					local fields, rewritten = {}, false
					for field, fieldType in pairs(held.fields) do
						---@cast field string
						fields[field] = fieldType
						local signature = ctx.signatures[name .. "." .. field]
							or ctx.signatures[name .. ":" .. field]
						local declaration = signature and signature.declaration
						local variable = declaration and ctx.byDeclaration[declaration]
						local declared = variable and variable.declared
						if declared ~= nil then
							---@cast declared lye.doc.Type
							if types.isFn(declared) then
								fields[field] = declared
								rewritten = true
							end
						end
					end
					if rewritten then held = types.object(fields, held.indexed) end
				end
				ctx.self.module = held
			end
		end
end
end


checks.moduleExport = moduleExport

--- A value nothing is known about. `any` is the same promise from the other side: it names no
--- operation either, so indexing it, operating on it or passing it to a concrete parameter is a
--- use the analysis cannot check. Returning or storing it is not.
---@param held lye.doc.Type?
local function settledUnknown(held)
	if not held then return false end
	---@cast held lye.doc.Type
	if held.variant == "union" then
		for _, member in ipairs(held.types) do
			if settledUnknown(member) then return true end
		end
		return false
	end
	if held.variant == "any" then return true end
	if held.variant ~= "unknown" then return false end
	---@cast held lye.doc.Type
	return not types.isMutable(held)
end

--- The values a type can be when it is written as one or more string literals, or nil when it
--- names a wider family. `type()` returns such a union, and comparing it with anything outside it
--- cannot be true.
---@param held lye.doc.Type?
---@return table<string, boolean>?
local function literalStrings(held)
	if not held then return nil end
	---@param member lye.doc.Type
	local function one(member)
		if member.variant ~= "extern" or type(member.name) ~= "string" then return nil end
		local first, last = member.name:sub(1, 1), member.name:sub(-1)
		if (first == '"' or first == "'") and last == first then return types.display(member) end
	end
	if held.variant == "union" then
		local out = {}
		for _, member in ipairs(held.types) do
			local written = one(member)
			if not written then return nil end
			out[written] = true
		end
		return out
	end
	local written = one(held)
	return written and { [written] = true } or nil
end

--- A string literal compared against a union of string literals must be one of them. The case that
--- matters is `type(x) == "f"`: `type` can only answer one of its named results, so the comparison
--- is a mistake rather than a test that is simply false.
---@param ctx lye.analyzer.CheckContext
local function comparisonChecks(ctx)
	local parsed, self, inferCtx = ctx.parsed, ctx.self, ctx.inferCtx
	for _, node in ipairs(ctx.nodesOf("binary")) do
		if not reused(ctx, node.start, node.stop) then
		if node.op == "==" or node.op == "~=" or node.op == "!=" then
			local left = parsed.nodes[node.left]
			local right = parsed.nodes[node.right]
			local literal, other, otherIdx
			if left and left.kind == "string" then
				literal, other, otherIdx = left, right, node.right
			elseif right and right.kind == "string" then
				literal, other, otherIdx = right, left, node.left
			end
			if literal and literal.value and other and otherIdx then
				---@cast literal lye.parser.Node
				---@cast other lye.parser.Node
				---@cast otherIdx integer
				local allowed = literalStrings(infer.at(inferCtx, otherIdx))
				if allowed then
					local value = literal.value
					---@cast value string
					local written = types.display(types.stringValue(value))
					if not allowed[written] then
						local message = other.kind == "call" and other.callee == "type"
							and string.format("%s is not a type `type` can return", written)
							or string.format("%s is not one of the values this comparison allows", written)
						diagnostic.add(self, message, literal.start, literal.stop, 1, "type")
					end
				end
			end
		end
		end
	end
end

--- Whether a type can be nil. `void` is the absence of a value in the same way, and a union may
--- hold either member.
---@param held lye.doc.Type?
---@return boolean
local function mayBeNil(held)
	if not held then return false end
	if held.variant == "nil" or held.variant == "void" then return true end
	if held.variant == "union" then
		for _, member in ipairs(held.types) do
			if mayBeNil(member) then return true end
		end
	end
	return false
end

--- Whether every value of a type is nil, so an access cannot be guarded by a value being there.
---@param held lye.doc.Type?
local function isNil(held)
	return held ~= nil and (held.variant == "nil" or held.variant == "void")
end

--- Reading a field of a value that may be absent, or calling one, fails at runtime. The checker
--- has always known the type was optional — this is what reports the read that forgot to narrow
--- it. `?.` is the access that says the absence is allowed, and its result is optional in turn.
---@param ctx lye.analyzer.CheckContext
---@param ctx lye.analyzer.CheckContext
local function nilReads(ctx)
	local parsed, self, inferCtx = ctx.parsed, ctx.self, ctx.inferCtx

	---@param index integer?
	---@return lye.doc.Type?
	local function typeOfNode(index)
		local node = index and parsed.nodes[index]
		if node and node.kind == "prefix" and node.callee then
			local variable = ctx.lookupIn(ctx.scopeAt(self, node.start), node.callee, node.start)
			if variable then return ctx.typeAt(self, variable, node.start) end
		end
		return index and infer.at(inferCtx, index) or nil
	end

	---@param node lye.parser.Node
	---@param target lye.doc.Type
	---@param what string
	local function report(node, target, what)
		if reused(ctx, node.start, node.stop) then return end
		local message = isNil(target)
			and string.format("%s is nil", what)
			or string.format("%s may be nil", what)
		diagnostic.add(self, message, node.start, node.stop, 1, "nil-read")
	end

	-- A field the document writes a value to before the read is not read as absent at that
	-- point: `self.cache = self.cache or {}` is how a lazy field is opened, and the declared `?`
	-- describes the value before the write. This is flow-insensitive — it asks whether a non-nil
	-- write happened anywhere above — which is what keeps the lazy-field idiom out of the report.
	---@type table<string, { at: integer, valueIdx: integer? }[]>
	local assigned = {}
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "assignment" then
			local name = names.writtenNameOf(parsed, node.target)
			---@cast name string?
			if name ~= nil then
				---@type { at: integer, valueIdx: integer? }[]?
				local list = assigned[name]
				if not list then
					list = {}
					assigned[name] = list
				end
				list[#list + 1] = { at = node.start, valueIdx = node.valueIdx }
			end
		end
	end
	---@param node lye.parser.Node
	---@return boolean
	local function writtenNonNil(node)
		local target = node.target and parsed.nodes[node.target]
		local name = target and names.writtenNameOf(parsed, node.target)
		---@cast name string?
		local writes = assigned[name] or {}
		for _, write in ipairs(writes) do
			if write.at < node.start and write.valueIdx then
				local held = infer.at(inferCtx, write.valueIdx)
				if held and not mayBeNil(held) and not types.isOpaque(held) then return true end
			end
		end
		return false
	end

	for _, node in ipairs(ctx.nodes or parsed.nodes) do
		if not node.isSafe and (node.kind == "index" or node.kind == "call") and node.target then
			local targetNode = parsed.nodes[node.target]
			-- A local whose type holds nil because of one initializer is not an optional name:
			-- the branches that assign a value before the read are not joined by the typing pass,
			-- and reporting `if not x then x = {} end; x.y` would be a false positive. A declared
			-- optional, a parameter that says so, or a field is a promise the reader can see.
			local variable = targetNode and targetNode.kind == "prefix" and targetNode.callee
				and ctx.lookupIn(ctx.scopeAt(self, targetNode.start), targetNode.callee, targetNode.start)
			local checked = not variable or variable.declaredExplicit or variable.qualifier == "param"
			if checked and not writtenNonNil(node) then
				local target = typeOfNode(node.target)
				if target and mayBeNil(target) and not types.isOpaque(target) then
					report(node, target, node.kind == "call" and "this value" or "this value")
				end
			end
		end
	end
end

--- Whether an object-shaped member declares the field a read asks for. An index signature of
--- string keys answers for every name, and `nil` is not a shape that can answer.
---@param member lye.doc.Type
---@param field string
---@return boolean? known nil when the member is a class or a name the checker cannot see into
local function fieldKnown(member, field)
	if member.variant == "nil" then return nil end
	-- A table literal with no shape yet is a table being built: a read of a field it does not
	-- name says nothing about the field not existing.
	if types.isUnknownShape(member) then return nil end
	if member.variant == "intersection" then
		local unknown
		for _, one in ipairs(member.types) do
			local known = fieldKnown(one, field)
			if known == true then return true end
			if known == nil then unknown = true end
		end
		return unknown and nil or false
	end
	if member.variant == "object" then
		if member.fields[field] then return true end
		return (member.indexed and member.indexed.key == "string") == true
	end
	if member.variant == "class" then
		if member.fields[field] then return true end
		-- An index signature or a metatable can answer a name the class did not declare.
		if (member.indexed and member.indexed.key == "string") or member.metatable then return nil end
		-- A class with no fields at all is a marker or a build target; leave it open. One with a
		-- declared shape is a promise, and a write to a missing field is already reported.
		local count = 0
		for _ in pairs(member.fields) do count += 1 end
		if count > 0 then return false end
		return nil
	end
	return nil
end

--- Whether a shape is a plain object literal small enough to reason about. The analyzer's own
--- type descriptions are wide tagged unions; a missing-field report there is a narrowing question,
--- not a shape question, and it is left to the branch checks.
---@param member lye.doc.Type
local function simpleShape(member)
	if member.variant ~= "object" or member.fields.variant then return false end
	local count = 0
	for _ in pairs(member.fields) do count += 1 end
	return count <= 3
end

--- A field read on a shape that never declared it is a mistake, and so is a read on a union where
--- only some members have the field: `u.a` on `{ a: number } | { b: string }` gives `number` for a
--- value that may be the other shape. A class is checked through the fields its type already has;
--- a method declared in another file may not be in this file's class type, so a colon call is left
--- alone. A bare `table` says nothing about its members.
---@param ctx lye.analyzer.CheckContext
local function missingFieldReads(ctx)
	local parsed, self, inferCtx = ctx.parsed, ctx.self, ctx.inferCtx
	for _, node in ipairs(ctx.nodesOf("index")) do
		if not reused(ctx, node.start, node.stop) then
		if node.field and node.target and not node.isSafe then
			local parent = node.parent and parsed.nodes[node.parent]
			local isWrite = parent and parent.kind == "assignment" and parent.target == node.index
			if not isWrite then
				local target = infer.at(inferCtx, node.target)
				local field = node.field
				---@cast field string
				if target ~= nil and not types.isOpaque(target) and not types.isUnknownShape(target) then
					---@cast target lye.doc.Type
					local has, missing, checkable = false, false, true
					local isUnion = target.variant == "union"
					if isUnion then
						for _, member in ipairs(target.types) do
							if member.variant == "class" then
								-- A class can grow a field from a method at runtime, and a union read
								-- is a discriminant question for the branch checks, not a shape check.
								checkable = false
								break
							end
							if member.variant ~= "object" and member.variant ~= "nil" then
								-- A union of callable, array, conditional, extern and object members
								-- is a description of a value, not a shape: the field may belong to
								-- whichever member the branch narrowed to.
								checkable = false
								break
							end
							if not simpleShape(member) and member.variant ~= "nil" then
								checkable = false
								break
							end
						end
					end
					if checkable and isUnion then
						for _, member in ipairs(target.types) do
							local known = fieldKnown(member, field)
							if known == true then has = true elseif known == false then missing = true end
						end
					else
						local known = fieldKnown(target, field)
						if known == false and (simpleShape(target) or target.variant == "class") then missing = true end
					end
					if missing and has then
						diagnostic.add(self, string.format("`%s` is not a field of every member of this union",
							node.field), node.start, node.stop, 1, "missing-field")
					elseif missing and (target.variant == "object" or target.variant == "class") then
						diagnostic.add(self, string.format("`%s` is not a field of %s",
							node.field, types.display(target)), node.start, node.stop, 1, "missing-field")
					end
				end
			end
		end
		end
	end

	-- A method call is a call node with a field, not an index node: `p:missing()` reaches the
	-- class's field table the same way a read does. A class may answer through `__index`, and a
	-- method another file declares is in the table the class was seeded with, so only a class
	-- whose table is complete and has no answer is reported.
	for _, node in ipairs(ctx.nodesOf("call")) do
		if not reused(ctx, node.start, node.stop) and node.field and node.target and not node.isSafe then
			local target = infer.at(inferCtx, node.target)
			if self.methodsComplete and target and target.variant == "class"
				and not types.isOpaque(target)
				and (target.fromDocument or target.hasWorkspaceMethods) then
				local known = fieldKnown(target, node.field)
				if known == false then
					diagnostic.add(self, string.format("`%s` is not a field of %s",
						node.field, types.display(target)), node.start, node.stop, 1, "missing-field")
				end
			end
		end
	end
end

--- Reading, operating on or calling an unknown answer is an error. Passing one on, returning it or
--- storing it is not: an editor asking what a value is may legitimately get `unknown`, and the
--- program has not used the answer for anything yet.
---@param ctx lye.analyzer.CheckContext
local function unknownUses(ctx)
	-- A definition file is a declaration, not a program: its bodies are stubs and its unannotated
	-- values say nothing about a running program.
	if ctx.self.isDefinition then return end
	local parsed, inferCtx, self = ctx.parsed, ctx.inferCtx, ctx.self

	---@param node lye.parser.Node
	---@param message string
	local function reportUnknown(node, message)
		if reused(ctx, node.start, node.stop) then return end
		diagnostic.add(self, message, node.start, node.stop, 1, "unknown")
	end

	-- The type of an expression as the analysis now has it. A name is read through its variable,
	-- because inference may have cached the placeholder it had before the variable settled.
	---@param index integer?
	---@return lye.doc.Type?
	local function typeOfNode(index)
		local node = index and parsed.nodes[index]
		if node and node.kind == "prefix" and node.callee then
			local variable = ctx.lookupIn(ctx.scopeAt(self, node.start), node.callee, node.start)
			if variable then return ctx.typeAt(self, variable, node.start) end
		end
		return index and infer.at(inferCtx, index) or nil
	end

	for _, node in ipairs(ctx.nodes or parsed.nodes) do
		if node.kind == "index" and node.target then
			if settledUnknown(typeOfNode(node.target)) then
				reportUnknown(node, "cannot index a value of unknown type")
			end
		elseif node.kind == "call" then
			local targetNode = node.target and parsed.nodes[node.target]
			local field = node.field or (targetNode and targetNode.field)
			local name = node.callee or (targetNode and targetNode.callee)
			local known = name and (ctx.signatures[name]
				or (ctx.prepared and ctx.prepared.globalNames and ctx.prepared.globalNames[name]))
			if field then
				-- A field call reads a method from the value it targets.
				if settledUnknown(typeOfNode(node.target)) then
					reportUnknown(node, "cannot index a value of unknown type")
				end
			elseif not known and node.target then
				-- A call with no field and no signature calls the value itself: `v()` where `v` is
				-- an unknown is a use; `ipairs(...)` is a declared function and is not.
				if settledUnknown(typeOfNode(node.target)) then
					reportUnknown(node, "cannot call a value of unknown type")
				end
			elseif not known and node.callee then
				if settledUnknown(infer.calleeTypeOf(inferCtx, node)) then
					reportUnknown(node, "cannot call a value of unknown type")
				end
			end
		elseif node.kind == "binary" then
			-- `and`/`or` are control flow and pass a value through; equality is how a value nothing
			-- is known about is narrowed, so it is a use the analysis can follow. Every other
			-- operator turns its operands into a result, which nothing can say about an unknown one.
			if node.op ~= "and" and node.op ~= "or" and node.op ~= "==" and node.op ~= "~="
				and node.op ~= "!=" then
				if settledUnknown(typeOfNode(node.left))
					or settledUnknown(typeOfNode(node.right)) then
					reportUnknown(node, string.format("cannot use an unknown value with `%s`", node.op or "an operator"))
				end
			end
		elseif node.kind == "unary" then
			if node.op ~= "not" and settledUnknown(typeOfNode(node.operand)) then
				reportUnknown(node, string.format("cannot use an unknown value with `%s`", node.op or "an operator"))
			end
		end
	end
end

--- A field the class marks `---@deprecated` is reported where it is read. A read that is the
--- target of a call is left to the call check, which reports the call itself rather than the
--- field name it is written through.
---@param ctx lye.analyzer.CheckContext
local function deprecatedReads(ctx)
	local parsed, inferCtx, self = ctx.parsed, ctx.inferCtx, ctx.self
	for _, node in ipairs(ctx.nodesOf("index")) do
		if node.field and node.target and not reused(ctx, node.start, node.stop) then
			local parent = node.parent and parsed.nodes[node.parent]
			local called = parent ~= nil and parent.kind == "call" and parent.target == node.index
			if not called then
				local target = infer.at(inferCtx, node.target)
				if target and types.deprecatedField(target, node.field) then
					diagnostic.add(self, string.format("`%s` is deprecated", node.field),
						node.start, node.stop, 3, "deprecated")
				end
			end
		end
	end
end

---@param ctx lye.analyzer.CheckContext
local CHECK_LIST = {
	{ "returnHints", returnHints }, { "anyFunctionHints", anyFunctionHints },
	{ "constWrites", constWrites }, { "declaredMismatches", declaredMismatches },
	{ "fieldWrites", fieldWrites }, { "metatableChecks", metatableChecks },
	{ "deadCode", deadCode }, { "arithmeticChecks", arithmeticChecks },
	{ "comparisonChecks", comparisonChecks }, { "indexedReads", indexedReads },
	{ "globalNames", globalNames }, { "paramNames", paramNames },
	{ "unusedLocals", unusedLocals }, { "callbackReturns", callbackReturns },
	{ "nilReads", nilReads }, { "missingFieldReads", missingFieldReads },
	{ "deprecatedReads", deprecatedReads },
	{ "unknownUses", unknownUses }, { "moduleExport", moduleExport },
}

---@param ctx lye.analyzer.CheckContext
function checks.report(ctx)
	local counters = ctx.counters
	for _, entry in ipairs(CHECK_LIST) do
		if counters then
			local started = os.clock()
			entry[2](ctx)
			counters["check_" .. entry[1]] = os.clock() - started
		else
			entry[2](ctx)
		end
	end
end

return checks
