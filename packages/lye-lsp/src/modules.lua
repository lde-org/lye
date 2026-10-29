--[[
	What a `require("name")` gives back: the type a module file returns, analysed once and kept
	until the text it was read from changes. Extracted from `language.lua`, so the record and the
	key can change without the server that asks.
]]

local framework = require("lye-framework")
local analyzer = require("lye-analyzer")
local cache = require("lye-lsp.cache")
local plugin = require("lye-plugin")
local rapidhash = require("rapidhash")
local serial = require("lye-doc.serial")
local docType = require("lye-doc.type")
local timing = require("lye-lsp.timing")

--- The definitions' own types, by a name a session can say them with. A module's answer holds
--- them — `ffi.cdecl` is a function the definitions declared — and a session that reads that answer
--- back has to reach the very tables the definitions built, because a signature is looked up by the
--- type it was built for. Built once, from the maps the definitions are already keyed by.
---@type { names: table<unknown, string>, tables: table<string, unknown> }?
local preludeTypes

--- The shape the analyzer's prepared prelude adds to `lye.analyzer.Prelude`.
---@class lye.ModulesPrelude
---@field evolved table<string, table<string, unknown>>?
---@field built table<string, unknown>?
---@field aliases table<string, unknown>
---@field returns table<string, unknown>

---@param prelude table
local function namedPreludeTypes(prelude)
	if preludeTypes then return preludeTypes end
	---@cast prelude lye.ModulesPrelude
	local names = {} ---@type table<unknown, string>
	local tables = {} ---@type table<string, unknown>
	if not prelude then return { names = names, tables = tables } end
	---@param held unknown
	---@param name string
	local function add(held, name)
		if type(held) ~= "table" or names[held] then return end
		names[held] = name
		tables[name] = held
	end
	-- A field's type is what the completion looks a signature up by, so it needs its name most:
	-- `evolved` is where the definitions' methods were put as they were declared.
	for className, fields in pairs(prelude.evolved or {}) do
		---@cast className string
		---@cast fields table<string, unknown>
		for field, held in pairs(fields) do
			---@cast field string
			add(held, "field:" .. className .. "." .. field)
		end
	end
	for name, alias in pairs(prelude.aliases) do
		---@cast name string
		add(alias, "alias:" .. name)
	end
	for name, held in pairs(prelude.returns) do
		---@cast name string
		add(held, "return:" .. name)
	end
	for text, held in pairs(prelude.built or {}) do
		---@cast text string
		add(held, "built:" .. text)
	end
	preludeTypes = { names = names, tables = tables }
	return preludeTypes
end

--- An estimate of what a held type costs, for the counters. A type graph is a table of tables and
--- strings; a recursive class is a cycle, so each table is counted once. The walk is bounded so a
--- pathological graph cannot make a keystroke pay for the bookkeeping.
---@param value unknown
local function estimateBytes(value)
	local seen, left = {}, 2048
	---@param held unknown
	local function walk(held)
		if left <= 0 then return 0 end
		left -= 1
		local kind = type(held)
		if kind == "string" then return #held end
		if kind ~= "table" then return 8 end
		if seen[held] then return 0 end
		seen[held] = true
		local bytes = 40
		for key, entry in pairs(held) do
			bytes += 8 + (type(key) == "string" and #key or 0) + walk(entry)
		end
		return bytes
	end
	return walk(value)
end

--- The tables `serial` writes by name, which a canonical copy must keep as themselves: a type
--- compared by identity has to come back as the very table it was, and a copied singleton would
--- serialize as a plain table and hash differently on load.
local SINGLETONS = {}
for _, name in ipairs({
	"NUMBER", "STRING", "BOOLEAN", "NIL_TYPE", "TABLE", "VOID", "NEVER", "UNKNOWN_TYPE",
	"ANY_TYPE", "FUNCTION",
}) do
	local held = docType[name]
	if held then SINGLETONS[held] = true end
end

--- A copy of a type graph whose fields are inserted in a fixed order, so `serial.write` writes the
--- same bytes for the same structure however the table's hash slots happen to be laid out. Shared
--- tables and cycles stay shared; named tables are kept, because the writer refers to them.
---@param value any
---@param known { names: table<unknown, string>, tables: table<string, unknown> }
---@param seen table<table, table>?
local function canonical(value, known, seen)
	if type(value) ~= "table" then return value end
	if known.names[value] or SINGLETONS[value] then return value end
	seen = seen or {}
	local made = seen[value]
	if made then return made end
	made = {}
	seen[value] = made
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys, function(left, right)
		if type(left) == type(right) then
			if type(left) == "number" then return left < right end
			return tostring(left) < tostring(right)
		end
		return type(left) == "number"
	end)
	for _, key in ipairs(keys) do made[key] = canonical(value[key], known, seen) end
	return made
end

--- The identity of a module's exported type: the bytes `serial.write` keeps it as, hashed. A
--- module that returns nothing says `false` — a real answer, not a missing one — so it is hashed
--- as that word rather than as an empty graph.
---
--- The graph is put in a canonical order first. `serial.write` follows `pairs`, whose order a
--- hash table does not promise and a round trip changes, so hashing the raw bytes would call every
--- loaded entry a mismatch. Sorting the fields before writing them makes the same structure hash
--- the same on both sides while keeping shared tables and cyclic classes as the tables they are.
---@param held lye.doc.Type?
---@param known { names: table<unknown, string>, tables: table<string, unknown> }
local function typeHash(held, known)
	if held == false or held == nil then return rapidhash.hex("false") end
	local text = serial.write(canonical(held, known), known)
	if not text then return nil end
	return rapidhash.hex(text)
end

--- What one resolved module is kept as: its own text and exported type, what they hash to, and the
--- requires and declaration names the key depended on, so an unrelated change can leave it alone.
--- What a caller hands `keep` when part of the record is already known.
---@class lye.ModuleRecordSeed
---@field textHash string?
---@field typeHash string?
---@field requires table<string, { path: string?, textHash: string?, typeHash: string? }>?
---@field declarationNames table<string, boolean>?
---@field key string?

---@class lye.ModuleRecord
---@field text string the source the type was read from
---@field textHash string
---@field type lye.doc.Type? what the module returns; nil for the `false` answer
---@field typeHash string? identity of the exported type, or of the `false` answer
---@field requires table<string, { path: string?, textHash: string?, typeHash: string? }>? the names it required and what they were
---@field declarationNames table<string, boolean>? names it resolved from another document's declarations
---@field key string? the persisted key, when one was written for it
---@field bytes integer
---@field used integer how recently the entry was read or written; higher is more recent

--- How much held answers may cost before the least recently used one goes. The entries are
--- persisted, so what an eviction costs is one analysis on the next lookup, never correctness.
local MAX_MODULE_BYTES = 16 * 1024 * 1024

--- The module cache: one entry per resolved module path, keyed by the path and validated by the
--- text it was read from.
---@class lye.Modules
---@field lye lye.Server
---@field entries table<string, lye.ModuleRecord> what each resolved module gives
---@field requiring table<string, boolean> the files being required now, so a cycle ends
---@field hits integer
---@field misses integer
---@field bytes integer
---@field maxBytes integer the budget `bytes` is kept under
---@field evictions integer
---@field clock integer the last use stamp; a higher one is more recently used
---@field lastPath string? the module the outermost lookup answered, which is never evicted
---@field openDigest string? the digest of the open documents, until one changes
---@field blocked table<string, boolean> modules whose kept answer was invalidated here, so the
--- persisted entry they still have is not read back until they are analysed again
local Modules = {}
Modules.__index = Modules
Modules.MAX_MODULE_BYTES = MAX_MODULE_BYTES

---@param lye lye.Server
---@param options { maxBytes: integer? }? a budget other than the default, for a test or a host
function Modules.new(lye, options)
	return setmetatable({
		lye = lye, entries = {}, requiring = {}, blocked = {}, hits = 0, misses = 0, bytes = 0,
		maxBytes = (options and options.maxBytes) or MAX_MODULE_BYTES,
		evictions = 0, clock = 0,
	}, Modules)
end

--- Say this entry was just used. One stamp per lookup is all the order needs.
---@param self lye.Modules
---@param entry lye.ModuleRecord
local function touched(self, entry)
	self.clock += 1
	entry.used = self.clock
	return entry
end

--- Drop the least recently used entries until the budget holds again. An entry whose resolve is
--- still in progress is skipped, so a cycle is never cut in half; `keepPath` is the entry the
--- caller is answering with, and it is never the victim. Evicting something a held module
--- required is allowed: `requiresCurrent` treats a missing require entry as a miss, so that
--- module is analysed again instead of handing out a type built from something gone.
---@param self lye.Modules
---@param keepPath string? the module the current lookup answered
function Modules:trim(keepPath)
	if self.bytes <= self.maxBytes then return end
	while self.bytes > self.maxBytes do
		local victim, victimUsed
		for path, entry in pairs(self.entries) do
			if path ~= keepPath and not self.requiring[path]
				and (not victim or (entry.used or 0) < victimUsed) then
				victim = path
				victimUsed = entry.used or 0
			end
		end
		if not victim then break end
		local entry = self.entries[victim]
		self.bytes -= entry.bytes
		self.entries[victim] = nil
		self.evictions += 1
	end
end

--- Keep what a module gave, with the dependencies it was keyed against. `known` names the
--- definitions' own tables, so the exported type writes to the same bytes every session.
---@param self lye.Modules
---@param path string
---@param text string
---@param held lye.doc.Type?
---@param known { names: table<unknown, string>, tables: table<string, unknown> }
---@param record lye.ModuleRecordSeed?
function Modules:keep(path, text, held, known, record)
	local previous = self.entries[path]
	if previous then self.bytes -= previous.bytes end
	local bytes = #text + estimateBytes(held)
	local entry = {
		text = text,
		textHash = record and record.textHash or rapidhash.hex(text),
		type = held,
		typeHash = record and record.typeHash or typeHash(held, known),
		requires = record and record.requires,
		declarationNames = record and record.declarationNames,
		key = record and record.key,
		bytes = bytes,
		used = 0,
	}
	self.entries[path] = entry
	self.bytes += bytes
	self.blocked[path] = nil
	touched(self, entry)
	self:trim(path)
	return entry
end

--- Whether the requires this module was kept against still say what they did. A require whose type
--- hash is unchanged answers the same even when its body moved; one whose exported type changed
--- makes this module's answer stale.
---@param self lye.Modules
---@param entry lye.ModuleRecord
---@return boolean
function Modules:requiresCurrent(entry)
	for _, required in pairs(entry.requires or {}) do
		if required.path then
			local held = self.entries[required.path]
			-- A require whose entry is gone cannot be shown to still say the same thing. The plan
			-- makes a missing require entry a miss: re-analyzing this module is cheaper than
			-- handing out a type built from something this session no longer holds.
			if not held then return false end
			if required.typeHash then
				if held.typeHash ~= required.typeHash then return false end
			elseif required.textHash and held.textHash ~= required.textHash then
				return false
			end
		end
	end
	return true
end

--- The record of what the analyser said a module's `require`s resolved to. It is read from the
--- entries already kept — an analysis of the file being kept has just asked for them — so a key
--- never pays for a second analysis.
---@param self lye.Modules
---@param from string
---@param names table<string, boolean>?
function Modules:requiresOf(from, names)
	if not names then return nil end
	local requires = {}
	for name in pairs(names) do
		---@cast name string
		local path = self.lye.declarations:moduleFile(name, from)
		---@cast path string?
		local held = path and self.entries[path]
		local textHash = held and held.textHash
		if path and not textHash then
			-- A cycle or a failed resolution kept no entry; the text hash is still cheap to read and
			-- is what says whether the next session read the same file.
			local handle = io.open(path, "rb")
			if handle then
				textHash = rapidhash.hex(handle:read("*a"))
				handle:close()
			end
		end
		requires[name] = {
			path = path,
			textHash = textHash,
			typeHash = held and held.typeHash,
		}
	end
	return requires
end

--- What `require("name")` is: the type the module file returns, analysed once and kept until its
--- text changes. A module that requires the file being analysed comes back around, so a name
--- already in progress answers nothing rather than recursing.
---@param name string
---@param from string? the document the require is written in, which is what says which package it
--- resolves within
---@param self lye.Modules
function Modules:type(name, from)
	local started = timing.detailed() and timing.now() or nil
	local outermost = next(self.requiring) == nil
	if outermost then self.lastPath = nil end
	local held = self:resolve(name, from)
	if outermost then
		-- A resolve may have kept several modules; now that none is in progress the budget can be
		-- enforced without cutting a cycle. The answer just handed back is never the victim.
		self:trim(self.lastPath)
	end
	if started and outermost then
		-- A nested require is part of the outer lookup's time; only the lookup the caller asked
		-- for writes the mark, so one keystroke does not print a chain of them.
		timing.detail("module", started, "hits=%d misses=%d bytes=%d",
			self.hits, self.misses, self.bytes)
	end
	return held
end

--- Resolve one module. The broad key is the module's own text plus everything an answer used to be
--- read against; the record adds what it required and which declarations it resolved, which is
--- what lets a later change leave it alone.
---@param name string
---@param from string?
---@param self lye.Modules
function Modules:resolve(name, from)
	local lye = self.lye
	local path = lye.declarations:moduleFile(name, from)
	---@cast path string?
	if not path then return nil end
	if self.requiring[path] then return nil end

	local uri = "file://" .. path
	local document = lye.server.documents:get(uri)
	local written
	if document then
		written = document.text
	else
		local handle = io.open(path, "rb")
		if not handle then return nil end
		written = handle:read("*a")
		handle:close()
	end

	local textKey = rapidhash.hex(written)
	local known = namedPreludeTypes(lye.prelude)
	local cached = self.entries[path]
	if cached and cached.textHash == textKey then
		-- The module's own text is what it was; whether that answer is still the answer depends
		-- on the requires it was built from. A body edit in one of them that kept its exported
		-- type leaves this entry valid, which is the early cutoff the record buys.
		if self:requiresCurrent(cached) then
			self.hits += 1
			self.lastPath = path
			return touched(self, cached).type
		end
		self.bytes -= cached.bytes
		self.entries[path] = nil
		-- The entry persisted under this text is stale in the same way; do not read it back and
		-- hand out the answer this session just decided was no longer the answer.
		self.blocked[path] = true
	end

	-- A document that is open has been analysed in full, and that analysis already says what
	-- `require` of it gives back: reading it again as a module is the same work for the same
	-- answer, and a monorepo with several files of one package open pays it once per file.
	local open = lye.names[uri]
	if document and open and open.module ~= nil then
		self:keep(path, written, open.module, known, {
			textHash = textKey,
			requires = self:requiresOf(uri, open.requiredModules),
			declarationNames = open.declarationNames,
		})
		self.hits += 1
		self.lastPath = path
		return open.module
	end

	-- What an earlier session worked out for this module. It is read against the workspace's
	-- declarations, this package's links and the documents that were open, so the key says all
	-- three: a session that has the same ones reads the same answer, and one that does not reads
	-- nothing. The first module of a session pays for the scan it needs anyway to say so.
	lye.declarations:workspace()
	local owner = lye:packageRoot(uri)
	if owner then lye.declarations:package(owner) end
	local key = cache.key("module", textKey, lye.annotationsDigest or "",
		(lye.packageDigests or {})[owner] or "", self:documentsDigest(),
		plugin.digest(lye:plugins(uri)))
	local entry
	if not self.blocked[path] then entry = cache.load(key, known) end
	-- An entry is the answer for this text only if it was written by this code version and its
	-- type hash is the hash of what it holds. An entry from before type hashes were written, one
	-- this run's serialisation names differently, or one a lost write damaged is a miss: it is
	-- re-analysed, never trusted.
	if entry and entry.key == cache.codeVersion() and entry.text == textKey
		and type(entry.typeHash) == "string" and (entry.module == false or type(entry.module) == "table") then
		local negative = entry.module == false
		local stored = entry.module --[[@as lye.doc.Type? ]]
		if typeHash(negative and false or stored, known) == entry.typeHash then
			-- `false` is the answer a module that returns nothing came to: it is kept too, so a
			-- run after this one is not made to read the file again to learn nothing.
			local kept = stored
			if negative then kept = nil end
			self:keep(path, written, kept, known, {
				textHash = textKey,
				typeHash = entry.typeHash,
				key = key,
			})
			self.hits += 1
			self.lastPath = path
			return kept
		end
	end

	self.requiring[path] = true
	-- The module's own `require`s resolve within *its* package: a dependency's file is a document
	-- of that package, and what it can reach is what lde linked into that package's `target/`.
	-- A module reached through `require` is read for its type: its diagnostics belong to its own
	-- document, which is analysed on its own account when it is open.
	---@param inner string
	local function moduleAt(inner) return self:type(inner, uri) end
	---@param message string
	local function reportPlugin(message) lye.server:log(message, framework.LOG.warning) end
	local names = analyzer.analyze(written, lye.prelude, lye.declarations:view(uri), moduleAt,
		nil, nil, true, lye:isDefinition(uri), lye:plugins(uri), reportPlugin, { uri = uri })
	self.requiring[path] = nil
	local kept = names.module
	local hash = typeHash(kept, known)
	local requires = self:requiresOf(uri, names.requiredModules)
	self:keep(path, written, kept, known, {
		textHash = textKey,
		typeHash = hash,
		requires = requires,
		declarationNames = names.declarationNames,
		key = key,
	})
	self.misses += 1
	self.lastPath = path
	-- Kept for the sessions after this one. The graph is written as it stands: a placeholder in
	-- it is a placeholder in the answer, which is what a session that analysed the file would have
	-- had. A module that returns nothing is kept too, as `false`, and its hash is the hash of
	-- that word. A graph that cannot be written is kept in memory only.
	if hash then
		cache.save(key, {
			text = textKey,
			key = cache.codeVersion(),
			module = kept or false,
			typeHash = hash,
		}, known)
	end
	return kept
end

--- A document's text moved on. A module read against its declarations, or requiring its file, no
--- longer has the answer this session kept for it. The changed document's declarations are what
--- it used to say, so a module whose record names none of them and which requires no such path
--- survives. An entry whose dependency set is not known falls back to the broad rule and goes.
--- The persisted entries are keyed by the documents that were open, so a later session reading
--- under a different digest does not find them anyway.
---@param uri string
---@param declarations table<string, boolean|lye.doc.Type>? what the document declared before it changed
---@param self lye.Modules
function Modules:documentChanged(uri, declarations)
	self.openDigest = nil
	local changed = uri and uri:gsub("^file://", "") or nil
	for path, entry in pairs(self.entries) do
		local drop
		for _, required in pairs(entry.requires or {}) do
			if changed and required.path == changed then
				drop = true
				break
			end
		end
		if not drop then
			if entry.declarationNames then
				if not declarations then
					drop = true
				else
					for name in pairs(entry.declarationNames) do
						if declarations[name] ~= nil then
							drop = true
							break
						end
					end
				end
			else
				drop = true
			end
		end
		if drop then
			self.bytes -= entry.bytes
			self.entries[path] = nil
			self.blocked[path] = true
		end
	end
end

--- A digest of the documents an editor has open. A module is analysed against what they declare —
--- a class written in an unsaved buffer is as real to it as one on disk — so an answer kept for a
--- session is only the answer for a session with the same ones open. Kept until one of them
--- changes, which is the only thing that can make it say something else.
---@param self lye.Modules
function Modules:documentsDigest()
	if self.openDigest then return self.openDigest end
	local documents = self.lye.server.documents
	local byUri = documents and documents.byUri
	if not byUri then return "" end
	local parts = {} ---@type string[]
	for uri, document in pairs(byUri) do
		---@cast uri string
		---@cast document lye.framework.Document
		parts[#parts + 1] = uri .. "\0" .. rapidhash.hex(document.text or "")
	end
	table.sort(parts)
	self.openDigest = rapidhash.hex(table.concat(parts, "\1"))
	return self.openDigest
end

---@return table
---@param self lye.Modules
function Modules:stats()
	local entries = 0
	for _ in pairs(self.entries) do entries += 1 end
	return {
		entries = entries,
		hits = self.hits,
		misses = self.misses,
		bytes = self.bytes,
		maxBytes = self.maxBytes,
		evictions = self.evictions,
	}
end

--- Drop every held answer. They are persisted, so a miss is one analysis, not correctness.
---@param self lye.Modules
function Modules:clear()
	self.entries = {}
	self.requiring = {}
	self.blocked = {}
	self.openDigest = nil
	self.bytes = 0
	self.evictions = 0
	self.clock = 0
	self.lastPath = nil
end

return Modules
