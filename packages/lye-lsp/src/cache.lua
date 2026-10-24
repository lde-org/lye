--[[
	What an earlier run already worked out, kept between runs.

	An entry is stored under a key its caller chooses — a hash of the text it is about and of what
	it was read against — and holds a plain Lua table, written and read by `lye-doc.serial`. Every
	entry carries the version of the code that wrote it: the sources of the packages that do the
	analysing, hashed, so a run of other code never reads this code's answers as its own.

	Everything a run keeps lives under one directory: `.lye` beside the project a check was called
	in, or wherever `cache.setRoot` or `LYE_CACHE_DIR` names — a build that wants its own, or an
	editor that wants the cache in the workspace it opened. `LYE_CACHE=off` turns the keeping off.
]]

local fs = require("fs")
local rapidhash = require("rapidhash")
local serial = require("lye-doc.serial")
local ffi = require("ffi")

local cache = {}

-- A name no other session's write shares, so two of them can write the same file at once without
-- one moving the other's half-written text into place.
pcall(ffi.cdef, [[int getpid(void);]])
local PID = 0
do
	local ok, value = pcall(function() return ffi.C.getpid() end)
	if ok then PID = tonumber(value) or 0 end
end

local version
local rootDir
local enabled
local named

--- The version an entry was written by: every source file of the packages whose code decides what
--- an analysis finds, hashed together, with the definitions they are read through.
---@return string
local function codeVersion()
	if version then return version end

	local parts = {}
	local function addFile(path)
		local text = fs.read(path)
		if type(text) == "string" then parts[#parts + 1] = rapidhash.hex(text) end
	end

	-- One function from each package, and the directory it was loaded from: every `.lua` beside it
	-- is part of the code under test. A package that cannot be located — a bundled build — adds
	-- nothing here, and the definitions below still say when the type system's input changed.
	local sources = {
		require("lye-analyzer").analyze,
		require("lye-doc").parse,
		require("lye-parser").parse,
		require("lye-lexer").tokenize,
		require("lye-cdef").parse,
		require("lye-plugin").types,
		require("lye-lsp.check").files,
	}
	for _, fn in ipairs(sources) do
		local source = fn and debug.getinfo(fn, "S").source
		local at = source and source:sub(1, 1) == "@" and source:sub(2) or nil
		local dir = at and at:match("^(.*)/[^/]+$")
		if dir and fs.isdir(dir) then
			for path in fs.scan(dir, "**/*.lua", { absolute = true }) do addFile(path) end
		end
	end

	local defined = {}
	for name, text in pairs(require("lye-defs")) do
		defined[#defined + 1] = name .. "=" .. tostring(text)
	end
	table.sort(defined)
	parts[#parts + 1] = rapidhash.hex(table.concat(defined))

	table.sort(parts)
	version = rapidhash.hex(table.concat(parts))
	return version
end

--- Whether this run keeps a cache at all. `LYE_CACHE=off` says no, and so does a caller that
--- wants a cold run out of a cache that is already there.
---@return boolean
function cache.enabled()
	if enabled ~= nil then return enabled end
	local set = os.getenv("LYE_CACHE")
	return set ~= "off" and set ~= "0"
end

---@param value boolean
function cache.setEnabled(value)
	enabled = value
end

--- Where this run keeps what it worked out. A caller that names a directory — the command line,
--- or a build that has its own idea — writes there instead of beside the project.
---@param dir string
function cache.setRoot(dir)
	rootDir = nil
	named = dir
end

--- Whether a directory has already been named, by a caller or by `LYE_CACHE_DIR`. The language
--- server asks before it points the cache at the workspace it was handed: a run that named one has
--- said where it wants everything, and the server is not the one to overrule it.
---@return boolean
function cache.named()
	return named ~= nil or (os.getenv("LYE_CACHE_DIR") or "") ~= ""
end

--- The directory everything this run keeps goes under: what a caller named, else `LYE_CACHE_DIR`,
--- else `.lye` in the working directory — the project a check was called in.
---@return string
function cache.root()
	if named then return named end
	local set = os.getenv("LYE_CACHE_DIR")
	if set and set ~= "" then return set end
	return "./.lye"
end

--- The directory this version's entries live in, made when it is first asked for. Nil when there
--- is no cache to write to at all.
local function directory()
	if rootDir then return rootDir end
	if not cache.enabled() then return nil end
	local dir = cache.root() .. "/" .. codeVersion()
	fs.mkdirAll(dir)
	rootDir = fs.isdir(dir) and dir or nil
	return rootDir
end

---@param key string
---@return string?
local function pathOf(key)
	local dir = directory()
	return dir and (dir .. "/" .. key .. ".entry")
end

--- The entry written under `key`, or nil when there is none (or it cannot be read). `known` is the
--- caller's own tables for the names an entry was written with: a type the analysis reaches by
--- identity has to come back as the very table it was.
---@param key string
---@param known { tables: table<string, unknown> }?
---@return table?
function cache.load(key, known)
	if not cache.enabled() then return nil end
	local path = pathOf(key)
	if not path then return nil end
	local text = fs.read(path)
	if type(text) ~= "string" then return nil end
	local value = serial.read(text, known)
	if type(value) ~= "table" then return nil end
	return value
end

--- Write `text` at `path`, unless the file already holds exactly that. A write that cannot happen
--- is not an error: the run goes on without one. The text lands whole or not at all — it goes to a
--- temporary name beside the file and is moved over it — so a reader never finds half of it.
---@param path string
---@param text string
---@return boolean
function cache.writeWhole(path, text)
	if fs.read(path) == text then return true end
	local temporary = string.format("%s.tmp.%d-%d", path, PID, math.floor(math.random(1, 1e9)))
	if not fs.write(temporary, text) then return false end
	if fs.move(temporary, path) then return true end
	os.remove(temporary)
	return false
end

--- Write `value` under `key`. A cache that cannot be written is not an error: the run goes on
--- without one.
---@param key string
---@param value table
---@param known { names: table<unknown, string> }? the caller's own tables, written by name
---@return boolean
function cache.save(key, value, known)
	if not cache.enabled() then return false end
	local path = pathOf(key)
	if not path then return false end
	local text = serial.write(value, known)
	if not text then return false end
	return cache.writeWhole(path, text)
end

--- A key from the parts that make an entry what it is: the text it is about, and what it was read
--- against. Two runs that agree on every part read the same entry.
---@param ... string
---@return string
function cache.key(...)
	local count = select("#", ...)
	if count == 0 then return rapidhash.hex("") end
	if count == 1 then return rapidhash.hex((...)) end
	return rapidhash.hex(table.concat({ ... }, "\0"))
end

--- The version this run writes under, for a caller that wants to record it in an entry.
cache.codeVersion = codeVersion

return cache
