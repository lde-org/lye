--[[
	Where the memory of one document goes, stage by stage, and what a node costs.

	Every number is a `collectgarbage("count")` reading taken after a collection, so what is reported
	is what is *held* rather than what was allocated. FFI memory counts too — a struct array reports
	what it occupies — which is what makes the lexer's arena and the parser's tables comparable, and
	it is why the answer to "does an FFI arena help?" is a number rather than an opinion.

		lde run -C packages/lye-lsp ../../tools/memory.lua
		FILE=another.lua lde run -C packages/lye-lsp ../../tools/memory.lua

	The fixture is the 2331-line file of another project that `compare.mjs --fixture` uses, so these
	are the memory numbers for the same work the timing numbers are about.
]]

local lexer = require("lye-lexer")
local parser = require("lye-parser")
local analyzer = require("lye-analyzer")

local PATH = os.getenv("FILE") or "/home/once/Projects/Personal/lye/editors/vscode/tests/fixtures/benchmark-lde.lua"

---@param path string
---@return string
local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

--- The heap in KiB, with everything unreachable collected first.
---@return number kib
local function heap()
	collectgarbage("collect")
	return collectgarbage("count")
end

---@param label string
---@param was number
local function stage(label, was)
	local now = heap()
	print(string.format("%-22s %7.2f MiB", label, (now - was) / 1024))
	return now
end

--- What dropping something frees, which is what it was holding.
---@param label string
---@param drop fun()
local function cost(label, drop)
	local was = heap()
	drop()
	print(string.format("%-22s %7.2f MiB", label, (was - heap()) / 1024))
end

local start = heap()
local source = read(PATH)
print(string.format("%s: %d lines, %.2f MiB of text",
	PATH:gsub(".*/", ""), select(2, source:gsub("\n", "\n")), #source / 1048576))

local tokens = lexer.tokenize(source)
local afterLex = stage("lex", start)
print(string.format("%-22s %7d", "  tokens", tokens.count))

-- The parser scans the source itself, so this stage includes a second pass of the lexer.
local parsed = parser.new(source):parse()
local afterParse = stage("parse", afterLex)
print(string.format("%-22s %7d", "  nodes", #parsed.nodes))

local PRELUDE = analyzer.prelude(require("lye-defs"))
local afterPrelude = stage("definitions", afterParse)

local names = analyzer.analyze(source, PRELUDE)
local afterAnalyze = stage("analyse", afterPrelude)
print(string.format("%-22s %7d variables, %d diagnostics", "  ", #names.variables, #names.diagnostics))

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
print(string.format("%-22s %7.2f MiB held in all", "total", afterAnalyze / 1024))
