--[[
	What the plugin hooks cost, against the same document read without them.

	A colouring hook walks every call of a document, and the three lye ships walk it once each.
	This measures that walk over a real file and over a synthetic one that is mostly `ffi.cdef`,
	which is the case the refactor moved out of the server: the analyzer still parses the block
	for the types it declares, so a token request that parses it again is paying twice.

	    lde run -C packages/lye-lsp ../../tools/bench-plugins.lua
	    lde run -C packages/lye-lsp ../../tools/bench-plugins.lua ../../packages/lye-lsp/src/language.lua

	Times are the best of `ROUNDS`, in milliseconds. `spans` is what the hooks answered with, so a
	row that is suspiciously fast is checked against a row that found nothing. `analyze` is the
	same document through the analyzer, which is what the hooks are a fraction of.
]]

local analyzer = require("lye-analyzer")
local types = require("lye-doc.type")

local ROUNDS = tonumber(os.getenv("ROUNDS") or "12")
local ROOT = os.getenv("LYE_ROOT") or "."
local PRELUDE = analyzer.prelude(require("lye-defs"))

---@param path string
---@return string?
local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

---@param fn fun()
local function best(fn)
	local bestMs = math.huge
	for _ = 1, ROUNDS do
		collectgarbage("collect")
		local started = os.clock()
		fn()
		local taken = (os.clock() - started) * 1000
		if taken < bestMs then bestMs = taken end
	end
	return bestMs
end

--- The heap in KiB, after everything unreachable has been collected, so a delta is what is held.
---@return number kib
local function heap()
	collectgarbage("collect")
	return collectgarbage("count")
end

-- The plugin layer is loaded by the analyzer itself now, so its module cost is part of every
-- analysis rather than an optional extra. What a session keeps per package is the spec tables.
local plugin = require("lye-plugin")

---@param source string
---@param names lye.analyzer.Result
---@return lye.plugin.TokenContext
local function contextOf(source, names)
	local context = { uri = "file:///bench.lua", source = source, text = source, root = ROOT }
	context.map = plugin.lower({}, context, function() end)
	context.parsed = names.parser
	context.analysis = names
	-- The server's own `typeOf` is a language.lua local. The dotted calls these plugins colour —
	-- `string.format`, `string.find` — need no type, and a method call on a receiver does; leaving
	-- it out understates the method-call share rather than inventing one.
	context.typeOf = function() return nil end
	context.ownerOf = types.ownerOf
	return context
end

---@type { name: string, entries: string[]? }[]
local GROUPS = {
	{ name = "all", entries = nil },
	{ name = "patterns", entries = { "!formats", "!ffi" } },
	{ name = "formats", entries = { "!patterns", "!ffi" } },
	{ name = "ffi", entries = { "!patterns", "!formats" } },
	{ name = "none", entries = { "!patterns", "!formats", "!ffi" } },
}

local specs = {}
local specsBefore = heap()
for _, group in ipairs(GROUPS) do
	specs[group.name] = plugin.load(group.entries, ROOT, nil, function(message)
		io.stderr:write("plugin: " .. message .. "\n")
	end)
end
print(string.format("shipped specs, five selections: %.0f KiB", heap() - specsBefore))

--- A cdef large enough for the duplicate parse to show: the definition files themselves carry
--- the C the standard library is written against, without a Lua string around it. `suffix` keeps
--- two calls from producing the same text, which the plugin's cache would answer for free.
---@param suffix string?
local function syntheticCdef(suffix)
	suffix = suffix or ""
	local parts = { "local ffi = require(\"ffi\")\nffi.cdef[[\n" }
	for index = 1, 80 do
		parts[#parts + 1] = string.format(
			"typedef struct { double x%d, y%d; int n%d; } Vec%d%s;\n"
			.. "typedef unsigned long size_t%d%s;\n"
			.. "typedef size_t%d (*write_cb%d%s)(char *ptr, size_t%d size, void *userdata);\n",
			index, index, index, index, suffix, index, suffix, index, index, suffix, index)
	end
	parts[#parts + 1] = "]]\n"
	parts[#parts + 1] = "local v = ffi.new(\"Vec1\")\n"
	parts[#parts + 1] = "string.format(\"%d %s\", 1, \"x\")\n"
	parts[#parts + 1] = "(\"%d\"):format(1)\n"
	parts[#parts + 1] = "string.find(\"abc\", \"%a+\")\n"
	return table.concat(parts)
end

local targets = {}
for index = 1, #arg do
	local text = read(arg[index])
	if text then targets[#targets + 1] = { name = arg[index], text = text } end
end
if #targets == 0 then
	local text = read("../../packages/lye-lsp/src/language.lua")
	if text then targets[#targets + 1] = { name = "lye-lsp/src/language.lua", text = text } end
	targets[#targets + 1] = { name = "synthetic cdef", text = syntheticCdef() }
end

print(string.format("%-30s %8s %14s %14s %14s %14s %8s", "document", "analyze", "all",
	"patterns", "formats", "ffi", "none"))
for _, target in ipairs(targets) do
	local names = analyzer.analyze(target.text, PRELUDE)
	local context = contextOf(target.text, names)
	local analyzeMs = best(function() analyzer.analyze(target.text, PRELUDE) end)
	local row = { string.format("%-30s %8.2f", target.name:gsub(".*/", ""), analyzeMs) }
	for _, group in ipairs(GROUPS) do
		local held = specs[group.name]
		local spans = 0
		local ms = best(function()
			local asked = plugin.tokens(held, context)
			spans = #asked
		end)
		if group.name == "none" then
			row[#row + 1] = string.format("%8.2f", ms)
		else
			row[#row + 1] = string.format("%14s", string.format("%6.2f/%-5d", ms, spans))
		end
	end
	print(table.concat(row, " "))
end

-- What the cdef cache adds after one block has been coloured. The document, its analysis and the
-- context are held before the measurement, so the delta is the parsed spans rather than a second
-- copy of the analysis. It is the one plugin table that grows with a document, and it keeps the
-- sixteen most recent blocks.
local text = syntheticCdef("_cache")
-- Read without plugins: the analyzer would otherwise populate the ffi plugin's block cache before
-- the measurement, and the number reported would be the hit rather than what the block costs.
local names = analyzer.analyze(text, PRELUDE, nil, nil, nil, nil, nil, nil, {})
local context = contextOf(text, names)
local before = heap()
plugin.tokens(specs.ffi, context)
print(string.format("ffi spans cache, one synthetic header: %.0f KiB", heap() - before))
