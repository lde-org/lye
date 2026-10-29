

local report = require("lye-lsp.report")
local doc = require("lye-doc")
local classes = require("lye-doc.class")
local analyzer = require("lye-analyzer")
local position = require("lye-framework.position")
local fs = require("fs")
local rapidhash = require("rapidhash")
local env = require("env")
local parallel = require("lye-lsp.parallel")
local cache = require("lye-lsp.cache")
local Index = require("lye-lsp.index")
local timing = require("lye-lsp.timing")
local plugin = require("lye-plugin")
local json = require("lye-json")
local Parser = require("lye-parser")

local check = {}

--- What lye reads of a document no plugin lowered: the text itself, and a map that moves nothing.
--- A shared one, since it holds no state: a check reads every file of a package through this.
local IDENTITY = require("lye-plugin.source").lower("", {})

--- Whether a file is a definition file: `.d.lua` describes a library the way a `---@meta` file
--- does, so a check holds it to its annotations rather than to bodies it does not have.
---@param path string
---@return boolean
--- Whether a file is a definition file: `.d.lua` describes a library the way a `---@meta` file
--- does, so a check holds it to its annotations rather than to bodies it does not have.
---@param path string
---@return boolean
local function isDefinitionPath(path)
	return path:match("%.d%.lua$") ~= nil
end

--- The LuaJIT definitions, prepared once, so a headless check sees the same standard library an
--- editor session does.
local PRELUDE = analyzer.prelude(require("lye-defs"))

--- The definitions' own types, by a name an entry can say them with. A module's answer holds them
--- — `ffi.cdecl` is a function the definitions declared — and a run that reads that answer back
--- has to reach the very tables the definitions built, because a signature is looked up by the
--- type it was built for. Built once, from the maps the definitions are already keyed by.
---@type { names: table<unknown, string>, tables: table<string, unknown> }?
local preludeTypes

---@return { names: table<unknown, string>, tables: table<string, unknown> }
local function namedPreludeTypes()
	if preludeTypes then return preludeTypes end
	local names, tables = {}, {}
	---@param held unknown
	---@param name string
	local function add(held, name)
		if type(held) ~= "table" or names[held] then return end
		names[held] = name
		tables[name] = held
	end
	-- A field's type is what a signature is looked up by, so it needs its name most: `evolved` is
	-- where the definitions' methods were put as they were declared.
	for className, fields in pairs(PRELUDE.evolved or {}) do
		for field, held in pairs(fields) do add(held, "field:" .. className .. "." .. field) end
	end
	for name, alias in pairs(PRELUDE.aliases) do add(alias, "alias:" .. name) end
	for name, held in pairs(PRELUDE.returns) do add(held, "return:" .. name) end
	for text, held in pairs(PRELUDE.built or {}) do add(held, "built:" .. text) end
	preludeTypes = { names = names, tables = tables }
	return preludeTypes
end

--- What this process has done so far: a warm run is one whose `analyses` did not grow and whose
--- module answers came back from the cache. Counters only; nothing is decided by them.
---@class lye.check.Stats
---@field analyses integer full analyses of a checked file, and module-only analyses
---@field interfaces { hits: integer, loaded: integer, misses: integer, stored: integer }
---@field documents { parsed: integer, loaded: integer } the batch's annotations, parsed here and
--- read from the persisted index

---@type lye.check.Stats
local stats = {
	analyses = 0,
	interfaces = { hits = 0, loaded = 0, misses = 0, stored = 0 },
	documents = { parsed = 0, loaded = 0 },
}

---@return lye.check.Stats
function check.stats()
	return stats
end

-- What each piece of text came to, by its own text. lde links or copies one file into every
-- package's `target/`, so a run of the check meets the same module under many names — the source
-- and the link beside it, and the link in each package that depends on it. Analysing each name
-- again reports its errors once per name and pays for it once per name, which is most of the bill
-- on a package-heavy project. The key is the text rather than the path because the text is what an
-- analysis is about; rapidhash reads a megabyte in well under a millisecond, and the same file is
-- asked for a dozen times here.
local analysesByText = {}
local docsByText = {}

-- What a module came to for a `require`, by its text: a module-only analysis, which is a different
-- thing from `analysesByText` — that one carries the diagnostics of a file being checked, and a
-- file reached as a dependency first must not be handed those away as its answer. An answer that
-- is still the answer is also kept between runs, under a key that says what it was read against.
local interfacesByText = {}

--- The key a piece of source is cached under.
---@param source string
---@return string
local function textKey(source)
	return rapidhash.hex(source)
end

--- The text of a file, or nil when it cannot be read — a missing file and a directory alike.
---@param path string
---@return string?
local function readSource(path)
	return fs.read(path)
end

--- A path as the file system wants it. The walks take a real path and hand back the paths under
--- it, so a run started in a directory has to say where that directory is before walking it.
---@param path string
---@return string
local function absolute(path)
	if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then return path end
	local cwd = env.cwd()
	local cleaned = path:gsub("/+$", "")
	if cleaned == "" or cleaned == "." then return cwd end
	return cwd .. "/" .. (cleaned:gsub("^%./", ""))
end

--- The package a file belongs to: the nearest `lde.json` above it, which is what says where its
--- modules were built. A path named relatively is read from the run's own directory, so it is made
--- whole first — `src/x.lua` has a package above it that the walk over its own spelling never
--- reaches.
---@param path string
---@return string?
local function packageOf(path)
	local at = absolute(path)
	while at and at ~= "" and at ~= "/" do
		if fs.exists(at .. "/lde.json") then return at end
		at = at:match("^(.*)/[^/]+$")
	end
end

--- The directory every path of a batch is under: a run with no workspace root named checks the
--- files it was handed, and the index for that batch is keyed by the smallest tree that holds it.
---@param paths string[]
---@return string?
local function commonRoot(paths)
	local common
	for _, path in ipairs(paths) do
		local at = absolute(path)
		if not fs.isdir(at) then at = at:match("^(.*)/[^/]+$") or at end
		if common == nil then
			common = at
		else
			while common ~= "" and common ~= "/" do
				if at == common or at:sub(1, #common + 1) == common .. "/" then break end
				common = common:match("^(.*)/[^/]+$")
			end
		end
	end
	if common == "" then return "/" end
	return common
end

--- The roots a batch can find a persisted index under: the directory the run was started in, the
--- directory the batch lives under, and each package its files belong to. A root is only ever
--- asked for an entry; a check never builds one, because building it is the reading this is here
--- to avoid.
---@param paths string[]
---@return string[]
local function indexRoots(paths)
	local roots, seen = {}, {}
	---@param root string?
	local function add(root)
		if type(root) ~= "string" or root == "" then return end
		local held = root:gsub("[/\\]+$", "")
		if held == "" then held = "/" end
		if seen[held] then return end
		seen[held] = true
		roots[#roots + 1] = held
	end
	add(env.cwd())
	add(commonRoot(paths))
	for _, path in ipairs(paths) do add(packageOf(path)) end
	return roots
end

--- The index records a loaded entry holds for the files being checked, by absolute path. The
--- entry for a workspace describes its sources; the entry for a package root describes the files
--- linked into its `target/`, which a batch can name as well. Both are read, each once, and an
--- entry that is missing, corrupt or from another version is simply not there: `open` never
--- builds, syncs or writes.
---@param paths string[]
---@return table<string, lye.lsp.IndexFile>?
local function indexedFiles(paths)
	if #paths == 0 then return nil end
	local wanted, remaining = {}, 0
	for _, path in ipairs(paths) do
		local at = absolute(path)
		if not wanted[at] then
			wanted[at] = true
			remaining += 1
		end
	end
	if remaining == 0 then return nil end

	local records = {}
	local index = Index.new()
	for _, root in ipairs(indexRoots(paths)) do
		if remaining == 0 then break end
		for _, kind in ipairs({ "workspace", "package" }) do
			local entry = index:open(root, { kind = kind })
			for path, record in pairs(entry and entry.files or {}) do
				if wanted[path] and records[path] == nil then
					records[path] = record
					remaining -= 1
				end
			end
		end
	end
	return records
end

--- What an index record says a document annotates, in the shape `doc.parse` returns: the
--- annotations the analyzer and `classes.declare` read, and nothing that would need the source.
--- The record's own tables are used as they are — a forked worker inherits them copy-on-write —
--- because nothing in a check writes to an annotation.
---@param record lye.lsp.IndexFile
---@return lye.doc.File
local function annotationDoc(record)
	return { annotations = record.annotations, isDefinition = record.isDefinition == true }
end

--- The names the modules linked into a package's `target/` declare. A dependency's class is as
--- real to a file as its own package's, and a check that only knew the files it was handed reported
--- every `clap.Args` and `process.Child` as a type nothing declares — which is what the editor,
--- reading the same `target/`, does not.
---@param root string the package root
---@param cache table<string, table<string, boolean|lye.doc.Type>>
---@param paths string[]? the files under `target/`, when a run has already listed them
local function linkedDeclarations(root, cache, paths)
	local held = cache[root]
	if held then return held end
	local found = {}
	local target = absolute(root) .. "/target"
	if fs.isdir(target) then
		-- Every file's names are read into one namespace before any is resolved: a class of one
		-- file holds a field whose type is an alias of another — `lde.Package.Config.features` is
		-- `lde.Package.Config.FeatureDefinitions` — and resolving the class with the file it is
		-- written in alone left that field a name nothing stands for. A link farm holds the same
		-- file under every package that depends on it, so the walk stops at the cap rather than
		-- reading the closure of every closure; a run whose cache has already listed the farm —
		-- its digest is taken over the same files — hands the list over instead of walking again.
		local parsedFiles = {}
		---@param file string
		local function read(file)
			if #parsedFiles >= 2000 then return end
			local source = readSource(file)
			if type(source) ~= "string" then return end
			local key = textKey(source)
			local parsed = docsByText[key]
			if parsed == nil then
				local isOk, one = pcall(doc.parse, source)
				if isOk then docsByText[key] = one end
				parsed = isOk and one or nil
			end
			if parsed then parsedFiles[#parsedFiles + 1] = parsed end
		end
		if paths then
			for _, file in ipairs(paths) do read(file) end
		else
			for file in fs.scan(target, "**/*.lua", { absolute = true, followSymlinks = true, ignore = ignored }) do
				read(file)
			end
		end
		-- What each name means, resolved once for the whole package: a dependency's alias is as
		-- real to a reader as its own, and a bare name refuses every argument made of it.
		found = classes.declare(parsedFiles)
	end
	cache[root] = found
	return found
end

--- Directories that never hold source to check: a build output and a fetched dependency tree.
--- Anything whose name begins with a dot is refused too — version control, editor state, and the
--- like — because walking those is most of the cost on a project that has been built.
local SKIPPED = { ["target"] = true, ["node_modules"] = true }

---@param name string
---@return boolean
local function ignored(name)
	return SKIPPED[name] or name:sub(1, 1) == "."
end

--- What a run keeps for the next one: the digest of everything a file is read against, and the
--- text of the files read on the way. `check.files` builds one; `check.file` and a run with the
--- cache off have none, and every file is then checked the way it always was.
---
--- There is no size/mtime manifest: measured on this repository, a warm run over the unchanged
--- tree is 0.08-0.10 s, of which hashing the sources is under the noise — a manifest would add a
--- second thing to validate and save nothing. A file's text key is its content hash, and a change
--- to it is the one thing that makes the entry a miss.
---@class lye.check.Store
---@field annotations string the digest of every annotation in the batch, which `declared` is built from
---@field keys table<string, string> the text key of each file of the batch, by path
---@field hashes table<string, string|false> the text key of a file read on demand, by path
---@field farms table<string, string> each package's `target/` digest, by package root
---@field farmFiles table<string, string[]> the files each digest was taken over
local Store = {}
Store.__index = Store

---@param paths string[]
---@param keysByPath table<string, string>
---@param docsByText table<string, lye.doc.File|false>
function Store.new(paths, keysByPath, docsByText)
	local parts = {}
	for _, path in ipairs(paths) do
		local key = keysByPath[path]
		local parsed = key and docsByText[key]
		parts[#parts + 1] = path
		if parsed then
			for _, annotation in ipairs(parsed.annotations) do
				-- Everything `classes.declare` reads from an annotation, and nothing that moves
				-- with it: a run whose annotations hash the same declares the same names.
				parts[#parts + 1] = (annotation.tag or "") .. "\0" .. (annotation.name or "") .. "\0"
					.. (annotation.text or "") .. "\0" .. (annotation.type or "") .. "\0"
					.. (annotation.typeText or "")
			end
		end
	end
	return setmetatable({
		annotations = rapidhash.hex(table.concat(parts, "\1")),
		keys = keysByPath, hashes = {}, farms = {}, farmFiles = {},
	}, Store)
end

--- The text key of a file, read and hashed once: what a dependency's text is says whether an
--- answer that depended on it still holds.
---@param path string
---@return string|false
---@param self lye.check.Store
function Store:keyOf(path)
	local held = self.hashes[path]
	if held ~= nil then return held end
	local text = readSource(path)
	held = type(text) == "string" and textKey(text) or false
	self.hashes[path] = held
	return held
end

--- Everything linked into a package's `target/`, and the digest of their texts: a change to any
--- of them changes what a file of that package is read against.
---@param owner string
---@return string
---@param self lye.check.Store
function Store:farm(owner)
	local held = self.farms[owner]
	if held then return held end
	local files = {}
	local target = absolute(owner) .. "/target"
	if fs.isdir(target) then
		for file in fs.scan(target, "**/*.lua", { absolute = true, followSymlinks = true, ignore = ignored }) do
			files[#files + 1] = file
		end
		table.sort(files)
	end
	local parts = {}
	for _, path in ipairs(files) do parts[#parts + 1] = path .. "=" .. tostring(self:keyOf(path)) end
	self.farmFiles[owner] = files
	self.farms[owner] = rapidhash.hex(table.concat(parts, "\1"))
	return self.farms[owner]
end

--- The entry a previous run left for this file, when the file, the batch's annotations and the
--- package's `target/` are all what they were: what a file of that package can require is what is
--- linked there, so that digest covers every module an analysis of it could have read.
---@param path string
---@param key string
---@param owner string?
---@return table?
---@param self lye.check.Store
function Store:hit(path, key, owner)
	local farm = owner and self:farm(owner) or ""
	local entry = cache.load(cache.key(key, self.annotations, farm, path))
	if not entry or entry.text ~= key or entry.key ~= cache.codeVersion() then return nil end
	return entry
end

--- Keep what this file came to, against the same digest the next run will ask its questions with.
---@param path string
---@param key string
---@param owner string?
---@param entries table[]
---@param self lye.check.Store
function Store:keep(path, key, owner, entries)
	local stored = {}
	for index, entry in ipairs(entries) do
		stored[index] = {
			start = entry.start, stop = entry.stop or entry.start,
			severity = entry.severity, message = entry.message,
		}
	end
	local farm = owner and self:farm(owner) or ""
	cache.save(cache.key(key, self.annotations, farm, path), {
		text = key, key = cache.codeVersion(), diagnostics = stored,
	})
end

--- What a file of a package is read against: what the batch declares and everything linked into
--- the package's `target/`, merged once per package. The merge is what makes a dependency's class
--- as real to a file as its own, and what an alias of another file means where it is used.
---@param owner string
---@param scopes table<string, table<string, boolean|lye.doc.Type>>
---@param elsewhere table<string, boolean|lye.doc.Type>?
---@param store lye.check.Store?
---@return table<string, boolean|lye.doc.Type>
local function scopeFor(owner, scopes, elsewhere, store)
	local held = scopes[owner]
	if held then return held end
	local scope = {}
	for name, value in pairs(elsewhere or {}) do scope[name] = value end
	for name, value in pairs(linkedDeclarations(owner, scopes, store and store.farmFiles[owner])) do
		scope[name] = value
	end
	scopes[owner] = scope
	return scope
end

--- The plugins a package asked for, loaded once per package: `lye.json` beside the package and in
--- the directory the run was started in, the package's answer winning — the way an editor session
--- reads them, so that a file is checked in whatever language its package said it is written in.
--- A plugin named rather than pathed is a module the package installed, which is one lde linked
--- into its `target/`: the same place a `require` finds. A plugin that cannot be loaded goes to the
--- run's error stream, because that is a fault of the run rather than of the file being checked.
local pluginsByPackage = {}

--- The file a module name resolves to inside a package's `target/`, without reading it: lde
--- links every module a package can reach under that directory, so one rule answers a dependency
--- and a sibling alike.
---@param owner string the package root
---@param name string
---@return string?
local function modulePath(owner, name)
	local base = absolute(owner)
	local tail = (name:gsub("%.", "/"))
	for _, candidate in ipairs({
		base .. "/target/" .. tail .. ".lua",
		base .. "/target/" .. tail .. "/init.lua",
	}) do
		if fs.exists(candidate) then return candidate end
	end
end

--- The plugins a package asked for, loaded once per package: `lye.json` beside the package and in
--- the directory the run was started in, the package's answer winning — the way an editor session
--- reads them, so that a file is checked in whatever language its package said it is written in.
--- A plugin named rather than pathed is a module the package installed, which is one lde linked
--- into its `target/`: the same place a `require` finds. A plugin that cannot be loaded goes to the
--- run's error stream, because that is a fault of the run rather than of the file being checked.
---@param path string
---@return lye.plugin.Spec[]
local function pluginsFor(path)
	local owner = packageOf(path)
	local key = owner or ""
	local held = pluginsByPackage[key]
	if held then return held end

	local entries, seen = {}, {}
	---@param dir string
	local function read(dir)
		if seen[dir] then return end
		seen[dir] = true
		local written = readSource(dir .. "/lye.json")
		if type(written) ~= "string" then return end
		local ok, config = pcall(json.decode, written)
		if not ok or type(config) ~= "table" or type(config.plugins) ~= "table" then return end
		for _, entry in ipairs(config.plugins) do
			if type(entry) == "string" and entry ~= "" then
				local named = entry:sub(1, 1) ~= "!" and entry:sub(1, 1) ~= "/"
					and (entry:sub(1, 1) == "." or entry:sub(-4) == ".lua")
				entries[#entries + 1] = named and (absolute(dir .. "/" .. entry:gsub("^%./", ""))) or entry
			end
		end
	end
	if owner then read(absolute(owner)) end
	read(absolute(env.cwd()))

	---@param name string
	---@return string?
	local function moduleAt(name) return modulePath(owner or env.cwd(), name) end
	---@param message string
	local function reportPlugin(message) io.stderr:write("check: " .. message .. "\n") end
	local specs = plugin.load(entries, owner and absolute(owner) or absolute(env.cwd()),
		moduleAt, reportPlugin)
	pluginsByPackage[key] = specs
	return specs
end

--- The key an analysis is kept under: what lye reads of the file, and the plugins that read it.
--- The ffi plugin is what gives a cdef block its types, so a workspace that turned it off must not
--- read the answer from when it was on.
---@param path string
---@param written string
---@return string
local function analysisKey(path, written)
	return textKey(written .. "\0" .. plugin.digest(pluginsFor(path)))
end

--- What lye reads of a file: the text itself, lowered when the package it belongs to asked for a
--- plugin that knows its language. The map is what carries a finding back to the file it was found
--- in, so a report says where a reader would look for it.
---
--- Kept by the file and the text, because a run asks twice: once for the batch it builds and once
--- for each file it checks, and a plugin that compiles a language is not something to do twice for
--- one unchanged file.
---@type table<string, { text: string, map: lye.plugin.Map }>
local loweredBySource = {}

---@param path string
---@param source string
---@return string text
---@return lye.plugin.Map map
local function lowered(path, source)
	local specs = pluginsFor(path)
	if #specs == 0 then return source, IDENTITY end
	local cacheKey = path .. "\0" .. textKey(source) .. "\0" .. plugin.digest(specs)
	local held = loweredBySource[cacheKey]
	if held then return held.text, held.map end
	local context = { uri = path, source = source, text = source, root = packageOf(path) }
	local map = plugin.lower(specs, context, function(message)
		io.stderr:write("check: " .. message .. "\n")
	end)
	loweredBySource[cacheKey] = { text = map.text, map = map }
	return map.text, map
end

--- The key an interface is kept under: the module's analysis key — its text and the plugins that
--- read it — the code that read it, and what it was read against. What it was read against is the
--- batch's annotations and everything linked into the module's own package: a module's `require`s
--- resolve within its package, so a change to any linked file can change the answer.
---@param key string the module's analysis key
---@param path string the file the `require` is written in, which says how the module is held
---@param store lye.check.Store
---@param owner string the module's package root
---@return string
local function interfaceKey(key, path, store, owner)
	return cache.key("interface", key, cache.codeVersion(),
		tostring(isDefinitionPath(path)), store.annotations, store:farm(owner))
end

--- The interface a previous run kept for a module, when its text, its plugins and everything it
--- was read against are unchanged. A `false` module is kept too, as the answer a module that
--- returns nothing came to. Anything else — an entry from another version, a corrupt one, one a
--- concurrent run is writing — is a miss.
---@param key string
---@param path string
---@param store lye.check.Store
---@param owner string
---@param written string the lowered text the interface is about
---@return { type: lye.doc.Type? }?
local function loadInterface(key, path, store, owner, written)
	local entry = cache.load(interfaceKey(key, path, store, owner), namedPreludeTypes())
	if not entry or entry.key ~= cache.codeVersion() or entry.text ~= textKey(written) then
		return nil
	end
	if entry.module == false then return { type = nil } end
	if type(entry.module) ~= "table" then return nil end
	return { type = entry.module }
end

--- Keep a module's interface for the runs after this one. A write that cannot happen is a miss
--- then, not an error: the answer is already in hand.
---@param key string
---@param path string
---@param store lye.check.Store
---@param owner string
---@param written string
---@param module lye.doc.Type?
---@return boolean
local function saveInterface(key, path, store, owner, written, module)
	return cache.save(interfaceKey(key, path, store, owner), {
		text = textKey(written), key = cache.codeVersion(), module = module or false,
	}, namedPreludeTypes())
end

--- The text of a module the definitions ship, when `name` is one. A definition file that returns
--- a value is a module `require` may name: `ffi`, `jit`, `string.buffer`, and the test harness.
---@param name string
---@return string?
local builtinModules = {}
local function builtinModule(name)
	local held = builtinModules[name]
	if held ~= nil then return held or nil end
	local sources = require("lye-defs")
	local source = sources[name]
	if type(source) ~= "string" then
		builtinModules[name] = false
		return nil
	end
	local parsed = Parser.new(source):parse()
	for _, child in ipairs(parsed.nodes[parsed.root].children or {}) do
		if parsed.nodes[child].kind == "return" then
			builtinModules[name] = source
			return source
		end
	end
	builtinModules[name] = false
end

--- The type `require("name")` has in `path`: lde links every module a package can reach under its
--- `target/`, so one rule answers a dependency and a sibling alike. `ffi` and the rest of the
--- engine's modules are named in the definitions rather than in a file, and come from there.
---@param path string the file the require is written in
---@param name string
---@param modules table<string, { type: lye.doc.Type? }> what each module came to, by the text it was read from
---@param analysing table<string, boolean> the modules being read, so a cycle ends
---@param elsewhere table<string, boolean|lye.doc.Type>? what the batch declares
---@param scopes table<string, table<string, boolean|lye.doc.Type>>? the scope of each package
---@param batch table<string, string>? the files being checked, by their text
---@param store lye.check.Store? what the run keeps between runs, whose farm list is reused here
---@return lye.doc.Type?
local function moduleOf(path, name, modules, analysing, elsewhere, scopes, batch, store)
	local owner = packageOf(path)
	if not owner then return nil end
	local found = modulePath(owner, name)
	local builtin = not found and builtinModule(name) or nil
	if not found and not builtin then
		return nil
	end
	if not found then found = "<builtin>/" .. name end

	local source = builtin or readSource(found)
	if type(source) ~= "string" then
		return nil
	end
	local written = lowered(found, source)
	local key = analysisKey(found, written)

	-- What the module came to is kept, including when it came to nothing: a package that requires
	-- another is read once for the whole run rather than once per file that names it — and the
	-- same file reached through another package's link is the same module and is not read again.
	local cached = modules[key] or interfacesByText[key]
	if cached then
		stats.interfaces.hits += 1
		return cached.type
	end
	-- A module that requires its way back here says nothing rather than being read again.
	if analysing[key] then return nil end

	-- What an earlier run kept, when nothing the module was read against has changed: the same
	-- answer two package slices, or two runs, would otherwise pay to work out twice.
	local ownerOfModule = packageOf(found) or owner
	if store then
		local kept = loadInterface(key, path, store, ownerOfModule, written)
		if kept then
			stats.interfaces.loaded += 1
			modules[key] = kept
			interfacesByText[key] = kept
			return kept.type
		end
	end

	-- The module's own `require`s resolve within its package, so it is read with a resolver of its
	-- own — and the analysis is the one the editor would do, definitions and all.
	analysing[key] = true
	-- Read against what the batch declares as well: a signature written with a class or an alias
	-- another file declares is otherwise an unresolved name, and every caller is then refused
	-- against a type that has no meaning outside the file it was written in.
	-- A module that is one of the files being checked is read the way its own check reads it — its
	-- package's scope, diagnostics and all — so that answer serves both and no file is read twice
	-- in two contexts. Anything else is read for its type alone: its diagnostics are not this
	-- run's to report, so the passes that only build them are left out.
	local batchPath = batch and batch[key]
	local own = batchPath
		and scopeFor(packageOf(batchPath) or path, scopes or {}, elsewhere, store)
		or elsewhere
	local names = analysesByText[key]
	if names == nil then
		stats.analyses += 1
		names = analyzer.analyze(written, PRELUDE, own, function(inner)
			return moduleOf(found, inner, modules, analysing, own, scopes, batch, store)
		end, nil, docsByText[key], batchPath == nil, builtin ~= nil or isDefinitionPath(path),
			builtin and {} or pluginsFor(found),
			function(message) io.stderr:write("check: " .. message .. "\n") end)
		analysesByText[key] = names
	end
	analysing[key] = nil
	stats.interfaces.misses += 1
	local held = { type = names.module }
	modules[key] = held
	interfacesByText[key] = held
	if store and saveInterface(key, path, store, ownerOfModule, written, names.module) then
		stats.interfaces.stored += 1
	end
	return names.module
end

--- Report what a file's analysis found, from the entries' byte offsets: this is the one place
--- that wants 1-based line and column, which is what a reader sees.
---@param reporter lye.Report
---@param path string
---@param source string
---@param entries { start: integer, stop: integer?, severity: integer?, message: string }[]
---@return boolean isOk
local function reportEntries(reporter, path, source, entries)
	local index
	local isOk = true
	for _, entry in ipairs(entries) do
		index = index or position.buildLineIndex(source)
		local line, character = position.toPosition(source, index, entry.start, position.UTF8)
		report.diagnostic(reporter, path, line + 1, character + 1, entry.severity, entry.message)
		-- An unused local is a hint, and a build step that fails on one is a build step nobody
		-- keeps: it is printed and it does not decide the exit code.
		-- A parser diagnostic carries no severity: a syntax error is the loudest thing there is.
		if entry.severity == nil or entry.severity <= 2 then isOk = false end
	end
	return isOk
end

---@return boolean? isOk
---@return string? err
---@param path string
---@param elsewhere table<string, boolean|lye.doc.Type>? what the other files in this batch declare
---@param modules table<string, { type: lye.doc.Type? }>? what each module came to, shared across the batch
---@param reporter lye.Report? where what is found is written
---@param scopes table<string, table<string, boolean|lye.doc.Type>>? what each package's links declare, merged
---@param source string?
---@param key string?
---@param isRead boolean
---@param store lye.check.Store? what this run keeps between runs, when it keeps anything
---@param batch table<string, string>? the files being checked, by their text
local function checkSource(path, elsewhere, modules, reporter, scopes, source, key, isRead, store, batch)
	reporter = reporter or report.new()
	-- A name the package's linked modules declare is not a typo, so the file is read against them
	-- as well as against the batch. Merged once per package rather than once per file.
	local owner = packageOf(path)
	if owner then elsewhere = scopeFor(owner, scopes or {}, elsewhere, store) end
	if not isRead then source = readSource(path) end
	-- A directory reads as nothing and `--check` is pointed at folders all the time: say so
	-- instead of handing the parser nothing to work with.
	if type(source) ~= "string" then
		return nil, string.format("%s: not a readable file", path)
	end

	-- The plugins the file's package asked for: what lye reads is the lowered text, and every
	-- finding is carried back to the file the reader wrote before it is reported or kept.
	local written, map = lowered(path, source)
	key = key or analysisKey(path, written)

	-- What a previous run found for this file, when nothing it was read against has changed:
	-- reported as it stands, with no analysis at all.
	if store then
		local held = store:hit(path, key, owner)
		if held then return reportEntries(reporter, path, source, held.diagnostics) end
	end

	-- Annotation type errors belong in the same report as syntax errors, so a declaration
	-- contradicting its `---@type` fails the check.
	-- This file counts as being read: a module it requires that requires it back would otherwise
	-- be followed for as long as the stack lasts, which is the whole run for a package cycle.
	local analysing = { [key] = true }
	local names = analysesByText[key]
	if names == nil then
		stats.analyses += 1
		---@param name string
		---@return lye.doc.Type?
		local function moduleFor(name)
			return moduleOf(path, name, modules or {}, analysing, elsewhere, scopes, batch, store)
		end
		---@param message string
		local function reportPlugin(message) io.stderr:write("check: " .. message .. "\n") end
		names = analyzer.analyze(written, PRELUDE, elsewhere, moduleFor, nil, docsByText[key],
			nil, isDefinitionPath(path), pluginsFor(path), reportPlugin)
		analysesByText[key] = names
		-- The full analysis says what `require` of this file gives back as well, and it is the
		-- richer answer: a module another file reaches afterwards takes it rather than being
		-- analysed a second time.
		interfacesByText[key] = { type = names.module }
		if store and owner and saveInterface(key, path, store, owner, written, names.module) then
			stats.interfaces.stored += 1
		end
	end
	-- A `require` naming a module that is neither linked into the package nor one of the
	-- definitions is not something the analysis can type. Saying so is better than letting every
	-- use of the value become a silent unknown.
	for _, node in ipairs(names.parser.nodes) do
		if node.kind == "call" and node.callee == "require" and node.args and node.args[1] then
			local argument = names.parser.nodes[node.args[1]]
			if argument and argument.kind == "string" and type(argument.value) == "string"
				and not (owner and modulePath(owner, argument.value))
				and not builtinModule(argument.value) then
				names.diagnostics[#names.diagnostics + 1] = {
					message = string.format("module `%s` is not found", argument.value),
					severity = 1, start = argument.start, stop = argument.stop,
				}
			end
		end
	end

	-- The analysis parsed the file already: its own parse carries the syntax errors, so a file is
	-- read by the parser once per check rather than twice.
	local all = {}
	local parsed = names.parser
	for _, entry in ipairs(parsed and parsed.diagnostics or {}) do all[#all + 1] = entry end
	for _, entry in ipairs(names.diagnostics) do all[#all + 1] = entry end
	-- Every finding travels back to the file it was found in, as a copy: what is held here is the
	-- analysis of the *lowered* text, and a finding of it that a report has already carried back
	-- would be carried back again the next time the same text is checked in this run.
	local mapped = {}
	for _, entry in ipairs(all) do
		local from, to = map:toOriginalRange(entry.start, entry.stop or entry.start)
		mapped[#mapped + 1] = { message = entry.message, severity = entry.severity, start = from, stop = to }
	end
	all = mapped
	table.sort(all, function(a, b) return a.start < b.start end)

	local isOk = reportEntries(reporter, path, source, all)
	if store then store:keep(path, key, owner, all) end
	return isOk
end

---@param path string
---@param elsewhere table<string, boolean|lye.doc.Type>?
---@param modules table<string, { type: lye.doc.Type? }>?
---@param reporter lye.Report?
---@param scopes table<string, table<string, boolean|lye.doc.Type>>?
function check.file(path, elsewhere, modules, reporter, scopes)
	return checkSource(path, elsewhere, modules, reporter, scopes, nil, nil, false)
end

--- Every file a check with no paths named checks: the Lua files under `root`, and the files of any
--- other language a plugin of the workspace claims. `.moon` is Lua to a project that said so, and a
--- walk that only knew `.lua` would check none of what such a project is made of.
---@param root string
---@return string[]
function check.discover(root)
	local found = {}
	local base = absolute(root)
	if not fs.isdir(base) then return found end
	-- The walk hands back the paths under the root, relative to it: what is checked is written the
	-- way the caller named it, so a run in a directory reports `./src/x.lua` and not the whole path.
	local cleaned = root:gsub("/+$", "")
	local prefix = (cleaned == "" or cleaned == ".") and "./" or (cleaned:gsub("^%./", "") .. "/")
	---@param glob string
	local function scan(glob)
		for path in fs.scan(base, glob, { ignore = ignored }) do
			found[#found + 1] = prefix .. path
		end
	end
	scan("**/*.lua")
	for _, extension in ipairs(check.extensions(root)) do
		scan("**/*." .. extension)
	end
	table.sort(found)
	return found
end

--- The extensions the plugins of the packages under `root` say their languages are written in,
--- each once. Read from the `lye.json` files the walk finds rather than from every package's own
--- listing, so a directory that holds no plugin pays one walk and nothing else.
---@param root string
---@return string[]
function check.extensions(root)
	local found, seen = {}, {}
	local base = absolute(root)
	for path in fs.scan(base, "**/lye.json", { ignore = ignored }) do
		local file = base .. "/" .. path
		local written = readSource(file)
		if type(written) == "string" then
			local ok, config = pcall(json.decode, written)
			if ok and type(config) == "table" and type(config.plugins) == "table" then
				local dir = file:match("^(.*)/[^/]+$")
				-- The plugins that file names, loaded the way the package's own check loads them,
				-- so that the extensions it walks for are the ones its files really have.
				---@param name string
				---@return string?
				local function moduleAt(name) return modulePath(dir, name) end
				local specs = plugin.load(config.plugins, dir, moduleAt, function() end)
				for _, spec in ipairs(specs) do
					for _, extension in ipairs(spec.extensions or {}) do
						if not seen[extension] and extension ~= "lua" then
							seen[extension] = true
							found[#found + 1] = extension
						end
					end
				end
			end
		end
	end
	table.sort(found)
	return found
end

--- Whether `path` is a directory. A directory opens as a handle on Linux and then reads as nil,
--- where an empty file reads as an empty string, which is what tells the two apart.
---@param path string
---@return boolean
local function isDirectory(path)
	return fs.isdir(path)
end

--- The files a list of arguments names: a directory stands for every Lua file under it, so
--- `lye check packages` means what it says. A file named twice — beside a directory that holds it,
--- or twice over — is one file, checked once: the batch is split across processes when the machine
--- has cores to spare, and a file repeated in it would be reported once per process that had it.
---@param paths string[]
---@return string[]
function check.expand(paths)
	local named = {}
	local seen = {}
	---@param path string
	local function add(path)
		if not seen[path] then
			seen[path] = true
			named[#named + 1] = path
		end
	end
	for _, path in ipairs(paths) do
		if isDirectory(path) then
			for _, found in ipairs(check.discover(path)) do add(found) end
		else
			add(path)
		end
	end
	return named
end

---@param paths string[]
---@param reporter lye.Report?
---@return boolean isOk
function check.files(paths, reporter)
	-- Every file in the batch is read first, so a name one of them declares is not a typo in
	-- another: annotations are workspace-wide even though a document is analysed on its own.
	-- The annotations themselves are the expensive part of that: an earlier run's declaration
	-- index already holds them, so a record whose hash is the text read here is used as it stands
	-- and only the files the index does not describe are comment-lexed. The records are plain
	-- tables, so a forked worker inherits them copy-on-write rather than through IPC.
	local parsedFiles = {}
	local sourcesByPath, keysByPath = {}, {}
	local records = cache.enabled() and indexedFiles(paths) or nil
	local loaded, parsed = 0, 0
	local started = timing.detailed() and timing.now() or nil
	for _, path in ipairs(paths) do
		local source = readSource(path)
		sourcesByPath[path] = source
		if type(source) == "string" then
			-- A file a plugin reads is keyed by what lye reads of it: that is what an analysis is
			-- about, and the annotations a batch hands over are the ones written in it.
			local written = lowered(path, source)
			local key = analysisKey(path, written)
			keysByPath[path] = key
			local held = docsByText[key]
			if held == nil then
				-- A lowered text is not the text the index read, and its annotations are the ones
				-- the plugin wrote rather than the ones in the file: those are parsed as they are.
				local record = records and written == source and records[absolute(path)] or nil
				if record and record.hash == textKey(source) then
					held = annotationDoc(record)
					loaded += 1
				else
					local isOk, one = pcall(doc.parse, written)
					held = isOk and one or false
					parsed += 1
				end
				docsByText[key] = held
			end
			if held then parsedFiles[#parsedFiles + 1] = held end
		end
	end
	stats.documents.loaded += loaded
	stats.documents.parsed += parsed
	if started then timing.detail("check-index", started, "loaded=%d parsed=%d", loaded, parsed) end

	reporter = reporter or report.new()
	-- What an earlier run kept, when this one can read it: everything a file is read against,
	-- hashed, so an answer that is still the answer is reported without working it out again.
	local store = cache.enabled() and Store.new(paths, keysByPath, docsByText) or nil
	if store then
		local held, missing = {}, false
		for _, path in ipairs(paths) do
			local key = keysByPath[path]
			local source = sourcesByPath[path]
			-- A file that could not be read, or could not be parsed, is not one a run kept an
			-- answer for: it is checked, and the check reports what is wrong with it.
			local entry = type(source) == "string" and key and docsByText[key]
				and store:hit(path, key, packageOf(path))
			if not entry then
				missing = true
				break
			end
			held[path] = entry
		end
		-- Every file is what a previous run read: report what it found and analyse nothing. A
		-- single file that is not is enough to make this an ordinary run.
		if not missing then
			local isOk = true
			for _, path in ipairs(paths) do
				local source = sourcesByPath[path] or ""
				if not reportEntries(reporter, path, source, held[path].diagnostics) then
					isOk = false
				end
			end
			return isOk
		end
	end

	-- What each name stands for, not only that it exists: a parameter declared with an alias
	-- another file writes is checked against what the alias means, and a name on its own refuses
	-- every argument handed to it.
	local declared = classes.declare(parsedFiles)

	-- The work, in the units one process has to hold together: a package's files, which read the
	-- same linked names and resolve one another in the order they are written.
	local groups = {}
	local current
	local owner
	for _, path in ipairs(paths) do
		local at = packageOf(path)
		if not current or at ~= owner then
			owner = at
			---@type lye.parallel.Group
			local group = { files = {}, sizes = {}, bytes = 0 }
			groups[#groups + 1] = group
			current = group
		end
		local size = #(sourcesByPath[path] or "")
		current.files[#current.files + 1] = path
		current.sizes[#current.sizes + 1] = size
		current.bytes += size
	end

	---@param files string[]
	---@param collector lye.Collector
	local function checkSlice(files, collector)
		local modules, scopes = {}, {}
		-- The files this slice is checking, by their text: one reached as a module on the way is
		-- read the way its own check reads it, so it is read once and its findings are kept.
		local batch = {}
		for _, path in ipairs(files) do
			local key = keysByPath[path]
			if key then batch[key] = path end
		end
		for _, path in ipairs(files) do
			local passed, err = checkSource(path, declared, modules, collector, scopes,
				sourcesByPath[path], keysByPath[path], true, store, batch)
			if passed ~= true and err then
				-- A file that cannot be read reports to whoever asked, and the name of the file is
				-- what that report is about, so it travels with the rest and is said where it is
				-- named.
				collector.collect[#collector.collect + 1] = { path = path, err = err }
			end
		end
	end

	local found = parallel.run(groups, parallel.workers(#paths), checkSlice)
	local isOk = true
	for _, path in ipairs(paths) do
		for _, entry in ipairs(found[path] or {}) do
			if entry.err then
				io.stderr:write(entry.err .. "\n")
				isOk = false
			else
				report.diagnostic(reporter, entry.path, entry.line, entry.column, entry.severity, entry.message)
				-- An unused local is a hint, and a build step that fails on one is a build step
				-- nobody keeps: it is printed and it does not decide the exit code. A parser
				-- diagnostic carries no severity, and a syntax error is the loudest thing there is.
				if entry.severity == nil or entry.severity <= 2 then isOk = false end
			end
		end
	end
	return isOk
end

return check
