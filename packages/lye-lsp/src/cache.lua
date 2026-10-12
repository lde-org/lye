--[[
	What an earlier run already worked out, kept between runs.

	An entry is stored under a key its caller chooses — a hash of the text it is about and of what
	it was read against — and holds a plain Lua table, written and read by `lye-doc.serial`. Every
	entry carries the version of the code that wrote it: the sources of the packages that do the
	analysing, hashed, so a run of other code never reads this code's answers as its own. A run
	with no cache directory to write to, or with `LYE_CACHE=off`, simply does not cache.
]]

local fs = require("fs")
local rapidhash = require("rapidhash")
local serial = require("lye-doc.serial")

local cache = {}

local version
local rootDir

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

--- Whether this run keeps a cache at all.
function cache.enabled()
	local set = os.getenv("LYE_CACHE")
	return set ~= "off" and set ~= "0"
end

--- The directory this version's entries live in, made when it is first asked for. Nil when there
--- is no cache to write to at all.
local function directory()
	if rootDir then return rootDir end
	if not cache.enabled() then return nil end
	local base = os.getenv("XDG_CACHE_HOME")
	if not base or base == "" then
		local home = os.getenv("HOME")
		base = home and home ~= "" and (home .. "/.cache") or "/tmp"
	end
	local dir = base .. "/lye/" .. codeVersion()
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

--- Write `value` under `key`. A cache that cannot be written is not an error: the run goes on
--- without one. The write lands whole or not at all, so a reader never sees half an entry.
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
	local temporary = path .. ".tmp." .. tostring(math.floor(math.random(1, 1e9)))
	if not fs.write(temporary, text) then return false end
	if fs.move(temporary, path) then return true end
	os.remove(temporary)
	return false
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
