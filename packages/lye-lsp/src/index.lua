--[[
	The declarations of a root's files, kept between runs.

	Every file of a workspace is comment-lexed for its annotations and the classes and aliases it
	declares, once, and the answer is written as one cache entry: the annotations of each file, the
	locations and declaration lines of the types it writes, and the namespace they resolve to. A
	later session reads that entry instead of reading every source file, and asks each file's
	metadata — size and modification time — whether its part of the answer is still its own. Only a
	file whose metadata moved is read again.

	Nothing read from an entry is code, and an entry that is missing, corrupt, older than the schema
	or written by other code is a miss rather than an error: the caller builds the index again.

	A package root gets an entry of the same shape for the files linked into its `target/`: what a
	document there can `require`. It depends on those links and their contents alone, never on the
	workspace entry.
]]

local fs = require("fs")
local ffi = require("ffi")
local rapidhash = require("rapidhash")
local doc = require("lye-doc")
local classes = require("lye-doc.class")
local serial = require("lye-doc.serial")
local cache = require("lye-lsp.cache")
local parallel = require("lye-lsp.parallel")
local timing = require("lye-lsp.timing")

-- The shape of an entry. A reader of another one rebuilds rather than guesses.
local SCHEMA = 2

-- A cold build of fewer files than this is cheaper in one process: the fork and the record file
-- cost more than a handful of comment lexes.
local MIN_PARALLEL_FILES = 64

-- And a build of small files is cheaper in one process however many there are: the processes and
-- the record files cost a few tens of milliseconds, which only enough source behind them can earn
-- back. Measured cold: 4 MiB of source is ~46 ms serial against ~42 ms split, 8 MiB ~58 against
-- ~48, 16 MiB ~79 against ~65, while this repository's 108 small files are ~105 ms either way.
local MIN_PARALLEL_BYTES = 4 * 1024 * 1024

-- More processes than this do not make one disk's files read faster.
local MAX_WORKERS = 8

-- More than this share of a root's files changing in one go makes a rebuild cheaper than editing
-- the entry file by file. At least one changed file is always an update: a three-file root where
-- two files changed is a rebuild, but one changed file is not.
local REBUILD_SHARE = 0.1

local sep = string.sub(package.config, 1, 1)

---@class lye.lsp.IndexAnnotation
---@field tag string
---@field name string?
---@field text string?
---@field type string?
---@field typeText string?
---@field start integer
---@field stop integer
---@field typeStart integer?
---@field typeStop integer?
---@field nameStart integer?
---@field nameStop integer?

---@class lye.lsp.IndexLocation
---@field uri string
---@field start integer
---@field stop integer

---@class lye.lsp.IndexType
---@field location lye.lsp.IndexLocation
---@field lines string

---@class lye.lsp.IndexFile
---@field hash string
---@field size integer
---@field mtime number
---@field isDefinition boolean
---@field annotations lye.lsp.IndexAnnotation[]
---@field types table<string, lye.lsp.IndexType>

---@class lye.lsp.IndexEntry
---@field schema integer
---@field root string
---@field codeVersion string
---@field annotationsDigest string
---@field linkDigest string? the files and their hashes, for a package entry
---@field files table<string, lye.lsp.IndexFile>
---@field known table<string, boolean|lye.doc.Type>? each name the root declares, resolved

---@class lye.lsp.IndexOptions
---@field kind "workspace"|"package"? what a root is when a call does not say
---@field read fun(path: string): string? the source of a file, injectable for counting
---@field stat fun(path: string): fs.Stat? the metadata of a file
---@field log fun(note: string)? where a cap is reported instead of stderr
---@field max integer? how many files to index at most
---@field parallel boolean? false makes every build serial, whatever the file count
---@field canFork boolean? whether a build may fork; by default the platform and `parallel` decide
---@field workers integer? how many processes a build may use
---@field minBytes integer? the source bytes below which a build stays serial; 0 forks on file count alone
---@field fork fun(): integer? process creation, injectable for a test that counts or refuses it
---@field onShard fun(slice: lye.parallel.Slice, index: integer): string? a test hook
--- "fail" makes a child end without a record; "short" makes it write one that does not read.

---@class lye.lsp.Index
---@field options lye.lsp.IndexOptions
---@field kind_ "workspace"|"package"
---@field read fun(path: string): string?
---@field stat fun(path: string): fs.Stat?
---@field entry_ lye.lsp.IndexEntry? the entry last adopted
---@field typeLocations_ table<string, lye.lsp.IndexType>? where each type the entry declares is written
---@field stats_ { index: number, built: integer, loaded: integer, files: integer, reads: integer, workers: integer, fellBack: integer }
local Index = {}
Index.__index = Index
Index.SCHEMA = SCHEMA

--- A root as a key and an entry name it: no trailing separator, so two spellings of one directory
--- share one entry.
---@param root string
local function normalize(root)
	local trimmed = root:gsub("[/\\]+$", "")
	return trimmed == "" and root or trimmed
end

---@param name string
local function isHidden(name)
	return name:sub(1, 1) == "."
end

--- Whether a file's entry still describes it: size and modification time are what a stat says
--- without reading the text, which is the whole cost the load is avoiding.
---@param record lye.lsp.IndexFile
---@param held fs.Stat
local function isCurrent(record, held)
	return record.size == tonumber(held.size) and record.mtime == tonumber(held.modifyTime)
end

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

--- The lines that declare a class or an alias: the comment above it, its own line, and the fields
--- written under it. The annotation above the comment is another type's business.
---@param source string
---@param annotations lye.doc.Annotation[]
---@param at integer
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

--- Where each class or alias of one file is written, with the lines that declare it. The first
--- file to declare a name is the one the root answers with, and the files are read in path order
--- so a build and a load of the same tree answer the same.
---@param into table<string, lye.lsp.IndexType>
---@param path string
---@param source string
---@param annotations lye.doc.Annotation[]
local function collectTypes(into, path, source, annotations)
	for index, annotation in ipairs(annotations) do
		local isType = annotation.tag == "class" or annotation.tag == "alias"
		if isType and annotation.name and not into[annotation.name] then
			into[annotation.name] = {
				location = {
					uri = "file://" .. path,
					start = annotation.nameStart or annotation.start,
					stop = annotation.nameStop or annotation.stop,
				},
				lines = declarationLines(source, annotations, index),
			}
		end
	end
end

---@param entry lye.lsp.IndexEntry
---@return string[]
local function pathsOf(entry)
	local paths = {}
	for path in pairs(entry.files) do paths[#paths + 1] = path end
	table.sort(paths)
	return paths
end

--- The digest of what every file declares: the same parts, in the same order, the cold scan
--- computed, so a module read against this workspace is only reused for a workspace that declares
--- the same things.
---@param entry lye.lsp.IndexEntry
local function digestOf(entry)
	local parts = {}
	for _, path in ipairs(pathsOf(entry)) do
		for _, annotation in ipairs(entry.files[path].annotations) do
			parts[#parts + 1] = annotation.tag .. "\0" .. (annotation.name or "") .. "\0"
				.. (annotation.text or "") .. "\0" .. (annotation.type or "")
		end
	end
	return rapidhash.hex(table.concat(parts, "\1"))
end

--- What a package's links are: each path and the hash of the text behind it. A module cache keys
--- on this, so a change to any linked file is a different set of links.
---@param entry lye.lsp.IndexEntry
local function linkDigestOf(entry)
	local parts = {}
	for _, path in ipairs(pathsOf(entry)) do
		parts[#parts + 1] = path .. "\0" .. entry.files[path].hash
	end
	return rapidhash.hex(table.concat(parts, "\1"))
end

---@param entry lye.lsp.IndexEntry
local function knownOf(entry)
	local files = {} ---@type lye.doc.File[]
	for _, path in ipairs(pathsOf(entry)) do
		files[#files + 1] = {
			annotations = entry.files[path].annotations --[[@as lye.doc.Annotation[] ]],
		}
	end
	return classes.declare(files)
end

---@param entry lye.lsp.IndexEntry
local function typesOf(entry)
	local into = {}
	for _, path in ipairs(pathsOf(entry)) do
		for name, held in pairs(entry.files[path].types) do
			if into[name] == nil then into[name] = held end
		end
	end
	return into
end

---@param entry table?
---@param root string
---@return boolean
local function isValidEntry(entry, root)
	if type(entry) ~= "table" then return false end
	local raw = entry --[[@as table ]]
	if raw.schema ~= SCHEMA then return false end
	if raw.root ~= root then return false end
	if raw.codeVersion ~= cache.codeVersion() then return false end
	if type(raw.annotationsDigest) ~= "string" then return false end
	if raw.linkDigest ~= nil and type(raw.linkDigest) ~= "string" then return false end
	if raw.known ~= nil and type(raw.known) ~= "table" then return false end
	local files = raw.files
	if type(files) ~= "table" then return false end
	for path, record in pairs(files) do
		---@cast path string
		local held = record --[[@as table ]]
		if type(path) ~= "string" or type(held) ~= "table" then return false end
		if type(held.hash) ~= "string" then return false end
		if type(held.size) ~= "number" or type(held.mtime) ~= "number" then return false end
		if type(held.annotations) ~= "table" or type(held.types) ~= "table" then return false end
		if held.isDefinition ~= nil and type(held.isDefinition) ~= "boolean" then return false end
	end
	return true
end

--- The unit a file is grouped into when a build is split: the package it belongs to, so a
--- package's files stay in one process, or the directory it is written in. A group is not a
--- correctness boundary — one file's record does not depend on another's — only what keeps a
--- split from cutting a package across processes.
---@param root string
---@param path string
local function packageOf(root, path)
	local prefix = root .. "/"
	if path:sub(1, #prefix) ~= prefix then return root end
	local relative = path:sub(#prefix + 1)
	local pkg = relative:match("^packages/([^/]+)/")
	if pkg then return root .. "/packages/" .. pkg end
	local dir = relative:match("^(.*)/[^/]+$")
	if dir then return root .. "/" .. dir end
	return root
end

--- How many bytes each file is, from its metadata alone, and the root's total. A build that stays
--- serial pays for no stat it did not already need; one that may split needs the bytes to decide
--- whether the split can pay for itself.
---@param paths string[]
---@param stat fun(path: string): fs.Stat?
---@return table<string, integer> sizes
---@return integer bytes
local function sizesOf(paths, stat)
	local sizes, bytes = {}, 0
	for _, path in ipairs(paths) do
		local held = stat(path)
		local size = held and tonumber(held.size) or 0
		sizes[path] = size
		bytes += size
	end
	return sizes, bytes
end

--- The groups a build is split across, each with the bytes its files are so the split is by cost
--- and not only by count.
---@param root string
---@param paths string[]
---@param sizes table<string, integer>
local function groupsOf(root, paths, sizes)
	local groups = {}
	---@cast groups lye.parallel.Group[]
	local at = {}
	---@cast at table<string, lye.parallel.Group>
	for _, path in ipairs(paths) do
		local owner = packageOf(root, path)
		local group = at[owner]
		if not group then
			group = { files = {}, sizes = {}, bytes = 0 }
			at[owner] = group
			groups[#groups + 1] = group
		end
		local size = sizes[path] or 0
		group.files[#group.files + 1] = path
		group.sizes[#group.sizes + 1] = size
		group.bytes += size
	end
	return groups
end

--- Where a forked shard writes its records: the cache's own directory when there is one, a
--- temporary one when `LYE_CACHE=off`, so a run that keeps no cache leaves nothing behind.
---@return string
local function recordDirectory()
	local dir
	if cache.enabled() then
		dir = cache.root() .. "/index-records"
	else
		dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/lye-index-records"
	end
	fs.mkdirAll(dir)
	return dir
end

--- One shard's records in one file, written by the same serialiser the cache uses. The paths the
--- shard was handed travel with them, so a parent can tell a short record from a file that could
--- not be read.
---@param slice lye.parallel.Slice
---@param files table<string, lye.lsp.IndexFile>
---@param reads integer
local function writeShard(slice, files, reads)
	local text = serial.write({ files = files, paths = slice.files, reads = reads })
	if not text then return false end
	return cache.writeWhole(slice.out, text)
end

--- Read and validate one shard's records. Anything that is not exactly the shard that was handed
--- out — missing, truncated, of another shape or about other files — is no record at all.
---@param slice lye.parallel.Slice
---@return { files: table<string, lye.lsp.IndexFile>, reads: integer }?
local function readShard(slice)
	local text = fs.read(slice.out)
	os.remove(slice.out)
	if type(text) ~= "string" then return nil end
	local isOk, value = pcall(serial.read, text)
	if not isOk or type(value) ~= "table" or type(value.files) ~= "table" then return nil end
	local listed = value.paths
	if type(listed) ~= "table" or #listed ~= #slice.files then return nil end
	for index, path in ipairs(slice.files) do
		if listed[index] ~= path then return nil end
	end
	for path, record in pairs(value.files) do
		if type(path) ~= "string" or type(record) ~= "table" or type(record.hash) ~= "string" then
			return nil
		end
	end
	return value
end

---@param entry lye.lsp.IndexEntry
---@return integer
local function countFiles(entry)
	local count = 0
	for _ in pairs(entry.files) do count += 1 end
	return count
end

---@param options lye.lsp.IndexOptions?
function Index.new(options)
	options = options or {}
	return setmetatable({
		options = options,
		kind_ = options.kind or "workspace",
		read = options.read or fs.read,
		stat = options.stat or fs.stat,
		stats_ = { index = 0, built = 0, loaded = 0, files = 0, reads = 0, workers = 0, fellBack = 0 },
	}, Index)
end

--- A cap the caller asked for is said out loud, with what it left behind, rather than silently
--- trimming what the root declares.
---@param note string
---@param self lye.lsp.Index
function Index:notice(note)
	local log = self.options.log
	if log then
		log(note)
		return
	end
	io.stderr:write("lye index: " .. note .. "\n")
	io.stderr:flush()
end

--- The key an entry for `root` is written under. A package entry names its kind, so a workspace
--- index and a package index of the same directory do not overwrite each other.
---@param root string
---@param kind "workspace"|"package"?
---@param self lye.lsp.Index
function Index:key(root, kind)
	root = normalize(root)
	if (kind or self.kind_) == "package" then
		return cache.key("index", tostring(SCHEMA), "package", root, cache.codeVersion())
	end
	return cache.key("index", tostring(SCHEMA), root, cache.codeVersion())
end

---@param opts { max: integer? }?
---@param self lye.lsp.Index
function Index:cap(opts)
	local max = (opts and opts.max) or self.options.max
	if max and max > 0 then return math.floor(max) end
	local set = tonumber(os.getenv("LYE_INDEX_MAX_FILES") or "")
	if set and set > 0 then return math.floor(set) end
	return nil
end

--- The Lua files of a root, in path order. A workspace leaves out `target/` — it mirrors other
--- packages and would be walked many times over — and a name beginning with `.` is a directory no
--- walk enters and not a module the workspace reads.
---@param root string
---@param kind "workspace"|"package"
---@param max integer?
---@param self lye.lsp.Index
function Index:scan(root, kind, max)
	local dir = kind == "package" and (root .. sep .. "target") or root
	local paths = {} ---@type string[]
	if not fs.isdir(dir) then return paths end
	---@param name string
	local function workspaceIgnore(name) return isHidden(name) or name == "target" end
	local ignore = kind == "package" and isHidden or workspaceIgnore
	for path in fs.scan(dir, "**/*.lua", {
		absolute = true,
		followSymlinks = kind == "package",
		ignore = ignore,
	}) do
		---@cast path string
		paths[#paths + 1] = path
	end
	table.sort(paths)
	if max and #paths > max then
		local found = #paths
		for index = #paths, max + 1, -1 do paths[index] = nil end
		self:notice(string.format("cap %d files, %d found, %d left unindexed under %s", max, found,
			found - max, dir))
	end
	return paths
end

--- Read and comment-lex one file: its hash and metadata, what it annotates, where its classes and
--- aliases are written. The source is dropped before the next file is read.
---@param path string
---@return lye.lsp.IndexFile?
---@param self lye.lsp.Index
function Index:record(path)
	local source = self.read(path)
	if type(source) ~= "string" then return nil end
	self.stats_.reads += 1
	local isOk, parsed = pcall(doc.parse, source)
	local record = { hash = rapidhash.hex(source), annotations = {}, types = {} }
	if isOk then
		---@cast parsed lye.doc.File
		record.isDefinition = parsed.isDefinition
		for _, annotation in ipairs(parsed.annotations) do
			record.annotations[#record.annotations + 1] = {
				tag = annotation.tag,
				name = annotation.name,
				text = annotation.text,
				type = annotation.type,
				typeText = annotation.typeText,
				start = annotation.start,
				stop = annotation.stop,
				typeStart = annotation.typeStart,
				typeStop = annotation.typeStop,
				nameStart = annotation.nameStart,
				nameStop = annotation.nameStop,
			}
		end
		collectTypes(record.types, path, source, parsed.annotations)
	end
	local held = self.stat(path)
	-- A stat's fields are integers, which on this runtime are cdata: the cache writes numbers.
	record.size = held and tonumber(held.size) or #source
	record.mtime = held and tonumber(held.modifyTime) or 0
	record.isDefinition = record.isDefinition == true
	return record
end

---@param entry lye.lsp.IndexEntry
---@param self lye.lsp.Index
function Index:adopt(entry)
	self.entry_ = entry
	self.typeLocations_ = typesOf(entry)
	if type(entry.known) ~= "table" then entry.known = knownOf(entry) end
	local files = 0
	for _ in pairs(entry.files) do files += 1 end
	self.stats_.files = files
end

--- The least source a build must hold for a split to be worth it. `minBytes = 0` in a test or a
--- benchmark forks on file count alone, and so does `LYE_INDEX_PARALLEL=1` — the escape hatch for a
--- workspace where this measurement does not hold.
---@param opts lye.lsp.IndexOptions
---@param self lye.lsp.Index
function Index:parallelBytes(opts)
	local least = opts.minBytes
	if least == nil then least = self.options.minBytes end
	if least ~= nil then return math.max(least, 0) end
	local set = os.getenv("LYE_INDEX_PARALLEL")
	if set == "1" or set == "on" then return 0 end
	return MIN_PARALLEL_BYTES
end

--- Whether a build of this root should be split across processes: enough files and enough source
--- behind them for the fork to pay for itself, a machine that has `fork`, and nothing that said no.
--- `LYE_INDEX_PARALLEL=0` forces one process, `=1` forks on file count alone, and unset follows the
--- measured byte gate.
---@param paths string[]
---@param opts lye.lsp.IndexOptions
---@return boolean wanted whether the build should be split
---@return table<string, integer>? sizes the bytes each file is, given along with a yes
---@param self lye.lsp.Index
function Index:parallelWanted(paths, opts)
	local wanted = opts.parallel
	if wanted == nil then wanted = self.options.parallel end
	if wanted == false then return false end
	local set = os.getenv("LYE_INDEX_PARALLEL")
	if set == "0" or set == "off" then return false end
	if #paths < MIN_PARALLEL_FILES then return false end
	local canFork = opts.canFork
	if canFork == nil then canFork = self.options.canFork end
	if canFork == nil then canFork = ffi.os ~= "Windows" and parallel.canFork() end
	if canFork ~= true then return false end
	-- Statting every file is the one thing a build that stays serial must not pay for, so the
	-- bytes are only asked for once the cheap gates have said the split is at least possible.
	local sizes, bytes = sizesOf(paths, self.stat)
	if bytes < self:parallelBytes(opts) then return false end
	return true, sizes
end

--- How many processes a build of this many files may use.
---@param paths string[]
---@param opts lye.lsp.IndexOptions
---@param self lye.lsp.Index
function Index:parallelWorkers(paths, opts)
	local wanted = opts.workers or self.options.workers
	if wanted and wanted >= 1 then
		return math.max(1, math.min(math.floor(wanted), MAX_WORKERS, #paths))
	end
	return math.max(1, math.min(parallel.cores(), MAX_WORKERS, #paths))
end

--- Work one shard: read its files and write their records where the parent reads them. The same
--- function runs in a child and in this process, so a shard a child abandoned is simply done
--- again. A test hook may make a child fail before it writes, or write a short record and claim
--- success, which is the two ways a shard can be lost.
---@param slice lye.parallel.Slice
---@param index integer
---@param isChild boolean
---@param hook fun(slice: lye.parallel.Slice, index: integer): string?
---@param self lye.lsp.Index
function Index:workShard(slice, index, isChild, hook)
	if isChild and hook then
		local mode = hook(slice, index)
		if mode == "fail" then return false end
		if mode == "short" then return cache.writeWhole(slice.out, "LYE1short") end
	end
	local files, reads = {}, 0
	for _, path in ipairs(slice.files) do
		local record = self:record(path)
		if record then
			files[path] = record
			reads += 1
		end
	end
	return writeShard(slice, files, reads)
end

--- Build a root's files across processes and fill `entry` from their records, sorted by path. A
--- shard that ends without a record is worked again here; anything else strange gives up on the
--- split rather than merging part of a root.
---@param entry lye.lsp.IndexEntry
---@param root string
---@param paths string[]
---@param sizes table<string, integer>
---@param opts lye.lsp.IndexOptions
---@return boolean isOk
---@return integer workers how many processes ran a shard
---@return integer fellBack how many shards this process had to take over
---@param self lye.lsp.Index
function Index:buildShards(entry, root, paths, sizes, opts)
	local workers = self:parallelWorkers(paths, opts)
	local groups = groupsOf(root, paths, sizes)
	local token = string.format("%d-%d-%d", parallel.pid(), os.time(), math.random(1, 1000000000))
	local dir = recordDirectory()
	local slices = parallel.splitWork(groups, workers, function(index)
		return string.format("%s/%s-%d.rec", dir, token, index)
	end)
	local hook = opts.onShard or self.options.onShard
	---@param slice lye.parallel.Slice
	---@param index integer
	---@param isChild boolean
	local function work(slice, index, isChild)
		return self:workShard(slice, index, isChild, hook)
	end
	local started, failed = parallel.dispatch(slices, work, opts.fork or self.options.fork)

	local merged, reads = {}, 0
	for index, slice in ipairs(slices) do
		if #slice.files > 0 then
			local shard = readShard(slice)
			if not shard and not slice.ranInParent then
				-- A child that claimed a record did not leave one that reads: its shard is this
				-- process's to do, the way a child that ended badly already was.
				failed += 1
				slice.ranInParent = true
				work(slice, index, false)
				shard = readShard(slice)
			end
			if not shard then
				for _, later in ipairs(slices) do os.remove(later.out) end
				return false, 1, failed + 1
			end
			-- A shard this process worked counted its reads as it read; a child's are only in the
			-- record it left.
			if not slice.ranInParent then reads += math.floor(tonumber(shard.reads) or 0) end
			for path, record in pairs(shard.files) do merged[path] = record end
		end
	end
	self.stats_.reads += reads

	-- Sorted by path, so a split build and a serial one produce the same entry.
	local sorted = {}
	for path in pairs(merged) do sorted[#sorted + 1] = path end
	table.sort(sorted)
	for _, path in ipairs(sorted) do entry.files[path] = merged[path] end
	return true, started, failed
end

--- Build the entry for a root by reading every file it has. A large root is read by several
--- processes when this machine can fork; each shard's records come back through the cache's own
--- serializer and are merged here, so no decoded type graph crosses a process boundary. Nothing
--- is written; `save` is the caller saying the answer is worth keeping, and it writes once.
---@param root string
---@param opts lye.lsp.IndexOptions? `kind`, `max`, and the fork options for a test
---@return lye.lsp.IndexEntry
---@param self lye.lsp.Index
function Index:build(root, opts)
	opts = opts or {}
	local started = timing.now()
	root = normalize(root)
	local kind = opts.kind or self.kind_
	self.kind_ = kind
	local entry = { schema = SCHEMA, root = root, codeVersion = cache.codeVersion(), files = {} }
	local paths = self:scan(root, kind, self:cap(opts))
	local readsBefore = self.stats_.reads
	local workers, fellBack = 1, 0
	local isShared = false
	local maySplit, sizes = self:parallelWanted(paths, opts)
	if maySplit then
		local isOk, used, failed = self:buildShards(entry, root, paths, sizes or {}, opts)
		if isOk then
			workers, fellBack, isShared = used, failed, true
		else
			-- A split that cannot answer the whole root is no answer: the entry is built again
			-- from the files, never merged from the shards that happened to arrive.
			entry.files = {}
			workers, fellBack = 1, failed
		end
	end
	if not isShared then
		for _, path in ipairs(paths) do
			---@cast path string
			local record = self:record(path)
			if record then entry.files[path] = record end
		end
	end
	entry.annotationsDigest = digestOf(entry)
	if kind == "package" then entry.linkDigest = linkDigestOf(entry) end
	entry.known = knownOf(entry)
	self:adopt(entry)
	self.stats_.built += 1
	self.stats_.workers += workers
	self.stats_.fellBack += fellBack
	self.stats_.index += timing.now() - started
	timing.mark("index", started, string.format("built=1 loaded=0 files=%d reads=%d workers=%d%s",
		countFiles(entry), self.stats_.reads - readsBefore, workers,
		fellBack > 0 and (" fellBack=" .. fellBack) or ""))
	return entry
end

--- Bring `entry` back in line with the files a root has now: a file whose metadata moved is read
--- and hashed, a file that is gone is dropped, a file that is new is read. `forced` names the
--- paths an event already said changed, which are read even when their metadata did not move.
--- `removed` is how many files the caller already took out of the entry, so the rebuild decision
--- counts them too.
---@param entry lye.lsp.IndexEntry
---@param root string
---@param kind "workspace"|"package"
---@param opts { max: integer? }?
---@param forced table<string, boolean>?
---@param removed integer?
---@return "stable"|"updated"|"rebuild"
---@param self lye.lsp.Index
function Index:sync(entry, root, kind, opts, forced, removed)
	local paths = self:scan(root, kind, self:cap(opts))
	local present = {}
	for _, path in ipairs(paths) do present[path] = true end

	-- What moved is settled before any file is read, so a root most of which moved is built
	-- again without hashing the files twice.

	local removedCount = 0
	for path in pairs(entry.files) do
		if not present[path] then removedCount += 1 end
	end
	local suspects = {}
	for _, path in ipairs(paths) do
		---@cast path string
		local record = entry.files[path]
		if not record or (forced and forced[path]) then
			suspects[#suspects + 1] = path
		else
			local held = self.stat(path)
			if not held or not isCurrent(record, held) then suspects[#suspects + 1] = path end
		end
	end
	if removedCount + #suspects > math.max(1, math.floor(#paths * REBUILD_SHARE)) then return "rebuild" end

	local isDirty = removedCount > 0
	for path in pairs(entry.files) do
		if not present[path] then entry.files[path] = nil end
	end
	for _, path in ipairs(suspects) do
		---@cast path string
		local record = entry.files[path]
		local fresh = self:record(path)
		if not fresh then
			entry.files[path] = nil
			isDirty = true
		elseif not record or fresh.hash ~= record.hash then
			entry.files[path] = fresh
			isDirty = true
		else
			-- Rewritten with the same text: the metadata is all that moved.
			record.size, record.mtime = fresh.size, fresh.mtime
			isDirty = true
		end
	end
	return isDirty and "updated" or "stable"
end

---@param entry lye.lsp.IndexEntry
---@param kind "workspace"|"package"
---@param self lye.lsp.Index
function Index:refresh(entry, kind)
	entry.annotationsDigest = digestOf(entry)
	if kind == "package" then entry.linkDigest = linkDigestOf(entry) end
	entry.known = knownOf(entry)
end

--- Read the entry for a root, or nil when there is none this run can trust. A root whose files
--- moved is brought back in line — or, when most of it moved, built again — and the entry is
--- written back for the next run.
---@param root string
---@param opts { kind: "workspace"|"package"?, max: integer? }?
---@param self lye.lsp.Index
function Index:load(root, opts)
	opts = opts or {}
	local started = timing.now()
	root = normalize(root)
	local kind = opts.kind or self.kind_
	local entry = cache.load(self:key(root, kind))
	local isUsable = isValidEntry(entry, root)
		and (kind ~= "package" or type(entry.linkDigest) == "string")
	if not isUsable then
		self.stats_.index += timing.now() - started
		return nil
	end
	---@cast entry lye.lsp.IndexEntry
	self.kind_ = kind
	local state = self:sync(entry, root, kind, opts)
	-- What an entry says about itself has to match what it holds, or it is a wrong answer that
	-- survived validation rather than a miss.
	local isStale = state == "stable" and (digestOf(entry) ~= entry.annotationsDigest
		or (kind == "package" and linkDigestOf(entry) ~= entry.linkDigest))
	if state == "rebuild" or isStale then
		local rebuilt = self:build(root, opts)
		self:save(rebuilt)
		self.stats_.index += timing.now() - started
		return rebuilt
	end
	if state == "updated" then self:refresh(entry, kind) end
	self:adopt(entry)
	if state == "updated" then self:save(entry) end
	self.stats_.loaded += 1
	self.stats_.index += timing.now() - started
	return entry
end

--- Read the entry for a root without syncing, building or writing anything: a caller that only
--- wants to consult a warm index — a check, say — gets the entry this run can trust or nil. A
--- missing, corrupt, older or differently-rooted entry is a miss, never an error.
---@param root string
---@param opts { kind: "workspace"|"package"? }?
---@param self lye.lsp.Index
function Index:open(root, opts)
	opts = opts or {}
	root = normalize(root)
	local kind = opts.kind or self.kind_
	local entry = cache.load(self:key(root, kind))
	if not isValidEntry(entry, root) then return nil end
	---@cast entry lye.lsp.IndexEntry
	if kind == "package" and type(entry.linkDigest) ~= "string" then return nil end
	return entry
end

--- Write an entry for the next run. What each file annotates is written; the namespace those
--- annotations resolve to is not, because building it from them costs less than reading the types
--- back and the entry is most of the file's size. A cache that cannot be written is not an error.
---@param entry lye.lsp.IndexEntry?
---@param self lye.lsp.Index
function Index:save(entry)
	entry = entry or self.entry_
	if not entry then return false end
	local persisted = {
		schema = entry.schema,
		root = entry.root,
		codeVersion = entry.codeVersion,
		annotationsDigest = entry.annotationsDigest,
		files = entry.files,
	}
	if entry.linkDigest ~= nil then persisted.linkDigest = entry.linkDigest end
	return cache.save(self:key(entry.root, self.kind_), persisted)
end

--- Apply what a file watcher reported, then bring the rest of the root in line. `changes` holds
--- file paths, or `{ path, removed }` tables: a path an event named is read even when its
--- metadata still looks unchanged.
---@param root string
---@param changes (string|{ path: string, removed: boolean? })[]
---@param opts { kind: "workspace"|"package"?, max: integer? }?
---@param self lye.lsp.Index
function Index:update(root, changes, opts)
	opts = opts or {}
	local started = timing.now()
	root = normalize(root)
	local kind = opts.kind or self.kind_
	local entry = cache.load(self:key(root, kind))
	if not isValidEntry(entry, root) or (kind == "package" and type(entry.linkDigest) ~= "string") then
		local built = self:build(root, opts)
		self:save(built)
		self.stats_.index += timing.now() - started
		return built
	end
	---@cast entry lye.lsp.IndexEntry
	self.kind_ = kind

	local forced, removed = {}, 0
	for _, change in ipairs(changes or {}) do
		local path = type(change) == "table" and change.path or change
		if type(path) == "string" then
			if type(change) == "table" and change.removed then
				if entry.files[path] ~= nil then
					entry.files[path] = nil
					removed += 1
				end
			else
				forced[path] = true
			end
		end
	end

	local state = self:sync(entry, root, kind, opts, forced, removed)
	if state == "rebuild" then
		local rebuilt = self:build(root, opts)
		self:save(rebuilt)
		self.stats_.index += timing.now() - started
		return rebuilt
	end
	self:refresh(entry, kind)
	self:adopt(entry)
	self:save(entry)
	self.stats_.loaded += 1
	self.stats_.index += timing.now() - started
	return entry
end

---@param self lye.lsp.Index
function Index:entry()
	return self.entry_
end

--- The files the current entry holds, each with its hash, metadata, annotations and types.
---@param self lye.lsp.Index
---@return table<string, lye.lsp.IndexFile>
function Index:files()
	return self.entry_ and self.entry_.files or {}
end

---@param path string
---@param self lye.lsp.Index
function Index:file(path)
	local entry = self.entry_
	return entry and entry.files[path] or nil
end

--- Each name the root declares, resolved to the type it stands for.
---@param self lye.lsp.Index
function Index:known()
	return self.entry_ and self.entry_.known or {}
end

--- Where each class or alias of the root is written.
---@param self lye.lsp.Index
function Index:typeLocations()
	return self.typeLocations_ or {}
end

--- What every file of the root annotates, as the workspace digest a module is keyed on.
---@param self lye.lsp.Index
function Index:digest()
	return self.entry_ and self.entry_.annotationsDigest or ""
end

--- What a package's links are, as the digest a module of that package is keyed on.
---@param self lye.lsp.Index
function Index:linkDigest()
	return self.entry_ and self.entry_.linkDigest
end

---@param path string
---@param self lye.lsp.Index
function Index:isDefinition(path)
	local record = self:file(path)
	return record ~= nil and record.isDefinition == true
end

--- `index` is the milliseconds spent reading and validating entries, the rest are counts: how
--- often an entry was built, how often one was read and trusted, how many files it holds, how many
--- source files were read, how many processes the builds used, and how many shards a failed child
--- left to this process.
---@param self lye.lsp.Index
function Index:stats()
	local held = self.stats_
	return {
		index = held.index,
		built = held.built,
		loaded = held.loaded,
		files = held.files,
		reads = held.reads,
		workers = held.workers,
		fellBack = held.fellBack,
	}
end

return Index
