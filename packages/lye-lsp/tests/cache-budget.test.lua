--[[
	The byte budget the analysis cache holds itself to.

	An editor may have any number of documents open and nothing bounds what an analysis of one costs,
	so the cache cannot keep them all. These tests use synthetic analyses of known size: the cache's
	estimates are arithmetic, so a document of a stated number of bytes, nodes and tokens costs a
	stated number of estimated bytes. The real analyzer is used only for the re-analysis check, where
	what matters is that an evicted document comes back to the same diagnostics.
]]

local test = require("lde-test")
local analyzer = require("lye-analyzer")
local AnalysisCache = require("lye-lsp.analysis_cache")

--- What a document with `text` looks like to the cache when it is not lowered.
---@param text string
---@return table
local function view(text)
	return { text = text, map = { isEmpty = function() return true end } }
end

--- A result shaped like the analyzer's, with the fields the cache reads: a parser result with its
--- source, its node arena and its token count, and a doc file for the annotations.
---@param text string
---@param nodeCount integer
---@param tokenCount integer
---@return table
local function resultOf(text, nodeCount, tokenCount)
	local nodes = {}
	for index = 1, nodeCount do nodes[index] = {} end
	return {
		parser = { source = text, nodes = nodes, tokens = { count = tokenCount } },
		doc = { annotations = {} },
		diagnostics = {},
	}
end

---@param value any
local function canonical(value)
	local kind = type(value)
	if kind == "table" then
		if #value > 0 then
			local parts = {}
			for index = 1, #value do parts[index] = canonical(value[index]) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for key in pairs(value) do keys[#keys + 1] = key end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local parts = {}
		for _, key in ipairs(keys) do
			parts[#parts + 1] = tostring(key) .. "=" .. canonical(value[key])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return tostring(value)
end

--- 2000 lines of 56 characters: about 114 KiB of source, which the cache estimates at roughly
--- 20 MiB once its analysis, parse tree and annotations are counted. Two fit in 32 MiB, not three.
local LINE = string.rep("x", 56)
local LARGE = string.rep(LINE .. "\n", 2000)

test.it("estimates each part with the documented constants and counts them once", function()
	local cache = AnalysisCache.new({} --[[@as lye.Server ]])
	local text = string.rep("a", 100)
	cache:store("file:///one", resultOf(text, 3, 7), view(text), 1)

	local stats = cache:stats()
	test.equal(stats.analyses, 1)
	test.equal(stats.analysisBytes, 100 * 96, "analysis: #source * 96")
	test.equal(stats.parsedBytes, 100 * 16 + 3 * 96 + 7 * 24,
		"parse: #source * 16 + nodes * 96 + tokens * 24")
	test.equal(stats.annotationBytes, 100 * 64, "annotations: #text * 64")
	test.equal(stats.previous, 0, "the held analysis and its predecessor are the same result")
	test.equal(stats.entries, 1)
	test.equal(stats.bytes, 100 * 96 + (100 * 16 + 3 * 96 + 7 * 24) + 100 * 64)
end)

test.it("does not evict while an analysis is landing; the budget is enforced once, at the idle point", function()
	local cache = AnalysisCache.new({} --[[@as lye.Server ]])
	for index = 1, 4 do
		cache:store("file:///large-" .. index, resultOf(LARGE, 2000, 2000), view(LARGE), index)
	end
	test.equal(cache:stats().analyses, 4, "every document just analysed is held")
	test.truthy(cache:stats().bytes > cache.maxBytes, "and the four are over the budget")

	cache:evict()
	local stats = cache:stats()
	test.truthy(stats.bytes <= cache.maxBytes,
		("after eviction the total is inside the budget: %d > %d"):format(stats.bytes, cache.maxBytes))
	test.truthy(stats.analyses <= cache.maxEntries, "and the count is inside its limit")
	test.truthy(cache.analysis["file:///large-4"] ~= nil, "the current document is still held")
	test.truthy(cache.parsed["file:///large-4"] ~= nil, "with its parse tree")
	test.truthy(cache.previous["file:///large-4"] ~= nil, "and its predecessor")
	test.equal(cache.analysis["file:///large-1"], nil, "the least recently used is gone")
	test.equal(cache.previous["file:///large-1"], nil, "and its predecessor with it")
	test.equal(cache.parsed["file:///large-1"], nil, "and its parse tree")
end)

test.it("keeps the current document when it alone is larger than the budget", function()
	local cache = AnalysisCache.new({} --[[@as lye.Server ]])
	cache.maxBytes = 1
	cache:store("file:///huge", resultOf(LARGE, 2000, 2000), view(LARGE), 1)
	cache:evict()

	test.truthy(cache.analysis["file:///huge"] ~= nil, "a document larger than the budget is still answered")
	test.truthy(cache.parsed["file:///huge"] ~= nil, "its parse is kept for the next edit")
	test.truthy(cache:stats().bytes > cache.maxBytes, "and the estimate honestly says it is over")
end)

test.it("holds at most four analyses however small they are", function()
	local cache = AnalysisCache.new({} --[[@as lye.Server ]])
	cache.maxBytes = 1e12
	for index = 1, 6 do
		local text = "return " .. index .. "\n"
		cache:store("file:///small-" .. index, resultOf(text, 2, 3), view(text), index)
	end
	cache:evict()

	local stats = cache:stats()
	test.equal(stats.analyses, cache.maxEntries, "the analysis count is capped")
	test.truthy(cache.analysis["file:///small-6"] ~= nil, "the current document stays")
	for index = 1, 2 do
		test.equal(cache.analysis["file:///small-" .. index], nil,
			"the oldest analyses are evicted first")
	end
end)

---@param source string
---@return table
local function analyze(source)
	return analyzer.analyze(source)
end

--- The problems an analysis reports, parser and annotation ones alike.
---@param names lye.analyzer.Result
---@return table[]
local function diagnosticsOf(names)
	local out = {}
	for _, entry in ipairs(names.parser.diagnostics) do
		out[#out + 1] = { message = entry.message, start = entry.start, stop = entry.stop }
	end
	for _, entry in ipairs(names.diagnostics) do
		out[#out + 1] = { message = entry.message, start = entry.start, stop = entry.stop }
	end
	return out
end

test.it("re-analyses an evicted document to the same diagnostics", function()
	local source = "local x = 1\nlocal = 2\n"
	local names = analyze(source)
	local expected = canonical(diagnosticsOf(names))

	local cache = AnalysisCache.new({} --[[@as lye.Server ]])
	cache.maxBytes = 1
	cache:store("file:///broken", names, view(source), 1)
	-- A second, smaller document becomes current; the budget cannot hold both, so the first is a
	-- full-parse miss the next time it is asked about.
	local other = "return 1\n"
	cache:store("file:///other", analyze(other), view(other), 2)
	cache:evict()

	test.equal(cache.analysis["file:///broken"], nil, "the first document's analysis was evicted")
	test.equal(cache.parsed["file:///broken"], nil, "and its parse with it")

	local again = analyze(source)
	test.equal(canonical(diagnosticsOf(again)), expected,
		"reading the text again reports exactly what the evicted result did")
end)

return true
