--[[
	What the workspace and the packages it can reach declare, and where the types they name are
	written. Extracted from `language.lua` so the index behind it can change without the server
	that asks.

	The declarations are read from the persisted index: a warm session reads the entry for a root
	and touches no source file, and a file watcher updates only the root an event belongs to. What
	this module keeps on the server — `known`, `annotationsDigest`, `packageNames`,
	`packageDigests`, `typeLocations` — is the contract the analyzer and the module cache read.
]]

local timing = require("lye-lsp.timing")
local fs = require("fs")
local definitionsIndex = require("lye-lsp.definitions")
local Index = require("lye-lsp.index")

--- How many package entries stay loaded. A monorepo can name more packages than a session needs
--- at once, and each entry holds every type its links declare; the least recently used is dropped
--- and read again if a document in it is opened.
local MAX_PACKAGES = 32

--- The starts of the lines a type is declared on, read out of the definitions. Kept here because
--- a builtin is not part of any index.
---@param source string
---@param offset integer
local function lineStart(source, offset)
	local at = offset - 1
	while at >= 1 do
		if source:byte(at) == 10 then return at + 1 end
		at -= 1
	end
	return 1
end

--- The line at a start offset, without its indentation.
---@param source string
---@param at integer
local function lineAt(source, at)
	local to = source:find("\n", at, true) or (#source + 1)
	return (source:sub(at, to - 1):gsub("^%s+", ""))
end

--- The lines that declare a class or an alias: the comment above it, which is its documentation,
--- its own line, and the fields written under it. The annotation above the comment is another
--- type's business, so the walk stops there.
---@param source string
---@param annotations lye.doc.Annotation[]
---@param at integer the index of the class or alias annotation
local function declarationLines(source, annotations, at)
	local annotation = annotations[at]
	local declaration = lineStart(source, annotation.start)
	local lines = {}
	local above = declaration
	while #lines < 8 and above > 1 do
		local previous = lineStart(source, above - 1)
		local text = lineAt(source, previous)
		if not text:match("^%-%-") or text:match("^%-%-%-@") then break end
		table.insert(lines, 1, text)
		above = previous
	end
	lines[#lines + 1] = lineAt(source, declaration)
	for following = at + 1, #annotations do
		local next_ = annotations[following]
		if next_.tag ~= "field" or not next_.name then break end
		lines[#lines + 1] = lineAt(source, lineStart(source, next_.start))
	end
	return table.concat(lines, "\n")
end

--- The module name of a path, in the layout lde builds from: `packages/lye-doc/src/type.lua` is
--- `lye-doc.type`, a leading `src.` is dropped, an `init` file is its directory, and separators
--- become dots. The same transform the workspace walk always applied, so completions do not move.
--- The folder a document belongs to. A session uses `Server:rootFor`; a test may hand a smaller
--- table with one `rootPath`, and that root is the answer.
---@param server table
---@param uri string?
---@return string?
local function rootFor(server, uri)
	if server.rootFor then return server:rootFor(uri) end
	return server.rootPath
end

---@param root string
---@param path string
local function moduleName(root, path)
	local base = root:gsub("[/\\]+$", "")
	if path:sub(1, #base + 1) ~= base .. "/" then return nil end
	local relative = path:sub(#base + 2)
	if relative == "" then return nil end
	local name = (relative:gsub("%.lua$", ""):gsub("/init$", ""):gsub("[/\\]", "."))
	local pkg, rest = name:match("^packages%.([%w_%-]+)%.src%.(.+)$")
	if pkg then
		name = pkg .. "." .. rest
	elseif name:match("^src%.") then
		name = name:sub(5)
	end
	return name
end

--- A declared name with nowhere to put its metatable, so a layered view can fall through to the
--- next layer without copying the maps it reads.
---@param held table<string, boolean|lye.doc.Type>
---@param below table<string, boolean|lye.doc.Type>
---@return table<string, boolean|lye.doc.Type>
local function layer(held, below)
	---@param _ table
	---@param name string
	---@return boolean|lye.doc.Type?
	local function layerIndex(_, name)
		local value = held[name]
		if value ~= nil then return value end
		return below[name]
	end
	return setmetatable({}, { __index = layerIndex })
end

--- The workspace/package scans, the declaration view, module names and files, and the locations
--- of the types they name. Every table it populates on the server is the contract the analyzer and
--- the module cache read: `known`, `typeLocations`, `annotationsDigest`, `packageNames`,
--- `packageDigests`.
---@class lye.Declarations
---@field lye lye.Server
---@field open table<string, table<string, boolean|lye.doc.Type>> what each open document declares
---@field generation integer bumped whenever the layer a view is built from changes
---@field workspaceIndex lye.lsp.Index? the index of the first workspace root
---@field workspaceRoot string? the root that index was loaded for
---@field workspaceIndexes table<string, lye.lsp.Index> the index of every open workspace root
---@field knownByRoot table<string, table<string, boolean|lye.doc.Type>> what each root declares
---@field digestByRoot table<string, string> each root's annotation digest
---@field packageIndexes table<string, lye.lsp.Index> the loaded package index per root
---@field packageOrder string[] loaded package roots, least recently used first
---@field views table<string, { generation: integer, view: table<string, boolean|lye.doc.Type> }> the view per open document
---@field indexes { workspace: fun(root: string): lye.lsp.Index?, package: fun(root: string): lye.lsp.Index? }? injected for tests
---@field base fun(self: lye.Declarations, uri: string?): table<string, boolean|lye.doc.Type> the layers without open buffers
local Declarations = {}
Declarations.__index = Declarations

--- The module name a path has under a root, in the layout lde builds from. Exposed for a file
--- rename: the name a moved file answers to is the one its `require` strings have to become.
---@param root string
---@param path string
---@return string?
function Declarations:moduleNameFor(root, path)
	return moduleName(root, path)
end

---@param lye lye.Server
---@param indexes { workspace: fun(root: string): lye.lsp.Index?, package: fun(root: string): lye.lsp.Index? }?
function Declarations.new(lye, indexes)
	return setmetatable({
		lye = lye,
		open = {},
		generation = 0,
		packageIndexes = {},
		packageOrder = {},
		workspaceIndexes = {},
		knownByRoot = {},
		digestByRoot = {},
		views = {},
		indexes = indexes,
	}, Declarations)
end

--- A fresh index for a root. A test injects a factory that counts what is read; a session gets
--- the one the cache backs.
---@param kind "workspace"|"package"
---@param root string
---@return lye.lsp.Index
---@param self lye.Declarations
function Declarations:newIndex(kind, root)
	local provider = self.indexes and self.indexes[kind]
	local injected = provider and provider(root)
	if injected then return injected end
	return Index.new(kind == "package" and { kind = "package" } or {})
end

--- Merge where each loaded root writes its types. A name declared twice belongs to the first root
--- that has it: the workspace, then each package root in path order, so a load and a build of the
--- same session answer the same.
---@param self lye.Declarations
function Declarations:mergeLocations()
	local merged = {}
	---@param index lye.lsp.Index?
	local function add(index)
		if not index then return end
		for name, held in pairs(index:typeLocations()) do
			if merged[name] == nil then merged[name] = held end
		end
	end
	for _, index in pairs(self.workspaceIndexes) do add(index) end
	local roots = {}
	for root in pairs(self.packageIndexes) do roots[#roots + 1] = root end
	table.sort(roots)
	for _, root in ipairs(roots) do
		-- A root whose names were cleared is read again on the next `package` call; until then
		-- what its index still remembers was read from a disk that has moved on.
		local names = self.lye.packageNames
		if names and names[root] ~= nil then
			add(self.packageIndexes[root])
		end
	end
	self.lye.typeLocations = merged
end

--- Rebuild the one table the analyzer and the type lookups read from the loaded roots. A single
--- root is its own table; several are layered in the order the client opened them, so the first
--- declaration of a name wins without copying every name into a new map.
---@param self lye.Declarations
function Declarations:mergeKnown()
	local roots = {}
	for _, root in ipairs(self.lye.server.rootPaths or {}) do
		local held = self.knownByRoot[root]
		if held then roots[#roots + 1] = held end
	end
	for _, held in pairs(self.knownByRoot) do
		local listed = false
		for _, known in ipairs(roots) do
			if known == held then listed = true break end
		end
		if not listed then roots[#roots + 1] = held end
	end
	if #roots == 0 then
		self.lye.known = self.lye.known or {}
	elseif #roots == 1 then
		self.lye.known = roots[1]
	else
		self.lye.known = setmetatable({}, {
			__index = function(_, name)
				for _, held in ipairs(roots) do
					local value = held[name]
					if value ~= nil then return value end
				end
				return nil
			end,
		})
	end
	local digests = {}
	for root, digest in pairs(self.digestByRoot) do digests[#digests + 1] = root .. "\0" .. digest end
	table.sort(digests)
	self.lye.annotationsDigest = table.concat(digests, "\0")
end

--- Load one workspace root's entry, build and write it when there is none, and fill what the
--- session reads from it. A load that does not have to read anything is the warm start;
--- `lye.known` is set to nil by the watcher's full invalidation, and that rebuilds rather than
--- trusts.
---@param self lye.Declarations
---@param requested string? the root to read; the client's first root when nil
function Declarations:ensureWorkspace(requested)
	local lye = self.lye
	lye:useWorkspaceCache()
	local root = requested or lye.server.rootPath --[[@as string? ]]
	if not root or root == "" then
		lye.known = lye.known or {}
		return self.workspaceIndex
	end
	root = root:gsub("[/\\]+$", "")
	local index = self.workspaceIndexes[root]
	if index and lye.known and self.knownByRoot[root] then
		if root == lye.server.rootPath then self.workspaceIndex = index end
		return index
	end
	local started = timing.now()
	local rebuild = index ~= nil and lye.known == nil
	if not index then
		index = self:newIndex("workspace", root)
		self.workspaceIndexes[root] = index
		-- A new root brings a view that may have read the old set of roots; its own package
		-- entries are still this session's, so only the views are dropped.
		self.views = {}
	end
	if not self.workspaceIndex or root == lye.server.rootPath then
		self.workspaceIndex = index
		self.workspaceRoot = root
	end
	if rebuild then
		index:save(index:build(root, { kind = "workspace" }))
	else
		local entry = index:load(root, { kind = "workspace" })
		if not entry then index:save(index:build(root, { kind = "workspace" })) end
	end
	local stats = index:stats()
	timing.mark("workspace-scan", started, string.format(
		"files=%d built=%d loaded=%d reads=%d", stats.files, stats.built, stats.loaded, stats.reads))
	self.knownByRoot[root] = index:known()
	self.digestByRoot[root] = index:digest()
	self:mergeKnown()
	self.generation += 1
	self:mergeLocations()
	return index
end

--- The classes and aliases every file in the workspace declares, each resolved to the type it
--- stands for. Read once from the index: a warm session touches no source file.
---@param self lye.Declarations
function Declarations:workspace()
	local roots = self.lye.server.rootPaths or { self.lye.server.rootPath }
	for _, root in ipairs(roots) do
		if root then self:ensureWorkspace(root) end
	end
	local known = self.lye.known or {}
	self.lye.known = known
	return known
end

---@param root string
---@param self lye.Declarations
function Declarations:touchPackage(root)
	local order = self.packageOrder
	for index = #order, 1, -1 do
		if order[index] == root then table.remove(order, index) end
	end
	order[#order + 1] = root
	while #order > MAX_PACKAGES do
		local dropped = table.remove(order, 1)
		if dropped ~= root then
			self.packageIndexes[dropped] = nil
			local names, digests = self.lye.packageNames, self.lye.packageDigests
			if names then names[dropped] = nil end
			if digests then digests[dropped] = nil end
		end
	end
end

--- The classes and aliases the modules linked into a package's `target/` declare, resolved.
---
--- This is what a project laid out as several lde packages needs and a flat repository does not:
--- the modules a document can `require` are exactly the ones lde linked beside it, and a
--- dependency's classes are as real to it as its own. The entry is keyed by the links and the
--- contents behind them, so a changed link is a different answer and the workspace is untouched.
---@param root string the package root
---@return table<string, boolean|lye.doc.Type>
---@param self lye.Declarations
function Declarations:package(root)
	local lye = self.lye
	if not root then return {} end
	lye.packageNames = lye.packageNames or {}
	lye.packageDigests = lye.packageDigests or {}
	local held = lye.packageNames[root]
	if held ~= nil then
		self:touchPackage(root)
		return held
	end
	local started = timing.now()
	local index = self.packageIndexes[root]
	if index then
		-- The names were dropped by the watcher's full invalidation: the entry is read again
		-- rather than asked whether its metadata still looks the same.
		index:save(index:build(root, { kind = "package" }))
	else
		index = self:newIndex("package", root)
		self.packageIndexes[root] = index
		local entry = index:load(root, { kind = "package" })
		if not entry then index:save(index:build(root, { kind = "package" })) end
	end
	lye.packageNames[root] = index:known()
	lye.packageDigests[root] = index:linkDigest() or ""
	self:touchPackage(root)
	local stats = index:stats()
	timing.detail("package-scan", started, "files=%d built=%d loaded=%d reads=%d root=%s",
		stats.files, stats.built, stats.loaded, stats.reads, root)
	self.generation += 1
	self:mergeLocations()
	return lye.packageNames[root]
end

--- The modules a `require("...")` could name, in the layout the workspace uses. The listing is
--- the workspace index's file manifest, so a completion does not walk the tree a third time.
---@param prefix string what has been typed inside the quotes so far
---@param from string? the document the completion is for, which says which layout it uses
---@return { name: string, path: string?, detail: string? }[] a workspace file has a path, a module of the engine a detail
---@param self lye.Declarations
function Declarations:moduleNames(prefix, from)
	local root = from and rootFor(self.lye.server, from) or self.lye.server.rootPath
	---@cast root string?
	---@type { name: string, path: string?, detail: string? }[]
	local found = {}
	---@type table<string, boolean>
	local seen = {}
	---@param name string
	---@param path string?
	---@param detail string?
	local function addModule(name, path, detail)
		found[#found + 1] = { name = name, path = path, detail = detail }
	end
	-- A project lde built resolves through `<package>/target/`, and listing every file of the
	-- workspace beside it offers the same modules twice under names lde does not use. The target
	-- scan is the require plugin's job; here only the engine's own modules remain.
	local usesLde = from ~= nil and self.lye:packageRoot(from) ~= nil
	if not usesLde and root and root ~= "" then
		usesLde = fs.exists(root .. "/lde.json")
	end
	if root and root ~= "" and not usesLde then
		local index = self:ensureWorkspace(root)
		if index then
			for path in pairs(index:files()) do
				---@cast path string
				local name = moduleName(root, path)
				if name and name:sub(1, #prefix) == prefix and not seen[name] then
					seen[name] = true
					addModule(name, path, nil)
				end
			end
		end
	end

	-- The modules the engine ships are named the same way and are not files here, so they are
	-- listed from the definitions. A workspace module of the same name was added first and wins,
	-- which is the order `require` itself resolves in.
	for name in pairs(self.lye:definitionIndex().modules) do
		---@cast name string
		if name:sub(1, #prefix) == prefix and not seen[name] then
			seen[name] = true
			addModule(name, nil, "LuaJIT")
		end
	end

	table.sort(found, function(left, right) return left.name < right.name end)
	return found
end

--- The modules a `require("...")` could name, in the layout the workspace uses. The layouts
--- tried in turn: beside the root, under `src/`, and inside the package directory lde builds a
--- module from — `require("lye-doc.type")` is `packages/lye-doc/src/type.lua` there.
---@param name string
---@param from string? the document the require is written in
---@param self lye.Declarations
function Declarations:moduleFile(name, from)
	local root = from and rootFor(self.lye.server, from) or self.lye.server.rootPath

	-- A `lye.json` beside a package or workspace adds search paths of its own, in the shape
	-- `package.path` uses. Asked first, because a project that says where its modules are wins.
	for _, pattern in ipairs(self.lye:requirePaths(from)) do
		---@cast pattern string
		local path = pattern:gsub("%?", (name:gsub("%%.", "/")))
		local handle = io.open(path, "rb")
		if handle then
			handle:close()
			return path
		end
	end

	if root then
		local tail = (name:gsub("%.", "/"))
		local candidates = {
			root .. "/" .. tail .. ".lua",
			root .. "/" .. tail .. "/init.lua",
			root .. "/src/" .. tail .. ".lua",
		}
		local head, rest = name:match("^([%w_]+)%.(.+)$")
		if head then
			local under = (rest:gsub("%.", "/"))
			candidates[#candidates + 1] = root .. "/packages/" .. head .. "/src/" .. under .. ".lua"
			candidates[#candidates + 1] = root .. "/packages/" .. head .. "/src/" .. under .. "/init.lua"
		end

		-- What lde itself resolves against: `<package>/target/?.lua` and `<package>/target/?/init.lua`,
		-- where `target/` holds a link per dependency, so one rule answers a sibling and its own modules.
		local owner = self.lye:packageRoot(from)
		if owner then
			candidates[#candidates + 1] = owner .. "/target/" .. tail .. ".lua"
			candidates[#candidates + 1] = owner .. "/target/" .. tail .. "/init.lua"
		end

		for _, path in ipairs(candidates) do
			local handle = io.open(path, "rb")
			if handle then
				handle:close()
				return path
			end
		end
	end

	-- A module the engine ships is not a file in this workspace: `ffi`, `jit` and `string.buffer` name
	-- the definitions, whose text is written to the cache for a client to open. The workspace is first.
	local builtin = self.lye:definitionIndex().modules[name] --[[@as table? ]]
	if builtin then return builtin.path --[[@as string? ]] end
end

--- What a document is analysed against, as a cached view: what each open document declared, then
--- the document's own package, then the workspace. The layers are metatables, not copies — the
--- analyzer only indexes `elsewhere[text]`, and a view lives until the generation it was built for
--- changes.
---
--- Only an open document's view is kept: an editor asks about the same buffer again and again,
--- while a closed file's view is a cache entry nothing will ask for. A module URI reached through
--- `require` is answered and forgotten rather than accumulated for the session's lifetime.
---@param uri string? the document the names are for
---@param self lye.Declarations
function Declarations:view(uri)
	local key = uri or ""
	local cached = self.views[key]
	if cached and cached.generation == self.generation then return cached.view end
	local workspaceRoot = rootFor(self.lye.server, uri)
	self:ensureWorkspace(workspaceRoot)
	local top = (workspaceRoot and self.knownByRoot[workspaceRoot]) or {}
	local root = uri and self.lye:packageRoot(uri) --[[@as string? ]]
	if root then top = layer(self:package(root), top) end
	for _, declarations in pairs(self.open) do top = layer(declarations, top) end
	if uri and self.lye.server.documents and self.lye.server.documents:get(uri) then
		self.views[key] = { generation = self.generation, view = top }
	end
	return top
end

--- The declarations that do not come from an open buffer: the workspace, the document's package
--- and the definitions. A module's answer depends on the open buffers only for the names they
--- actually shadow, and this is the layer to compare against to find those.
---@param uri string?
---@return table<string, boolean|lye.doc.Type>
---@param self lye.Declarations
function Declarations:base(uri)
	local workspaceRoot = rootFor(self.lye.server, uri)
	self:ensureWorkspace(workspaceRoot)
	local top = (workspaceRoot and self.knownByRoot[workspaceRoot]) or {}
	local root = uri and self.lye:packageRoot(uri) --[[@as string? ]]
	if root then top = layer(self:package(root), top) end
	return top
end

--- A document has been analysed: its declarations are the open-document layer of every view, and
--- a view cached against the previous layer is no longer the answer.
---@param uri string
---@param declarations table<string, boolean|lye.doc.Type>
---@param self lye.Declarations
function Declarations:declared(uri, declarations)
	self.open[uri] = declarations
	self.generation += 1
end

--- A document's text moved on: drop its layer. The analysis that follows calls `declared` with the
--- declarations of the new text.
---@param uri string
---@param self lye.Declarations
function Declarations:documentChanged(uri)
	self.open[uri] = nil
	self.generation += 1
end

--- What every view was built from has changed, and nothing built so far is an answer about the
--- project on disk. The open documents keep their layers — they are still the text the editor
--- holds — but every cached view is dropped and the next one is built anew.
---@param self lye.Declarations
function Declarations:invalidate()
	self.generation += 1
	self.views = {}
end

--- The client changed the folders it has open. A root that left is dropped with what it declared;
--- one that arrived is read on the next view or symbol request.
---@param self lye.Declarations
---@param roots string[]
function Declarations:setRoots(roots)
	local keep = {}
	for _, root in ipairs(roots) do keep[root:gsub("[/\\]+$", "")] = true end
	for root in pairs(self.workspaceIndexes) do
		if not keep[root] then
			self.workspaceIndexes[root] = nil
			self.knownByRoot[root] = nil
			self.digestByRoot[root] = nil
		end
	end
	self.views = {}
	self.generation += 1
	self:mergeKnown()
	self:mergeLocations()
end

--- The document is closed: its layer went with `documentChanged`, and a view built while it was
--- open cannot stand in for one built without it.
---@param uri string
---@param self lye.Declarations
function Declarations:documentClosed(uri)
	self.open[uri] = nil
	self:invalidate()
end

---@param change table
local function pathOfChange(change)
	local uri = change.uri or change.path
	if type(uri) ~= "string" then return nil end
	if uri:sub(1, 7) == "file://" then return uri:sub(8) end
	return uri
end

--- Files changed on disk. A source file belongs to the workspace entry; a file under a loaded
--- package's `target/` belongs to that package's entry. Each event is read or dropped by the entry
--- it belongs to, and the session's tables are rebuilt from those entries. A source event also
--- invalidates every loaded package: a source file may be linked into several `target/`
--- directories, so none of their answers can be trusted until they are read again. `false` is the
--- one answer that says the whole workspace has to be read again and the module cache cleared.
---@param params table
---@return boolean
---@param self lye.Declarations
function Declarations:watchedFiles(params)
	local lye = self.lye
	local roots = lye.server.rootPaths or { lye.server.rootPath }
	if #roots == 0 then return false end
	local changes = type(params) == "table" and params.changes or nil
	if type(changes) ~= "table" then return false end

	-- Every event is attributed before anything is applied, so a partial update never stands in
	-- for an invalidation the caller was told to do.
	local sourceByRoot, packages = {}, {}
	for _, change in ipairs(changes) do
		if type(change) ~= "table" then return false end
		local path = pathOfChange(change)
		local kind = change.type
		if not path or (kind ~= 1 and kind ~= 2 and kind ~= 3) then return false end
		local root
		for _, candidate in ipairs(roots) do
			if candidate and candidate ~= ""
				and (path == candidate or path:sub(1, #candidate + 1) == candidate .. "/") then
				if not root or #candidate > #root then root = candidate end
			end
		end
		if not root or path == root then return false end
		local relative = path:sub(#root + 2)
		local packageRoot
		if relative:sub(1, 7) == "target/" then
			packageRoot = root
		else
			local prefix = relative:match("^(.-)/target/")
			if prefix then packageRoot = root .. "/" .. prefix end
		end
		local entry = { path = path, removed = kind == 3 }
		if packageRoot then
			if not self.packageIndexes[packageRoot] then return false end
			local list = packages[packageRoot]
			if not list then
				list = {}
				packages[packageRoot] = list
			end
			list[#list + 1] = entry
		else
			local list = sourceByRoot[root]
			if not list then
				list = {}
				sourceByRoot[root] = list
			end
			list[#list + 1] = entry
		end
	end

	for root, list in pairs(sourceByRoot) do
		local index = self.workspaceIndexes[root]
		if not index then return false end
		index:update(root, list, { kind = "workspace" })
		self.knownByRoot[root] = index:known()
		self.digestByRoot[root] = index:digest()
	end
	for packageRoot, list in pairs(packages) do
		self.packageIndexes[packageRoot]:update(packageRoot, list, { kind = "package" })
	end

	self:mergeKnown()
	lye.packageNames = lye.packageNames or {}
	lye.packageDigests = lye.packageDigests or {}

	if next(sourceByRoot) ~= nil then
		-- A source file can be linked into any number of packages' `target/`, so a package's
		-- answer may no longer be the one its links give. Every loaded root is cleared and read
		-- again by the next `package` call, and what a module resolved through those
		-- declarations is dropped with them.
		for packageRoot in pairs(self.packageIndexes) do
			lye.packageNames[packageRoot] = nil
			lye.packageDigests[packageRoot] = nil
		end
	end
	for packageRoot in pairs(packages) do
		local index = self.packageIndexes[packageRoot]
		lye.packageNames[packageRoot] = index:known()
		lye.packageDigests[packageRoot] = index:linkDigest() or ""
	end
	if next(sourceByRoot) ~= nil and lye.modules then lye.modules:clear() end
	-- Whatever a view was built from has moved: the workspace, a package, or both.
	self:invalidate()
	self:mergeLocations()
	return true
end

--- The class or alias a name stands for, with the lines that declare it: the comment above it,
--- its own line, and the fields written under it. The workspace is read for these when it is read
--- for anything else, so a type written in one file is answerable from another even when that
--- file's own analysis is not held. A builtin is read out of the definitions the same way.
---@param name string
---@param uri string? the document the question came from, which is read first
---@return { location: lye.DefinitionLocation, lines: string }?
---@param self lye.Declarations
function Declarations:typeLocation(name, uri)
	local lye = self.lye
	-- The document the cursor is in comes first: a class written in a buffer that was never saved
	-- is as real as one on disk, and the workspace scan has only read the disk.
	local names = uri and lye.names[uri]
	local annotations = names and names.doc and names.doc.annotations
	local text = uri and lye:textOf(uri)
	if annotations and text then
		---@cast annotations lye.doc.Annotation[]
		---@cast text string
		---@cast uri string
		for at, annotation in ipairs(annotations) do
			local isType = annotation.tag == "class" or annotation.tag == "alias"
			if isType and annotation.name == name then
				return {
					location = {
						uri = uri --[[@as string ]],
						start = annotation.nameStart or annotation.start,
						stop = annotation.nameStop or annotation.stop,
					},
					lines = declarationLines(text --[[@as string ]], annotations, at),
				}
			end
		end
	end

	-- The index is only read when the workspace has been asked for something; a lookup that the
	-- open document answered must not pay for the scan.
	local held = lye.typeLocations and lye.typeLocations[name]
	if held then return held end

	local index = lye:definitionIndex() --[[@as lye.Definitions ]]
	local found = definitionsIndex.find(index, name)
	if not found then return nil end
	local source = definitionsIndex.sourceOf(index, found.uri)
	if not source then return nil end

	local lines = { lineAt(source, lineStart(source, found.start)) }
	local fields = {}
	for fieldName, where in pairs(index.fields) do
		---@cast fieldName string
		---@cast where lye.DefinitionLocation
		if fieldName:sub(1, #name + 1) == name .. "." then fields[#fields + 1] = where end
	end
	table.sort(fields, function(left, right) return left.start < right.start end)
	for _, where in ipairs(fields) do
		lines[#lines + 1] = lineAt(source, lineStart(source, where.start))
	end
	return { location = found, lines = table.concat(lines, "\n") }
end

--- The class or alias a name declares: in this document, in another the server has analysed, or in
--- the definitions — which is where the builtin types live.
---@param name string
---@param uri string
---@return lye.DefinitionLocation?
---@param self lye.Declarations
function Declarations:targetOfType(name, uri)
	local lye = self.lye
	---@param documentUri string
	---@param names lye.analyzer.Result?
	local function inDocument(documentUri, names)
		for _, annotation in ipairs(names and names.doc and names.doc.annotations or {}) do
			local isType = annotation.tag == "class" or annotation.tag == "alias"
			if isType and annotation.name == name then
				return {
					uri = documentUri,
					start = annotation.nameStart or annotation.start,
					stop = annotation.nameStop or annotation.stop,
				}
			end
		end
	end

	local indexed = lye.typeLocations and lye.typeLocations[name]
	if indexed then return indexed.location end

	local mine = inDocument(uri, lye.names[uri])
	if mine then return mine end
	for otherUri, names in pairs(lye.names) do
		---@cast otherUri string
		---@cast names lye.analyzer.Result
		if otherUri ~= uri then
			local found = inDocument(otherUri, names)
			if found then return found end
		end
	end
	return definitionsIndex.find(lye:definitionIndex() --[[@as lye.Definitions ]], name)
end

--- What the scans and the view hold, for `LYE_TIMING=1`. `index` is the time spent reading and
--- validating entries; the rest are counts across the workspace and every loaded package, with
--- `workers` the processes the builds used and `fellBack` the shards a failed child left behind.
---@return table
---@param self lye.Declarations
function Declarations:stats()
	local lye = self.lye
	local known, packages = 0, 0
	for _, held in pairs(self.knownByRoot) do
		for _ in pairs(held) do known += 1 end
	end
	if lye.packageNames then for _ in pairs(lye.packageNames) do packages += 1 end end
	local locations = 0
	if lye.typeLocations then for _ in pairs(lye.typeLocations) do locations += 1 end end
	local open = 0
	for _ in pairs(self.open) do open += 1 end
	local built, loaded, files, reads, spent = 0, 0, 0, 0, 0
	local workers, fellBack = 0, 0
	---@param index lye.lsp.Index?
	local function add(index)
		if not index then return end
		local held = index:stats()
		built += held.built
		loaded += held.loaded
		files += held.files
		reads += held.reads
		spent += held.index
		workers += held.workers or 0
		fellBack += held.fellBack or 0
	end
	for _, index in pairs(self.workspaceIndexes) do add(index) end
	for _, index in pairs(self.packageIndexes) do add(index) end
	return {
		known = known,
		locations = locations,
		packages = packages,
		open = open,
		generation = self.generation,
		index = spent,
		built = built,
		loaded = loaded,
		files = files,
		reads = reads,
		workers = workers,
		fellBack = fellBack,
	}
end

return Declarations
