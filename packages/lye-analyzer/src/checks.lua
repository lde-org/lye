--[[
	What an analysis reports: the promises a document makes about itself, checked against the code.

	Every check runs after the typing rounds, when both sides of its comparison are known.
]]

local types = require("lye-doc.type")
local diagnostic = require("lye-analyzer.diagnostic")
local infer = require("lye-analyzer.infer")
local names = require("lye-analyzer.names")
local annotations = require("lye-analyzer.annotations")
local writtenNameOf = names.writtenNameOf
local collectAssignments, isNeverNumeric, callLabel =
	annotations.collectAssignments, annotations.isNeverNumeric, annotations.callLabel

--- Everything the checks share, all of it built by `analyzer.analyze` before it calls this.
---@class lye.analyzer.CheckContext
---@field prepared lye.analyzer.Prelude? the definitions, when the caller built them
---@field parsed lye.parser.Result
---@field self lye.analyzer.Result
---@field signatures table<string, lye.analyzer.Signature>
---@field returns table<string, lye.doc.Type>
---@field resolve fun(text: string): lye.doc.Type?
---@field inferCtx table the memoising context `infer` reads
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
---@field declaredField fun(held: lye.doc.Type, field: string): lye.doc.Type?
---@field arithmetic table<string, boolean>

local checks = {}

---@param ctx lye.analyzer.CheckContext

local function returnHints(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local signatures = ctx.signatures
	local resolve = ctx.resolve
	local inferredValuesOf = ctx.inferredValuesOf
	for _, declaration in ipairs(parsed.declarations) do
		---@type lye.analyzer.Signature?
		local signature = declaration.name and signatures[declaration.name]
		local annotation = signature and signature.returns
		local written = annotation and annotation.type and types.parse(annotation.type, resolve)
		if signature and declaration.valueIdx then
			local values = inferredValuesOf(declaration.valueIdx)
			signature.inferred = values[1]
			-- Nothing written down, so what a reader is shown is what the body gives back — all of
			-- it, not only the value a call in an expression is worth.
			if not signature.values then signature.inferredValues = values end
		end
		-- An annotation that says exactly what the body says is a line kept in step with the code for
		-- nothing. A hint rather than a warning, since a written signature is often what a reader wants.
		local inferred = signature and signature.inferred
		-- One value only: `---@return number, string` is one signature, and its first half agreeing says
		-- nothing about the second. The shape has to match too, not just what it prints.
		local single = annotation and annotation.type and #types.splitValues(annotation.type) == 1
		if single and written and inferred and written.variant == inferred.variant
			and types.display(written) == types.display(inferred) then
			diagnostic.add(self, string.format("`---@return %s` says what the body already infers", annotation.type), annotation.start, annotation.stop, 3)
		end
	end

	-- A fixed type does not evolve, so every assignment is checked against it, each reported on its
	-- own span. A `const` name is reported where it is written rather than quietly changing.
end

local function constWrites(ctx)
	for _, variable in ipairs(ctx.self.variables) do
		if variable.declaration.isConst then
			for _, assignment in ipairs(variable.assignments) do
				diagnostic.add(ctx.self, string.format("`%s` is const, so it cannot be assigned to", variable.name),
					assignment.at, assignment.at + #variable.name - 1)
			end
		end
	end

end

local function declaredMismatches(ctx)
	local parsed, self = ctx.parsed, ctx.self
	for _, variable in ipairs(self.variables) do
		if variable.declared then
			local declaration = variable.declaration
			local message = types.mismatch(variable.declared, variable.initializer, variable.name)
			if message then
				diagnostic.add(self, message, declaration.start, declaration.stop)
			end
			for _, assignment in ipairs(variable.assignments) do
				local assigned = types.mismatch(variable.declared, assignment.type, variable.name)
				if assigned then
					local value = parsed.nodes[assignment.valueIdx]
					diagnostic.add(self, assigned, value and value.start or assignment.at,
						value and value.stop or assignment.at)
				end
			end
		end
	end

	--- Whether the write is on the table a class is *built* on rather than on a value of it.
	--- `---@class lde.Package` above `local Package = {}` declares the class and its table at once,
	--- and `Package.Config = require(...)` is how that table gets its fields — the same thing a
	--- method declaration does, written as an assignment. A value *of* the class still has only the
	--- fields the class names: `local one = Package.open(dir)` may not grow a field nobody declared.
	---@param held lye.doc.Type
	---@param base string? the name the write is written on
end

local function fieldWrites(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local inferCtx = ctx.inferCtx
	local byDeclaration = ctx.byDeclaration
	local receiverTypeOf, declaredHere = ctx.receiverTypeOf, ctx.declaredHere
	local declaredField = ctx.declaredField
	local function buildsItsOwnClass(held, base)
		-- A class is named with its namespace, and the table it is built on carries the last part of that
		-- name. Either spelling counts.
		return base ~= nil and (held.name == base or held.name:match("%.([%w_]+)$") == base)
	end

	-- A value with a type does not grow fields nobody declared, and a function written for a field has
	-- to be the function that field says it is: what was written does not fit what the type said.
	for _, node in ipairs(parsed.nodes) do
		local target = node.kind == "assignment" and parsed.nodes[node.target]
		local field = target and target.kind == "index" and target.field
		local base = field and writtenNameOf(parsed, target.target)
		local held = base and receiverTypeOf(base, node.start)
		-- Only a class says what its fields are; a table built field by field is typed by what was put
		-- into it. `Foo.__index = Foo` is how a class is built, so the metatable keys are left alone.
		local metatable = type(field) == "string" and field:sub(1, 2) == "__"
		-- A write can be redirected by the metatable, which is what makes a read-only or computed table
		-- possible. The write lands in the `__newindex` value and has to fit it.
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
			and not buildsItsOwnClass(held, base) and destination then
			local wanted = declaredField(destination, field)
			local value = parsed.nodes[node.value]
			if not wanted then
				diagnostic.add(self, string.format("`%s` is not a field of %s", field,
						destination.name or types.display(destination)), target.start, target.stop)
			elseif value then
				local actual = infer.at(inferCtx, node.value)
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
				local message = actual and types.mismatch(expected, actual, field)
				if message then
					diagnostic.add(self, message, value.start, value.stop)
				end
			end
		end
	end

	-- A field a class keeps to itself is read only from that class, or, when it is protected,
	-- from a class that extends it. The read is judged against the method it sits in.
end

local function metatableChecks(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local resolve, inferCtx = ctx.resolve, ctx.inferCtx
	local functionNodes, bodyOwner = ctx.functionNodes, ctx.bodyOwner
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
						diagnostic.add(self, string.format("'%s' is %s to %s", node.field, visibility,
								targetType.name), node.start, node.stop)
					end
				end
			end
		end
	end

	-- A call that never comes back makes what follows it in the same block dead. The statements of a
	-- block are the arena's unparented nodes, so a nested body is its own list.
end

local function deadCode(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local inferCtx = ctx.inferCtx
	local scopeAt = ctx.scopeAt
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
		local stopped, stopping = false, nil
		for _, node in ipairs(list) do
			-- What cannot run is what comes *after* the call that never comes back, not that call itself,
			-- which a block may list twice. Reporting it reads as the opposite of true.
			if stopped and node ~= stopping then
				diagnostic.add(self, string.format("%s never returns, so this cannot run", stopped), node.start, node.stop, 1)
				break
			end
			stopped = neverStatement(node)
			stopping = stopped and node or nil
		end
	end

	-- Arithmetic on a type that can never be a number cannot work at all, so it is an error rather
	-- than a guess — `"3" * 2` is exactly the case a reader should be told about.
end

local function arithmeticChecks(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local inferCtx = ctx.inferCtx
	local ARITHMETIC = ctx.arithmetic
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "binary" and ARITHMETIC[node.op] then
			local left = infer.at(inferCtx, node.left)
			local right = infer.at(inferCtx, node.right)
			-- A type that answers this operator with a metamethod decides what the operands may be, so the
			-- metamethod's parameters are what is checked.
			local metamethod = left and right and types.metamethodFor(node.op, left, right)
			if metamethod then
				for position, operandIdx in ipairs({ node.left, node.right }) do
					local operand = parsed.nodes[operandIdx]
					local wanted = metamethod.params[position]
					local actual = position == 1 and left or right
					if operand and wanted and actual and types.mismatch(wanted, actual, node.op) then
						diagnostic.add(self, string.format("'%s' takes %s on the %s, but this is %s", node.op,
								types.display(wanted), position == 1 and "left" or "right",
								types.display(actual)), operand.start, operand.stop, 1)
					end
				end
			else
				for _, operandIdx in ipairs({ node.left, node.right }) do
					local operand = parsed.nodes[operandIdx]
					local operandType = operand and infer.at(inferCtx, operandIdx)
					if operandType and isNeverNumeric(operandType) then
						diagnostic.add(self, string.format("'%s' needs numbers, but this is a %s",
								node.op, types.display(operandType)), operand.start, operand.stop, 1)
					end
				end
			end
		end
	end

	-- An index with a computed key asks a value what it holds there. A class that declares an index
	-- signature answers — `size[1]` on a `size_t` is the mistake the C types exist to catch.
end

local function indexedReads(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local inferCtx = ctx.inferCtx
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "index" and node.isDynamic == true and node.target and node.key then
			local base = infer.at(inferCtx, node.target)
			local key = infer.at(inferCtx, node.key)
			if base and base.variant == "class" and not base.indexed and key and key.variant == "number" then
				local at = parsed.nodes[node.key]
				diagnostic.add(self, string.format("%s cannot be indexed by a number", types.display(base)),
					at.start, at.stop)
			end
		end
	end

	-- A reference is a node that names something: a bare name, a call target, an index base.
	-- The arena has one for each, so this never has to decide whether a name token is a use.
end

local function globalNames(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local signatures = ctx.signatures
	local scopeAt, lookupIn = ctx.scopeAt, ctx.lookupIn
	local prepared = ctx.prepared
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
	--- The keys a table literal writes with a bare word: `{ const = true, fn = true }` names two
	--- fields, and neither word is a name a reader is asking the environment for.
	---@type table<integer, table<string, boolean>>

	local keyTexts = {}
	for index, fields in pairs(parsed.tableFields or {}) do
		local names = {}
		for key in pairs(fields) do names[key] = true end
		keyTexts[index] = names
	end

	for _, node in ipairs(parsed.nodes) do
		local parent = node.parent and parsed.nodes[node.parent]
		--- Whether the word is a key a table literal writes rather than a name being read.
		local isKey = parent and node.callee and parent.kind == "table" and node.start == node.stop
			and keyTexts[parent.index] and keyTexts[parent.index][node.callee]
		local name = node.kind == "prefix" and not isKey and node.callee
		if name then
			local found = lookupIn(scopeAt(self, node.start), name, node.start)
			if found then
				found.references[#found.references + 1] = node.start
				self.byStart[node.start] = found
			elseif not globals[name] then
				-- A name nothing declares and nothing in the definitions declares either: the reader is asking
				-- for a global that is not there. A global assigned in this file is in `self.variables`.
				diagnostic.add(self, string.format("undefined global `%s`", name),
					node.start, node.start + #name - 1, 2)
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
					if name and name ~= "..." and not taken[name] then
						diagnostic.add(self, string.format("`%s` is not a parameter of this function", name),
							annotation.nameStart or annotation.start, annotation.nameStop or annotation.stop)
					end
				end
			end
		end
	end
end

local function unusedLocals(ctx)
	for _, variable in ipairs(ctx.self.variables) do
		local unused = variable.qualifier == "local" and #variable.references == 0
			and not variable.name:match("^_")
		if unused then
			local declaration = variable.declaration
			diagnostic.add(ctx.self, string.format("unused local `%s`", variable.name), declaration.start, declaration.stop, 2)
		end
	end

	-- The same field written by an assignment rather than declared. A callback's result crosses back
	-- into C, so a body that gives the wrong thing is reported against the signature it was cast to.
end

local function callbackReturns(ctx)
	local parsed, self = ctx.parsed, ctx.self
	local callbackReturns = ctx.callbackReturns
	local inferredReturnOf = ctx.inferredReturnOf
	local annotatedBodies = ctx.annotatedBodies
	for index, promised in pairs(callbackReturns) do
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
			local message = types.mismatch(promised, inferred, "the result")
			if message then
				self.diagnostics[#self.diagnostics + 1] = {
					message = message, severity = 1,
					start = parsed.nodes[index].start, stop = parsed.nodes[index].stop,
				}
			end
		end
	end

	-- What this file gives a caller: a top-level `return { ... }` is what a module is, and its type
	-- is what `require("this.file")` means elsewhere. Read after typing, so its names are settled.

	-- The module's own type, published so a `require` of this file resolves to it. Typed after the
	-- rounds, like every other read, so the names it is built from are settled.
end

local function moduleExport(ctx)
	for _, node in ipairs(ctx.parsed.nodes) do
		-- Top level means the scope it is written in is the file's own: `parent` says which node was
		-- being built, which a statement inside a function body also answers with the root.
		if node.kind == "return" and ctx.scopeAt(ctx.self, node.start) == ctx.self.root and not ctx.self.module then
			local first = node.children and node.children[1]
			if first then ctx.self.module = infer.at(ctx.inferCtx, first) end
		end
end
end


function checks.report(ctx)
	returnHints(ctx)
	constWrites(ctx)
	declaredMismatches(ctx)
	fieldWrites(ctx)
	metatableChecks(ctx)
	deadCode(ctx)
	arithmeticChecks(ctx)
	indexedReads(ctx)
	globalNames(ctx)
	paramNames(ctx)
	unusedLocals(ctx)
	callbackReturns(ctx)
	moduleExport(ctx)
end

return checks
