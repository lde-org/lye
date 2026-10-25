--[[
	Tests for the declarations facade over the persisted index.

	Each drives a real `Lye.new` with a server table of its own over a root written under
	`target/`: a cold build and a warm load have to answer the same declarations, a warm load may
	read no source file, a watcher event updates only the entry it belongs to, and a view changes
	with the generation it was built for.
]]

local test = require("lde-test")
local fs = require("fs")
local cache = require("lye-lsp.cache")
local Index = require("lye-lsp.index")
local Lye = require("lye-lsp.language")
local Declarations = require("lye-lsp.declarations")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local ROOT = PACKAGE_DIR .. "/target/declarations-fixture"
local CACHE = PACKAGE_DIR .. "/target/declarations-cache"

---@param path string
---@param content string
local function write(path, content)
	local dir = path:match("^(.*)/[^/]+$")
	os.execute("mkdir -p " .. string.format("%q", dir))
	local handle = assert(io.open(path, "wb"))
	handle:write(content)
	handle:close()
end

--- A cache of its own for one test: an entry an earlier test wrote must not decide this one.
local function freshCache()
	os.execute("rm -rf " .. string.format("%q", CACHE) .. " && mkdir -p " .. string.format("%q", CACHE))
	cache.setRoot(CACHE)
	cache.setEnabled(true)
end

---@param dirs string[]?
local function reset(dirs)
	os.execute("rm -rf " .. string.format("%q", ROOT) .. " && mkdir -p " .. string.format("%q", ROOT))
	for _, dir in ipairs(dirs or {}) do os.execute("mkdir -p " .. string.format("%q", ROOT .. "/" .. dir)) end
end

---@param files table<string, string> by relative path under the fixture root
---@param dirs string[]?
local function fixture(files, dirs)
	freshCache()
	reset(dirs)
	for relative, content in pairs(files) do write(ROOT .. "/" .. relative, content) end
end

--- A real server facade over the fixture, with an index factory that counts reads so a warm
--- session can be shown to touch no source.
---@param open table<string, boolean>? the documents the editor holds open, by URI
---@return lye.Declarations
---@return lye.Server
---@return fun(): integer
local function session(open)
	local reads = 0
	local function provider()
		return Index.new({
			read = function(path)
				reads += 1
				return fs.read(path)
			end,
		})
	end
	local lye = Lye.new({
		rootPath = ROOT,
		log = function() end,
		documents = {
			get = function(_, uri)
				return open and open[uri] and { uri = uri } or nil
			end,
		},
	})
	local declarations = Declarations.new(lye, { workspace = provider, package = provider })
	lye.declarations = declarations
	return declarations, lye, function() return reads end
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

--- The file the cache wrote the entry for, so a test can damage it the way a lost write does.
---@param root string
---@param kind "workspace"|"package"?
---@return string
local function entryPath(root, kind)
	local index = Index.new({ kind = kind })
	return CACHE .. "/" .. cache.codeVersion() .. "/" .. index:key(root) .. ".entry"
end

local POINT = table.concat({
	"---@class Point\n",
	"---@field x number\n",
	"---@field y number\n",
	"local Point = {}\n",
	"return Point\n",
}, "")

local ALIAS = "---@alias NumberLike number|string\nreturn nil\n"

test.it("a cold facade build loads warm with no source reads and the same answer", function()
	fixture({ ["src/point.lua"] = POINT, ["src/alias.lua"] = ALIAS })
	local cold, coldLye, coldReads = session()
	local known = cold:workspace()
	test.truthy(coldReads() >= 2, "a cold start reads every file")
	test.truthy(cold:stats().built >= 1, "and builds an entry")
	local digest = coldLye.annotationsDigest
	local locations = coldLye.typeLocations
	test.truthy(known.Point, "the class is declared")
	test.truthy(locations.NumberLike, "the alias is written somewhere")
	local coldView = cold:view("file://" .. ROOT .. "/src/point.lua")

	local warm, warmLye, warmReads = session()
	warm:workspace()
	test.equal(warmReads(), 0, "a warm start reads no source")
	test.equal(warm:stats().loaded, 1, "the entry was loaded")
	test.equal(warm:stats().built, 0, "and not built again")
	test.equal(warm:stats().reads, 0, "the index counted no source read")
	test.equal(warmLye.annotationsDigest, digest, "the annotations digest is the one that was built")
	sameAs(warmLye.known, known, "every declared name resolves the same")
	sameAs(warmLye.typeLocations, locations, "every type is written in the same place")
	local view = warm:view("file://" .. ROOT .. "/src/point.lua")
	test.truthy(view.Point, "the view answers from the index")
	sameAs(view.Point, coldView.Point, "and answers what the cold view did")
	sameAs(view.NumberLike, coldView.NumberLike, "the alias included")
	test.equal(warmReads(), 0, "and building a view reads nothing")
end)

test.it("LYE_CACHE=off builds in memory and answers the same", function()
	fixture({ ["src/point.lua"] = POINT, ["src/alias.lua"] = ALIAS })
	local cold, coldLye = session()
	cold:workspace()
	local digest = coldLye.annotationsDigest
	local known = coldLye.known

	cache.setEnabled(false)
	local offline, offlineLye = session()
	offline:workspace()
	test.equal(offline:stats().loaded, 0, "no entry is loaded")
	test.truthy(offline:stats().built >= 1, "the workspace is built in memory")
	test.equal(offlineLye.annotationsDigest, digest, "and answers the digest a build does")
	sameAs(offlineLye.known, known, "and the declarations a build does")
	cache.setEnabled(true)
end)

test.it("a watcher event updates one source file and drops a removed one's types", function()
	fixture({ ["src/point.lua"] = POINT, ["src/alias.lua"] = ALIAS })
	local declarations, lye, reads = session()
	declarations:workspace()
	local before = lye.annotationsDigest
	local readBefore = reads()

	write(ROOT .. "/src/point.lua", POINT .. "---@class Added\n---@field value number\n")
	test.truthy(declarations:watchedFiles({
		changes = { { uri = "file://" .. ROOT .. "/src/point.lua", type = 2 } },
	}), "a source event is handled")
	test.equal(reads() - readBefore, 1, "only the reported file was read")
	test.truthy(lye.known.Added, "the new class is in the workspace")
	test.truthy(lye.typeLocations.Added, "and its type location is there")
	test.truthy(lye.annotationsDigest ~= before, "the annotations digest moved")

	os.remove(ROOT .. "/src/alias.lua")
	test.truthy(declarations:watchedFiles({
		changes = { { uri = "file://" .. ROOT .. "/src/alias.lua", type = 3 } },
	}), "a removal is handled")
	test.falsy(lye.known.NumberLike, "the removed file declared nothing now")
	test.falsy(lye.typeLocations.NumberLike, "and its type location does not linger")
end)

test.it("a watcher event updates the package its target link belongs to", function()
	fixture({
		["src/main.lua"] = "return require(\"dep\")\n",
		[".deps/dep.lua"] = "---@class First\nreturn {}\n",
	}, { "src", "target", ".deps" })
	local link = ROOT .. "/target/dep.lua"
	test.truthy(fs.mklink(ROOT .. "/.deps/dep.lua", link), "the dependency is linked")

	local declarations, lye = session()
	declarations:workspace()
	declarations:package(ROOT)
	test.truthy(lye.packageNames[ROOT].First, "the package reads what it links")
	test.falsy(lye.known.First, "the workspace does not read a link")
	local before = lye.packageDigests[ROOT]
	test.truthy(before and before ~= "", "the package has a links digest")

	write(ROOT .. "/.deps/dep.lua", "---@class First\n---@class Extra\nreturn {}\n")
	test.truthy(declarations:watchedFiles({
		changes = { { uri = "file://" .. link, type = 2 } },
	}), "a target event is handled by the package")
	test.truthy(lye.packageNames[ROOT].Extra, "the package followed the file behind the link")
	test.truthy(lye.packageDigests[ROOT] ~= before, "and its links digest moved")
	test.truthy(lye.typeLocations.Extra, "the new type is written somewhere")
	test.falsy(lye.known.Extra, "the workspace entry did not move")
end)

test.it("a corrupt or truncated entry is built again", function()
	fixture({ ["src/point.lua"] = POINT })
	local first = session()
	first:workspace()

	local path = entryPath(ROOT)
	write(path, "not an entry this reads")
	local second, secondLye = session()
	second:workspace()
	test.equal(second:stats().built, 1, "a corrupt entry is a miss")
	test.truthy(secondLye.known.Point, "and the build answers")

	local text = assert(fs.read(path))
	test.truthy(#text > 20)
	write(path, text:sub(1, 20))
	local third, thirdLye = session()
	third:workspace()
	test.equal(third:stats().built, 1, "half an entry is a miss")
	test.truthy(thirdLye.known.Point, "and the build answers")
end)

test.it("a root with more than 2000 files is indexed through the facade", function()
	local files = {}
	for number = 1, 2001 do
		files["src/f" .. number .. ".lua"] =
			string.format("---@class C%d\nlocal value = %d\nreturn value\n", number, number)
	end
	fixture(files, { "src" })
	local declarations, lye = session()
	declarations:workspace()
	test.truthy(lye.known.C2001, "the last file's class is declared")
	test.equal(declarations:stats().files, 2001, "every file is in the index")
end)

test.it("a view reads the open document, then the package, then the workspace", function()
	fixture({
		["lde.json"] = "{}",
		["src/point.lua"] = POINT,
		["target/point.lua"] = "---@class Point\n---@field z number\n",
		["target/shared.lua"] = "---@class Shared\n",
	}, { "src", "target" })
	local uri = "file://" .. ROOT .. "/src/point.lua"
	local declarations, lye = session({ [uri] = true })
	declarations:workspace()
	declarations:package(ROOT)

	local openPoint = { marker = true }
	declarations:declared(uri, { Point = openPoint, OnlyOpen = true, Shared = "open" })
	local view = declarations:view(uri)
	test.equal(view.Point, openPoint, "the open document's declaration wins")
	test.equal(view.OnlyOpen, true, "a name only the open document has is there")
	test.equal(view.Shared, "open", "the open document beats the package")

	declarations:documentChanged(uri)
	local after = declarations:view(uri)
	test.falsy(after.OnlyOpen, "the open document's layer is gone")
	test.equal(after.Point, lye.packageNames[ROOT].Point, "the package's declaration is next")
	test.truthy(after.Point ~= lye.known.Point, "and it is not the workspace's")
	test.equal(after.Shared, lye.packageNames[ROOT].Shared, "the package beats the workspace")
	test.truthy(rawequal(after, declarations:view(uri)), "a stable generation answers the same view")
	declarations:documentChanged(uri)
	test.falsy(rawequal(after, declarations:view(uri)), "a new generation answers a new view")
end)

test.it("module names come from the index manifest in the old layout", function()
	fixture({
		["src/foo.lua"] = "return 1\n",
		["src/init.lua"] = "return {}\n",
		["packages/lye-doc/src/type.lua"] = "return {}\n",
		["packages/lye-doc/src/nested/init.lua"] = "return {}\n",
		["target/ignored.lua"] = "return 1\n",
		[".hidden/ignored.lua"] = "return 1\n",
	})
	local declarations = session()
	local names = declarations:moduleNames("lye-doc.")
	test.equal(#names, 2, "only the package's two files match")
	test.equal(names[1].name, "lye-doc.nested", "an init file is its directory")
	test.equal(names[2].name, "lye-doc.type", "a package source file drops the layout prefix")
	test.equal(names[2].path, ROOT .. "/packages/lye-doc/src/type.lua")

	local foo = declarations:moduleNames("foo")
	test.equal(#foo, 1)
	test.equal(foo[1].name, "foo", "a leading src is dropped")

	local all = {}
	for _, found in ipairs(declarations:moduleNames("")) do all[found.name] = true end
	test.falsy(all.ignored, "target and hidden files are not modules")
	test.truthy(all.src, "a root src init file keeps the exact transform")
end)

test.it("a warm module listing reads no source", function()
	fixture({ ["src/foo.lua"] = "return 1\n" })
	local cold = session()
	cold:moduleNames("")
	local warm, _, reads = session()
	warm:moduleNames("")
	test.equal(reads(), 0, "the manifest answers without reading a file")
end)

test.it("a source event invalidates every loaded package and reads it again", function()
	fixture({
		["src/main.lua"] = "return require(\"dep\")\n",
		[".deps/dep.lua"] = "---@class First\nreturn {}\n",
	}, { "src", "target", ".deps" })
	test.truthy(fs.mklink(ROOT .. "/.deps/dep.lua", ROOT .. "/target/dep.lua"),
		"the dependency is linked")

	local uri = "file://" .. ROOT .. "/src/main.lua"
	local declarations, lye, reads = session({ [uri] = true })
	declarations:workspace()
	declarations:package(ROOT)
	test.truthy(lye.packageNames[ROOT].First, "the package reads what it links")
	test.truthy(lye.typeLocations.First, "and its type is written somewhere")
	local view = declarations:view(uri)
	test.truthy(declarations.views[uri], "the open document's view is cached")

	-- A source file may be linked into any package's `target/`, so a source event says nothing
	-- about which package's answer moved: all of them are read again on their next ask.
	write(ROOT .. "/.deps/dep.lua", "---@class First\n---@class Second\nreturn {}\n")
	local cleared = 0
	lye.modules = { clear = function() cleared += 1 end }
	test.truthy(declarations:watchedFiles({
		changes = { { uri = "file://" .. ROOT .. "/src/main.lua", type = 2 } },
	}), "the source event is handled")
	test.equal(lye.packageNames[ROOT], nil, "the loaded package's names are dropped")
	test.equal(lye.packageDigests[ROOT], nil, "and so is its link digest")
	test.falsy(lye.typeLocations.First, "its old type locations are not merged in")
	test.equal(cleared, 1, "the module cache is cleared, since declarations it read changed")
	test.equal(declarations.views[uri], nil, "and every cached view is dropped")

	local rebuilt = declarations:package(ROOT)
	test.truthy(rebuilt.Second, "the package is read again from disk")
	test.truthy(lye.typeLocations.Second, "and its new type is located")
	test.truthy(declarations:view(uri) ~= view, "the next view is built anew")
end)

test.it("invalidate drops every cached view and keeps the open layers", function()
	fixture({ ["src/point.lua"] = POINT })
	local uri = "file://" .. ROOT .. "/src/point.lua"
	local declarations = session({ [uri] = true })
	declarations:workspace()
	declarations:declared(uri, { Point = "open" })
	local before = declarations:view(uri)
	test.truthy(declarations.views[uri], "an open document's view is cached")
	local generation = declarations.generation

	declarations:invalidate()
	test.equal(declarations.generation, generation + 1, "the generation moves")
	test.equal(declarations.views[uri], nil, "no cached view survives it")
	test.truthy(declarations.open[uri], "the open document's layer does")
	local after = declarations:view(uri)
	test.falsy(rawequal(before, after), "the next view is built anew")
	test.equal(after.Point, "open", "and still reads the open layer")
end)

test.it("a view is cached for an open document and dropped when it closes", function()
	fixture({ ["src/point.lua"] = POINT })
	local uri = "file://" .. ROOT .. "/src/point.lua"
	local declarations = session({ [uri] = true })
	declarations:workspace()
	declarations:declared(uri, { Point = "open" })
	local first = declarations:view(uri)
	test.truthy(declarations.views[uri], "an open document's view is cached")
	test.truthy(rawequal(first, declarations:view(uri)), "and a second ask is the same view")

	declarations:documentChanged(uri)
	test.falsy(rawequal(first, declarations:view(uri)), "a generation bump answers a new view")

	declarations:documentClosed(uri)
	test.equal(declarations.views[uri], nil, "closing drops the cached view")

	-- A module URI is resolved while it is not open, so its view is an answer, not a cache entry.
	local moduleUri = "file://" .. ROOT .. "/src/other.lua"
	declarations:view(moduleUri)
	declarations:view(moduleUri)
	test.equal(declarations.views[moduleUri], nil, "a module URI does not accumulate a view")
end)
