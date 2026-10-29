--[[
	The item tree of one document: the unit incremental analysis will reuse.

	A top-level function is the boundary that matters. Its locals cannot reach another function
	except through globals, upvalues, a module table or its signature, so a body edit needs only
	that item typed again. Everything else at the top level — requires, module table construction,
	globals — belongs to the module item, which conservatively invalidates everything.

	The manifest holds no parser node index and no parser node: a cached result must survive a
	reparse whose node arena was rebuilt. Spans are absolute in the current text; structural IDs
	name the item rather than its offset.
]]

local rapidhash = require("rapidhash")
local names = require("lye-analyzer.names")
local callName, writtenNameOf = names.callName, names.writtenNameOf

---@class lye.analyzer.ItemSignature
---@field name string the declared name, or the module's file name
---@field params { name: string, type: string? }[]
---@field returns string? the first `---@return` type, as written
---@field annotations string[] the annotation lines directly above the item
---@field generics table<string, boolean> names the signature introduces

---@class lye.analyzer.ItemDeps
---@field items table<string, boolean> item IDs this item calls, reads as a value, or whose table fields it reads
---@field modules table<string, boolean> module names `require` is handed here
---@field globals table<string, boolean> names read here that nothing in this file declares
---@field tables table<string, boolean> module-level tables this item builds or reads
---@field upvalues table<string, boolean> module-level names this item reads

---@class lye.analyzer.Item
---@field id string structural ID: file:<uri>#<kind>:<name>:<ordinal>
---@field kind "module"|"function"|"class"|"alias"
---@field name string
---@field ordinal integer the position among items of this kind and name
---@field parent string? the ID of the item holding this one
---@field path string where the item sits, by names rather than offsets
---@field start integer
---@field stop integer
---@field bodyStart integer
---@field bodyStop integer
---@field bodyHash string hash of the body source slice
---@field signature lye.analyzer.ItemSignature
---@field deps lye.analyzer.ItemDeps
---@field cache lye.analyzer.ItemCache? what a previous analysis kept for reuse

---@class lye.analyzer.ItemVar
---@field name string
---@field rel integer
---@field declared lye.doc.Type?
---@field initializer lye.doc.Type
---@field assignments lye.doc.Type[]

---@class lye.analyzer.ItemFn
---@field rel integer
---@field ordinal integer
---@field type lye.doc.Type

---@class lye.analyzer.ItemSignatureCache
---@field name string
---@field rel integer
---@field inferred lye.doc.Type?
---@field inferredValues lye.doc.Type[]?

---@class lye.analyzer.ItemDiag
---@field message string
---@field relStart integer
---@field relStop integer
---@field severity integer

---@class lye.analyzer.ItemCache
---@field signatureDigest string
---@field depsHash string
---@field resultHash string
---@field variables lye.analyzer.ItemVar[]
---@field fnTypes lye.analyzer.ItemFn[]
---@field callTypes lye.analyzer.ItemFn[]
---@field signatureInferred lye.analyzer.ItemSignatureCache[]
---@field diagnostics lye.analyzer.ItemDiag[]

---@class lye.analyzer.ItemTree
---@field skeletonHash string non-body source, annotation text and module-level declaration names
---@field moduleItem lye.analyzer.Item
---@field items table<string, lye.analyzer.Item>

local items = {}

---@param tokens lye.lexer.Tokens
---@param offset integer
--- index of the first token starting at or after the offset
local function tokenAtOrAfter(tokens, offset)
	local arena, low, high = tokens.arena, 1, tokens.count
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if arena[mid].start < offset then low = mid + 1 else high = mid - 1 end
	end
	return low
end

---@param tokens lye.lexer.Tokens
---@param offset integer
--- index of the last token starting at or before the offset
local function tokenAtOrBefore(tokens, offset)
	local arena, low, high, found = tokens.arena, 1, tokens.count, 1
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if arena[mid].start <= offset then found = mid; low = mid + 1 else high = mid - 1 end
	end
	return found
end

--- The interior of a function: what follows the parameter list (and an inline return type) and
--- precedes the closing `end`. An arrow function stores its body node, which is its interior.
---@param parsed lye.parser.Result
---@param node lye.parser.Node
---@return integer? bodyStart
---@return integer? bodyStop
local function functionBody(parsed, node)
	if node.body then
		local body = parsed.nodes[node.body]
		if body then return body.start, body.stop end
	end
	local tokens = parsed.tokens
	local arena, texts = tokens.arena, tokens.texts
	local from, angle, opener = tokenAtOrAfter(tokens, node.start), 0, nil
	for index = from, tokens.count do
		local token = arena[index]
		if token.start > node.stop then break end
		local text = texts[token.index]
		if text == "<" then
			angle += 1
		elseif text == ">" then
			if angle > 0 then angle -= 1 end
		elseif text == "(" and angle == 0 then
			opener = index
			break
		elseif text == "end" then
			break
		end
	end
	if not opener then return nil, nil end
	local depth, close = 0, nil
	for index = opener, tokens.count do
		local token = arena[index]
		if token.start > node.stop then break end
		local text = texts[token.index]
		if text == "(" then
			depth += 1
		elseif text == ")" then
			depth -= 1
			if depth == 0 then
				close = token
				break
			end
		end
	end
	if not close then return nil, nil end
	local bodyStart = (node.inlineReturnsStop or close.stop) + 1
	-- The last token is `end` for a block function; its keyword opens at `stop - 3`, and slicing
	-- from its offset rather than assuming three bytes keeps a malformed tail from being cut off.
	local last = arena[tokenAtOrBefore(tokens, node.stop)]
	local bodyStop = node.stop
	if last and last.stop == node.stop and texts[last.index] == "end" then bodyStop = last.start - 1 end
	if bodyStop < bodyStart then bodyStop = bodyStart - 1 end
	return bodyStart, bodyStop
end

--- The annotations written directly above a declaration, nearest last. Only whitespace may sit
--- between them; a blank line or another statement ends the block.
---@param source string
---@param list lye.doc.Annotation[]
---@param offset integer
---@return lye.doc.Annotation[]
local function leadingAnnotations(source, list, offset)
	local low, high, last = 1, #list, 0
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if list[mid].start < offset then
			last = mid
			low = mid + 1
		else
			high = mid - 1
		end
	end
	local found, cursor = {}, offset
	for index = last, 1, -1 do
		local annotation = list[index]
		if annotation.stop >= cursor then break end
		if source:sub(annotation.stop + 1, cursor - 1):find("%S") then break end
		found[#found + 1] = annotation
		cursor = annotation.start
	end
	local ordered = {}
	for index = #found, 1, -1 do ordered[#ordered + 1] = found[index] end
	return ordered
end

---@param annotation lye.doc.Annotation
local function annotationType(annotation)
	return annotation.typeText or annotation.type
end

---@param source string
---@param annotation lye.doc.Annotation
local function annotationText(source, annotation)
	return source:sub(annotation.start, annotation.stop)
end

--- The names a signature declares for itself, as `---@generic` and an inline `<T>` do.
---@param annotation lye.doc.Annotation
---@param generics table<string, boolean>
local function addGenerics(annotation, generics)
	if annotation.name then generics[annotation.name] = true end
	for word in (annotation.text or ""):gmatch("[%a_][%w_]*") do generics[word] = true end
	local params = annotationType(annotation)
	if params then
		local inside = params:match("^%s*<([^<>]*)>")
		if inside then
			for name in inside:gmatch("[%a_][%w_%.]*") do generics[name] = true end
		end
	end
end

---@param parsed lye.parser.Result
---@param source string
---@param list lye.doc.Annotation[]
---@param declaration lye.parser.Declaration
---@param node lye.parser.Node
---@return lye.analyzer.ItemSignature
---@return integer? leadingStart where the annotation block above the declaration opens
local function functionSignature(parsed, source, list, declaration, node)
	-- The annotation block ends where the statement opens, not where its name is: `local function
	-- f` and `function M.f` put code between the two, and reading from the name would drop the
	-- annotations above them.
	local anchor = declaration.anchorIdx and parsed.tokens.arena[declaration.anchorIdx]
	local leading = leadingAnnotations(source, list, anchor and anchor.start or declaration.start)
	local annotations, generics, paramTypes = {}, {}, {}
	local returns
	for _, annotation in ipairs(leading) do
		annotations[#annotations + 1] = annotationText(source, annotation)
		if annotation.tag == "param" and annotation.name then
			paramTypes[annotation.name] = annotationType(annotation)
		elseif annotation.tag == "return" then
			if not returns then returns = annotationType(annotation) end
		elseif annotation.tag == "generic" then
			addGenerics(annotation, generics)
		end
	end
	local params = {}
	for _, param in ipairs(node.params or {}) do
		params[#params + 1] = { name = param.name, type = paramTypes[param.name] }
	end
	if node.inlineVariadic then
		params[#params + 1] = { name = "...", type = node.inlineVariadic }
	elseif node.isVariadic then
		params[#params + 1] = { name = "..." }
	end
	if node.inlineGenerics then
		for word in node.inlineGenerics:gmatch("[%a_][%w_]*") do generics[word] = true end
	end
	if not returns and node.inlineReturns then returns = node.inlineReturns end
	return {
		name = declaration.name, params = params, returns = returns,
		annotations = annotations, generics = generics,
	}, leading[1] and leading[1].start or nil
end

---@param source string
---@param annotation lye.doc.Annotation
---@param name string
---@return lye.analyzer.ItemSignature
local function annotationSignature(source, annotation, name)
	local generics, params = {}, {}
	local inside = (annotationType(annotation) or ""):match("^%s*<([^<>]*)>")
	if inside then
		for param in inside:gmatch("[%a_][%w_%.]*") do
			---@cast param string
			params[#params + 1] = { name = param }
			generics[param] = true
		end
	end
	return {
		name = name, params = params, returns = nil,
		annotations = { annotationText(source, annotation) }, generics = generics,
	}
end

--- A name as the ID may hold it. Structural IDs are keys, not source, so punctuation a Lua name
--- can carry (`M:method`, `A.B`) is folded to `_` rather than read back as the separators.
---@param name string
local function idName(name)
	return (name:gsub("[^%w_%.]", "_"))
end

---@param uri string
local function moduleNameOf(uri)
	local name = uri:match("([^/\\]+)%.lua$")
	return name or "module"
end

--- The earliest byte of the annotation block written directly above an offset. A module-level
--- declaration's annotations say what its type is, so a cache keyed by the declaration alone has
--- to include them.
---@param source string
---@param list lye.doc.Annotation[]
---@param offset integer
function items.annotationStart(source, list, offset)
	local leading = leadingAnnotations(source, list, offset)
	return leading[1] and leading[1].start or offset
end

--- The item tree of a parse.
---@param source string
---@param parsed lye.parser.Result
---@param annotations lye.doc.File the annotations read from the same source
---@param uri string? the document's URI, for structural IDs
---@return lye.analyzer.ItemTree
function items.build(source, parsed, annotations, uri)
	assert(type(source) == "string", "items.build expects a string")
	uri = uri or ""
	local list = (annotations and annotations.annotations) or {}
	local moduleName = moduleNameOf(uri)
	local modulePath = "module:" .. idName(moduleName) .. ":1"
	local moduleId = "file:" .. uri .. "#module:" .. idName(moduleName) .. ":1"

	---@type lye.analyzer.Item
	local moduleItem = {
		id = moduleId, kind = "module", name = moduleName, ordinal = 1, parent = nil,
		path = modulePath, start = 1, stop = #source,
		bodyStart = 1, bodyStop = #source, bodyHash = rapidhash.hex(source),
		signature = {
			name = moduleName, params = {}, returns = nil, annotations = {}, generics = {},
		},
		deps = { items = {}, modules = {}, globals = {}, tables = {}, upvalues = {} },
	}

	---@type table<string, lye.analyzer.Item>
	local byId = {}
	---@type lye.analyzer.Item[] sorted by start, for finding the item holding a node
	local spans = {}
	---@type table<string, lye.analyzer.Item>
	local byName = {}
	local ordinals = {}
	---@param kind string
	---@param name string
	---@return integer
	local function nextOrdinal(kind, name)
		local key = kind .. "\0" .. name
		local ordinal = (ordinals[key] or 0) + 1
		ordinals[key] = ordinal
		return ordinal
	end

	-- Top-level declarations are the ones with depth 0: a function declared inside a body is part
	-- of the item holding it, and the parser already says which depth a declaration was made at.
	for _, declaration in ipairs(parsed.declarations) do
		if declaration.depth == 0 and declaration.valueIdx then
			local node = parsed.nodes[declaration.valueIdx]
			if node and node.kind == "function" then
				local bodyStart, bodyStop = functionBody(parsed, node)
				local ordinal = nextOrdinal("function", declaration.name)
				local id = "file:" .. uri .. "#function:" .. idName(declaration.name) .. ":" .. ordinal
				local signature, leadingStart = functionSignature(parsed, source, list, declaration, node)
				local anchor = declaration.anchorIdx and parsed.tokens.arena[declaration.anchorIdx]
				-- The annotation block above the declaration is part of the item: a signature is
				-- written there, and a diagnostic about it belongs to this item rather than the module.
				local start = math.min(declaration.start, node.start, anchor and anchor.start or declaration.start)
				if leadingStart then start = math.min(start, leadingStart) end
				---@type lye.analyzer.Item
				local item = {
					id = id, kind = "function", name = declaration.name, ordinal = ordinal,
					parent = moduleId, path = modulePath .. "/function:" .. idName(declaration.name) .. ":" .. ordinal,
					start = start, stop = node.stop,
					bodyStart = bodyStart or node.start, bodyStop = bodyStop or node.stop,
					bodyHash = rapidhash.hex(source:sub(bodyStart or node.start, bodyStop or node.stop)),
					signature = signature,
					deps = { items = {}, modules = {}, globals = {}, tables = {}, upvalues = {} },
				}
				byId[id] = item
				spans[#spans + 1] = item
				byName[declaration.name] = item
				-- `function M:method` is called `M.method`, and both spellings name the same item.
				local dotted = declaration.name:gsub(":", ".")
				if dotted ~= declaration.name then byName[dotted] = item end
				local field = declaration.name:match("[%.:]([%w_]+)$")
				if field then byName[field] = byName[field] or item end
			end
		end
	end
	table.sort(spans, function(left, right) return left.start < right.start end)

	---@param node { start: integer, stop: integer }
	--- the innermost top-level function item holding the node
	local function ownerOf(node)
		local low, high, index = 1, #spans, 0
		while low <= high do
			local mid = math.floor((low + high) / 2)
			if spans[mid].start <= node.start then
				index = mid
				low = mid + 1
			else
				high = mid - 1
			end
		end
		while index > 0 do
			local item = spans[index]
			if item.start <= node.start and node.stop <= item.stop then return item end
			index -= 1
		end
		return nil
	end

	-- `---@class` and `---@alias` are items of their own: a declaration namespace change is what
	-- they describe, and the manifest names them like any other structural unit. An annotation
	-- written inside a function belongs to that function's item, not to the module.
	for _, annotation in ipairs(list) do
		local tag = annotation.tag
		if tag == "class" or tag == "alias" then
			---@cast tag "class"|"alias"
			local node = { start = annotation.start, stop = annotation.stop }
			if not ownerOf(node) then
				local name = annotation.name or (annotation.text or ""):match("^([%w_%.]+)") or tag
				local ordinal = nextOrdinal(tag, name)
				local id = "file:" .. uri .. "#" .. tag .. ":" .. idName(name) .. ":" .. ordinal
				---@type lye.analyzer.Item
				local item = {
					id = id, kind = tag, name = name, ordinal = ordinal, parent = moduleId,
					path = modulePath .. "/" .. tag .. ":" .. idName(name) .. ":" .. ordinal,
					start = annotation.start, stop = annotation.stop,
					bodyStart = annotation.start, bodyStop = annotation.stop,
					bodyHash = rapidhash.hex(annotationText(source, annotation)),
					signature = annotationSignature(source, annotation, name),
					deps = { items = {}, modules = {}, globals = {}, tables = {}, upvalues = {} },
				}
				byId[id] = item
			end
		end
	end

	-- Names nothing in this file declares are the ones read from the environment: a coarse but
	-- real answer without resolving every scope.
	---@type table<string, boolean>
	local declaredNames, moduleTables = {}, {}
	---@type table<string, lye.parser.Declaration>
	local topDeclarations = {}
	for _, declaration in ipairs(parsed.declarations) do
		declaredNames[declaration.name] = true
		if declaration.depth == 0 then
			topDeclarations[declaration.name] = declaration
			if declaration.initializer == "table" then
				moduleTables[declaration.name] = true
				moduleItem.deps.tables[declaration.name] = true
			end
		end
	end

	---@param node lye.parser.Node
	--- the function item's deps, or the module's at the top level
	local function depsOf(node)
		local owner = ownerOf(node)
		return owner and owner.deps or moduleItem.deps
	end

	-- What a module-level local's initializer reaches. `local factor = compute()` makes every
	-- reader of `factor` depend on `compute`: a changed result changes what the name holds even
	-- though the declaration's own text did not move.
	local topList = {}
	for _, declaration in pairs(topDeclarations) do topList[#topList + 1] = declaration end
	table.sort(topList, function(left, right) return left.start < right.start end)
	---@param from integer
	---@param to integer
	local function topAt(from, to)
		local low, high, index = 1, #topList, 0
		while low <= high do
			local mid = math.floor((low + high) / 2)
			if topList[mid].start <= from then
				index = mid
				low = mid + 1
			else
				high = mid - 1
			end
		end
		local declaration = topList[index]
		if declaration and declaration.start <= from and to <= declaration.stop then return declaration end
		return nil
	end
	---@type table<string, { items: table<string, boolean>, locals: table<string, boolean> }>
	local moduleValueDeps = {}
	for name, declaration in pairs(topDeclarations) do
		if declaration.valueIdx and declaration.initializer ~= "function" then
			moduleValueDeps[name] = { items = {}, locals = {} }
		end
	end
	for _, node in ipairs(parsed.byKind.call or {}) do
		local declaration = topAt(node.start, node.stop)
		local held = declaration and moduleValueDeps[declaration.name]
		if held then
			local called = callName(parsed, node)
			local target = called and (byName[called] or byName[called:match("([%w_]+)$")])
			if target then held.items[target.id] = true end
		end
	end
	for _, node in ipairs(parsed.byKind.prefix or {}) do
		local name = node.callee
		local declaration = name and topAt(node.start, node.stop)
		local held = declaration and moduleValueDeps[declaration.name]
		if held and name ~= declaration.name and topDeclarations[name] then held.locals[name] = true end
	end
	-- A name whose initializer reads another module local reaches whatever that one reaches.
	for _ = 1, 8 do
		local changed = false
		for _, held in pairs(moduleValueDeps) do
			for localName in pairs(held.locals) do
				local nested = moduleValueDeps[localName]
				if nested then
					for id in pairs(nested.items) do
						if not held.items[id] then
							held.items[id] = true
							changed = true
						end
					end
					for deeper in pairs(nested.locals) do
						if not held.locals[deeper] and deeper ~= localName then
							held.locals[deeper] = true
							changed = true
						end
					end
				end
			end
		end
		if not changed then break end
	end

	-- Which item writes which field of which module-level table. A function that reads the table
	-- depends on every writer: changing what a field holds changes what a read of it is.
	---@type table<string, table<string, boolean>>
	local writersByTable = {}
	---@param tableName string
	---@param item lye.analyzer.Item
	local function addWriter(tableName, item)
		if not moduleTables[tableName] then return end
		---@type table<string, boolean>?
		local list = writersByTable[tableName]
		if not list then
			list = {}
			writersByTable[tableName] = list
		end
		list[item.id] = true
	end
	for _, item in pairs(byId) do
		if item.kind == "function" then
			local base = item.name:match("^([%w_%.]+)%s*[%.:]") or item.name:match("^([%w_]+)$")
			if base and base ~= item.name then addWriter(base, item) end
		end
	end

	-- A method declared on a module table is a field write like any other, and a body that writes
	-- one names the table it writes through: `M.cache = {}` is the module's shape changing.
	for _, node in ipairs(parsed.byKind.assignment or {}) do
		local written = node.target and writtenNameOf(parsed, node.target)
		local base = written and written:match("^([%w_]+)[%.:]")
		if base then
			local owner = ownerOf(node) or moduleItem
			addWriter(base, owner)
		end
	end

	for _, node in ipairs(parsed.byKind.call or {}) do
		local deps = depsOf(node)
		if node.callee == "require" then
			local argIdx = node.args and node.args[1]
			local argument = argIdx and parsed.nodes[argIdx]
			if argument and argument.kind == "string" and type(argument.value) == "string" then
				deps.modules[argument.value] = true
			end
		end
		local called = callName(parsed, node)
		if called then
			local target = byName[called] or byName[called:match("([%w_]+)$")]
			if target and target.deps ~= deps then deps.items[target.id] = true end
		end
	end
	-- A name read from the module item: a function value, a module-level local, or the table the
	-- item's own methods live on. `deps.items` is what a changed result reaches; `upvalues` is
	-- what a changed declaration reaches.
	for _, node in ipairs(parsed.byKind.prefix or {}) do
		local name = node.callee
		if name then
			local deps = depsOf(node)
			local top = topDeclarations[name]
			if top then
				deps.upvalues[name] = true
				local target = byName[name]
				if target and target.deps ~= deps then deps.items[target.id] = true end
				for id in pairs((moduleValueDeps[name] or {}).items or {}) do
					if id ~= nil then deps.items[id] = true end
				end
			elseif not declaredNames[name] then
				deps.globals[name] = true
			end
		end
	end
	-- `M.field` reads and writes: reading a field of a module-level table is depending on what the
	-- items writing it made the field hold.
	for _, node in ipairs(parsed.byKind.index or {}) do
		if node.field then
			local base = node.target and writtenNameOf(parsed, node.target)
			local root = base and base:match("^([%w_]+)")
			if root and moduleTables[root] then depsOf(node).tables[root] = true end
		end
	end
	-- The table a method item lives on is read by its own body whenever it recurses through it.
	for _, item in pairs(byId) do
		for tableName in pairs(item.deps.tables) do
			for writerId in pairs(writersByTable[tableName] or {}) do
				if writerId ~= item.id then item.deps.items[writerId] = true end
			end
		end
	end
	for id in pairs(byId) do moduleItem.deps.items[id] = true end

	-- The skeleton is everything a body edit must not touch: the source outside every function
	-- body, the annotation text (a signature is written there) and the module-level names.
	-- `spans` is in start order and top-level items do not overlap, so their body regions are
	-- disjoint and already in the order the source is walked.
	local pieces, cursor = {}, 1
	for _, item in ipairs(spans) do
		if item.bodyStop >= item.bodyStart then
			pieces[#pieces + 1] = source:sub(cursor, item.bodyStart - 1)
			cursor = item.bodyStop + 1
		end
	end
	pieces[#pieces + 1] = source:sub(cursor)
	for _, annotation in ipairs(list) do
		pieces[#pieces + 1] = "\1a"
		pieces[#pieces + 1] = annotationText(source, annotation)
	end
	for _, declaration in ipairs(parsed.declarations) do
		if declaration.depth == 0 then
			pieces[#pieces + 1] = "\1d"
			pieces[#pieces + 1] = declaration.name
		end
	end

	return {
		skeletonHash = rapidhash.hex(table.concat(pieces, "\0")),
		moduleItem = moduleItem,
		items = byId,
	}
end

return items
