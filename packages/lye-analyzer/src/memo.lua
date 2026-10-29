--[[
	The questions an analysis asks more than once, and the answers it can keep.

	A resolver is a closure made by one analysis, and a type is a table that analysis reads, so the
	memos here are keyed by those objects and are weak tables: when the analysis and its resolvers
	are dropped, nothing here keeps a type alive. That is what makes a memo safe to add without a
	lifecycle of its own.

	No parsed type outlives the analysis that made it. That is deliberate: `serial.write` writes a
	type graph by identity, so two analyses of one text have to share exactly the tables a fresh
	reading would share, and a type kept from an earlier analysis would either be shared where the
	new one is not or be a stale copy of a mutable type. The namespace read is the one cache that
	outlives an analysis, and it holds only class/alias *definitions*, whose mutable half
	(`evolved`, `built`) is rebuilt for every analysis.
]]

local doc = require("lye-doc")
local types = require("lye-doc.type")

local memo = {}

local NONE = {}

---@class lye.analyzer.MemoSlot
---@field texts table<string, lye.doc.Type|false> the texts it already answered, `false` for one nothing stands for
---@field counters table<string, number>? where its hit and miss counts go

--- Per-resolver state: the texts it already answered, and where its counters go. The resolver is
--- made by one analysis and dies with it, so the weak key gives the memo the analysis's lifetime.
---@type table<function, lye.analyzer.MemoSlot>
local slots = setmetatable({}, { __mode = "k" })

---@param resolve function
---@return lye.analyzer.MemoSlot
local function slotOf(resolve)
	local slot = slots[resolve]
	if not slot then
		slot = { texts = {} }
		slots[resolve] = slot
	end
	return slot
end

--- A parsed type text, as this resolver reads it. The same text is read many times in one analysis
--- — every call site of a signature, every `@param` of a method, the same annotation checked and
--- then built — and each read of a compound text was a tree of fresh tables.
---@param text string?
---@param resolve function?
---@return lye.doc.Type?
function memo.parse(text, resolve)
	if text == nil or resolve == nil then return types.parse(text, resolve) end
	local slot = slotOf(resolve)
	local held = slot.texts[text]
	if held ~= nil then
		local counters = slot.counters
		if counters ~= nil then
			counters.typeHits = (counters.typeHits or 0) + 1
		end
		if held == false then return nil end
		return held
	end
	local counters = slot.counters
	if counters ~= nil then
		counters.typeMisses = (counters.typeMisses or 0) + 1
	end
	local parsed = types.parse(text, resolve)
	slot.texts[text] = parsed or false
	return parsed
end

--- Attach the counters a resolver's memo reports to. The resolver is the memo's key, so call this
--- with the function the parse sites use.
---@param resolve function
---@param counters table<string, number>?
function memo.bind(resolve, counters)
	slotOf(resolve).counters = counters
end

-- The classes and aliases of one annotation digest, read once. A namespace's `classes` and
-- `aliases` are immutable after this: the definitions are reached through a metatable, a plugin
-- contributes into a copy, and `evolve` writes to `evolved`/`built`, which are per-analysis.
---@type table<table?, table<string, lye.doc.Namespace>>
local namespaces = setmetatable({}, { __mode = "k" })
local namespaceCount = 0
local MAX_NAMESPACES = 128

---@param prepared lye.analyzer.Prelude?
---@param digest string
---@param annotations lye.doc.File
---@return lye.doc.Namespace
---@return boolean reused whether the read was kept from an earlier analysis
function memo.namespace(annotations, digest, prepared)
	local owner = prepared or NONE
	local bucket = namespaces[owner]
	if not bucket then
		bucket = {}
		namespaces[owner] = bucket
	end
	local base = bucket[digest]
	local reused = base ~= nil
	if not base then
		if namespaceCount >= MAX_NAMESPACES then
			for held in pairs(namespaces) do namespaces[held] = nil end
			namespaceCount = 0
			bucket = {}
			namespaces[owner] = bucket
		end
		base = doc.classes.read(annotations)
		if prepared then
			setmetatable(base.classes, { __index = prepared.classes })
			setmetatable(base.aliases, { __index = prepared.aliases })
		end
		bucket[digest] = base
		namespaceCount += 1
	end
	-- The mutable half is always this analysis's own: a method evolved by one analysis must not be
	-- there for the next, and a class type built for one must not be handed to another.
	local evolved = {}
	for className, fields in pairs(prepared and prepared.evolved or {}) do
		local copy = {}
		for field, method in pairs(fields) do copy[field] = method end
		evolved[className] = copy
	end
	return {
		classes = base.classes, aliases = base.aliases, evolved = evolved, built = {},
	}, reused
end

--- Give a namespace a classes/aliases pair this analysis may write to. A plugin contributes
--- through assignment, so the shared read-only tables are copied before the first contribution.
---@param namespace lye.doc.Namespace
function memo.writable(namespace)
	local classes, aliases = {}, {}
	local classesMeta, aliasesMeta = getmetatable(namespace.classes), getmetatable(namespace.aliases)
	for name, value in pairs(namespace.classes) do classes[name] = value end
	for name, value in pairs(namespace.aliases) do aliases[name] = value end
	if classesMeta then setmetatable(classes, classesMeta) end
	if aliasesMeta then setmetatable(aliases, aliasesMeta) end
	namespace.classes, namespace.aliases = classes, aliases
	return namespace
end

return memo
