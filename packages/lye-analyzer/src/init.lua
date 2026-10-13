--[[
	Name resolution, evolving types and narrowing.

	A variable's type is the union of every value assigned to it up to an offset, so it evolves; an
	explicit `---@type` fixes it instead, and a condition narrows what holds inside its branch.
]]

-- An analysis is thousands of short loops, so LuaJIT's defaults are wrong for it twice over: a cache
-- of 1000 traces flushes and refills for the whole run, and a side trace is compiled after 10 takes.
jit.opt.start("maxtrace=8000", "maxmcode=8192", "hotexit=250")

local Parser = require("lye-parser")
local doc = require("lye-doc")
local cdef = require("lye-cdef")
local types = require("lye-doc.type")
local diagnostic = require("lye-analyzer.diagnostic")
local infer = require("lye-analyzer.infer")
local names = require("lye-analyzer.names")
local narrow = require("lye-analyzer.narrow")
local annotations = require("lye-analyzer.annotations")
local checks = require("lye-analyzer.checks")
local typing = require("lye-analyzer.typing")
local callName, writtenNameOf = names.callName, names.writtenNameOf
local nodesOf = require("lye-parser").nodesOf
local annotationValues, annotationSpan, documentationOf, trailsCode, sameLine, collectAssignments, factHolds, withGenerics, signatureOf, paramTypeOf, callLabel =
	annotations.annotationValues, annotations.annotationSpan, annotations.documentationOf, annotations.trailsCode, annotations.sameLine, annotations.collectAssignments, annotations.factHolds, annotations.withGenerics, annotations.signatureOf, annotations.paramTypeOf, annotations.callLabel

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
---@field variables table<string, lye.analyzer.Variable[]> the declarations of each name
---@field children lye.analyzer.Scope[]
---@field facts table<string, lye.analyzer.Narrowing[]> conditions that hold over this scope
---@field names table<string, lye.analyzer.Variable[]|boolean>? which scope each name was found in, remembered
---@field lastLookupName string?
---@field lastLookupOffset integer?
---@field lastLookupResult lye.analyzer.Variable?
---@field hasLastLookup boolean?

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
---@field parsed lye.doc.Type? the type, read once and kept, since every call shares it

--- One function body's span, as a tree: a body holds the bodies declared inside it, so a statement
--- belongs to every span covering it. `calls` and `writes` are what is written here and below.
---@class lye.analyzer.BodySpan
---@field start integer
---@field stop integer
---@field parent lye.analyzer.BodySpan?
---@field names string[] the declared names whose body this is
---@field calls (string?)[] the callee named by each call written here or below
---@field writes boolean whether anything here or below is assigned
---@field pure boolean whether nothing here or below writes


---@class lye.analyzer.Signature
---@field params lye.doc.Annotation[]
---@field returns lye.doc.Annotation?
---@field values string[]? every value the signature names, `---@return A, B` being two
---@field inferred lye.doc.Type? what the body gives back where a call reads one value
---@field inferredValues lye.doc.Type[]? every value the body gives back, when nothing was written
---@field generics table<string, boolean>
---@field constraints table<string, string>
---@field predicates lye.analyzer.Predicate[]
---@field overloads string[] the shapes a call may take besides the parameters, as written
---@field declaration lye.parser.Declaration? the declaration it was read from, in this document
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
---@field scopes lye.analyzer.Scope[] sorted by start offset for lexical lookup
---@field lastScope lye.analyzer.Scope?
---@field lastScopeOffset integer?
---@field scopeSlots integer[]? the offset each scope lookup slot was last asked about
---@field scopeValues lye.analyzer.Scope[]? the scope that answered it
---@field variables lye.analyzer.Variable[]
---@field byStart table<integer, lye.analyzer.Variable>
---@field diagnostics lye.analyzer.Diagnostic[]
---@field signatures table<string, lye.analyzer.Signature>
---@field returns table<string, lye.doc.Type>
---@field callTypes table<integer, lye.doc.Type> what each call was bound to, by node index
---@field module lye.doc.Type? what `require` of this file means, when it returns a table
---@field ffiC lye.doc.Type? the functions `ffi.C` reaches, when this file declared any

---@param result lye.parser.Result
---@return lye.analyzer.Scope
local ARITHMETIC = {
	["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true, ["^"] = true,
	["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true, ["~>>"] = true,
}


local function buildScopes(result)
	local root = { start = 1, stop = math.huge, depth = 0, variables = {}, children = {}, facts = {} }
	local byRecord = {}
	local records = {}
	for _, node in ipairs(result.scopes) do records[#records + 1] = node end
	table.sort(records, function(a, b)
		if a.start ~= b.start then return a.start < b.start end
		return a.stop > b.stop
	end)

	-- Children are appended in start order, so the innermost scope holding an offset is
	-- found by bisection rather than a walk of every sibling.
	---@param scope lye.analyzer.Scope
	---@param from integer
	---@param stop integer
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

	local scopes = {}
	for _, node in ipairs(records) do
		local parent = innermost(root, node.start, node.stop)
		local scope = {
			start = node.start, stop = node.stop, parent = parent, depth = parent.depth + 1,
			variables = {}, children = {}, facts = {},
		}
		parent.children[#parent.children + 1] = scope
		byRecord[node] = scope
		scopes[#scopes + 1] = scope
	end
	return root, byRecord, scopes
end

-- How many offsets the scope lookup remembers. The question is asked by offset, and a node's
-- children are typed before the node itself, so the same offset rarely comes twice in a row:
-- one remembered answer is almost always a miss. 256 slots answer nearly every repeat.
local SCOPE_SLOTS = 256

---@param self lye.analyzer.Result
---@param offset integer
local function scopeAt(self, offset)
	local slot = (offset % SCOPE_SLOTS) + 1
	local offsets, scopes_ = self.scopeSlots, self.scopeValues
	if not offsets then
		offsets, scopes_ = {}, {}
		self.scopeSlots, self.scopeValues = offsets, scopes_
	end
	local held = offsets[slot]
	if held == offset then return scopes_[slot] end
	local scopes = self.scopes
	local low, high = 1, #scopes
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if scopes[mid].start <= offset then low = mid + 1 else high = mid - 1 end
	end
	local scope = scopes[high]
	while scope and offset > scope.stop do scope = scope.parent end
	scope = scope or self.root
	offsets[slot] = offset
	scopes_[slot] = scope
	return scope
end

--- Resolve a name where it is read: an inner declaration of the same name only takes over
--- from its own offset on, which is what makes shadowing resolve rather than collide.
---@param scope lye.analyzer.Scope
---@param name string
---@param offset integer
---@return lye.analyzer.Variable?
local function lookupIn(scope, name, offset)
	-- Which scope first declares the name does not depend on the offset, so that walk outwards is
	-- done once per name and remembered. Whether each declaration is *visible* does depend on the
	-- offset — a name read above its own `local` is the outer one — so the scan runs every time,
	-- and a scope holding the name whose declarations are not in scope yet keeps walking outwards.
	local names = scope.names
	if not names then
		names = {}
		scope.names = names
	end
	local held = names[name]
	local declared, owner
	if held then
		declared, owner = held[1], held[2]
	else
		owner = scope
		while owner do
			declared = owner.variables[name]
			if declared then break end
			owner = owner.parent
		end
		declared = declared or false
		names[name] = { declared, owner }
	end
	while owner do
		if declared then
			for index = #declared, 1, -1 do
				local candidate = declared[index]
				-- A local is visible after its initializer, but its own name stays a declaration target.
				if offset >= (candidate.visibleFrom or candidate.start)
					or (offset >= candidate.start and offset <= candidate.stop) then
					return candidate
				end
			end
		end
		owner = owner.parent
		declared = owner and owner.variables[name] or false
	end
	return nil
end




















--- The `@type` that describes a declaration, or nil when it has none.
---
--- An annotation describes a declaration when it is the comment immediately before the
--- statement that declares it, or the one written after it on the same line. That is a question
--- about tokens — the parser records which token opens the declaration — so no gap is ever
--- measured or copied.
---@param parsed lye.parser.Result
---@param file lye.doc.File
---@param declaration lye.parser.Declaration
---@param resolve fun(text: string): lye.doc.Type?
---@return lye.doc.Type?
function analyzer.declaredTypeFor(parsed, file, declaration, resolve)
	-- A definition file writes the type where the name is — `local held: number = 1` — and that is
	-- the type the declaration has. An annotation above it is the older, louder spelling of the
	-- same thing, and it wins where both are written.
	local inline = declaration.inlineType and declaration.inlineType ~= "" and declaration.inlineType
	if inline then
		local held = types.parse(inline, resolve)
		if held then return held end
	end

	-- Annotations are in source order, so the candidate is the last one before the declaration.
	local annotations = file.annotations
	local low, high = 1, #annotations
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if annotations[mid].start < declaration.start then low = mid + 1 else high = mid - 1 end
	end
	-- A trailing annotation belongs to the declaration it was written after, so it is never read as
	-- the type of the next one. An inline one is a cast, and the inline reader owns it.
	local value = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
	local trailing
	for index = high + 1, #annotations do
		local annotation = annotations[index]
		if annotation.start > declaration.stop and not (value and annotation.start <= value.stop)
			and sameLine(parsed, declaration.stop, annotation.start) then
			trailing = annotation
		else
			break
		end
	end
	--- The type an annotation says this declaration is, when it is one that says a type at all.
	--- `---@as T` is the same thing said the other way round.
	---@param annotation lye.doc.Annotation
	---@return lye.doc.Type?
	local function typedBy(annotation)
		if annotation.tag ~= "type" and annotation.tag ~= "as" then return nil end
		-- `---@type A, B` names one type per name of the statement, in order.
		local written = types.splitValues(annotation.type or "")
		if #written > 1 then
			local at = declaration.position or 1
			if written[at] then return types.parse(written[at], resolve) end
		end
		return types.parse(annotation.type, resolve)
	end

	-- The trailing annotation is written at the declaration it describes, so it is the answer
	-- whether or not there is a block above; everything below looks upwards.
	if trailing then
		local written = typedBy(trailing)
		if written then return written end
	end

	local spanStart = annotationSpan(parsed, declaration)
	if not spanStart then return nil end

	-- Searching back skips the trailing annotations of earlier lines, which describe those lines.
	local previous
	for index = high, 1, -1 do
		local annotation = annotations[index]
		if annotation.start < spanStart then break end
		if not trailsCode(parsed, annotation) then
			previous = annotation
			break
		end
	end
	if not previous then return nil end
	-- A class declared above a declaration is that declaration's type, looked for rather than taken
	-- from the last line because its `---@field` lines follow it. Only where it holds the table.
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
	-- `---@as T` says what `---@type T` does: what follows is a T, whoever built it. It is the
	-- spelling a reader reaches for when the value comes from where the analyzer cannot follow.
	return typedBy(previous)
end

--- A fact belongs to the variable its condition resolved to, so an inner `local` of the same
--- name never inherits an outer narrowing. A name that does not resolve is left alone, which is
--- the safer half of the two.
---@param self lye.analyzer.Result
---@param fact lye.analyzer.Narrowing
---@param variable lye.analyzer.Variable
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
	elseif fact.kind == "cast" then
		-- A cast is what the writer says the value is, so it *replaces* what was known: narrowing an
		-- `unknown` to a class would leave the unknown, which is the one case `---@cast` exists for.
		return fact.type
	elseif fact.kind == "field" or fact.kind == "notfield" then
		local want = fact.kind == "field"
		-- Read *as* the field the comparison is about the value itself, keeping the union members that
		-- value can be; read as the object it is about which member is in hand.
		if onField then
			return want and types.narrowToType(base, fact.type) or types.excludeType(base, fact.type)
		end
		return types.narrowDiscriminant(base, fact.field, fact.type, want)
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
function analyzer.fieldTypeAt(self, base, baseName, field, offset)
	-- A string reads the `string` table's fields, because Lua points the string metatable's `__index`
	-- at it. That is how the environment is arranged, so this layer owns the rule.
	local held
	-- `ffi.C` reaches the functions the file's own cdef declared, and the name is what says so: the
	-- far side is read the way `ffi.cdef`, `ffi.new` and `ffi.load` are, since a file that requires
	-- `ffi` has that name for it whether or not the definitions were reached to type the table.
	if field == "C" and baseName == "ffi" and self.ffiC then
		return self.ffiC
	end
	if types.mayBe(base, "string") then
		local library = analyzer.lookupAt(self, "string", offset)
		local declared = library and analyzer.typeAt(self, library, offset)
		held = declared and types.fieldOf(declared, field) or nil
	end
	held = held or types.indexResult(base, field)
	if not baseName then return held end

	-- The same name has to be the same thing here as it was in the condition: an inner `local`
	-- of the same name ends the fact rather than inheriting it.
	local scope = scopeAt(self, offset)
	local here = lookupIn(scope, baseName, offset)
	local guarding = {}
	while scope do
		if scope.facts[baseName] then guarding[#guarding + 1] = scope end
		scope = scope.parent
	end

	local narrowed = held
	for index = #guarding, 1, -1 do
		for _, fact in ipairs(guarding[index].facts[baseName]) do
			local same = lookupIn(scopeAt(self, fact.start), baseName, fact.start) == here
			-- Only this field's facts: a condition on `a.x` says nothing about `a.y`.
			if fact.field == field and same and factHolds(fact, offset) then
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
	-- A declaration with neither annotation nor initializer has nothing to start from, and the
	-- mutable unknown says so: it can still be refined by what is assigned below.
	local base = variable.declared or variable.initializer or types.mutable()

	local latest
	for _, assignment in ipairs(variable.assignments) do
		-- An assignment the typing rounds did not reach has no type to combine. Left out rather than
		-- combined, so asking about a name can never raise.
		if assignment.type and assignment.at <= offset then
			latest = assignment
			-- With no annotation the name may still be the value it started as, so every write is
			-- combined with it. A declared type is what the name is *where it is written* and not a
			-- promise about the rest of its life, which is the other half of this below.
			if not variable.declared then base = types.combine(base, assignment.type) end
		end
	end
	-- The last write before a read is what that read gets: `x = x or default` narrows a declared
	-- `x?` to `x`, and a name reused for another type is read as the new one. Leaving the declared
	-- type in place instead made every assignment below an annotation invisible to the type
	-- checker, which is why `local dest = x or fallback` had to be written out as its own name.
	-- A write that has not settled is read as the declared type while the write itself is being
	-- worked out — `current = current.parent` asks about `current` mid-write — but anywhere else
	-- the read is the placeholder the write will become, so the promotion that fills it in reaches
	-- this read as well rather than the declared type staying here for good.
	if latest and variable.declared then
		local value = latest.valueIdx and self.parser.nodes[latest.valueIdx]
		local midWrite = value and offset >= value.start and offset <= value.stop
		if not types.isMutable(latest.type) or not midWrite then base = latest.type end
	end

	-- Every enclosing scope may hold a condition on the name, outermost first so a nested one narrows
	-- on top of it: the scope chain is the containment.
	local guarding = {}
	local scope = scopeAt(self, offset)
	while scope do
		if scope.facts[variable.name] then guarding[#guarding + 1] = scope end
		scope = scope.parent
	end

	local narrowed = base
	for index = #guarding, 1, -1 do
		for _, fact in ipairs(guarding[index].facts[variable.name]) do
			if factHolds(fact, offset) and factReaches(self, fact, variable) then
				local next
				-- A predicate names a type the writer chose, so it is used as parsed; a `type(x) == "T"` test
				-- names a base type, which is not a type until something parses it.
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





--- Check the arguments a call passes against the parameters the callee declares, and collect
--- what a named callee returns so a later `local x = f()` can be typed.
---@param self lye.analyzer.Result
---@param parsed lye.parser.Result
---@param signatureOfCall fun(node: lye.parser.Node): lye.analyzer.Signature?, lye.doc.Type?, boolean
---@param returns table<string, lye.doc.Type>
---@param resolve fun(text: string): lye.doc.Type?
---@param inferCtx lye.infer.Context
---@param source string the document, so a string literal can be read where it was written
---@param positionalParams fun(signature: lye.analyzer.Signature, resolve: fun(text: string): lye.doc.Type?): (lye.doc.Type?)[]
local function checkCalls(self, parsed, signatureOfCall, returns, resolve, inferCtx, source, positionalParams)
	--- A generic name in a signature is a type variable: the argument cannot be checked against
	--- the name itself, so it is checked against what the name was limited to, if anything.
	---@param signature lye.analyzer.Signature?
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

	-- The type a written text came to, parsed once per document. A generic signature is read at
	-- every call site of the function, and parsing `T` or `T[]` again at each of them is a tree
	-- per read; one resolution context covers the whole analysis, so one text is one type here.
	---@type table<string, lye.doc.Type|false>
	local parsedTypes = {}
	---@param text string
	---@return lye.doc.Type?
	local function typeOfText(text)
		local held = parsedTypes[text]
		if held ~= nil then return held or nil end
		local parsed = types.parse(text, resolve)
		parsedTypes[text] = parsed or false
		return parsed
	end
	---@param signature lye.analyzer.Signature
	---@return (lye.doc.Type?)[]
	---@return lye.doc.Type?
	local function typesOf(signature)
		local held = parsedSignatures[signature]
		if held then return held.params, held.returns, held.variadic end

		local local_ = resolveFor(signature)
		local params = positionalParams(signature, local_)
		-- What the `...` a signature declares accepts, which is what an argument past the named
		-- parameters is checked against.
		local variadic
		for _, annotation in ipairs(signature.params or {}) do
			if annotation.name == "..." and annotation.type then
				variadic = types.parse(annotation.type, local_) or nil
			end
		end
		local written = signature.returns and signature.returns.type
		local returned = written and types.parse(written, local_) or nil
		-- Kept for a generic signature too: what a name of its own stands for is read the same at
		-- every call — the call's own binding is applied by `types.substitute` on the answer, not
		-- by reading the signature again, and re-reading it per call was a tree per call.
		parsedSignatures[signature] = { params = params, returns = returned, variadic = variadic }
		return params, returned, variadic
	end

	--- The type an argument has as it was written. A string literal is the one string it spells,
	--- which is what `select("#", ...)` and the option flags in the definitions ask for; a name of
	--- type `string` is not that string, so this says nothing about one passed in its place.
	---@param argIdx integer
	---@return lye.doc.Type
	local function argumentAt(argIdx)
		local argument = parsed.nodes[argIdx]
		if argument and argument.kind == "string" then
			-- The value the literal spells, not the text it was written with: `f([[read]])` and `f("read")`
			-- are the same argument, and only the value compares against a parameter written `"read"`.
			return types.stringValue(argument.value or source:sub(argument.start, argument.stop))
		end
		return infer.at(inferCtx, argIdx)
	end

	--- The first argument that cannot be what its parameter says, so the caller can decide whether
	--- another shape of the same call accepts what this one did not.
	---@param node lye.parser.Node
	---@param params (lye.doc.Type?)[]
	---@param receiver lye.doc.Type? the value a `:` call passes, which fills the first parameter
	---@param variadic lye.doc.Type? what an argument past the named ones has to be
	---@return integer? nodeIdx the argument, or the receiver, that cannot be what it is
	---@return lye.doc.Type? wanted
	---@return lye.doc.Type? actual
	local function firstMismatch(node, params, receiver, variadic)
		-- A `:` call passes the receiver as its first argument. Its type decides whether that argument
		-- occupies a parameter, while a mismatch leaves the written arguments unshifted.
		local shift = 0
		if receiver then
			local wanted = params[1]
			if wanted == nil then
				shift = 1
			elseif not types.mismatch(wanted, receiver, "argument 1") then
				if types.mismatch(wanted, receiver, "argument 1") then
					return node.target, wanted, receiver
				end
				shift = 1
			end
		end
		for index, argIdx in ipairs(node.args or {}) do
			-- An argument past the named parameters is one of the `...` a signature declares, and
			-- what that accepts is what it says: `f(1, {})` is wrong for `---@param ... number`.
			local wanted = params[index + shift]
			if not wanted and variadic and index + shift > #params then wanted = variadic end
			if wanted and parsed.nodes[argIdx] then
				local actual = argumentAt(argIdx)
				if types.mismatch(wanted, actual, "argument " .. (index + shift)) then
					return argIdx, wanted, actual
				end
			end
		end
	end

	--- Report the arguments that cannot be what the parameters say they are. A call that fits one of
	--- the declaration's `---@overload` shapes is not reported at all: `debug.getinfo(1, "S")` and
	--- `collectgarbage("count")` are calls to functions written with overloads, and checking them
	--- against the first signature alone reports every one of them.
	---@param node lye.parser.Node
	---@param name string? what the call is written with, for the message a mismatch is reported in
	---@param params (lye.doc.Type?)[]
	---@param overloads string[]?
	---@param receiver lye.doc.Type?
	local function checkArgs(node, name, params, overloads, receiver, variadic)
		local blame, wanted, actual = firstMismatch(node, params, receiver, variadic)
		if not blame then return end

		for _, written in ipairs(overloads or {}) do
			local shape = types.parse(written, resolve)
			if shape and shape.variant == "fn"
				and not firstMismatch(node, shape.params, receiver, shape.variadic) then
				return
			end
		end

		-- The label is a string built by walking the call's name, and a call that fits its
		-- parameters never needs one: it is written where the diagnostic it belongs to is.
		local label = name or callLabel(parsed, node)
		local argument = parsed.nodes[blame]
		diagnostic.add(self, string.format("%s expects %s, got %s", label,
				types.display(wanted), types.display(actual)), argument.start, argument.stop, 1)
	end

	for _, node in ipairs(nodesOf(parsed, "call")) do
		do
			local signature, calleeType, byName = signatureOfCall(node)
			-- The name the call is written with, when it is one: the label a mismatch is reported
			-- under, built only where one is reported.
			local name = byName and node.callee or nil
			-- The value a method call is written on, which the callee receives first: a `:` call passes it, a
			-- `__call` metamethod is handed it, and a `.` call passes nothing extra.
			local target = node.target and infer.at(inferCtx, node.target)
			local callable = target and types.metamethod(target, "__call")
			local receiver = (node.isMethod or callable) and target or nil
			if signature then
				local params, returned, variadic = typesOf(signature)
				if byName and returned then returns[node.callee] = returned end
				checkArgs(node, name, params, signature.overloads, receiver, variadic)
			elseif calleeType and types.isFn(calleeType) and not types.isAnyFn(calleeType) then
				-- A callable nothing annotated, such as a method declared in this document: its own type is all
				-- there is to check against, and a parameter of the signature's own is bound by this very call.
				local params = calleeType.params
				local variadic = calleeType.variadic
				if calleeType.generics and next(calleeType.generics) then
					local bindings = {}
					for name in pairs(calleeType.generics) do
						local limit = calleeType.constraints and calleeType.constraints[name]
						bindings[name] = (limit and typeOfText(limit)) or types.UNKNOWN_TYPE
					end
					local replaced = {}
					for index, param in ipairs(params) do
						replaced[index] = types.substitute(param, bindings)
					end
					params = replaced
					if variadic then variadic = types.substitute(variadic, bindings) end
				end
				checkArgs(node, name, params, nil, receiver, variadic)
			end
		end
	end
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
	-- The table each class describes, by the name it is written under: `math = {}` is a global the
	-- document can read, and a local still names the receiver of `function file:close()`.
	local backing = {}
	for _, source in pairs(sources) do
		local parsed = Parser.new(source):parse()
		local file = doc.parse(source, parsed.tokens)
		local namespace = doc.classes.read(file)

		-- The link between a class and the table it describes is read from the first line after the
		-- class's annotations, since nothing states it and the library's names do not match.
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
				-- A global the definitions declare, remembered by name: the signatures are reached through the
				-- document's own table, so a pass asking whether a name is known cannot iterate it.
				if not declaration.name:find("[%.:]") then
					prepared.globalNames[declaration.name] = true
				end
				prepared.signatures[declaration.name] = {
					params = params, returns = returned, generics = generics,
					constraints = constraints, predicates = predicates, overloads = overloads,
					values = annotationValues(returned),
					doc = documentationOf(parsed, declaration),
				}
				if returned and returned.type and not next(generics) then
					-- A generic return is known only once the arguments are, so it is left out: a recorded `T` would
					-- be cached as the answer and never revisited. The call is bound at the call site instead.
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
				local params, isVariadic, variadic = {}, false, nil
				for _, annotation in ipairs(entry.params) do
					if annotation.name == "..." then
						isVariadic = true
						variadic = annotation.type and types.parse(annotation.type, local_) or nil
					else
						params[#params + 1] = annotation.type
							and types.parse(annotation.type, local_) or types.UNKNOWN_TYPE
					end
				end
				local returned = entry.returns and entry.returns.type
				local bare = returned and (returned:gsub("%.%.%.$", "")) or nil
				local fnType = types.fn(params,
					(bare and types.parse(bare, local_)) or types.ANY_TYPE, isVariadic, nil, variadic)
				doc.classes.evolve(prepared, className, field, fnType)
				-- The annotations stay reachable from the type they built, so a call through the field is checked
				-- and bound exactly as a call to a named function is.
				prepared.fields[fnType] = entry
			end
		end
	end

	return prepared
end

--- The metamethods Lua has, and how many arguments each is handed besides the value it was found
--- on. A `table` entry may be a table rather than a function, which `__index` allows.
local METAMETHODS = {
	__index = { arity = 1, table = true }, __newindex = { arity = 2, table = true },
	__add = { arity = 2 }, __sub = { arity = 2 }, __mul = { arity = 2 }, __div = { arity = 2 },
	__mod = { arity = 2 }, __pow = { arity = 2 }, __idiv = { arity = 2 }, __concat = { arity = 2 },
	__eq = { arity = 2 }, __lt = { arity = 2 }, __le = { arity = 2 }, __band = { arity = 2 },
	__bor = { arity = 2 }, __bxor = { arity = 2 }, __shl = { arity = 2 }, __shr = { arity = 2 },
	__call = { arity = nil, table = false },
	__unm = { arity = 1 }, __len = { arity = 1 }, __bnot = { arity = 1 }, __tostring = { arity = 1 },
	-- Accepted but not wired to anything: LuaJIT ignores `__len` for tables and has no `__pairs`, and
	-- the bitwise operators are Lua 5.3, so a metatable may name them without the engine asking.
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
			local report, severity = nil, 1
			if not known then
				-- A hint, not an error: a metatable is a table like any other, and a library may keep its own key
				-- in one. Lua will never ask for it, which is worth knowing and is not a mistake.
				report, severity = string.format("`%s` is not a metamethod Lua has", name), 3
			elseif not known.value then
				-- Whether a metamethod is a function of the right shape is the `lye.Metatable` constraint's
				-- business. This checks what the annotation cannot know: the value it is being set on.
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
					message = report, severity = severity,
					start = node.start, stop = node.stop,
				}
			end
		end
	end
end

---@param source string
---@param prepared lye.analyzer.Prelude? what the definitions declare
---@param elsewhere table<string, boolean|lye.doc.Type>? what other files declare: the name alone as a typo guard, the type where a caller can build one
---@param modules fun(name: string): lye.doc.Type? ? what `require("name")` is, when the caller can
--- find the file: the analyzer reads the document it is given, and a module lives elsewhere
---@return lye.analyzer.Result
---@param resume lye.parser.Resume? what the previous parse of this document kept, when the
--- text before the change is unchanged — a keystroke then re-reads one statement, not the file
---@param cachedAnnotations lye.doc.File? annotations already parsed for a batch check
---@param isModuleOnly boolean? the document is read for what `require` gives back, so its own
--- diagnostics are nobody's to report and the passes that only build them are left out
function analyzer.analyze(source, prepared, elsewhere, modules, resume, cachedAnnotations, isModuleOnly,
	isDefinition)
	assert(type(source) == "string", "analyzer.analyze expects a string")

	local parsed = Parser.new(source, resume, isDefinition):parse()
	local annotations = cachedAnnotations or doc.parse(source, parsed.tokens)
	
	-- What this file declares, so a class name or an alias in an annotation means what it says. Read
	-- before anything parses a type, with the definitions folded in first.
	local namespace = doc.classes.read(annotations)
	if prepared then
		-- The definitions are reached through the namespace rather than copied into it: copying hundreds
		-- of classes and aliases on each keystroke is work thrown away with the namespace.
		setmetatable(namespace.classes, { __index = prepared.classes })
		setmetatable(namespace.aliases, { __index = prepared.aliases })
		-- The methods the definitions added to their classes, which the resolver reads from here. Copied,
		-- because a method declared on a definition's class has to merge into the prepared entry.
		for className, fields in pairs(prepared.evolved or {}) do
			namespace.evolved = namespace.evolved or {}
			namespace.evolved[className] = namespace.evolved[className] or {}
			for field, method in pairs(fields) do
				namespace.evolved[className][field] = method
			end
		end
	end
	---@param node lye.parser.Node
	local function calledName(node) return callName(parsed, node) end

	--- Where the text inside a `ffi.cdef` string begins in the document: past the quote, or past the
	--- brackets and whatever `=` signs a long one was written with. The parser reports offsets into
	--- the text it was handed, and a reader has to be told where in their file that is. A quoted
	--- string with escapes in it would drift — a cdef is written as a long string in practice.
	---@param written string the document
	---@param argument lye.parser.Node the string the cdef was written as
	---@param offset integer 1-based, into the text the parser read
	local function cdefTextStart(written, argument, offset)
		local source = written:sub(argument.start, argument.stop)
		local level = source:match("^%[(=*)%[")
		local opened = level and (2 + #level) or 1
		return argument.start + opened + offset - 1
	end

	-- The C a `ffi.cdef` call declares. Its types belong to this file, and its declarations are
	-- written back out as annotation text, so one reader builds every class rather than two.
	local cdefs, cdefProblems
	-- Only a file that writes the word can be declaring C, and the scan is per node: reading the
	-- text first is what keeps a file that declares nothing from paying for the search.
	if source:find("cdef", 1, true) then
	for _, node in ipairs(nodesOf(parsed, "call")) do
		if calledName(node) == "ffi.cdef" then
			local argument = node.args and node.args[1] and parsed.nodes[node.args[1]]
			if argument and argument.kind == "string" and type(argument.value) == "string" then
				local declared = cdef.parse(argument.value)
				local written = doc.parse(cdef.annotations(declared))
				local from = doc.classes.read(written)
				for name, class in pairs(from.classes) do
					-- A block that only referred to a name writes a class for it with no members — the
					-- layout belongs to the block that defined it, and the reference landing on top
					-- threw that away: `struct termios` mentioned by a function declaration in a third
					-- cdef read as having no fields at all.
					local held = namespace.classes[name]
					if not held or #class.fields > 0 then namespace.classes[name] = class end
				end
				for name, alias in pairs(from.aliases) do namespace.aliases[name] = alias end
				cdefs = cdefs or {}
				cdefs[#cdefs + 1] = declared

				-- A declaration that could not be read is reported inside the string, so the offsets the parser
				-- gives have to be mapped before they mean anything. What *was* readable is still used.
				for _, problem in ipairs(declared.problems) do
					local at = cdefTextStart(source, argument, problem.start)
					cdefProblems = cdefProblems or {}
					cdefProblems[#cdefProblems + 1] = {
						message = "cdef: " .. problem.message,
						severity = 1,
						start = at,
						stop = at + math.max(problem.stop - problem.start, 0),
					}
				end
			end
		end
	end
	end

	local own = doc.classes.resolver(namespace, elsewhere)
	-- A name this file does not declare may be one that another file does, and the caller is the
	-- one that can say so. When it hands over what the name *is* — the alias body, the class — that
	-- answer is used as it stands: `---@param t lye.doc.Type` in one file means the same thing as it
	-- means in the file that declares it, and reading it as a bare name instead makes every argument
	-- of that parameter disagree with it.
	---@param text string
	---@return lye.doc.Type?
	local function resolve(text)
		local found = own(text)
		if found then return found end
		local foreign = elsewhere and elsewhere[text]
		if type(foreign) == "table" then return foreign end
	end

	--- What a call that names a C type is worth. `ffi.new("Vec")` and `ffi.cast("Vec", v)` hand
	--- back a Vec, and `ffi.typeof("Vec")` hands back the ctype — which is the class itself, since
	--- what a reader does with a ctype is construct from it. Only the names the cdef introduced
	--- resolve: `ffi.new("int")` is a number, which the definitions already say.
	--- The C type a written name stands for, and the block that declared it: `ffi.cast("Node *")`
	--- is the C type wherever a reader needs the type rather than the class a value of it is.
	---@param written string
	---@return lye.cdef.Type?
	---@return lye.cdef.Namespace?
	local function cTypeNamed(written)
		for _, declared in ipairs(cdefs or {}) do
			local found = cdef.typeOf(declared, written)
			if found then return found, declared end
		end
	end

	--- What a Lua function handed to `ffi.cast` has to be. The value really is a C function pointer
	--- at runtime, so the callback's parameters are the C ones and its result is converted back
	--- into the C type — which is what makes `buf:putcdata(ptr, len)` inside one the right thing to
	--- do and `size * nmemb` a number.
	---@param written string the type the cast names
	---@return lye.cdef.Type?
	---@return lye.cdef.Namespace?
	local function cTypeOfCallback(written)
		local found, declared = cTypeNamed(written)
		if not found then return nil end
		if found.kind == "function" then return found, declared end
		if found.kind == "pointer" and found.target and found.target.kind == "function" then
			return found.target, declared
		end
		-- A typedef of a callback: `curl_write_callback` is one.
		local resolved = cdef.resolve(declared, found.name or written)
		if resolved and resolved.kind == "pointer" and resolved.target
			and resolved.target.kind == "function" then
			return resolved.target, declared
		end
		if resolved and resolved.kind == "function" then return resolved, declared end
	end

	--- The C signature of each function literal written as a callback, by the node that is the
	--- function. Read before the names are declared, because a parameter's type is one of them.
	---@type table<integer, { type: lye.cdef.Type, namespace: lye.cdef.Namespace }>
	local callbacks = {}
	---@type table<integer, lye.doc.Type>
	local callbackReturns = {}
	--- Which C parameter each of a callback's parameters is, by the declaration the parser made for
	--- it. An anonymous function has no declaration of its own to hang them on, so the parameter
	--- itself is what is known: this is the third parameter of *that* signature.
	---@type table<lye.parser.Declaration, { index: integer, type: lye.cdef.Type, namespace: lye.cdef.Namespace }>
	-- Only a file that writes the word can be calling `ffi.cast`: the name a callback is read from
	-- has to appear in the text, so a file without it has no callbacks to gather.
	local callbackParams = {}
	if source:find("ffi", 1, true) then
	for _, node in ipairs(nodesOf(parsed, "call")) do
		if node.args and node.args[2] then
			local called = calledName(node)
			if called == "ffi.cast" or called == "ffi.new" then
				local written = parsed.nodes[node.args[1]]
				local body = parsed.nodes[node.args[2]]
				if written and written.kind == "string" and type(written.value) == "string"
					and body and body.kind == "function" then
					local signature, declared = cTypeOfCallback(written.value)
					if signature then
						callbacks[node.args[2]] = { type = signature, namespace = declared }
						for index, param in ipairs(body.params or {}) do
							callbackParams[param] = { index = index, type = signature, namespace = declared }
						end
						-- The engine converts what the callback returns into the C result type, so
						-- the C says what the body has to give — a promise like a `@return`.
						local returned = signature.returns
						if returned then
							callbackReturns[node.args[2]] = types.parse(
								cdef.notation(declared, returned), resolve)
						end
					end
				end
			end
		end
	end
	end

	--- The signatures a `ffi.cdef` in this file declared, as the fields a `ffi.load` gives back.
	--- A cdef declares the functions of one library, and the file that wrote it is the one that
	--- knows them: taking every symbol the process has ever seen would be a list nobody can read.
	---@return lye.doc.Type?
	local function loadedSymbols()
		local fields = {}
		for _, declared in ipairs(cdefs or {}) do
			for _, name in ipairs(declared.order) do
				local type = declared.types[name]
				if type and type.kind == "function" then
					local parts = {}
					for _, param in ipairs(type.params or {}) do
						parts[#parts + 1] = cdef.notation(declared, param, "parameter")
					end
					if type.variadic then parts[#parts + 1] = "..." end
					local returned = type.returns and cdef.notation(declared, type.returns)
					local written = "fun(" .. table.concat(parts, ", ") .. ")"
					if returned and returned ~= "nil" then written = written .. ": " .. returned end
					local held = types.parse(written, resolve)
					if held then fields[name] = held end
				end
			end
		end
		if not next(fields) then return nil end
		return types.object(fields)
	end

	local function cTypeOf(node)
		if not cdefs then return nil end
		local called = calledName(node)
		if called == "ffi.load" then return loadedSymbols() end
		if called ~= "ffi.new" and called ~= "ffi.cast" and called ~= "ffi.typeof" then return nil end
		local argument = node.args and node.args[1] and parsed.nodes[node.args[1]]
		if not argument or argument.kind ~= "string" or type(argument.value) ~= "string" then return nil end
		local found, declared = cTypeNamed(argument.value)
		if not found then return nil end
		-- A struct, a union, an enum or a typedef of one is a class this file declares, and looking the
		-- name up lets the document's own class win over the generated one. Everything else is mapped.
		local className = cdef.className(found)
		local named = className and resolve(className)
		if named and (found.kind == "struct" or found.kind == "union" or found.kind == "enum"
			or (found.kind == "typedef" and cdef.resolve(declared, found.name or "") ~= nil)) then
			return named
		end
		return types.parse(cdef.notation(declared, found), resolve)
	end

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
	local self = {
		parser = parsed, variables = {}, byStart = {}, diagnostics = {}, doc = annotations,
		-- A definition file — one marked `---@meta`, or named `.d.lua` — declares a library: what it
		-- writes is the whole of a function, so the checks that read a body have nothing to read.
		isDefinition = isDefinition or (type(annotations) == "table" and annotations.isDefinition) or false,
	}
	-- `ffi.C` names the same functions `ffi.load` hands back: one C namespace, and the file that
	-- wrote the cdef is the one that knows what is in it. Built once rather than per read, since
	-- every `ffi.C` in the file is that same namespace — and not at all when there is no cdef.
	self.ffiC = cdefs and loadedSymbols() or nil
	-- The problems were collected with their offsets already mapped into the document, so they are
	-- added to this list here rather than where they were found.
	for _, problem in ipairs(cdefProblems or {}) do
		self.diagnostics[#self.diagnostics + 1] = problem
	end

		-- A name an annotation writes has to mean something: the definitions, this file's classes and
		-- aliases, its generics and the names other files declare are what a name may be. What other
		-- files declare is read through this table rather than copied into it: a batch has a few
		-- thousand such names, and the copy was paid once per analysis.
	local declared = elsewhere and setmetatable({}, { __index = elsewhere }) or {}
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
	-- Which annotations say something about a type, and where in what they write the type is: a
	-- parent after a colon, a cast's direction, a generic's limit, or an `is` proof.
	local MEANS_A_TYPE = {
		param = true, field = true, ["return"] = true, type = true, cast = true, as = true,
		overload = true,
		alias = true, class = true,
	}

	-- The names an annotation writes that mean nothing here, filled in by `unknownName` as a type
	-- is read: one closure asks for the whole document rather than one per annotation.
	local missing
	---@param name string
	---@return lye.doc.Type?
	local function unknownName(name)
		-- `Box<string>` and `lye.Metatable<table>` are the class they name, and a trailing `*` is the
		-- `file*` marker. What is left has to look like a name: a description is prose, not a typo.
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
	end

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
				-- `---@cast name +T`: the name comes first and the type follows the marker, so the
				-- name is stepped over here rather than read as a type nothing declares.
				local rest = written and written:match("^%s*[%w_%.]+%s+(.*)$")
				rest = rest and (rest:gsub("^%s*[%+%-!%?]%s*", ""))
				from = rest and from and source:find(rest, from, true) or nil
				written = rest
			elseif annotation.tag == "return" and written:find(" is ", 1, true) then
				written = nil
			end
		else
			written = nil
		end
		if written and written ~= "" and from then
			missing = nil
			types.parse(written, unknownName)
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
	-- What a call is checked and bound against: the name it uses where it names one, and otherwise
	-- the annotations that built the type the callee holds.
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

	--- The types a definition file wrote inline — `function f(n: number): string` — folded into
	--- the signature its annotations gave it. A parameter the annotations already typed keeps that
	--- type: the annotation is the older, louder spelling, and two of them disagreeing is not this
	--- reader's to settle.
	---@return lye.doc.Annotation[]
	---@return lye.doc.Annotation?
	local function withInline(params, returned, generics, constraints, body)
		for _, param in ipairs(body.params or {}) do
			if param.inlineType and param.inlineType ~= "" then
				local found
				for _, annotation in ipairs(params) do
					if annotation.name == param.name then found = annotation end
				end
				if found then
					found.type = found.type or param.inlineType
				else
					params[#params + 1] = { tag = "param", name = param.name, type = param.inlineType }
				end
			end
		end
		if body.inlineVariadic then
			-- The `...` a signature declares is written the same way a named parameter is, and the
			-- reader that builds the signature looks for it by that name.
			params[#params + 1] = { tag = "param", name = "...", type = body.inlineVariadic }
		end
		local written = body.inlineGenerics
		if written then
			local inner = written:match("^%s*<(.+)>%s*$")
			for _, part in ipairs(doc.classes.splitList(inner or "")) do
				local name, constraint = part:match("^%s*([%a_][%w_]*)%s*:%s*(.*)$")
				if name then
					generics[name] = false
					constraints[name] = constraint
				else
					name = part:match("^%s*([%a_][%w_]*)%s*$")
					if name then generics[name] = false end
				end
			end
		end
		if body.inlineReturns and not returned then
			returned = { tag = "return", type = body.inlineReturns }
		end
		return params, returned
	end

	for _, declaration in ipairs(parsed.declarations) do
		local params, returned, generics, constraints, predicates, overloads =
			signatureOf(parsed, annotations, declaration)
		local inlineBody = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
		if isDefinition and inlineBody and inlineBody.isFunction then
			params, returned = withInline(params, returned, generics, constraints, inlineBody)
		end
		if #params > 0 or returned or #predicates > 0 or #overloads > 0 then
			signatures[declaration.name] = {
				params = params, returns = returned, generics = generics, constraints = constraints,
				predicates = predicates, overloads = overloads, declaration = declaration,
				values = annotationValues(returned),
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
				-- The parameters are the ones the body declares, and they belong to it alone: handing them to
				-- whichever declaration came last invented arguments for a function nobody called that way.
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
		-- `self` is the receiver a method is called with rather than an argument a caller writes, and
		-- only the colon form makes it implicit.
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

	--- The parameters a call is checked against, in order. A signature this document declares is
	--- read from the declaration, so a parameter no annotation names still holds its place —
	--- `function parseBinary(self, min, flag)` with two `@param`s had its `1` checked against the
	--- `boolean`. One from a definition file answers with the `@param` list alone, which is what
	--- those files write their parameters as.
	---@param signature lye.analyzer.Signature
	---@param resolve fun(text: string): lye.doc.Type?
	---@return (lye.doc.Type?)[]
	local function positionalParams(signature, resolve)
		if signature.declaration and declaredParams[signature.declaration] then
			return paramsFor(signature.declaration, signature, resolve)
		end
		local params = {}
		for index, annotation in ipairs(signature.params) do
			params[index] = annotation.type and types.parse(annotation.type, resolve)
		end
		return params
	end

	--- The type a function's own annotations give it. A declaration with no annotation keeps the
	--- permissive callable, so only what was written down is enforced.
	---@param signature lye.analyzer.Signature
	---@return lye.doc.Type
	local function signatureTypeOf(declaration, signature)
		local local_ = withGenerics(signature.generics, signature.constraints, resolve)
		local params, isVariadic = paramsFor(declaration, signature, local_)
		local variadic
		for _, annotation in ipairs(signature.params) do
			if annotation.name == "..." then
				isVariadic = true
				variadic = annotation.type and types.parse(annotation.type, local_) or nil
			end
		end
		-- A definition file writes it inline instead: `function f(...: string|number)`.
		local inlineBody = not variadic and declaration.valueIdx and parsed.nodes[declaration.valueIdx]
		if inlineBody and inlineBody.inlineVariadic then
			isVariadic = true
			variadic = types.parse(inlineBody.inlineVariadic, local_) or nil
		end
		local returned = signature.returns and signature.returns.type
		-- `---@return T1, T2` and `---@return T...` spread: each returned value is that type.
		local isSpread = false
		if returned and returned:sub(-3) == "..." then
			returned = (returned:sub(1, -4):gsub("%s+$", ""))
			isSpread = true
		end
		-- `---@return A, B` names two values in order, and the commas inside a signature are not
		-- separators, which is why this splits at the top level.
		local written = returned and types.splitValues(returned)
		local values
		if written and #written > 1 then
			values = {}
			for index, text in ipairs(written) do
				values[index] = types.parse(text, local_) or types.UNKNOWN_TYPE
			end
			returned = written[1]
		end
		-- A signature that names its parameters but not its return promises nothing about one. A mutable
		-- unknown says exactly that, and the body's own return is promoted into it in place.
		local fnType = types.fn(params, (returned and types.parse(returned, local_)) or types.mutable(),
			isVariadic, isSpread, variadic)
		if values then fnType.values = values end
		return fnType
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

	-- The loops in the document, so a control variable can find the one that declares it: a `for`
	-- declares its own names, and the innermost holding one is the containment rule `return` uses.
	local forNodes = nodesOf(parsed, "for")
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

	-- `f --[[@as Vec]].x`: a cast inside an expression, which is how a value gets a type where no
	-- declaration carries one. The node ending just before it is typed as what it names.
	local inlineCasts = {}
	-- Where each node ends, sorted once, so a cast finds the node it was written after without a
	-- walk of every node: a document with a cast per line is otherwise its own nodes read once per
	-- cast, which is the whole document squared.
	local byEnd
	for _, annotation in ipairs(annotations.annotations or {}) do
		if annotation.tag == "as" or annotation.tag == "cast" then
			byEnd = {}
			for _, node in ipairs(parsed.nodes) do byEnd[#byEnd + 1] = node end
			table.sort(byEnd, function(a, b)
				if a.stop ~= b.stop then return a.stop < b.stop end
				return a.start < b.start
			end)
			break
		end
	end
	for _, annotation in ipairs(annotations.annotations or {}) do
		if annotation.tag == "as" or annotation.tag == "cast" then
			local lineStart = annotation.start
			while lineStart > 1 and source:byte(lineStart - 1) ~= 10 do lineStart -= 1 end
			local before = source:sub(lineStart, annotation.start - 1)
			-- Written after code on its line, so it is inside a statement rather than above one.
			if before:find("[^%s%-]") then
				local _, rest = (annotation.type or ""):match("^([%w_%.]+)%s*(.*)$")
				local written = annotation.tag == "as" and annotation.type or rest
				-- The marker is the whole difference between saying what a value is and saying what
				-- it is not. Dropping it made `raw ---@cast raw -nil` mean the value *is* nil, which
				-- is how a read that had already ruled nil out was reported as still possibly nil.
				local marker, wanted = (written or ""):match("^%s*([%+%-]?)%s*(.*)$")
				local held = wanted ~= "" and types.parse(wanted, resolve)
				if held then
					-- The last node ending at or before the cast: the one it was written after.
					local low, high = 1, #byEnd
					while low <= high do
						local mid = math.floor((low + high) / 2)
						if byEnd[mid].stop <= annotation.start then low = mid + 1 else high = mid - 1 end
					end
					local best = byEnd[high]
					-- A negative cast says what the expression is not, so what it is has to be read
					-- from the expression itself: it is kept to be applied against that.
					-- The expression it follows has to be on the same line: a `---@cast` written at the
					-- end of `else ---@cast source string` has no expression of its own, and the node
					-- that happens to end just before it belongs to the branch above.
					if best and sameLine(parsed, best.stop, annotation.start) then
						inlineCasts[best.index] = marker == "-" and { exclude = held } or held
					end
				end
			end
		end
	end

	local root, byRecord, scopes = buildScopes(parsed)
	self.root = root
	self.scopes = scopes
	-- The list itself, not the file it was parsed into: a `---@cast` is read from there.
	narrow.collect(parsed, byRecord, signatures, resolve, annotations.annotations)
	inferCtx = infer.context(parsed, typeOfName, returns, function(base, baseName, field, offset)
		return analyzer.fieldTypeAt(self, base, baseName, field, offset)
	end, modules, cTypeOf)
	inferCtx.casts = inlineCasts
	for index, node in ipairs(parsed.nodes) do
		if node.kind == "function" then
			local declaration = bodyOwner[index]
			if declaration then
				local signature = signatureOfDecl[declaration]
				-- A declaration that says what it returns hands that to the function's type: the body
				-- implements the signature rather than replacing it. The signature is read through the
				-- same helper the declared type uses, so `---@return A, B` gives the function both
				-- values — read here as one text it gave a return nothing could compare against.
				if signature then
					inferCtx.fnTypes[index] = signatureTypeOf(declaration, signature)
				else
					inferCtx.fnTypes[index] = types.fn(
						paramsFor(declaration, nil, resolve),
						types.mutable(),
						(parsed.nodes[index].isVariadic == true)
					)
				end
			end
		end
	end

	-- The class a table declaration gives its name to. A class is often spelled longer than the
	-- table that holds it — `---@class lde.Package` over `local Package = {}` — and the method
	-- written on `Package` belongs to `lde.Package`. Only a class annotation counts: a `---@type`
	-- says what the table holds rather than that the table declares the class.
	local classOfTable = {}
	local written = annotations.annotations or {}
	for _, declaration in ipairs(parsed.declarations) do
		local spanStart = declaration.name and not declaration.name:find("[%.:]")
			and declaration.initializer == "table" and annotationSpan(parsed, declaration)
		if spanStart then
			local low, high = 1, #written
			while low <= high do
				local mid = math.floor((low + high) / 2)
				if written[mid].start < declaration.start then low = mid + 1 else high = mid - 1 end
			end
			-- The class has to be the declaration's own: a `---@type App` in the block belongs to the
			-- declaration and stops the walk, while the fields of a class annotation are part of it.
			-- Prose describes whatever follows, so it is walked over rather than read as a decision.
			for index = high, 1, -1 do
				local annotation = written[index]
				if annotation.start < spanStart then break end
				local tag = annotation.tag
				if tag == "class" then
					local name = annotation.name or (annotation.text or ""):match("^([%w_%.]+)")
					if name and namespace.classes[name] then classOfTable[declaration.name] = name end
					break
				end
				if tag ~= "field" and tag ~= "private" and tag ~= "protected" and tag ~= "public"
					and tag ~= "unknown" and tag ~= "meta" and tag ~= "version" and tag ~= "see" then
					break
				end
			end
		end
	end

	-- A method written on a class is part of it: `function Foo:bar()` gives every `Foo` a `bar`
	-- that returns what the body returns. Done before typing so a call reads the finished class.
	-- The assignment form is the same method — `Foo.bar = function(...)` and `Table.__index =
	-- function(self, key)` are how a class's metamethods are written — so both are read here.
	---@param methodName string
	---@param owner string
	---@param valueIdx integer
	local function evolveMethod(owner, methodName, valueIdx)
		-- The definitions are the signatures a document reads, including a document that *is* one
		-- of them — its text is what a client opens to show the definitions. The prelude's own
		-- field type is the one its annotations were kept beside, so it stays.
		local fromPrelude = prepared and prepared.evolved and prepared.evolved[owner]
		if fromPrelude and fromPrelude[methodName] then return end
		local methodType = inferCtx.fnTypes[valueIdx] or infer.at(inferCtx, valueIdx)
		if methodType and types.isFn(methodType) then
			doc.classes.evolve(namespace, owner, methodName, methodType)
		end
	end

	for _, declaration in ipairs(parsed.declarations) do
		if declaration.valueIdx then
			local className, methodName = declaration.name:match("^([%w_%.]+)%s*[%.:]([%w_]+)$")
			-- Only the last segment names the method: `A.B.c` is a method of `A.B`.
			local owner = className and (namespace.classes[className] and className or classOfTable[className])
			if owner and methodName then evolveMethod(owner, methodName, declaration.valueIdx) end
		end
	end
	for _, node in ipairs(nodesOf(parsed, "assignment")) do
		if node.value and parsed.nodes[node.value].kind == "function" then
			local written = writtenNameOf(parsed, node.target)
			-- A name that is not there leaves both unset; `written and written:match(...)` would take
			-- only the first capture, since a value written with `and` is one value.
			local className, methodName
			if written then className, methodName = written:match("^([%w_%.]+)%s*[%.:]([%w_]+)$") end
			local owner = className and (namespace.classes[className] and className or classOfTable[className])
			if owner and methodName then evolveMethod(owner, methodName, node.value) end
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
					-- A function literal handed to `ffi.cast` is called by C, so its parameters are the ones the
					-- header declares: `ptr` is a pointer rather than a Lua string.
					local asCallback = callbackParams[declaration]
					if not declared and asCallback then
						local wanted = asCallback.type.params and asCallback.type.params[asCallback.index]
						if wanted then
							declared = types.parse(
								cdef.notation(asCallback.namespace, wanted, "parameter"), resolve)
						end
					end
					-- A parameter with no `@param` is `any`: the arity is known, the type is not.
					if not declared and declaration.qualifier == "param" then
						declared = types.ANY_TYPE
					end
				end
			end
			local initializer = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
			local variable = {
				declaration = declaration,
				name = declaration.name,
				qualifier = declaration.qualifier,
				start = declaration.start,
				-- Where the name comes into scope. `local function f` is sugar for declaring `f`
				-- and then assigning it, so its body reads the `f` being made; every other
				-- initializer is read in the scope above, where the name does not exist yet.
				visibleFrom = declaration.isFunction and declaration.start
					or (initializer and initializer.stop or declaration.stop),
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
	local function receiverTypeOf(text, offset)
		local variable = lookupIn(scopeAt(self, offset), text, offset)
		-- The variable first, the name second: what a name resolves to is what it was declared as, and
		-- the fall-through covers names nothing declares. Two branches, because `a or f(a)` does not narrow.
		if variable then
			local found = variable
			if found.declared then return found.declared end
			return analyzer.typeAt(self, found, offset)
		end

		local held = resolve(text)
		if held or not text:find(".", 1, true) then return held end
		local head, rest = text:match("^([%w_]+)%.(.+)$")
		if not head then return nil end
		local root = lookupIn(scopeAt(self, offset), head, offset)
		if root then
			local found = root
			held = found.declared or analyzer.typeAt(self, found, offset)
		else
			held = resolve(head)
		end
		for segment in rest:gmatch("[%w_]+") do held = declaredField(held, segment) end
		return held
	end

	-- A field written onto a value is part of that value's shape, whether or not the writer called it
	-- a class. `local M = {}` given its functions below is how a Lua module is written — the whole
	-- of `string.buffer` in the definitions is written that way, and so is most Lua written by hand.
	-- Without this the table a `require` hands back has no fields at all, so `M.add` reads as nil
	-- and `M.` completes nothing.
	--
	-- It runs after every name is in scope, because the value a field is written on is looked up by
	-- name, and before the typing rounds, because the type it is given here is the one those rounds
	-- read: the literal's own table, not a copy.
	---@param written string the name as written, `M.field`, `M:field` or `A.B.field`
	---@param offset integer
	---@param fieldType lye.doc.Type?
	local function addTableField(written, offset, fieldType)
		if not fieldType then return end
		local base, field = written:match("^(.-)[%.:]([%w_]+)$")
		if not base or base == "" then return end
		local first, rest = base:match("^([%w_]+)%.?(.*)$")
		local variable = first and lookupIn(scopeAt(self, offset), first, offset)
		-- An annotation governs the value: `---@type App local x = {}` is an App, and a method written on
		-- `x` belongs to App — which the class pass above has given it — not to the literal behind it.
		if variable and variable.declared then return end
		local declaration = variable and variable.declaration
		local held
		if declaration and declaration.valueIdx then
			held = infer.at(inferCtx, declaration.valueIdx)
		else
			held = receiverTypeOf(base, offset)
		end
		for segment in rest:gmatch("[%w_]+") do
			held = held and types.indexResult(held, segment)
		end
		if held and held.variant == "object" and held.fields then
			-- Two writes to one field are two possible values, the same way a variable's own
			-- assignments are.
			local previous = held.fields[field]
			held.fields[field] = previous and types.combine(previous, fieldType) or fieldType
		end
	end

	for _, declaration in ipairs(parsed.declarations) do
		if declaration.valueIdx then
			local className, methodName = declaration.name:match("^([%w_%.]+)%s*[%.:]([%w_]+)$")
			if className and methodName and not namespace.classes[className] then
				local methodType = inferCtx.fnTypes[declaration.valueIdx]
					or infer.at(inferCtx, declaration.valueIdx)
				addTableField(declaration.name, declaration.start, methodType)
			end
		end
	end
	--- What a table holds at a computed key, read off the writes to it. Run before the rounds, where a
	--- key a literal spells is known, and again after them, where a name is.
	local function recordIndexedWrites()
	for _, node in ipairs(nodesOf(parsed, "assignment")) do
		if node.target and node.value then
			-- A write through a computed key says what the table holds at it: `consts[name] = true` is a
			-- `table<string, true>`. Without this the table is a plain `table` and every read of it is unknown.
			local target = parsed.nodes[node.target]
			if target and target.kind == "index" and target.isDynamic == true
				and target.key and target.target then
				local base = parsed.nodes[target.target]
				local name = base and (base.callee or base.name)
				local variable = name and lookupIn(scopeAt(self, node.start), name, node.start)
				local declaration = variable and variable.declaration
				local held = declaration and declaration.valueIdx
					and infer.at(inferCtx, declaration.valueIdx)
				if held and held.variant == "object" then
					local key = infer.at(inferCtx, target.key)
					local value = infer.at(inferCtx, node.value)
					-- What the key *is*, not what its type is called: a string value written as a key is a string, and
					-- a number is what an annotation writes as `integer`. An unknown is asked about first.
					local word
					if key and key.variant ~= "unknown" and key.variant ~= "any" then
						if types.satisfies(key, types.NUMBER) then
							word = "integer"
						elseif types.satisfies(key, types.STRING) then
							word = "string"
						else
							word = key.variant
						end
					end
					local previous = held.indexed
					-- A write of nil removes the key rather than storing a nil under it: `t[#t] = nil`
					-- pops, and widening the element type to `T?` would make every read of a list
					-- optional for the sake of one pop.
					if word and value and value.variant ~= "nil" then
						held.indexed = {
							key = word,
							type = previous and types.combine(previous.type, value) or value,
						}
					end
				end
			end
		end
	end
	end

	recordIndexedWrites()

	for _, node in ipairs(nodesOf(parsed, "assignment")) do
		if node.value then
			local written = writtenNameOf(parsed, node.target)
			if written and written:find("[%.:]") then
				addTableField(written, node.start, infer.at(inferCtx, node.value))
			end
		end
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
		-- A `---@field` is a promise the body has to keep, even though the class also grew the field from
		-- this very declaration. Only a field with nothing but the method behind it describes itself.
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
			-- `function Cache:put()` is a method of the class `Cache`, which is often a local whose own type
			-- is the table it was built from. The name is the class, so the field is looked for there first.
			held = resolve(base)
			wanted = declaredField(held, field)
		end
		-- A class carries the method it evolved from this very declaration, with the parameters nothing
		-- has typed yet. When a `---@field` says what the signature is, that promise is read instead.
		local className = held and held.name
		local byHand = className and doc.classes.fieldsOf(namespace, className)[field]
		if byHand then wanted = types.parse(byHand.type, resolve) or wanted end
		if not wanted or not types.isFn(wanted) then return end

		-- Either side may spell the receiver out and the other leave it implicit, so a parameter list one
		-- longer than the other side's belongs to the receiver, and the receiver's type says so.
		local shift = 0
		if #wanted.params == #list + 1 and held
			and not types.mismatch(wanted.params[1], held, "self") then
			shift = 1
		elseif #wanted.params == #list - 1 and list[1].name == "self" then
			shift = -1
		elseif #wanted.params ~= #list then
			return
		end

		if not list then return end
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
	-- A function assigned to a value whose type was written down takes that type's parameters, so the
	-- body's own `x` is a number rather than the `any` an unannotated parameter starts as.
	for _, declaration in ipairs(parsed.declarations) do
		local value = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
		local owner = byDeclaration[declaration]
		local held = owner and owner.declared
		local list = value and value.kind == "function" and value.params or nil
		-- A method's own receiver is not one of the signature's parameters, so the lists have to
		-- line up exactly for this to mean anything.
		if held and types.isFn(held) and list and #list == #held.params then
			-- A name the signature declares for itself stands for what it is limited to inside the body:
			-- `---@type fn<T: string>(t: T)` takes a string, so `t` is a string rather than a bare `T`.
			local limits = {}
			for name in pairs(held.generics or {}) do
				local constraint = held.constraints and held.constraints[name]
				limits[name] = (constraint and types.parse(constraint, resolve)) or types.UNKNOWN_TYPE
			end
			for index, param in ipairs(list) do
				local variable = byDeclaration[param]
				local paramType = held.params[index]
				if paramType and next(limits) then paramType = types.substitute(paramType, limits) end
				if variable and paramType and (variable.declared == nil or variable.declared == types.ANY_TYPE) then
					variable.declared = paramType
				end
			end
		end
	end

	-- The assignment form is not a declaration, so the parameters are the function's own and the
	-- name comes from the target: `x.call = function(y)` is read exactly like `function x:call(y)`.
	for _, node in ipairs(nodesOf(parsed, "assignment")) do
		local value = node.value and parsed.nodes[node.value]
		if value and value.kind == "function" then
			local written = writtenNameOf(parsed, node.target)
			if written then adoptFieldFunction(written, node.value, value.params) end
		end
	end

	-- Collected now that names are in scope. The target belongs to the name as it resolves where the
	-- assignment is written: a map from name to declaration hands `x = ...` to the last `x` declared.
	local assignments = collectAssignments(parsed)
	for _, assignment in ipairs(assignments) do
		local variable = lookupIn(scopeAt(self, assignment.at), assignment.name, assignment.at)
		if variable then
			local list = variable.assignments
			-- The type starts as a mutable unknown because typing one assignment can read the variable it
			-- writes: `current = current.parent` asks for `current` while its own type is still being worked out.
			list[#list + 1] = {
				at = assignment.at, valueIdx = assignment.valueIdx, type = types.mutable(),
				valuePosition = assignment.valuePosition,
			}
		end
	end
	-- Which function a `return` belongs to: the innermost function whose span holds it. Functions nest
	-- properly, and the walk back covers a literal that closed before the statement.
	local functionNodes, returnsOf = nodesOf(parsed, "function"), {}
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

	local typingCtx = {
		parsed = parsed, self = self, inferCtx = inferCtx, signatures = signatures,
		returns = returns, resolve = resolve, typeOfText = typeOfText, fieldReturns = fieldReturns,
		loopOf = loopOf, signatureOfCall = signatureOfCall, returnsOf = returnsOf,
		bodyOwner = bodyOwner, annotatedBodies = annotatedBodies, checkMetatable = checkMetatable, signatureOfDecl = signatureOfDecl,
	}
	local function inferredValuesOf(index) return typing.inferredValuesOf(typingCtx, index) end
	local function inferredReturnOf(index) return typing.inferredReturnOf(typingCtx, index) end

	-- The standard library's tables, typed as the classes the definitions describe, so `math.floor`
	-- reads a field of `mathlib`. They must exist before the rounds or `math` resolves to nothing.
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

	typing.typeAll(typingCtx)
	-- A second walk settles what the first could not: a value read before its type was known is
	-- left a placeholder, and the pass that typed it has to read it again. Only the names holding
	-- one are read again — everything else settled, and walking it finds nothing.
	if typingCtx.pending then
		local only = {}
		for _, variable in ipairs(self.variables) do
			if variable.pending then
				variable.pending = nil
				only[variable] = true
			end
		end
		typingCtx.pending = nil
		typing.typeAll(typingCtx, only)
	end
	recordIndexedWrites()

	-- What each function's own body gives back, beside what its annotation promised. Nothing is
	-- reported from it: it is how a tool asks whether an annotation says something the body does not.
	local ctx = {
		prepared = prepared,
		parsed = parsed, self = self, signatures = signatures, returns = returns,
		resolve = resolve, inferCtx = inferCtx, callbackReturns = callbackReturns, assignments = assignments,
		byDeclaration = byDeclaration,
		receiverTypeOf = receiverTypeOf, declaredHere = declaredHere, functionNodes = functionNodes, bodyOwner = bodyOwner, annotatedBodies = annotatedBodies,
		inferredValuesOf = inferredValuesOf, inferredReturnOf = inferredReturnOf,
		scopeAt = scopeAt, lookupIn = lookupIn, declaredField = declaredField,
		arithmetic = ARITHMETIC,
	}
	if isModuleOnly then
		-- What `require("this.file")` is — the one thing a module analysis is read for.
		checks.moduleExport(ctx)
	else
		checks.report(ctx)
		checkCalls(self, parsed, signatureOfCall, returns, resolve, inferCtx, source, positionalParams)
	end
	-- What each call was bound to, by node: a generic result is settled per call, and a reader
	-- asking what `f()` is — a completion after `f().` — has no other way to that answer.
	self.callTypes = inferCtx.callTypes
	self.signatures = signatures
	self.returns = returns

	-- Typing runs twice, so a check that reports while typing would see the same fault twice and a
	-- reader should be told about it once.
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
function analyzer.lookupAt(self, name, offset)
	return lookupIn(scopeAt(self, offset), name, offset)
end

return analyzer
