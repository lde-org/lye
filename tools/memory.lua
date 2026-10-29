--[[
	Where the memory of one document goes, stage by stage, and what a node costs.

	Every number is a `collectgarbage("count")` reading taken after a collection, so what is reported
	is what is *held* rather than what was allocated. FFI memory counts too — a struct array reports
	what it occupies — which is what makes the lexer's arena and the parser's tables comparable, and
	it is why the answer to "does an FFI arena help?" is a number rather than an opinion.

	Beside the heap each stage reports the process's resident set from `/proc/self/status`, falling
	back to `ps`. The heap is what the collector can give back; RSS is what the editor's machine
	pays for, and an FFI arena or a fragmented heap shows up in one and not the other.

	The later stages are the caches the plan adds: the workspace index (its load when an entry for
	this root and version is already on disk, and the scan/parse a build costs), the analyses the
	language server keeps, and a module's export type as the module cache persists it. A stage whose
	subject has not landed yet says so and is skipped rather than guessed at.

		lde run -C packages/lye-lsp ../../tools/memory.lua
		FILE=another.lua lde run -C packages/lye-lsp ../../tools/memory.lua
		INDEX_MAX_FILES=500 lde run -C packages/lye-lsp ../../tools/memory.lua
		INDEX_SAVE=1 lde run -C packages/lye-lsp ../../tools/memory.lua   # keep the built index
		MODULE_FILE=path.lua ...                                            # another module's cache

	The fixture is the 2331-line file of another project that `compare.mjs --fixture` uses, so these
	are the memory numbers for the same work the timing numbers are about.
]]

-- The packages through root `lye.json`, which the checker does not follow.
---@class lye.MemoryLexer
---@field tokenize fun(source: string): lye.lexer.Tokens

---@class lye.MemoryParsed
---@field parse fun(self: lye.MemoryParsed): lye.parser.Result

---@class lye.MemoryParser
---@field new fun(source: string): lye.MemoryParsed

---@class lye.MemoryAnalyzer
---@field prelude fun(sources: table<string, string>): lye.analyzer.Prelude
---@field analyze fun(source: string, prepared?: lye.analyzer.Prelude, elsewhere?: table<string, boolean|lye.doc.Type>?, modules?: table?, resume?: lye.parser.Resume?, cachedAnnotations?: lye.doc.File?, isModuleOnly?: boolean): lye.analyzer.Result

---@class lye.MemorySerial
---@field write fun(value: unknown): string?
---@field read fun(bytes: string): unknown?

---@class lye.MemoryIndexEntry
---@field files table<string, boolean>?

---@class lye.MemoryIndex
---@field new fun(options: table): lye.MemoryIndex
---@field load fun(self: lye.MemoryIndex, root: string): lye.MemoryIndexEntry?
---@field build fun(self: lye.MemoryIndex, root: string): lye.MemoryIndexEntry?
---@field save fun(self: lye.MemoryIndex, built: lye.MemoryIndexEntry): boolean?

local ffi = require("ffi") --[[@as table]]
local lexer = require("lye-lexer") --[[@as lye.MemoryLexer]]
local parser = require("lye-parser") --[[@as lye.MemoryParser]]
local analyzer = require("lye-analyzer") --[[@as lye.MemoryAnalyzer]]
local serial = require("lye-doc.serial") --[[@as lye.MemorySerial]]

local SCRIPT = debug.getinfo(1, "S").source:sub(2)
local TOOLS = assert(SCRIPT:match("^(.*)/[^/]+$"))
local ROOT = os.getenv("LYE_ROOT") or assert(TOOLS:match("^(.*)/tools$"))
if ROOT:sub(1, 1) ~= "/" then
	local pipe = io.popen("cd " .. string.format("%q", ROOT) .. " && pwd -P")
	if pipe then
		ROOT = (pipe:read("*a") or ROOT):gsub("%s+$", "")
		pipe:close()
	end
end

local PATH = os.getenv("FILE") or ROOT .. "/editors/vscode/tests/fixtures/benchmark-lde.lua.txt"

---@param path string
local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

--- The process id, for the `ps` fallback. `cache.lua` reads it the same way.
local cdef = ffi.cdef --[[@as fun(declaration: string)]]
local C = ffi.C --[[@as table]]
pcall(cdef, [[int getpid(void);]])
local PID
do
	local ok, value = pcall(function()
		local getpid = C.getpid --[[@as fun(): integer]]
		return tonumber(getpid())
	end)
	if ok and value then PID = value end
end

--- The process's resident set in KiB: what the machine has to keep, rather than what the collector
--- is tracking. `/proc` is the answer on Linux; `ps` is the fallback elsewhere.
local function processRss()
	local status = io.open("/proc/self/status", "rb")
	if status then
		for line in status:lines() do
			---@cast line string
			local kib = line:match("^VmRSS:%s*(%d+)%s*kB")
			if kib then
				status:close()
				return tonumber(kib)
			end
		end
		status:close()
	end
	if not PID then
		local stat = io.open("/proc/self/stat", "rb")
		if stat then
			local text = stat:read("*a")
			stat:close()
			PID = tonumber(text and text:match("^(%d+)"))
		end
	end
	if not PID then return nil end
	local pipe = io.popen(string.format("ps -o rss= -p %d 2>/dev/null", PID))
	if not pipe then return nil end
	local text = pipe:read("*a")
	pipe:close()
	return tonumber(text and text:match("%d+"))
end

--- The heap in KiB, with everything unreachable collected first.
---@return number kib
local function heap()
	collectgarbage("collect")
	return collectgarbage("count")
end

---@param label string
---@param was number
---@param wasRss number?
---@return number heap
---@return number? rss
local function stage(label, was, wasRss)
	collectgarbage("collect")
	local now = collectgarbage("count")
	local rss = processRss()
	local delta = rss and wasRss and (rss - wasRss) / 1024 or nil
	print(string.format("%-22s %7.2f MiB  rss %s", label, (now - was) / 1024,
		delta and string.format("%7.2f MiB", delta) or "     n/a"))
	return now, rss
end

--- What dropping something frees, which is what it was holding.
---@param label string
---@param drop fun()
local function cost(label, drop)
	local was, wasRss = heap(), processRss()
	drop()
	collectgarbage("collect")
	local now, rss = collectgarbage("count"), processRss()
	local delta = rss and wasRss and (wasRss - rss) / 1024 or nil
	print(string.format("%-22s %7.2f MiB  rss %s", label, (was - now) / 1024,
		delta and string.format("%7.2f MiB", delta) or "     n/a"))
end

---@param path string
local function exists(path)
	local handle = io.open(path, "rb")
	if handle then handle:close() end
	return handle ~= nil
end

local startHeap = heap()
local startRss = processRss()
local source = assert(read(PATH), "cannot read " .. PATH)
print(string.format("%s: %d lines, %.2f MiB of text",
	PATH:gsub(".*/", ""), select(2, source:gsub("\n", "\n")), #source / 1048576))
print(string.format("%-22s %7.2f MiB  rss %s", "start", startHeap / 1024,
	startRss and string.format("%7.2f MiB", startRss / 1024) or "     n/a"))

local tokens = lexer.tokenize(source)
local afterLex, rssLex = stage("lex", startHeap, startRss)
print(string.format("%-22s %7d", "  tokens", tokens.count))

-- The parser scans the source itself, so this stage includes a second pass of the lexer.
local parsed = parser.new(source):parse()
local afterParse, rssParse = stage("parse", afterLex, rssLex)
print(string.format("%-22s %7d", "  nodes", #parsed.nodes))

local PRELUDE = analyzer.prelude(require("lye-defs") --[[@as table<string, string>]])
local afterPrelude, rssPrelude = stage("definitions", afterParse, rssParse)

local names = analyzer.analyze(source, PRELUDE)
stage("analyse", afterPrelude, rssPrelude)
print(string.format("%-22s %7d variables, %d diagnostics", "  ", #names.variables, #names.diagnostics))

-- The workspace index: an entry for this root and this code version is a load; building one is a
-- scan, a read, a comment parse and a declaration collection per file. The stage uses
-- `lye-lsp.index` when it is there, and says so when it is not — the module is the lane's own, and
-- a benchmark that guessed at its methods would measure the guess.
local indexFile = ROOT .. "/packages/lye-lsp/src/index.lua"
local hasIndex, rawIndex = pcall(require, "lye-lsp.index")
local Index = rawIndex --[[@as lye.MemoryIndex]]
if not exists(indexFile) then
	print(string.format("%-22s %s", "index load",
		"skipped (packages/lye-lsp/src/index.lua is absent; A2 has not landed)"))
	print(string.format("%-22s %s", "index build", "skipped (same)"))
elseif not hasIndex or type(Index) ~= "table" or type(Index.new) ~= "function" then
	print(string.format("%-22s %s", "index load", "skipped (lye-lsp.index did not load: " .. tostring(Index) .. ")"))
	print(string.format("%-22s %s", "index build", "skipped (same)"))
else
	local okNew, rawNew = pcall(Index.new, {
		log = function(message) print(string.format("%-22s %s", "  index", message)) end,
	})
	local index = rawNew --[[@as lye.MemoryIndex?]]
	if not okNew then
		print(string.format("%-22s %s", "index load", "skipped (Index.new failed: " .. tostring(index) .. ")"))
		print(string.format("%-22s %s", "index build", "skipped (same)"))
	else
		local instance = index --[[@as lye.MemoryIndex]]
		local was, wasRss = heap(), processRss()
		local started = os.clock()
		local okLoad, rawLoaded = pcall(function() return instance:load(ROOT) end)
		local loaded = rawLoaded --[[@as lye.MemoryIndexEntry?]]
		local loadMs = (os.clock() - started) * 1000
		if not okLoad then
			print(string.format("%-22s %s", "index load", "skipped (load failed: " .. tostring(loaded) .. ")"))
			loaded = nil
		elseif loaded then
			---@cast loaded lye.MemoryIndexEntry
			local files = 0
			for _ in pairs(loaded.files or {}) do files = files + 1 end
			local afterLoad = stage("index load", was, wasRss)
			print(string.format("%-22s %7.1f ms, %d files, %.2f MiB held", "  ", loadMs, files,
				(afterLoad - was) / 1024))
		else
			print(string.format("%-22s %s", "index load",
				"miss (no usable entry for this root and version; the build below is what a first run pays)"))
		end

		local buildWas, buildRss = heap(), processRss()
		local buildStarted = os.clock()
		local okBuild, rawBuilt = pcall(function() return instance:build(ROOT) end)
		local built = rawBuilt --[[@as lye.MemoryIndexEntry?]]
		local buildMs = (os.clock() - buildStarted) * 1000
		if not okBuild then
			print(string.format("%-22s %s", "index build", "skipped (build failed: " .. tostring(built) .. ")"))
			built = nil
		else
			---@cast built lye.MemoryIndexEntry
			local afterBuild = stage("index build", buildWas, buildRss)
			local files = 0
			for _ in pairs(built.files or {}) do files = files + 1 end
			print(string.format("%-22s %7.1f ms, %d files, %.2f MiB held", "  ", buildMs, files,
				(afterBuild - buildWas) / 1024))
			if os.getenv("INDEX_SAVE") == "1" then
				local okSaved, saved = pcall(function() return instance:save(built) end)
				---@cast okSaved boolean
				---@cast saved boolean?
				print(string.format("%-22s %s", "  index saved", okSaved and saved and "yes" or "no"))
			end
		end
		cost("  index dropped", function()
			loaded, built, index = nil, nil, nil
		end)
	end
end

-- The analyses an editor keeps open. The budget in the plan is a byte estimate — 96 bytes of
-- analysis for each byte of source, four documents — so both the measured hold and the estimate
-- are reported against it.
local MAX_ANALYSIS_BYTES = tonumber(os.getenv("MAX_ANALYSIS_BYTES")) or 32 * 1024 * 1024
local MAX_ANALYSIS_COUNT = tonumber(os.getenv("MAX_ANALYSIS_COUNT")) or 4
do
	local was, wasRss = heap(), processRss()
	local held = {}
	for index = 1, MAX_ANALYSIS_COUNT do held[index] = analyzer.analyze(source, PRELUDE) end
	local afterCache = stage("analysis cache", was, wasRss)
	local bytes = (afterCache - was) * 1024
	local estimate = #source * 96 * MAX_ANALYSIS_COUNT
	print(string.format("%-22s %7.2f MiB held, %.2f MiB estimated (#source*96*%d), cap %.1f MiB: %s",
		"  ", bytes / 1048576, estimate / 1048576, MAX_ANALYSIS_COUNT, MAX_ANALYSIS_BYTES / 1048576,
		bytes <= MAX_ANALYSIS_BYTES and "within budget" or "OVER BUDGET"))
	cost("  analyses dropped", function() held = nil end)
end

-- The module cache: what a required file's export type costs to work out and to keep serialized.
-- `isModuleOnly` is the path `require` takes, and the bytes are what the cache would persist.
local MODULE = os.getenv("MODULE_FILE") or ROOT .. "/packages/lye-doc/src/serial.lua"
do
	local text = read(MODULE)
	if not text then
		print(string.format("%-22s %s", "module cache", "skipped (no module file: " .. MODULE .. ")"))
	else
		local was, wasRss = heap(), processRss()
		local started = os.clock()
		local module = analyzer.analyze(text, PRELUDE, nil, nil, nil, nil, true)
		local moduleMs = (os.clock() - started) * 1000
		local afterModule = stage("module cache", was, wasRss)
		if module.module == nil then
			print(string.format("%-22s %s", "  ", "skipped (the file exports no type)"))
		else
			local bytes = serial.write(module.module)
			local roundTrip = bytes and serial.read(bytes)
			print(string.format("%-22s %7.1f ms, export %.1f KiB, round-trip %s, %.2f MiB held", "  ",
				moduleMs, bytes and #bytes / 1024 or 0, roundTrip and "ok" or "failed",
				(afterModule - was) / 1024))
		end
		cost("  module dropped", function() module = nil end)
	end
end

-- What the tree holds, measured by taking it apart. Done last, since it destroys it.
local fields, lists = 0, 0
for _, node in ipairs(parsed.nodes) do
	for _, value in pairs(node) do
		fields += 1
		if type(value) == "table" then lists += 1 end
	end
end
local nodes = #parsed.nodes
cost("  child lists", function()
	for _, node in ipairs(parsed.nodes) do
		for key, value in pairs(node) do
			if type(value) == "table" then node[key] = nil end
		end
	end
end)
local nodeTables = heap()
for index = 1, nodes do parsed.nodes[index] = nil end
local freed = (nodeTables - heap()) / 1024
print(string.format("%-22s %7.2f MiB", "  node tables", freed))
print(string.format("%-22s %7.0f bytes each, %.1f fields, %d of them lists",
	"  ", nodes > 0 and freed * 1048576 / nodes or 0, fields / math.max(nodes, 1), lists))

local total, totalRss = heap(), processRss()
print(string.format("%-22s %7.2f MiB  rss %s", "total", total / 1024,
	totalRss and string.format("%7.2f MiB", totalRss / 1024) or "     n/a"))
-- LuaJIT's collector reports bytes held, not how many times it ran: there is no counter to read.
print(string.format("%-22s %s", "gc collections", "unavailable (LuaJIT exposes no collection counter)"))
