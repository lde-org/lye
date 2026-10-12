

local report = require("lye-lsp.report")
local doc = require("lye-doc")
local classes = require("lye-doc.class")
local analyzer = require("lye-analyzer")
local position = require("lye-framework.position")
local fs = require("fs")
local rapidhash = require("rapidhash")
local env = require("env")
local parallel = require("lye-lsp.parallel")

local check = {}

--- The LuaJIT definitions, prepared once, so a headless check sees the same standard library an
--- editor session does.
local PRELUDE = analyzer.prelude(require("lye-defs"))

-- What each piece of text came to, by its own text. lde links or copies one file into every
-- package's `target/`, so a run of the check meets the same module under many names — the source
-- and the link beside it, and the link in each package that depends on it. Analysing each name
-- again reports its errors once per name and pays for it once per name, which is most of the bill
-- on a package-heavy project. The key is the text rather than the path because the text is what an
-- analysis is about; rapidhash reads a megabyte in well under a millisecond, and the same file is
-- asked for a dozen times here.
local analysesByText = {}
local docsByText = {}

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
--- modules were built.
---@param path string
---@return string?
local function packageOf(path)
	local at = path:match("^(.*)/[^/]+$")
	while at and at ~= "" and at ~= "/" do
		if fs.exists(at .. "/lde.json") then return at end
		at = at:match("^(.*)/[^/]+$")
	end
end

--- The names the modules linked into a package's `target/` declare. A dependency's class is as
--- real to a file as its own package's, and a check that only knew the files it was handed reported
--- every `clap.Args` and `process.Child` as a type nothing declares — which is what the editor,
--- reading the same `target/`, does not.
---@param root string the package root
---@param cache table<string, table<string, boolean|lye.doc.Type>>
local function linkedDeclarations(root, cache)
	local held = cache[root]
	if held then return held end
	local found = {}
	local target = absolute(root) .. "/target"
	if fs.isdir(target) then
		-- A link farm holds the same file under every package that depends on it, so the walk
		-- stops at the cap rather than reading the closure of every closure.
		local parsedFiles = {}
		for file in fs.scan(target, "**/*.lua", { absolute = true, followSymlinks = true, ignore = ignored }) do
			if #parsedFiles >= 2000 then break end
			local source = readSource(file)
			if type(source) == "string" then
				local key = textKey(source)
				local parsed = docsByText[key]
				if parsed == nil then
					local isOk, one = pcall(doc.parse, source)
					if isOk then docsByText[key] = one end
					parsed = isOk and one or nil
				end
				if parsed then parsedFiles[#parsedFiles + 1] = parsed end
			end
		end
		-- What each name means, resolved once for the whole package: a dependency's alias is as
		-- real to a reader as its own, and a bare name refuses every argument made of it.
		found = classes.declare(parsedFiles)
	end
	cache[root] = found
	return found
end

--- The type `require("name")` has in `path`: lde links every module a package can reach under its
--- `target/`, so one rule answers a dependency and a sibling alike. `ffi` and the rest of the
--- engine's modules are named in the definitions rather than in a file, and come from there.
---@param path string the file the require is written in
---@param name string
---@param modules table<string, { type: lye.doc.Type? }> what each module came to, by the text it was read from
---@param analysing table<string, boolean> the modules being read, so a cycle ends
---@param elsewhere table<string, boolean|lye.doc.Type>? what the batch declares
---@return lye.doc.Type?
local function moduleOf(path, name, modules, analysing, elsewhere)
	local owner = packageOf(path)
	if not owner then return nil end
	local base = absolute(owner)
	local tail = (name:gsub("%.", "/"))
	local found
	for _, candidate in ipairs({
		base .. "/target/" .. tail .. ".lua",
		base .. "/target/" .. tail .. "/init.lua",
	}) do
		if fs.exists(candidate) then
			found = candidate
			break
		end
	end
	if not found then return nil end

	local written = readSource(found)
	if type(written) ~= "string" then return nil end
	local key = textKey(written)

	-- What the module came to is kept, including when it came to nothing: a package that requires
	-- another is read once for the whole run rather than once per file that names it — and the
	-- same file reached through another package's link, or as one of the files being checked, is
	-- the same module and is not read again either.
	local cached = modules[key]
	if cached then return cached.type end
	-- A module that requires its way back here says nothing rather than being read again.
	if analysing[key] then return nil end

	-- The module's own `require`s resolve within its package, so it is read with a resolver of its
	-- own — and the analysis is the one the editor would do, definitions and all.
	analysing[key] = true
	local names = analysesByText[key]
	if names == nil then
		-- Read against what the batch declares as well: a signature written with a class or an
		-- alias another file declares is otherwise an unresolved name, and every caller is then
		-- refused against a type that has no meaning outside the file it was written in.
		names = analyzer.analyze(written, PRELUDE, elsewhere, function(inner)
			return moduleOf(found, inner, modules, analysing, elsewhere)
		end, nil, docsByText[key])
		analysesByText[key] = names
	end
	analysing[key] = nil
	modules[key] = { type = names.module }
	return names.module
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
local function checkSource(path, elsewhere, modules, reporter, scopes, source, key, isRead)
	reporter = reporter or report.new()
	-- A name the package's linked modules declare is not a typo, so the file is read against them
	-- as well as against the batch. Merged once per package rather than once per file.
	local owner = packageOf(path)
	if owner then
		local known = scopes or {}
		local scope = known[owner]
		if not scope then
			-- What each name means, not only that it exists: an alias is carried as the type it
			-- stands for, and copying the keys alone left every one of them a bare name again —
			-- which is what made `pairs(depInfo)` refuse a dependency's own dependency union.
			scope = {}
			for name, held in pairs(elsewhere or {}) do scope[name] = held end
			for name, held in pairs(linkedDeclarations(owner, known)) do scope[name] = held end
			known[owner] = scope
		end
		elsewhere = scope
	end
	if not isRead then source = readSource(path) end
	-- A directory reads as nothing and `--check` is pointed at folders all the time: say so
	-- instead of handing the parser nothing to work with.
	if type(source) ~= "string" then
		return nil, string.format("%s: not a readable file", path)
	end
	key = key or textKey(source)

	local index

	-- Annotation type errors belong in the same report as syntax errors, so a declaration
	-- contradicting its `---@type` fails the check.
	-- This file counts as being read: a module it requires that requires it back would otherwise
	-- be followed for as long as the stack lasts, which is the whole run for a package cycle.
	local analysing = { [key] = true }
	local names = analysesByText[key]
	if names == nil then
		names = analyzer.analyze(source, PRELUDE, elsewhere, function(name)
			return moduleOf(path, name, modules or {}, analysing, elsewhere)
		end, nil, docsByText[key])
		analysesByText[key] = names
	end
	-- The analysis parsed the file already: its own parse carries the syntax errors, so a file is
	-- read by the parser once per check rather than twice.
	local all = {}
	local parsed = names.parser
	for _, entry in ipairs(parsed and parsed.diagnostics or {}) do all[#all + 1] = entry end
	for _, entry in ipairs(names.diagnostics) do all[#all + 1] = entry end
	table.sort(all, function(a, b) return a.start < b.start end)

	local failed = false
	for _, entry in ipairs(all) do
		-- Byte offsets mean nothing to a human reading a terminal, so report 1-based
		-- line and column here. This is the one place that wants them.
		index = index or position.buildLineIndex(source)
		local line, character = position.toPosition(source, index, entry.start, position.UTF8)
		report.diagnostic(reporter, path, line + 1, character + 1, entry.severity, entry.message)
		-- An unused local is a hint, and a build step that fails on one is a build step nobody
		-- keeps: it is printed and it does not decide the exit code.
		-- A parser diagnostic carries no severity: a syntax error is the loudest thing there is.
		if entry.severity == nil or entry.severity <= 2 then failed = true end
	end
	return not failed
end

---@param path string
---@param elsewhere table<string, boolean|lye.doc.Type>?
---@param modules table<string, { type: lye.doc.Type? }>?
---@param reporter lye.Report?
---@param scopes table<string, table<string, boolean|lye.doc.Type>>?
function check.file(path, elsewhere, modules, reporter, scopes)
	return checkSource(path, elsewhere, modules, reporter, scopes, nil, nil, false)
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

--- Every Lua file under `root`, which is what a check with no paths named checks.
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
	for path in fs.scan(base, "**/*.lua", { ignore = ignored }) do
		found[#found + 1] = prefix .. path
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
	local parsedFiles = {}
	local sourcesByPath, keysByPath = {}, {}
	for _, path in ipairs(paths) do
		local source = readSource(path)
		sourcesByPath[path] = source
		if type(source) == "string" then
			local key = textKey(source)
			keysByPath[path] = key
			local parsed = docsByText[key]
			if parsed == nil then
				local isOk, one = pcall(doc.parse, source)
				parsed = isOk and one or false
				docsByText[key] = parsed
			end
			if parsed then parsedFiles[#parsedFiles + 1] = parsed end
		end
	end
	-- What each name stands for, not only that it exists: a parameter declared with an alias
	-- another file writes is checked against what the alias means, and a name on its own refuses
	-- every argument handed to it.
	local declared = classes.declare(parsedFiles)

	reporter = reporter or report.new()

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
			local group = { files = {}, bytes = 0 }
			groups[#groups + 1] = group
			current = group
		end
		current.files[#current.files + 1] = path
		current.bytes += #(sourcesByPath[path] or "")
	end

	---@param files string[]
	---@param collector lye.Collector
	local function checkSlice(files, collector)
		local modules, scopes = {}, {}
		for _, path in ipairs(files) do
			local passed, err = checkSource(path, declared, modules, collector, scopes,
				sourcesByPath[path], keysByPath[path], true)
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
