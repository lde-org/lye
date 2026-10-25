--[[
	Tests for the persisted declaration index.

	Each drives the module's own entry points over a root written under `target/`: a build and a
	load have to answer the same declarations, a load must not read files whose metadata did not
	move, and a corrupt or older entry has to be a miss rather than an error.
]]

local test = require("lde-test")
local fs = require("fs")
local cache = require("lye-lsp.cache")
local Index = require("lye-lsp.index")
local parallel = require("lye-lsp.parallel")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local ROOT = PACKAGE_DIR .. "/target/index-fixture"
local CACHE = PACKAGE_DIR .. "/target/index-cache"

os.execute("rm -rf " .. string.format("%q", CACHE) .. " && mkdir -p " .. string.format("%q", CACHE))
cache.setRoot(CACHE)
cache.setEnabled(true)

---@param path string
---@param content string
local function write(path, content)
	local dir = path:match("^(.*)/[^/]+$")
	os.execute("mkdir -p " .. string.format("%q", dir))
	local handle = assert(io.open(path, "wb"))
	handle:write(content)
	handle:close()
end

--- An empty fixture root, and the directories a fixture writes under.
---@param dirs string[]?
local function reset(dirs)
	os.execute("rm -rf " .. string.format("%q", ROOT) .. " && mkdir -p " .. string.format("%q", ROOT))
	for _, dir in ipairs(dirs or {}) do os.execute("mkdir -p " .. string.format("%q", ROOT .. "/" .. dir)) end
end

---@param files table<string, string> by relative path under the fixture root
local function fixture(files)
	reset()
	for relative, content in pairs(files) do write(ROOT .. "/" .. relative, content) end
end

--- An index that counts what it reads, so a warm start can be shown to touch no source.
---@return lye.lsp.Index
---@return fun(): integer
local function counted()
	local reads = 0
	local index = Index.new({
		read = function(path)
			reads += 1
			return fs.read(path)
		end,
	})
	return index, function() return reads end
end

--- Structural equality that tolerates the cycles a class naming itself gives a type.
---@param left unknown
---@param right unknown
---@param seen table<table, table>?
---@return boolean
local function same(left, right, seen)
	if left == right then return true end
	if type(left) ~= "table" or type(right) ~= "table" then return false end
	seen = seen or {}
	if seen[left] ~= nil then return seen[left] == right end
	seen[left] = right
	for key, held in pairs(left) do
		if not same(held, right[key], seen) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end

---@param left unknown
---@param right unknown
---@param message string
local function sameAs(left, right, message)
	test.truthy(same(left, right), message)
end

--- A root's entry as text, with its files and their records in path order: two builds that answer
--- the same root produce the same text, whatever order their tables were filled in. A forked build
--- returns its records through a file, so this is also what a probe run in another process prints.
---@param entry lye.lsp.IndexEntry
---@return string
local function canonical(entry)
	local parts = { "digest=" .. entry.annotationsDigest }
	if entry.linkDigest then parts[#parts + 1] = "link=" .. entry.linkDigest end
	local paths = {}
	for path in pairs(entry.files) do paths[#paths + 1] = path end
	table.sort(paths)
	for _, path in ipairs(paths) do
		local record = entry.files[path]
		parts[#parts + 1] = table.concat({ "file", path, record.hash, tostring(record.size),
			tostring(record.mtime), tostring(record.isDefinition) }, "\0")
		for _, annotation in ipairs(record.annotations) do
			parts[#parts + 1] = table.concat({ "a", annotation.tag or "", annotation.name or "",
				annotation.text or "", annotation.type or "", annotation.typeText or "",
				tostring(annotation.start), tostring(annotation.stop), tostring(annotation.typeStart),
				tostring(annotation.typeStop), tostring(annotation.nameStart),
				tostring(annotation.nameStop) }, "\0")
		end
		local names = {}
		for name in pairs(record.types) do names[#names + 1] = name end
		table.sort(names)
		for _, name in ipairs(names) do
			local held = record.types[name]
			parts[#parts + 1] = table.concat({ "t", name, held.location.uri,
				tostring(held.location.start), tostring(held.location.stop), held.lines }, "\0")
		end
	end
	return table.concat(parts, "\n")
end

--- Many small files: classes, aliases, typed parameters and a definition file, spread over
--- directories and a package, so a split would have both groups and files to balance.
---@param count integer
---@return table<string, string>
local function manyFiles(count)
	local files = { ["defs/meta.lua"] = "---@meta\n---@class MetaOnly\n" }
	for number = 1, count do
		local dir = number % 3 == 0 and "packages/pkg" or "src"
		files[string.format("%s/f%03d.lua", dir, number)] = table.concat({
			string.format("---@class C%d\n", number),
			"---@field value number\n",
			string.format("---@alias A%d string|number\n", number),
			string.format("---@param x C%d\n", number),
			"---@return number\n",
			"local function f(x)\n\treturn x.value\nend\n",
			string.format("local value = %d\n", number),
			"return f, value\n",
		})
	end
	return files
end

--- The same shape with enough source behind it to pay for a split: each file is about 64 KiB, so
--- the root is above the byte gate and a build is expected to fork.
local PADDING = string.rep("local value = 1\n", 4096)

---@param count integer
---@return table<string, string>
local function largeFiles(count)
	local files = { ["defs/meta.lua"] = "---@meta\n---@class MetaOnly\n" }
	for number = 1, count do
		local dir = number % 3 == 0 and "packages/pkg" or "src"
		files[string.format("%s/big%03d.lua", dir, number)] = table.concat({
			string.format("---@class Big%d\n", number),
			"---@field value number\n",
			string.format("---@alias BigAlias%d string|number\n", number),
			string.format("---@param x Big%d\n", number),
			"---@return number\n",
			"local function f(x)\n\treturn x.value\nend\n",
			PADDING,
			string.format("return f, %d\n", number),
		})
	end
	return files
end

local POINT = table.concat({
	"---@class Point\n",
	"---@field x number\n",
	"---@field y number\n",
	"local Point = {}\n",
	"return Point\n",
}, "")

local ALIAS = "---@alias NumberLike number|string\nreturn nil\n"

--- The file the cache wrote the entry for, so a test can damage it the way a lost write does.
---@param root string
---@param kind "workspace"|"package"?
---@return string
local function entryPath(root, kind)
	local index = Index.new({ kind = kind })
	return CACHE .. "/" .. cache.codeVersion() .. "/" .. index:key(root) .. ".entry"
end

test.it("a built index loads with the declarations it was built from", function()
	fixture({
		["src/point.lua"] = POINT,
		["src/alias.lua"] = ALIAS,
		["src/definition.lua"] = "---@meta\n---@class DefinitionOnly\n",
	})
	local cold = Index.new()
	local built = cold:build(ROOT)
	test.equal(test.count(built.files), 3)
	test.truthy(cold:save(built), "the entry is written")

	local warm = Index.new()
	local loaded = warm:load(ROOT)
	test.truthy(loaded, "the entry loads")
	test.equal(warm:digest(), cold:digest(), "the annotation digest is the one that was built")
	test.equal(warm:linkDigest(), nil, "a workspace entry holds no link digest")
	sameAs(warm:known(), cold:known(), "every declared name resolves to the same type")
	sameAs(warm:typeLocations(), cold:typeLocations(), "every type is written in the same place")
	test.truthy(warm:known().Point, "the class is resolved")
	test.truthy(warm:typeLocations().NumberLike, "the alias keeps its declaration lines")
	test.truthy(warm:isDefinition(ROOT .. "/src/definition.lua"), "the definition file is marked")
	test.falsy(warm:isDefinition(ROOT .. "/src/point.lua"), "a source file is not")
	test.equal(warm:stats().built, 0, "loading built nothing")
	test.equal(warm:stats().loaded, 1)
end)

test.it("a warm load reads no source", function()
	fixture({ ["src/point.lua"] = POINT, ["src/alias.lua"] = ALIAS })
	local cold = Index.new()
	test.truthy(cold:save(cold:build(ROOT)))

	local reads
	local warm
	warm, reads = counted()
	test.truthy(warm:load(ROOT))
	test.equal(reads(), 0, "not one file was read")
	test.equal(warm:stats().reads, 0)
	test.equal(test.count(warm:files()), 2)
end)

test.it("a changed file is read again and the index follows it", function()
	fixture({ ["src/point.lua"] = POINT, ["src/alias.lua"] = ALIAS, ["src/other.lua"] = "return 1\n" })
	local cold = Index.new()
	test.truthy(cold:save(cold:build(ROOT)))
	local before = cold:digest()

	write(ROOT .. "/src/point.lua", POINT .. "---@class Added\n---@field value number\n")

	local reads
	local warm
	warm, reads = counted()
	local loaded = warm:load(ROOT)
	test.truthy(loaded)
	test.equal(reads(), 1, "only the file whose metadata moved was read")
	test.truthy(warm:known().Added, "the new class is there")
	test.truthy(warm:digest() ~= before, "the annotations digest moved")

	local coldAgain = Index.new()
	local rebuilt = coldAgain:build(ROOT)
	test.equal(warm:digest(), rebuilt.annotationsDigest, "the update answers what a cold build does")
	sameAs(warm:known(), rebuilt.known, "and resolves the same names")
	sameAs(warm:typeLocations(), coldAgain:typeLocations(), "and keeps the same type locations")
end)

test.it("a removed file leaves the index", function()
	fixture({ ["src/point.lua"] = POINT, ["src/alias.lua"] = ALIAS })
	local cold = Index.new()
	test.truthy(cold:save(cold:build(ROOT)))
	os.remove(ROOT .. "/src/alias.lua")

	local reads
	local warm
	warm, reads = counted()
	test.truthy(warm:load(ROOT))
	test.equal(reads(), 0, "a file that is gone is not read")
	test.equal(test.count(warm:files()), 1, "it is out of the manifest")
	test.falsy(warm:typeLocations().NumberLike, "and the alias it declared is gone")

	local rebuilt = Index.new():build(ROOT)
	test.equal(warm:digest(), rebuilt.annotationsDigest, "the digest matches a cold build")
	sameAs(warm:known(), rebuilt.known, "and so do the declarations")
end)

test.it("an update follows what a watcher reported, even when metadata did not move", function()
	-- The rewrite below keeps the length, and it lands in the same second, so size and mtime say
	-- nothing: only the event can tell the index to read the file again.
	fixture({ ["src/a.lua"] = "---@class A\nlocal a = 1\nreturn a\n", ["src/b.lua"] = "return 2\n" })
	local cold = Index.new()
	test.truthy(cold:save(cold:build(ROOT)))

	local changed = ROOT .. "/src/a.lua"
	write(changed, "---@class B\nlocal a = 1\nreturn a\n")

	local reads
	local updated
	updated, reads = counted()
	updated:update(ROOT, { changed })
	test.equal(reads(), 1, "the reported file was read")
	test.truthy(updated:known().B, "the new class is there")
	test.falsy(updated:known().A, "the old one is gone")

	local again, later = counted()
	test.truthy(again:load(ROOT))
	test.equal(later(), 0, "and the entry it wrote answers the next run without a read")
	test.truthy(again:known().B)
end)

test.it("a corrupt entry is a miss", function()
	fixture({ ["src/point.lua"] = POINT })
	local cold = Index.new()
	test.truthy(cold:save(cold:build(ROOT)))
	write(entryPath(ROOT), "not an entry this reads")
	test.equal(Index.new():load(ROOT), nil, "a corrupt entry is not trusted")
	test.truthy(Index.new():build(ROOT).known.Point, "and a build still answers")
end)

test.it("a truncated entry is a miss", function()
	fixture({ ["src/point.lua"] = POINT, ["src/alias.lua"] = ALIAS })
	local cold = Index.new()
	test.truthy(cold:save(cold:build(ROOT)))
	local path = entryPath(ROOT)
	local text = assert(fs.read(path))
	test.truthy(#text > 20)
	write(path, text:sub(1, 20))
	test.equal(Index.new():load(ROOT), nil, "half an entry is not trusted")
	test.truthy(Index.new():build(ROOT).known.Point, "and a build still answers")
end)

test.it("an entry of an older schema is a miss", function()
	fixture({ ["src/point.lua"] = POINT })
	local key = Index.new():key(ROOT)
	test.truthy(cache.save(key, {
		schema = 1,
		root = ROOT,
		codeVersion = cache.codeVersion(),
		annotationsDigest = "old",
		files = {},
	}))
	test.equal(Index.new():load(ROOT), nil, "an older schema is not trusted")
end)

test.it("a package index follows its links and not the workspace", function()
	reset({ "src", "target", ".deps" })
	local link = ROOT .. "/target/dep.lua"
	local first = ROOT .. "/.deps/first.lua"
	local second = ROOT .. "/.deps/second.lua"
	write(ROOT .. "/src/main.lua", "return require(\"dep\")\n")
	write(first, "---@class First\nreturn {}\n")
	write(second, "---@class Second\nreturn {}\n")
	test.truthy(fs.mklink(first, link), "the link is made")

	local workspace = Index.new()
	test.truthy(workspace:save(workspace:build(ROOT)))
	local before = workspace:digest()
	test.equal(test.count(workspace:files()), 1, "the workspace walks only its own files")
	test.falsy(workspace:known().First, "a linked file is not the workspace's declaration")

	local pkg = Index.new({ kind = "package" })
	test.truthy(pkg:save(pkg:build(ROOT)))
	test.truthy(pkg:known().First, "the package reads what it links")
	test.falsy(pkg:known().Second)
	test.truthy(pkg:linkDigest(), "the links have a digest")

	write(first, "---@class First\n---@class Extra\nreturn {}\n")

	local workspaceReads
	local warmWorkspace
	warmWorkspace, workspaceReads = counted()
	test.truthy(warmWorkspace:load(ROOT))
	test.equal(workspaceReads(), 0, "a linked change is not a workspace read")
	test.equal(warmWorkspace:digest(), before, "nor a workspace declaration")

	local warmPkg = Index.new({ kind = "package" })
	local loaded = warmPkg:load(ROOT)
	test.truthy(loaded)
	test.truthy(warmPkg:known().Extra, "the package follows the file behind the link")
	test.truthy(warmPkg:linkDigest() ~= pkg:linkDigest(), "and its links digest moved")

	os.remove(link)
	test.truthy(fs.mklink(second, link))
	local repointed = Index.new({ kind = "package" })
	test.truthy(repointed:load(ROOT))
	test.truthy(repointed:known().Second, "a repointed link is read at its new target")
	test.falsy(repointed:known().First, "and the old target is gone")
end)

test.it("a root with more than 2000 files is fully indexed", function()
	reset({ "src" })
	local notes = {}
	local index = Index.new({ log = function(note) notes[#notes + 1] = note end })
	for number = 1, 2001 do
		write(ROOT .. "/src/f" .. number .. ".lua",
			string.format("---@class C%d\nlocal value = %d\nreturn value\n", number, number))
	end
	local entry = index:build(ROOT)
	test.equal(test.count(entry.files), 2001, "every file is in the index")
	test.equal(#notes, 0, "nothing was dropped without a word")
	test.truthy(index:known().C2001, "the last file's class is declared")
end)

test.it("an explicit cap is reported with what it left behind", function()
	fixture({})
	for number = 1, 12 do write(ROOT .. "/f" .. number .. ".lua", "return " .. number .. "\n") end
	local notes = {}
	local index = Index.new({ log = function(note) notes[#notes + 1] = note end })
	local entry = index:build(ROOT, { max = 10 })
	test.equal(test.count(entry.files), 10, "the cap is the index's")
	test.equal(#notes, 1, "and it is said once")
	test.includes(notes[1], "12", "the note names how many files there were")
	test.includes(notes[1], "10", "the note names the cap")
end)

test.it("a body edit is read but leaves the annotations digest alone", function()
	fixture({ ["src/point.lua"] = POINT, ["src/alias.lua"] = ALIAS })
	local cold = Index.new()
	test.truthy(cold:save(cold:build(ROOT)))
	local before = cold:digest()

	write(ROOT .. "/src/alias.lua", ALIAS .. "local extra = 1\nreturn extra\n")

	local reads
	local warm
	warm, reads = counted()
	test.truthy(warm:load(ROOT))
	test.equal(reads(), 1, "the file that moved was read")
	test.equal(warm:digest(), before, "what it declares did not change")
	test.equal(warm:stats().loaded, 1)
end)

test.it("a file touched without a change is rehashed but keeps its entry", function()
	fixture({ ["src/point.lua"] = POINT })
	local cold = Index.new()
	test.truthy(cold:save(cold:build(ROOT)))
	local before = cold:digest()
	os.execute("touch -m -d '2030-01-01T00:00:00' " .. string.format("%q", ROOT .. "/src/point.lua"))

	local reads
	local warm
	warm, reads = counted()
	test.truthy(warm:load(ROOT))
	test.equal(reads(), 1, "a moved modification time means the text is checked")
	test.equal(warm:digest(), before, "the same text keeps the same digest")

	local later
	local again
	again, later = counted()
	test.truthy(again:load(ROOT))
	test.equal(later(), 0, "and the entry it wrote carries the new metadata")
end)

test.it("a root where most files moved is built again", function()
	fixture({ ["src/a.lua"] = "return 1\n", ["src/b.lua"] = "return 2\n", ["src/c.lua"] = "return 3\n" })
	local cold = Index.new()
	test.truthy(cold:save(cold:build(ROOT)))
	for number, name in ipairs({ "a", "b", "c" }) do
		write(ROOT .. "/src/" .. name .. ".lua", string.format("---@class C%d\nreturn %d\n", number, number))
	end

	local reads
	local warm
	warm, reads = counted()
	test.truthy(warm:load(ROOT))
	test.equal(reads(), 3, "the whole root was read again")
	test.equal(warm:stats().built, 1, "a rebuild is a build")
	test.equal(warm:stats().loaded, 0, "not a load")
	test.truthy(warm:known().C3)
	test.equal(warm:digest(), Index.new():build(ROOT).annotationsDigest, "and it answers a cold build")
end)

test.it("an entry whose digest does not describe its files is not trusted", function()
	fixture({ ["src/point.lua"] = POINT })
	local cold = Index.new()
	test.truthy(cold:save(cold:build(ROOT)))
	local key = cold:key(ROOT)
	local entry = assert(cache.load(key))
	entry.annotationsDigest = "a digest of something else"
	test.truthy(cache.save(key, entry))

	local warm = Index.new()
	local loaded = warm:load(ROOT)
	test.truthy(loaded)
	test.equal(warm:stats().built, 1, "the entry was built again")
	test.equal(warm:digest(), cold:digest(), "and answers what a build does")
end)

test.it("an update forgets a file a watcher saw removed", function()
	fixture({ ["src/point.lua"] = POINT, ["src/alias.lua"] = ALIAS })
	local cold = Index.new()
	test.truthy(cold:save(cold:build(ROOT)))
	os.remove(ROOT .. "/src/alias.lua")

	local updated = Index.new()
	updated:update(ROOT, { { path = ROOT .. "/src/alias.lua", removed = true } })
	test.equal(test.count(updated:files()), 1, "the manifest holds the file that is left")
	test.falsy(updated:typeLocations().NumberLike, "and forgets what the other one declared")
	test.falsy(updated:known().NumberLike)
end)

-- A build is only worth splitting across processes if the result is the build one process would
-- have made. These tests compare the two: a root above the fork gate built both ways, a child that
-- loses its shard, the off switch, a root too small to be worth a fork, and a machine without one.

--- A probe run in its own process, because `LYE_INDEX_PARALLEL` is read once from the environment
--- this process started with. It prints the same canonical text the tests build, with the number of
--- processes the build used first.
local PROBE = PACKAGE_DIR .. "/target/index-parallel-probe.lua"

local PROBE_SOURCE = [==[
local cache = require("lye-lsp.cache")
local Index = require("lye-lsp.index")

local root, out, cacheDir = arg[1], arg[2], arg[3]
cache.setRoot(cacheDir)
local index = Index.new()
local entry = index:build(root)

local parts = { "digest=" .. entry.annotationsDigest }
if entry.linkDigest then parts[#parts + 1] = "link=" .. entry.linkDigest end
local paths = {}
for path in pairs(entry.files) do paths[#paths + 1] = path end
table.sort(paths)
for _, path in ipairs(paths) do
	local record = entry.files[path]
	parts[#parts + 1] = table.concat({ "file", path, record.hash, tostring(record.size),
		tostring(record.mtime), tostring(record.isDefinition) }, "\0")
	for _, annotation in ipairs(record.annotations) do
		parts[#parts + 1] = table.concat({ "a", annotation.tag or "", annotation.name or "",
			annotation.text or "", annotation.type or "", annotation.typeText or "",
			tostring(annotation.start), tostring(annotation.stop), tostring(annotation.typeStart),
			tostring(annotation.typeStop), tostring(annotation.nameStart),
			tostring(annotation.nameStop) }, "\0")
	end
	local names = {}
	for name in pairs(record.types) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local held = record.types[name]
		parts[#parts + 1] = table.concat({ "t", name, held.location.uri,
			tostring(held.location.start), tostring(held.location.stop), held.lines }, "\0")
	end
end
local handle = assert(io.open(out, "wb"))
handle:write("workers=", tostring(index:stats().workers), "\n", table.concat(parts, "\n"))
handle:close()
]==]

local function writeProbe()
	write(PROBE, PROBE_SOURCE)
end

---@param env string
---@return string?
local function probe(env)
	local out = PACKAGE_DIR .. "/target/index-parallel-probe.out"
	os.remove(out)
	local code = os.execute(string.format("cd %q && %s lde run %q %q %q %q 2>/dev/null",
		PACKAGE_DIR, env or "", PROBE, ROOT, out, CACHE))
	if code ~= 0 and code ~= true then return nil end
	return fs.read(out)
end

test.it("a root above the fork gate builds what one process builds", function()
	if not parallel.canFork() then return end
	fixture(largeFiles(64))
	local plain = Index.new({ parallel = false })
	local one = plain:build(ROOT)
	test.equal(plain:stats().workers, 1, "the serial build used one process")
	test.equal(plain:stats().fellBack, 0)

	local shared = Index.new()
	local many = shared:build(ROOT)
	local stats = shared:stats()
	test.truthy(stats.workers > 1, "the split build used more than one process: " .. stats.workers)
	test.equal(stats.fellBack, 0, "and no shard was taken over")
	test.equal(test.count(many.files), test.count(one.files), "every file is in the split entry")
	test.equal(many.annotationsDigest, one.annotationsDigest, "the annotations digest is the same")
	test.equal(canonical(many), canonical(one), "every file's record is the same")
	sameAs(many.known, one.known, "and every declared name resolves the same")
	sameAs(shared:typeLocations(), plain:typeLocations(), "and every type is written in the same place")
end)

test.it("a shard a child lost is built here, not left half an index", function()
	if not parallel.canFork() then return end
	fixture(largeFiles(64))
	local one = Index.new({ parallel = false }):build(ROOT)

	-- The child for shard 2 ends without a record. Its files must still be in the answer, and the
	-- build must say that this process had to take the shard over.
	local failed = Index.new({
		workers = 4,
		onShard = function(_, index) return index == 2 and "fail" or nil end,
	})
	local kept = failed:build(ROOT)
	test.equal(failed:stats().fellBack, 1, "one shard was taken over")
	test.equal(test.count(kept.files), test.count(one.files), "no file is missing")
	test.equal(canonical(kept), canonical(one), "and the answer is the serial one")

	-- The same child writes a record that is not one, and claims success. A short record is no
	-- more a result than a missing one.
	local short = Index.new({
		workers = 4,
		onShard = function(_, index) return index == 3 and "short" or nil end,
	})
	local held = short:build(ROOT)
	test.equal(short:stats().fellBack, 1, "the short record's shard was taken over")
	test.equal(canonical(held), canonical(one), "and the answer is still the serial one")
end)

test.it("LYE_INDEX_PARALLEL=0 builds what the serial build does", function()
	fixture(largeFiles(64))
	writeProbe()
	local one = Index.new({ parallel = false }):build(ROOT)
	local expected = canonical(one)

	local off = probe("LYE_INDEX_PARALLEL=0")
	test.truthy(off, "the off-switch probe ran")
	test.equal(off:match("^workers=(%d+)"), "1", "with one process")
	test.equal(off:gsub("^workers=%d+\n", ""), expected, "and the same entry")

	if parallel.canFork() then
		local on = probe("")
		test.truthy(on, "the default probe ran")
		local workers = tonumber(on:match("^workers=(%d+)"))
		test.truthy(workers and workers > 1, "the default build forks: " .. tostring(workers))
		test.equal(on:gsub("^workers=%d+\n", ""), expected, "and answers the serial entry")
	end
end)

test.it("a root below the fork gate never forks", function()
	fixture({ ["src/point.lua"] = POINT, ["src/alias.lua"] = ALIAS })
	local forks = 0
	local index = Index.new({ fork = function() forks += 1 return 0 end })
	local entry = index:build(ROOT)
	test.equal(forks, 0, "two files are not worth a process")
	test.equal(index:stats().workers, 1, "and the build says it used one")
	test.equal(test.count(entry.files), 2)
end)

test.it("many small files stay in one process", function()
	-- 108 files is this repository's own size, and its source is only a few megabytes: the split
	-- costs more than it saves there, so the byte gate keeps the build serial.
	fixture(manyFiles(108))
	local forks = 0
	local index = Index.new({ fork = function() forks += 1 return 0 end })
	local entry = index:build(ROOT)
	test.equal(forks, 0, "no process was started for small files")
	test.equal(index:stats().workers, 1, "the build says it used one process")
	test.equal(test.count(entry.files), 109, "and every file is indexed")

	-- The switch is the escape hatch: `1` forks on the file count alone, for a workspace where the
	-- byte measurement does not hold.
	if parallel.canFork() then
		writeProbe()
		local on = probe("LYE_INDEX_PARALLEL=1")
		test.truthy(on, "the force probe ran")
		local workers = tonumber(on:match("^workers=(%d+)"))
		test.truthy(workers and workers > 1, "LYE_INDEX_PARALLEL=1 forks on file count alone")
		test.equal(on:gsub("^workers=%d+\n", ""), canonical(entry), "and still answers the serial entry")
	end
end)

test.it("a machine without fork builds in one process", function()
	fixture(largeFiles(64))
	local forks = 0
	local index = Index.new({ canFork = false, fork = function() forks += 1 return 0 end })
	local entry = index:build(ROOT)
	test.equal(forks, 0, "no process was started")
	test.equal(index:stats().workers, 1)
	local one = Index.new({ parallel = false }):build(ROOT)
	test.equal(canonical(entry), canonical(one), "and the entry is the serial one")
	sameAs(entry.known, one.known)
end)
