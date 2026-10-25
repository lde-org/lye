--[[
	The analyses a session holds, and what each one was read from.

	An analysis is the expensive thing: a document's tree, its scopes and every type its names came
	to. A session keeps the most recently used ones, because an editor sends the same request about
	the same file many times and re-analysing it for each one is work with no reader. What is kept
	for a document is dropped when the budget says so, which costs one analysis later rather than an
	answer now.

	The budget is 32 MiB in total, spent across everything this module holds. Each part has one
	estimate, all of them rough but on the same scale, so the total is comparable across kinds:

	- an analysis: `#source * 96` (its scopes, variables, signatures and diagnostics);
	- a parse tree: `#source * 16 + nodes * 96 + tokens * 24` (the slices and both arenas);
	- an annotations file: `#text * 64` (its list of annotations and their parsed text);
	- a retained predecessor: the analysis estimate, counted once — it is the same table as the
	  held analysis while that exists, and only counted separately after `forget` let the analysis go.

	At most four analyses are held. The current document — the last one analysed, or in an idle pass
	the most recently changed one — always keeps its analysis, its parse tree and its predecessor,
	so one document larger than the budget is kept on its own rather than refused an answer.
	Everything else is evicted least recently used first; an eviction drops that document's
	analysis, predecessor, parse tree and annotations together, and the next request for it is a
	full-parse miss, never a wrong answer.

	The parse tree is kept apart from the analysis. `forget` drops what the old text meant — its
	names, the declarations it contributed, the annotations it read — while the tree stays: the next
	text of the document is usually the old one with a few bytes changed, and the parser can carry
	on from where they stop matching. Only closing the document lets the tree go.

	`previous` is the last analysis this document had, kept for the next analysis of the same
	document: it is the predecessor text's result, which is what says which items may be reused. It
	is replaced, not accumulated, when the next result lands.
]]

-- The whole cache's budget, and the most analyses it holds whatever their size. A document larger
-- than the byte budget is still kept while it is current: an answer is worth more than the number.
local MAX_BYTES = 32 * 1024 * 1024
local MAX_ANALYSES = 4

-- A block of source compared with `==` rather than a byte at a time. LuaJIT compares a string
-- slice in C, so four kilobytes at a time turns a whole-file comparison into a few hundred calls
-- with a small constant, whatever the language below.
local BLOCK = 4096

-- A rough cost of what an analysis keeps, per byte of its source. It is only a budget number: the
-- tables are Lua tables and the exact figure differs by document, but the shape of the cost does
-- not. The parse tree is counted by its nodes and tokens instead, which is closer to what it
-- allocates.
local ANALYSIS_BYTES_PER_BYTE = 96
local PARSE_NODE_BYTES = 96
local PARSE_TOKEN_BYTES = 24
local PARSE_SOURCE_BYTES_PER_BYTE = 16
local ANNOTATION_BYTES_PER_BYTE = 64

---@class lye.AnalysisCacheStats
---@field analyses integer how many analyses are held
---@field analysisBytes integer estimated bytes they hold
---@field parsed integer how many parse trees are held
---@field parsedBytes integer estimated bytes those trees hold
---@field previous integer how many predecessor results are held apart from the analyses
---@field previousBytes integer estimated bytes those predecessors hold
---@field annotations integer how many parsed annotation sets are held
---@field annotationBytes integer estimated bytes they hold
---@field entries integer how many documents have anything held
---@field bytes integer the enforced total estimate: analyses + predecessors + parses + annotations
---@field maxBytes integer the byte budget those numbers are held to
---@field maxEntries integer the analysis count limit

---@class lye.AnalysisCache
---@field analysis table<string, lye.parser.Result> what each held document's analysis reads
---@field names table<string, lye.analyzer.Result> the names that analysis came to
---@field parsed table<string, { source: string, parsed: lye.parser.Result }> the parse each text left, independent of its analysis
---@field previous table<string, lye.analyzer.Result> the last analysis of each document, for the next one
---@field annotations table<string, { text: string, doc: lye.doc.File }> the annotations already parsed for a text
---@field order string[] the documents whose analyses are held, least recently used first
---@field spans table<string, { from: integer, prefix: integer, suffix: integer }> where the current text first differs from the parsed one
---@field epochs table<string, integer> the change count each held analysis was made under
---@field current string? the document whose analysis, parse and predecessor are never evicted
---@field maxBytes integer the byte budget, 32 MiB unless a test forces it
---@field maxEntries integer the most analyses held, 4 unless a test forces it

local AnalysisCache = {}
AnalysisCache.__index = AnalysisCache

--- The tables are published on `lye` as well: the declaration and module facades read
--- `lye.analysis` and `lye.names`, and must keep seeing the very tables this cache clears.
---@param lye lye.Server
---@return lye.AnalysisCache
function AnalysisCache.new(lye)
	local cache = setmetatable({
		analysis = {}, names = {}, parsed = {}, previous = {}, annotations = {},
		order = {}, spans = {}, epochs = {}, current = nil,
		maxBytes = MAX_BYTES, maxEntries = MAX_ANALYSES,
	}, AnalysisCache)
	lye.analysis = cache.analysis
	lye.names = cache.names
	lye.order = cache.order
	return cache
end

--- The byte the current text first differs from a text at, or nil when a full parse is the only
--- honest answer. The prefix is compared in blocks and the suffix is counted for the report and
--- for a caller that wants to know the change is whole; only the prefix decides where a parse can
--- carry on, since everything after it is re-read anyway.
---@param a string
---@param b string
---@return integer prefix
local function commonPrefix(a, b)
	local limit = math.min(#a, #b)
	local at = 0
	while at + BLOCK <= limit and a:sub(at + 1, at + BLOCK) == b:sub(at + 1, at + BLOCK) do
		at = at + BLOCK
	end
	while at < limit and a:byte(at + 1) == b:byte(at + 1) do at = at + 1 end
	return at
end

---@param a string
---@param b string
---@param limit integer the most bytes the suffix may cover, so that it never reaches into the prefix
---@return integer
local function commonSuffix(a, b, limit)
	local at = 0
	while at + BLOCK <= limit
		and a:sub(#a - at - BLOCK + 1, #a - at) == b:sub(#b - at - BLOCK + 1, #b - at) do
		at = at + BLOCK
	end
	while at < limit and a:byte(#a - at) == b:byte(#b - at) do at = at + 1 end
	return at
end

--- The change from the text the held parse was for to `text`, or nil when there is nothing to
--- resume from. A plugin-lowered document is a different text at different offsets, so its parse
--- is dropped rather than resumed: a kept tree of the text the editor holds would be resumed at
--- offsets of the text the plugin wrote.
---@param uri string
---@param text string the text the next analysis will read
---@param lowered boolean the view is a plugin's lowering of the document
---@return { from: integer, prefix: integer, suffix: integer }?
function AnalysisCache:span(uri, text, lowered)
	if lowered then
		self.parsed[uri] = nil
		self.spans[uri] = nil
		return nil
	end
	local held = self.parsed[uri]
	if not held then return nil end
	local prefix = commonPrefix(held.source, text)
	if prefix == 0 then return nil end
	local suffix = commonSuffix(held.source, text, math.min(#held.source, #text) - prefix)
	return { from = prefix + 1, prefix = prefix, suffix = suffix }
end

--- The annotations already parsed for exactly this text, or nil when the text has moved on.
---@param uri string
---@param text string
---@return lye.doc.File?
function AnalysisCache:annotationsFor(uri, text)
	local held = self.annotations[uri]
	if held and held.text == text then return held.doc end
	if held then self.annotations[uri] = nil end
	return nil
end

--- Drop everything the text meant. The parse stays: the next text is read against it.
---@param uri string
function AnalysisCache:forget(uri)
	self.analysis[uri] = nil
	self.names[uri] = nil
	self.annotations[uri] = nil
	for index = #self.order, 1, -1 do
		if self.order[index] == uri then table.remove(self.order, index) end
	end
end

--- Drop everything held for a document, including what could resume its next text. Closing is the
--- only time that is right: the document is not coming back to this session.
---@param uri string
function AnalysisCache:close(uri)
	self:forget(uri)
	self:drop(uri)
	if self.current == uri then self.current = self.order[#self.order] end
	self:evict()
end

--- Drop everything held for one document, wherever it is held.
---@param uri string
function AnalysisCache:drop(uri)
	self.analysis[uri] = nil
	self.names[uri] = nil
	self.parsed[uri] = nil
	self.previous[uri] = nil
	self.annotations[uri] = nil
	self.spans[uri] = nil
	self.epochs[uri] = nil
end

--- Record that `uri` is the most recently used entry. The budget is enforced by `evict` once an
--- idle pass has finished publishing, not here.
---@param uri string
function AnalysisCache:keep(uri)
	local order = self.order
	for index = #order, 1, -1 do
		if order[index] == uri then table.remove(order, index) end
	end
	order[#order + 1] = uri
end

---@param uri string
---@param names lye.analyzer.Result
---@param view lye.View
---@param epoch integer
function AnalysisCache:store(uri, names, view, epoch)
	local result = names.parser
	self.analysis[uri] = result
	self.names[uri] = names
	self.previous[uri] = names
	self.epochs[uri] = epoch
	self.current = uri
	if view.map:isEmpty() then
		self.parsed[uri] = { source = view.text, parsed = result }
	else
		self.parsed[uri] = nil
	end
	if names.doc then self.annotations[uri] = { text = view.text, doc = names.doc } end
	-- The span described the text before this analysis; the tree it pointed past is the one just
	-- stored, so a later change computes its own against that.
	self.spans[uri] = nil
	self:keep(uri)
end

---@return lye.AnalysisCacheStats
function AnalysisCache:stats()
	local analyses, analysisBytes = 0, 0
	local held = {}
	for _, result in pairs(self.analysis) do
		analyses = analyses + 1
		held[result] = true
		analysisBytes = analysisBytes + #(result.source or "") * ANALYSIS_BYTES_PER_BYTE
	end
	local previous, previousBytes = 0, 0
	for _, names in pairs(self.previous) do
		local tree = names.parser
		if not (tree and held[tree]) then
			previous = previous + 1
			previousBytes = previousBytes + #((tree and tree.source) or "") * ANALYSIS_BYTES_PER_BYTE
		end
	end
	local parsed, parsedBytes = 0, 0
	for _, entry in pairs(self.parsed) do
		parsed = parsed + 1
		local tree = entry.parsed
		local nodes = tree.nodes and #tree.nodes or 0
		local tokens = tree.tokens and tree.tokens.count or 0
		parsedBytes = parsedBytes + #entry.source * PARSE_SOURCE_BYTES_PER_BYTE
			+ nodes * PARSE_NODE_BYTES + tokens * PARSE_TOKEN_BYTES
	end
	local annotations, annotationBytes = 0, 0
	for _, entry in pairs(self.annotations) do
		annotations = annotations + 1
		annotationBytes = annotationBytes + #entry.text * ANNOTATION_BYTES_PER_BYTE
	end
	local entries = {}
	for uri in pairs(self.analysis) do entries[uri] = true end
	for uri in pairs(self.previous) do entries[uri] = true end
	for uri in pairs(self.parsed) do entries[uri] = true end
	for uri in pairs(self.annotations) do entries[uri] = true end
	local entryCount = 0
	for _ in pairs(entries) do entryCount = entryCount + 1 end
	return {
		analyses = analyses, analysisBytes = analysisBytes,
		parsed = parsed, parsedBytes = parsedBytes,
		previous = previous, previousBytes = previousBytes,
		annotations = annotations, annotationBytes = annotationBytes,
		entries = entryCount,
		bytes = analysisBytes + previousBytes + parsedBytes + annotationBytes,
		maxBytes = self.maxBytes, maxEntries = self.maxEntries,
	}
end

--- Drop the least recently used held analysis that is not the current document.
---@return boolean didDrop
function AnalysisCache:_evictAnalysis()
	local order = self.order
	for index = 1, #order do
		local uri = order[index]
		if uri ~= self.current and self.analysis[uri] then
			table.remove(order, index)
			self:drop(uri)
			return true
		end
	end
	for uri in pairs(self.analysis) do
		if uri ~= self.current then
			for index = #order, 1, -1 do
				if order[index] == uri then table.remove(order, index) end
			end
			self:drop(uri)
			return true
		end
	end
	return false
end

--- Drop one entry of a kind that has no held analysis, oldest first. A document that still has
--- its analysis loses its parse, predecessor and annotations with that analysis, not before it.
---@param field "previous"|"annotations"|"parsed"
---@return boolean didDrop
function AnalysisCache:_evictUnheld(field)
	local chosen, chosenAt
	for uri in pairs(self[field]) do
		if uri ~= self.current and not self.analysis[uri] then
			local at = self.epochs[uri] or 0
			if not chosen or at < chosenAt then chosen, chosenAt = uri, at end
		end
	end
	if not chosen then return false end
	self[field][chosen] = nil
	if field == "parsed" then self.spans[chosen] = nil end
	return true
end

--- Enforce the budget. Called after an idle pass has published every answer, so an analysis is
--- never dropped half way through answering for it, and when a document closes.
---@return lye.AnalysisCacheStats the numbers after eviction
function AnalysisCache:evict()
	local measured = self:stats()
	while measured.analyses > self.maxEntries do
		if not self:_evictAnalysis() then break end
		measured = self:stats()
	end
	while measured.bytes > self.maxBytes do
		if self:_evictAnalysis() then
			-- A held analysis is the largest thing a document keeps; drop it whole.
		elseif self:_evictUnheld("previous") then
		elseif self:_evictUnheld("annotations") then
		elseif self:_evictUnheld("parsed") then
		else
			-- Only the current document is left, and keeping it is the point of the exception.
			break
		end
		measured = self:stats()
	end
	return measured
end
return AnalysisCache
