--[[
	What the `---@` lines above a declaration say, and the signature they make of it.

	Built once and read by every call site, so reading them is a pass of its own.
]]

local lexer = require("lye-lexer")
local KIND = lexer.KIND
local doc = require("lye-doc")
local types = require("lye-doc.type")
local memo = require("lye-analyzer.memo")
local names = require("lye-analyzer.names")
local targetName = names.targetName

--- The values one `@return` line names, as text, in order. A function type has commas of its
--- own in the values it returns — `fun():integer, V` is one value, not two — while a plain
--- `---@return A, B` names two.
---@param annotation lye.doc.Annotation?
---@return string[]?
local function returnValues(annotation)
	local text = annotation and annotation.type
	if not text then return nil end
	if text:match("^%s*fu?n%s*[%(<]") or text:match("^%s*function%s*%(") then return { text } end
	return types.splitValues(text)
end

--- The values a `@return` name, as text, in order. Several `---@return` lines are one
--- signature's values in order; the synthetic annotation carries the flattened list.
---@param annotation lye.doc.Annotation?
---@return string[]?
local function annotationValues(annotation)
	if not annotation then return nil end
	if annotation.values then return annotation.values end
	return returnValues(annotation)
end

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

---@param kind string
---@param returns table<string, lye.doc.Type>?
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

--- Every assignment, as `name`, the offset it happened at, and the arena index of the value.
--- The tree supplies all three, so nothing is recovered by scanning spans. A name past the last
--- expression of the statement records which value of it the name takes.
---@param parsed lye.parser.Result
---@return { name: string, at: integer, valueIdx: integer, valuePosition: integer? }[]
local function collectAssignments(parsed)
	local found = {}
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "assignment" and node.value then
			local names = node.targets
			if names then
				for index, target in ipairs(names) do
					local name = targetName(parsed, target)
					if name then
						found[#found + 1] = {
							name = name, at = node.start,
							valueIdx = node.targetValues and node.targetValues[index] or node.value,
							valuePosition = node.targetPositions and node.targetPositions[index] or 1,
						}
					end
				end
			else
				local name = targetName(parsed, node.target)
				if name then
					found[#found + 1] = { name = name, at = node.start, valueIdx = node.value }
				end
			end
		end
	end
	return found
end

--- Every assertion a guard makes about the region it guards. A conjunction asserts both of
--- its operands, and by De Morgan a disjunction asserts both only where it fails, which is
--- what narrows the `else` of `if x == nil or x == "" then`. The other two combinations say
--- nothing definite, so they assert nothing rather than guessing.
--- Whether a fact still says something about a read at an offset. A fact about a field is cut where
--- something could disturb it, but a read written inside the disturbing call's own arguments is
--- evaluated before that call runs, so the cut does not apply to it: `ipairs(shape.params)` is the
--- very read the fact was gathered for.
---@param fact lye.analyzer.Narrowing
---@param offset integer
---@return boolean
local function factHolds(fact, offset)
	if offset < fact.start then return false end
	if fact.disturbance and offset >= fact.disturbance and offset <= (fact.disturbanceStop or 0) then
		return true
	end
	return offset <= fact.stop
end

--- Whether a blank line sits between two offsets: the same rule a reader applies when deciding
--- which declaration a comment block belongs to.
---@param source string?
---@param stop integer
---@param start integer
---@return boolean
local function blankBetween(source, stop, start)
	if not source then return false end
	local between = source:sub(stop + 1, start - 1)
	return select(2, between:gsub("\n", "")) > 1
end

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

	local tokens, source = parsed.tokens.arena, parsed.source
	local first, index = nil, anchorIdx - 1
	while index >= 1 and tokens[index].kind == KIND.comment do
		-- A blank line ends the block. Without this a doc block left behind by an edit attaches to
		-- whatever declaration happens to come next: a `---@return` written for a function that
		-- moved away becomes the signature of the one below it, and the body then contradicts an
		-- annotation nobody wrote for it.
		if first and blankBetween(source, tokens[index].stop, tokens[first].start) then break end
		first = index
		index -= 1
	end
	if not first then return nil end
	-- And the block has to reach the declaration: what is written above a blank line describes
	-- nothing, and a declaration taking it anyway is how a class left behind by an edit became the
	-- type of whatever was written next. Only the last line of the block is checked, because the
	-- lines above it are the same block.
	if blankBetween(source, tokens[anchorIdx - 1].stop, tokens[anchorIdx].start) then return nil end
	return tokens[first].start, tokens[anchorIdx - 1].stop
end

--- The prose a declaration carries, as markdown, or nil when it carries none. The `---@` lines are
--- left out: they are the signature, which a reader is shown separately, and a line of `---` is a
--- paragraph break.
---@param parsed lye.parser.Result
---@param declaration lye.parser.Declaration
local function documentationOf(parsed, declaration)
	local anchorIdx = declaration.anchorIdx
	if not anchorIdx then return nil end

	-- The comment block is the run of comment tokens immediately above the statement, so it is
	-- walked rather than searched: looking through every token in the file for the ones that fall
	-- before the declaration made this cost the file size for each declaration in it.
	local tokens, texts = parsed.tokens.arena, parsed.tokens.texts
	local source = parsed.source
	local lines = {}
	local index, first = anchorIdx - 1, nil
	while index >= 1 and tokens[index].kind == KIND.comment do
		-- The same rule the signature is read under: a blank line ends the block, so a description
		-- that belongs to something else does not turn up in this hover.
		if first and blankBetween(source, tokens[index].stop, tokens[first].start) then break end
		first = index
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

--- Whether an annotation is written after code on its line. `local names = {} ---@type string[]`
--- is the other spelling of the same thing, and it says what *that* line's declaration is — reading it
--- as the annotation above the next declaration typed `names` as a plain table and the next name as a
--- list of strings.
---@param parsed lye.parser.Result
---@param annotation lye.doc.Annotation
---@return boolean
local function trailsCode(parsed, annotation)
	local source = parsed.source
	if not source then return false end
	-- Walked back to the newline rather than taken as a slice: copying the file up to every
	-- annotation made analysing a 2331-line file four times slower.
	local at = annotation.start - 1
	while at >= 1 do
		local char = source:sub(at, at)
		if char == "\n" then return false end
		if char ~= " " and char ~= "\t" and char ~= "\r" then return true end
		at -= 1
	end
	return false
end

--- Whether the text between two offsets stays on one line.
---@param parsed lye.parser.Result
---@param from integer
---@param to integer
---@return boolean
local function sameLine(parsed, from, to)
	local source = parsed.source
	return source == nil or not source:sub(from, to):find("\n", 1, true)
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
	local params, generics, constraints, predicates, overloads = {}, {}, {}, {}, {}
	local returns = {}
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
				-- Reading backwards, so each earlier line goes in front of the ones gathered: a
				-- second `---@return` is another value after the first, not a replacement for it.
				table.insert(returns, 1, annotation)
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
	local returned = returns[1]
	if #returns > 1 then
		-- One signature can name several values, and `---@return A` followed by `---@return B`
		-- writes the same two values that `---@return A, B` does. Keep the first line as the
		-- annotation a caller sees, and carry every value beside it.
		local values = {}
		for _, annotation in ipairs(returns) do
			for _, text in ipairs(returnValues(annotation) or {}) do
				values[#values + 1] = text
			end
		end
		returned = {
			tag = "return", type = returns[1].type, typeText = returns[1].typeText,
			start = returns[1].start, stop = returns[#returns].stop, values = values,
		}
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
			local held = constraint and memo.parse(constraint, resolve)
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
			return memo.parse(annotation.type, resolve)
		end
	end
end

--- How a call is written, for a message: `id`, `math.floor`, `Point.new`.
---@param parsed lye.parser.Result
---@param node lye.parser.Node
local function callLabel(parsed, node)
	if node.field then
		local target = node.target and parsed.nodes[node.target]
		return (target and callLabel(parsed, target) or "call") ..
			(node.isMethod and ":" or ".") .. node.field
	end
	if node.target then return callLabel(parsed, parsed.nodes[node.target]) end
	return node.callee or "call"
end

local annotations = {}
annotations.annotationValues = annotationValues
annotations.returnValues = returnValues
annotations.isNeverNumeric = isNeverNumeric
annotations.blankBetween = blankBetween
annotations.annotationSpan = annotationSpan
annotations.documentationOf = documentationOf
annotations.trailsCode = trailsCode
annotations.sameLine = sameLine
annotations.collectAssignments = collectAssignments
annotations.factHolds = factHolds
annotations.kindToType = kindToType
annotations.withGenerics = withGenerics
annotations.signatureOf = signatureOf
annotations.paramTypeOf = paramTypeOf
annotations.callLabel = callLabel
return annotations
