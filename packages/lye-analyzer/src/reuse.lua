--[[
	Deciding which top-level items a keystroke has to look at again.

	An item's cached result is keyed by what it can observe: its own signature and body, the
	signatures of the items it reads, the declarations of the module-level names it closes over,
	the modules it requires, and the declaration namespace. Nothing here holds a parser node
	index: the manifest names items structurally and every cached offset is relative to the item,
	so a reparse or an offset shift is a mapping rather than a reason to throw the cache away.

	The conservative rule is the default. Items before the edit are reused when their hashes
	match; items after it are rebased only when the edit is one contiguous replacement and every
	offset inside the item moved by the same delta. Anything else is dirty.
]]

local rapidhash = require("rapidhash")
local types = require("lye-doc.type")

local reuse = {}

-- The version of the reuse model itself. A cached result from another one is a miss even when
-- every source hash happens to agree.
reuse.VERSION = "lye-analyzer/reuse:2"

---@param list string[]
local function sorted(list)
	table.sort(list)
	return list
end

---@param map table<string, any>?
local function keys(map)
	local out = {}
	for name in pairs(map or {}) do out[#out + 1] = name end
	return sorted(out)
end

--- The one contiguous replacement between two texts: the longest common prefix and suffix, and
--- what is left between them. Two distant edits become one region, which is conservative: every
--- item touching the region is recomputed and everything after it shifts by one delta.
---@param old string
---@param new string
function reuse.region(old, new)
	local oldLen, newLen = #old, #new
	local minLen = oldLen < newLen and oldLen or newLen
	local step = 4096
	local prefix = 0
	while prefix + step <= minLen and old:sub(prefix + 1, prefix + step) == new:sub(prefix + 1, prefix + step) do
		prefix += step
	end
	while prefix < minLen and old:byte(prefix + 1) == new:byte(prefix + 1) do prefix += 1 end
	local limit = minLen - prefix
	local suffix = 0
	while suffix + step <= limit and old:sub(oldLen - suffix - step + 1, oldLen - suffix)
		== new:sub(newLen - suffix - step + 1, newLen - suffix) do
		suffix += step
	end
	while suffix < limit and old:byte(oldLen - suffix) == new:byte(newLen - suffix) do suffix += 1 end
	return {
		oldStart = prefix + 1, oldStop = oldLen - suffix,
		newStart = prefix + 1, newStop = newLen - suffix,
		delta = newLen - oldLen,
	}
end

--- The signature an item presents to its callers, as one hash. A change here is a change every
--- reader of the item can observe.
---@param item lye.analyzer.Item
function reuse.signatureDigest(item)
	local parts = { item.kind, item.name, tostring(item.ordinal), item.signature.name or "" }
	for _, param in ipairs(item.signature.params or {}) do
		parts[#parts + 1] = "p:" .. param.name .. ":" .. (param.type or "")
	end
	parts[#parts + 1] = "r:" .. (item.signature.returns or "")
	for _, annotation in ipairs(item.signature.annotations or {}) do
		parts[#parts + 1] = "a:" .. annotation
	end
	for _, name in ipairs(keys(item.signature.generics)) do parts[#parts + 1] = "g:" .. name end
	return rapidhash.hex(table.concat(parts, "\0"))
end

--- The declaration namespace as one hash: every class and alias this document writes. A change
--- to one is a change to what a name in any item's annotation means.
---@param source string
---@param annotations lye.doc.File?
function reuse.namespaceDigest(source, annotations)
	local parts = {}
	for _, annotation in ipairs((annotations and annotations.annotations) or {}) do
		if annotation.tag == "class" or annotation.tag == "alias" then
			parts[#parts + 1] = annotation.tag
			parts[#parts + 1] = source:sub(annotation.start, annotation.stop)
		end
	end
	return rapidhash.hex(table.concat(parts, "\0"))
end

-- One digest per parsed annotation file: the file is read-only, so the text a cache keys on is
-- the same for every analysis that was handed the same file.
local annotationDigests = setmetatable({}, { __mode = "k" })
local annotationSources = setmetatable({}, { __mode = "k" })

--- The annotation text of a document, as one hash. Classes, aliases, fields and generics are the
--- whole of what an annotation type expression resolves against, so this is what a parsed type's
--- cache keys on.
---@param source string
---@param annotations lye.doc.File?
function reuse.annotationsDigest(source, annotations)
	if not annotations then return "" end
	local held = annotationDigests[annotations]
	-- The digest covers the text, so a file object paired with other text is read again rather than
	-- answering with the digest of the text it was first seen with.
	if held ~= nil and annotationSources[annotations] == source then return held end
	local parts = {}
	for _, annotation in ipairs(annotations.annotations or {}) do
		parts[#parts + 1] = source:sub(annotation.start, annotation.stop)
	end
	held = rapidhash.hex(table.concat(parts, "\0"))
	annotationDigests[annotations] = held
	annotationSources[annotations] = source
	return held
end

--- The plugins a document is read with, as one hash. A workspace that turns one off reads the
--- same file differently, so its cached results are not this run's.
---@param specs { name: string?, path: string? }[]?
function reuse.pluginsDigest(specs)
	local parts = {}
	for _, spec in ipairs(specs or {}) do
		parts[#parts + 1] = tostring(spec.name or spec.path or "?")
	end
	return rapidhash.hex(table.concat(sorted(parts), "\0"))
end

--- The annotations written inside an item, resolved through the declaration namespace and the
--- other files the analysis can see. The text itself is already in the signature or body hash;
--- what this adds is that `Remote` may mean something different today.
---@param ctx table
---@param item lye.analyzer.Item
local function resolvedAnnotations(ctx, item)
	local list = (ctx.annotations and ctx.annotations.annotations) or {}
	-- The annotations are in start order. Find the first that can reach the item, then walk the
	-- candidates that start inside it; the list is sparse compared with the source.
	local low, high, last = 1, #list, 0
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if list[mid].start <= item.stop then
			last = mid
			low = mid + 1
		else
			high = mid - 1
		end
	end
	local parts, cache = {}, {}
	for index = last, 1, -1 do
		local annotation = list[index]
		if annotation.stop < item.start then break end
		local text = annotation.typeText
		if text and annotation.start >= item.start then
			for word in text:gmatch("[%a_][%w_%.]*") do
				local held = cache[word]
				if held == nil then
					local found = ctx.digestResolve and ctx.digestResolve(word) or nil
					if found ~= nil then
						---@cast found lye.doc.Type
						held = types.display(found)
					else
						held = ""
					end
					cache[word] = held
				end
				if held ~= "" then parts[#parts + 1] = word .. "=" .. held end
			end
		end
	end
	return rapidhash.hex(table.concat(parts, "\0"))
end

--- What an item can observe, as one hash. Two analyses that agree on this agree on everything
--- the item's cached result was computed from.
---@param ctx table
---@param item lye.analyzer.Item
function reuse.depsHash(ctx, item)
	local parts = {
		reuse.VERSION, ctx.pluginsDigest or "", ctx.namespaceDigest or "",
		reuse.signatureDigest(item),
	}
	local deps = item.deps
	for _, id in ipairs(keys(deps.items)) do
		local dep = ctx.tree.items[id]
		---@cast dep lye.analyzer.Item?
		local digest = "?"
		if dep ~= nil then digest = reuse.signatureDigest(dep) end
		parts[#parts + 1] = "i\0" .. id .. "\0" .. digest
	end
	for _, name in ipairs(keys(deps.modules)) do
		parts[#parts + 1] = "m\0" .. name .. "\0" .. (ctx.moduleDigest and ctx.moduleDigest(name) or "")
	end
	for _, name in ipairs(keys(deps.upvalues)) do
		-- A name that names a function item is already covered by that item's signature above.
		if not (ctx.nameToItem and ctx.nameToItem[name]) then
			parts[#parts + 1] = "u\0" .. name .. "\0" .. (ctx.declarationDigest and ctx.declarationDigest(name) or "")
		end
		-- A function that writes the name changes what a reader sees without moving the declaration.
		parts[#parts + 1] = "w\0" .. name .. "\0" .. (ctx.writeDigest and ctx.writeDigest(name) or "")
	end
	for _, name in ipairs(keys(deps.tables)) do
		parts[#parts + 1] = "t\0" .. name .. "\0" .. (ctx.declarationDigest and ctx.declarationDigest(name) or "")
	end
	local assigned = false
	for _, name in ipairs(keys(deps.globals)) do
		parts[#parts + 1] = "g\0" .. name .. "\0" .. (ctx.globalDigest and ctx.globalDigest(name) or "")
		parts[#parts + 1] = "w\0" .. name .. "\0" .. (ctx.writeDigest and ctx.writeDigest(name) or "")
		if ctx.assignedGlobals and ctx.assignedGlobals[name] then assigned = true end
	end
	-- A global this file assigns at the module level has no declaration to hash: what it holds is
	-- whatever the module-level statements left in it.
	if assigned then parts[#parts + 1] = "ga\0" .. (ctx.moduleAssignDigest or "") end
	parts[#parts + 1] = resolvedAnnotations(ctx, item)
	return rapidhash.hex(table.concat(parts, "\1"))
end

--- The declarations and annotations a document has, as one string. A name that appeared,
--- disappeared or changed kind changes structural IDs and annotation ownership, and an item
--- whose IDs moved is not safe to carry over from an older tree.
---@param parsed lye.parser.Result
---@param annotations lye.doc.File?
function reuse.declarationShape(parsed, annotations)
	local parts = {}
	for _, declaration in ipairs(parsed.declarations or {}) do
		parts[#parts + 1] = table.concat({ tostring(declaration.depth), declaration.name,
			tostring(declaration.isFunction), tostring(declaration.valueIdx ~= nil) }, "\0")
	end
	for _, annotation in ipairs((annotations and annotations.annotations) or {}) do
		if annotation.tag == "class" or annotation.tag == "alias" then
			parts[#parts + 1] = "a\0" .. annotation.tag .. "\0" .. tostring(annotation.name or "")
		end
	end
	return table.concat(sorted(parts), "\1")
end

---@class lye.reuse.Clean
---@field old lye.analyzer.Item
---@field delta integer
---@field rebased boolean?

---@class lye.reuse.Meta
---@field signatureDigest string?
---@field depsHash string?

---@class lye.reuse.Plan
---@field clean table<string, lye.reuse.Clean>
---@field dirty table<string, boolean>
---@field meta table<string, lye.reuse.Meta>
---@field conservative integer
---@field region table

--- Which items may be reused, and which have to be looked at again.
---@param ctx table
---@param previous lye.analyzer.Result?
---@param region table
---@return lye.reuse.Plan
function reuse.plan(ctx, previous, region)
	local plan = { clean = {}, dirty = {}, meta = {}, conservative = 0, region = region }
	---@type lye.analyzer.ItemTree?
	local oldTree = previous and previous.items
	if not (oldTree and oldTree.items) then
		for id in pairs(ctx.tree.items) do plan.dirty[id] = true end
		return plan
	end
	---@cast oldTree lye.analyzer.ItemTree
	---@type table<string, lye.analyzer.Item>
	local items = ctx.tree.items
	---@type table<string, lye.analyzer.Item>
	local oldItems = oldTree.items
	for id, item in pairs(items) do
		local old = oldItems[id]
		local signature = reuse.signatureDigest(item)
		local deps = reuse.depsHash(ctx, item)
		plan.meta[id] = { signatureDigest = signature, depsHash = deps }
		local cache = old and old.cache
		---@cast cache lye.analyzer.ItemCache?
		local same = old ~= nil and cache ~= nil and cache.signatureDigest == signature
			and old.bodyHash == item.bodyHash and cache.depsHash == deps
		if not old then
			plan.dirty[id] = true
		elseif ctx.forceDirty then
			-- The parse or the declaration set moved in a way this reuse model does not follow:
			-- the item may be byte-identical and still observe something different.
			plan.dirty[id] = true
			if same then plan.conservative += 1 end
		elseif not same then
			plan.dirty[id] = true
		else
			-- `before` and `after` are established against both texts: an item that moved is only
			-- reusable when every offset in it moved by the one edit's delta.
			local before = old.stop < region.oldStart and item.stop < region.newStart
			local after = old.start > region.oldStop and item.start > region.newStop
			if before then
				if item.start == old.start and item.stop == old.stop then
					plan.clean[id] = { old = old, delta = 0 }
				else
					plan.dirty[id] = true
					plan.conservative += 1
				end
			elseif after then
				if not ctx.allowRebase then
					-- The safe default: only items entirely before the edit are reused. A later
					-- item's spans can be rebased by the delta, but nothing proves the parser put
					-- it back in the same place, so it is recomputed unless a caller opts in.
					plan.dirty[id] = true
					plan.conservative += 1
				else
				local delta = item.start - old.start
				if delta == region.delta and item.stop - old.stop == delta then
					plan.clean[id] = { old = old, delta = delta, rebased = true }
				else
					plan.dirty[id] = true
					plan.conservative += 1
				end
				end
			else
				plan.dirty[id] = true
				plan.conservative += 1
			end
		end
	end
	return plan
end

--- What an item gives anyone outside it: its signature and what its body returns, as one hash.
--- A dirty item whose hash did not move leaves its dependents' cached results valid.
---@param item lye.analyzer.Item
---@param fnType lye.doc.Type?
---@param exports table<string, string>?
function reuse.resultHash(item, fnType, exports)
	local parts = { reuse.signatureDigest(item) }
	if fnType then
		local returns = fnType.returns
		if returns ~= nil then
			parts[#parts + 1] = "r:" .. types.display(returns)
		else
			parts[#parts + 1] = "r:?"
		end
		for _, value in ipairs(fnType.values or {}) do
			parts[#parts + 1] = "v:" .. types.display(value)
		end
	end
	---@type table<string, string>
	local values = exports or {}
	for _, name in ipairs(keys(values)) do parts[#parts + 1] = "e:" .. name .. "=" .. values[name] end
	return rapidhash.hex(table.concat(parts, "\0"))
end

--- A shallow copy of a settled type. A reused result must not hand a mutable type object to the
--- new analysis: a check that promotes a constraint in place would then change the previous
--- result's answer, and the next edit would read something the old text never said.
---@param held lye.doc.Type?
function reuse.copyType(held)
	if type(held) ~= "table" then return held end
	local copy = {}
	for key, value in pairs(held) do copy[key] = value end
	local metatable = getmetatable(held)
	if metatable then setmetatable(copy, metatable) end
	---@cast copy lye.doc.Type
	return copy
end

--- Do two tables of names share one?
---@param left table<string, boolean>
---@param right table<string, boolean>
---@return boolean
function reuse.intersects(left, right)
	for name in pairs(left or {}) do
		if right and right[name] then return true end
	end
	return false
end

return reuse
