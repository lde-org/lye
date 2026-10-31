--[[
	Tests for the module cache.

	Each drives `Modules` directly over a root written under `target/`, with a fake server that
	only answers what a module lookup asks: the file a name resolves to, the open documents (none),
	and the declarations other files would provide. The record, the persisted type hash and the
	invalidation rule are the contract; the analysis itself is the real analyzer.
]]

local test = require("lde-test")
local analyzer = require("lye-analyzer")
local cache = require("lye-lsp.cache")
local plugin = require("lye-plugin")
local rapidhash = require("rapidhash")
local Modules = require("lye-lsp.modules")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local ROOT = PACKAGE_DIR .. "/target/modules-fixture"
local CACHE = PACKAGE_DIR .. "/target/modules-cache"

---@param path string
---@param content string
local function write(path, content)
	local dir = path:match("^(.*)/[^/]+$")
	os.execute("mkdir -p " .. string.format("%q", dir))
	local handle = assert(io.open(path, "wb"))
	handle:write(content)
	handle:close()
end

--- A fresh root and cache. The cache module remembers the first root it made, so a test that wants
--- entries from no earlier test says where they go again.
---@param files table<string, string> module name -> source
---@return table lye the fake server side a lookup reads
local function prepare(files)
	os.execute("rm -rf " .. string.format("%q", ROOT) .. " " .. string.format("%q", CACHE)
		.. " && mkdir -p " .. string.format("%q", ROOT) .. " " .. string.format("%q", CACHE))
	cache.setRoot(CACHE)
	cache.setEnabled(true)
	local paths = {}
	for name, content in pairs(files) do
		---@cast name string
		paths[name] = ROOT .. "/" .. name .. ".lua"
		write(paths[name], content)
	end

	local PLUGINS = {}
	local declarations = {}
	function declarations:moduleFile(name, _from)
		return paths[name]
	end
	function declarations:workspace() return {} end
	function declarations:package() return {} end
	local view = {}
	function declarations:view() return view end
	function declarations:documentChanged() end

	local server = {
		rootPath = ROOT,
		documents = { byUri = {}, get = function() return nil end },
		log = function() end,
	}
	local lye = {
		server = server,
		declarations = declarations,
		names = {},
		prelude = nil,
		annotationsDigest = "",
		packageDigests = {},
		view = view,
		paths = paths,
	}
	function lye:packageRoot() return nil end
	function lye:plugins() return PLUGINS end
	function lye:isDefinition() return false end
	return lye
end

--- Run `fn` with every `analyzer.analyze` counted, restoring the real one even when the body
--- fails: a module that is a hit has to prove it did no analysis.
---@param fn fun(count: fun(): integer)
local function counted(fn)
	local real = analyzer.analyze
	local analyses = 0
	analyzer.analyze = function(...)
		analyses += 1
		return real(...)
	end
	local ok, err = pcall(fn, function() return analyses end)
	analyzer.analyze = real
	if not ok then error(err, 0) end
end

--- The key the cache writes a module under, mirrored from `Modules:resolve`.
---@param lye table
---@param path string
---@param text string
local function keyOf(lye, path, text)
	local uri = "file://" .. path
	local owner = lye:packageRoot(uri)
	return cache.key("module", rapidhash.hex(text), lye.annotationsDigest or "",
		(lye.packageDigests or {})[owner] or "", plugin.digest(lye:plugins(uri)))
end

local PONY = table.concat({
	"---@class Pony\n",
	"---@field speed number\n",
	"local Pony = {}\n",
	"Pony.speed = 1\n",
	"local hidden = 1\n",
	"return Pony\n",
}, "")

local DEPENDENT = "local pony = require(\"pony\")\nreturn pony\n"

-- The same module under names of one length, so each entry's estimate is the same and a budget
-- of two fits exactly two of them however the type graph is counted.
local PONYA = (PONY:gsub("Pony", "PonyA"))
local PONYB = (PONY:gsub("Pony", "PonyB"))
local PONYC = (PONY:gsub("Pony", "PonyC"))

test.it("a module is analysed once, and a second lookup is a hit", function()
	local lye = prepare({ pony = PONY })
	local modules = Modules.new(lye)
	local first
	counted(function(analyses)
		first = modules:type("pony")
		test.truthy(first, "the module has a type")
		local second = modules:type("pony")
		test.equal(second, first, "the kept answer is the same table")
		test.equal(analyses(), 1, "one analysis for two lookups")
	end)

	local stats = modules:stats()
	test.equal(stats.entries, 1)
	test.equal(stats.hits, 1)
	test.equal(stats.misses, 1)
	test.truthy(stats.bytes > 0, "the estimate counts something")

	local record = modules.entries[lye.paths.pony]
	test.equal(record.text, PONY)
	test.equal(record.textHash, rapidhash.hex(PONY))
	test.equal(record.type, first)
	test.truthy(record.typeHash, "the exported type has an identity")
	test.equal(record.key, keyOf(lye, lye.paths.pony, PONY))
	test.truthy(record.declarationNames, "the dependency set is recorded")
	test.truthy(record.requires, "the requires are recorded")
end)

test.it("a persisted entry loads without analysis", function()
	local lye = prepare({ pony = PONY })
	Modules.new(lye):type("pony")

	local warm = Modules.new(lye)
	counted(function(analyses)
		local held = warm:type("pony")
		test.truthy(held, "the type comes back")
		test.equal(analyses(), 0, "nothing was analysed")
	end)
	test.equal(warm:stats().hits, 1)
	test.equal(warm:stats().misses, 0)
	test.truthy(warm.entries[lye.paths.pony].typeHash, "the type hash travelled with it")
end)

test.it("a body-only change keeps the exported type hash and the dependent", function()
	local lye = prepare({ pony = PONY, dependent = DEPENDENT })
	local modules = Modules.new(lye)
	modules:type("pony")
	modules:type("dependent")
	local before = modules.entries[lye.paths.pony].typeHash
	test.truthy(modules.entries[lye.paths.dependent].requires.pony, "the require is recorded")

	write(lye.paths.pony, (PONY:gsub("local hidden = 1", "local hidden = 2")))
	local hits = modules:stats().hits
	modules:type("pony")
	test.equal(modules.entries[lye.paths.pony].typeHash, before,
		"the exported type is unchanged, so its identity is")
	modules:type("dependent")
	test.equal(modules:stats().hits, hits + 1, "the dependent is a hit, not a re-analysis")
	test.equal(modules.entries[lye.paths.dependent].requires.pony.typeHash, before,
		"the dependent still names the require's type hash")
end)

test.it("an exported type change changes the hash and drops the dependent", function()
	local lye = prepare({ pony = PONY, dependent = DEPENDENT })
	local modules = Modules.new(lye)
	modules:type("pony")
	modules:type("dependent")
	local before = modules.entries[lye.paths.pony].typeHash
	local misses = modules:stats().misses

	local changed = (PONY:gsub("%-%-%-@field speed number\n", "---@field speed number\n---@field name string\n"))
	changed = changed:gsub("Pony.speed = 1\n", "Pony.speed = 1\nPony.name = \"x\"\n")
	write(lye.paths.pony, changed)

	local held = modules:type("pony")
	test.truthy(held, "the new type is answered")
	test.truthy(modules.entries[lye.paths.pony].typeHash ~= before, "the identity moved")
	modules:type("dependent")
	test.equal(modules:stats().misses, misses + 2, "the dependent was analysed against the new type")
	test.equal(modules.entries[lye.paths.dependent].requires.pony.typeHash,
		modules.entries[lye.paths.pony].typeHash, "and records the new identity")
end)

test.it("a version mismatch or a damaged entry is a miss", function()
	local lye = prepare({ pony = PONY })
	local modules = Modules.new(lye)
	local key = keyOf(lye, lye.paths.pony, PONY)
	local textKey = rapidhash.hex(PONY)
	local known = { names = {}, tables = {} }

	test.truthy(cache.save(key, { text = textKey, key = "an older run", module = false,
		typeHash = rapidhash.hex("false") }))
	local versioned = Modules.new(lye)
	versioned:type("pony")
	test.equal(versioned:stats().hits, 0, "an older version is not read")
	test.equal(versioned:stats().misses, 1, "and the module is analysed")

	test.truthy(cache.save(key, { text = textKey, key = cache.codeVersion(), module = { stale = true },
		typeHash = "not the hash of that" }))
	local damaged = Modules.new(lye)
	damaged:type("pony")
	test.equal(damaged:stats().hits, 0, "a hash that does not match is a miss")
	test.equal(damaged:stats().misses, 1)

	test.truthy(cache.save(key, { text = textKey, key = cache.codeVersion(), module = false }, known))
	local old = Modules.new(lye)
	old:type("pony")
	test.equal(old:stats().hits, 0, "an entry from before type hashes is a miss")
	test.equal(old:stats().misses, 1)
end)

test.it("a recursive class keeps its identity through the persisted entry", function()
	local lye = prepare({ node = table.concat({
		"---@class Node\n",
		"---@field next Node\n",
		"local Node = {}\n",
		"return Node\n",
	}, "") })
	local modules = Modules.new(lye)
	local first = modules:type("node")
	test.truthy(first, "the class is answered")
	test.equal(modules:stats().misses, 1)

	local warm = Modules.new(lye)
	counted(function(analyses)
		local held = warm:type("node")
		test.truthy(held, "the recursive type loads")
		test.equal(analyses(), 0, "the type hash of a cycle is the same on both sides")
	end)
	test.equal(warm:stats().hits, 1)
end)

test.it("a module that returns nothing stays false, and is a hit", function()
	local lye = prepare({ nothing = "return\n" })
	local modules = Modules.new(lye)
	test.equal(modules:type("nothing"), nil, "the answer is nothing")
	test.equal(modules:stats().misses, 1)
	local record = modules.entries[lye.paths.nothing]
	test.equal(record.typeHash, rapidhash.hex("false"), "false is an identity, not a missing value")

	counted(function(analyses)
		test.equal(modules:type("nothing"), nil)
		test.equal(analyses(), 0, "the second lookup does no work")
	end)

	local warm = Modules.new(lye)
	counted(function(analyses)
		test.equal(warm:type("nothing"), nil)
		test.equal(analyses(), 0, "the persisted false loads")
	end)
	test.equal(warm:stats().hits, 1)
	test.equal(warm:stats().misses, 0)

	local entry = cache.load(keyOf(lye, lye.paths.nothing, "return\n"),
		{ names = {}, tables = {} })
	test.truthy(entry, "the entry is written")
	test.equal(entry.module, false, "and keeps the negative answer as false")
	test.equal(entry.typeHash, rapidhash.hex("false"))
end)

test.it("a document change keeps a module that depends on neither it nor its declarations", function()
	local lye = prepare({ pony = PONY })
	local modules = Modules.new(lye)
	modules:type("pony")
	modules:documentChanged("file://" .. ROOT .. "/unrelated.lua", { Unrelated = true })
	test.truthy(modules.entries[lye.paths.pony], "an unrelated declaration leaves it alone")
	modules:type("pony")
	test.equal(modules:stats().hits, 1, "the next lookup is a hit")
end)

test.it("a document change drops the module that requires the changed path", function()
	local lye = prepare({ pony = PONY, dependent = DEPENDENT })
	local modules = Modules.new(lye)
	modules:type("dependent")
	test.truthy(modules.entries[lye.paths.dependent])
	modules:documentChanged("file://" .. lye.paths.pony, { Pony = true })
	test.falsy(modules.entries[lye.paths.dependent], "the dependent is gone")
	local misses = modules:stats().misses
	modules:type("dependent")
	test.equal(modules:stats().misses, misses + 1, "and is analysed again")
end)

test.it("a document change drops the module that resolved one of its declarations", function()
	local lye = prepare({ pony = PONY })
	local modules = Modules.new(lye)
	local ponyType = modules:type("pony")
	local consumer = ROOT .. "/consumer.lua"
	write(consumer, table.concat({
		"local shared = Shared\n",
		"---@class Consumer\n",
		"---@field value Shared\n",
		"local Consumer = { shared = shared }\n",
		"return Consumer\n",
	}, ""))
	lye.paths.consumer = consumer
	-- The fake only knew the names `prepare` was given; the consumer was written after it.
	local declarations = lye.declarations
	local previous = declarations.moduleFile
	function declarations:moduleFile(name, from)
		if name == "consumer" then return consumer end
		return previous(self, name, from)
	end
	-- The class the consumer's annotation names comes from another file's declarations, which is
	-- the dependency the record has to carry.
	lye.view.Shared = ponyType

	local held = modules:type("consumer")
	test.truthy(held, "the consumer is analysed")
	test.truthy(modules.entries[consumer].declarationNames.Shared,
		"the name it resolved elsewhere is recorded")
	modules:documentChanged("file://" .. ROOT .. "/shared.lua", { Shared = true })
	test.falsy(modules.entries[consumer], "the consumer is gone")
end)

test.it("the byte budget evicts the least recently used module and keeps the current one", function()
	local lye = prepare({ a = PONYA, b = PONYB, c = PONYC })
	local modules = Modules.new(lye)
	modules:type("a")
	modules:type("b")
	modules:type("c")
	local aPath, bPath, cPath = lye.paths.a, lye.paths.b, lye.paths.c
	local unit = modules.entries[aPath].bytes
	test.equal(modules.entries[bPath].bytes, unit, "the fixtures cost the same")

	-- a is read again, so b is now the oldest; c is the module being asked for.
	modules:type("a")
	modules.maxBytes = unit * 2
	test.truthy(modules.bytes > modules.maxBytes, "three modules are over the budget")
	modules:type("c")

	test.truthy(modules.bytes <= modules.maxBytes, "the cache fits the budget again")
	test.truthy(modules.entries[cPath], "the current module stays")
	test.truthy(modules.entries[aPath], "the recently read module stays")
	test.equal(modules.entries[bPath], nil, "the least recently used module is evicted")
	test.equal(modules.evictions, 1, "one eviction")
	test.falsy(modules.blocked[bPath], "an eviction is not an invalidation to block")
	test.equal(modules:stats().maxBytes, unit * 2, "stats reports the budget")
end)

test.it("an evicted module is analysed again and gives the same type", function()
	local lye = prepare({ a = PONYA, b = PONYB })
	local modules = Modules.new(lye)
	modules:type("a")
	modules:type("b")
	local aPath, bPath = lye.paths.a, lye.paths.b
	local hash = modules.entries[bPath].typeHash
	local misses = modules:stats().misses

	modules:type("a")
	modules.maxBytes = modules.entries[aPath].bytes
	modules:type("a")
	test.equal(modules.entries[bPath], nil, "b is evicted from memory")
	test.truthy(modules.entries[aPath], "a is current")

	-- The persisted entry is what makes the eviction safe; ignoring it proves the in-memory
	-- answer is recomputed rather than remembered.
	cache.setEnabled(false)
	counted(function(analyses)
		local held = modules:type("b")
		test.truthy(held, "the evicted module is answered")
		test.equal(analyses(), 1, "and analysed again")
		test.equal(modules:stats().misses, misses + 1, "counted as a miss")
		test.equal(modules.entries[bPath].typeHash, hash, "with the same exported type identity")
	end)
end)

test.it("a dependent re-analyses when the entry it required was evicted", function()
	local lye = prepare({ pony = PONY, dependent = DEPENDENT })
	local modules = Modules.new(lye)
	modules:type("pony")
	modules:type("dependent")
	local ponyPath, dependentPath = lye.paths.pony, lye.paths.dependent
	local ponyHash = modules.entries[ponyPath].typeHash
	local misses = modules:stats().misses

	-- The dependent is the newest; pony is the oldest and the budget leaves room for one.
	modules:type("dependent")
	modules.maxBytes = modules.entries[dependentPath].bytes
	modules:type("dependent")
	test.equal(modules.entries[ponyPath], nil, "the required module is evicted")
	test.truthy(modules.entries[dependentPath], "the dependent itself is still held")

	counted(function(analyses)
		local held = modules:type("dependent")
		test.truthy(held, "the dependent is answered")
		test.equal(analyses(), 1, "it is analysed rather than answered stale")
		test.equal(modules:stats().misses, misses + 1, "the missing require is a miss")
	end)
	test.equal(modules.entries[dependentPath].requires.pony.typeHash, ponyHash,
		"the require still names the same exported type")
end)
