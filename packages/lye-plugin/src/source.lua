--[[
	Lowering a document, and reading an answer about it again.

	A plugin that knows another language compiles it to Lua and hands the result over, and lye then
	works on *that* text: the parser, the analyzer and every check read Lua. The editor, meanwhile,
	holds the other language and asks about it, so offsets have to travel in both directions — a
	cursor position into the lowered text, and every range an analysis produced back out of it.

	The travel is described by the edits alone. An edit replaces a span of the original with new
	text; what no edit touches keeps its place, moved by the length the edits before it added or
	removed. Inside a replacement the plugin decides what it can promise:

	* `same` says the text is the original span written again, so an offset within it maps to the
	  offset it stands for, both ways.
	* Anything else was written by the plugin, so a range inside it answers with the whole span the
	  edit replaced — that is the code a reader of the original can see — and a position asking to
	  be read there answers with the start of the replacement, which is the nearest honest place.
]]

local source = {}

---@class lye.plugin.Edit
---@field from integer byte offset of the first byte replaced, 1-based
---@field to integer byte offset one past the last byte replaced, so `from == to` is an insertion
---@field text string what stands there in the lowered text
---@field same boolean? the text is the original span written again, which maps one to one

--- A document that was lowered, and how to get back: the text the analysis reads, the edits that
--- made it, and where each of them starts in it.
---@class lye.plugin.Map
---@field text string the lowered text
---@field edits lye.plugin.Edit[] the replacements, in the order they appear
---@field starts integer[] where each replacement begins in the lowered text
local Map = {}
Map.__index = Map

--- The index of the last edit that starts at or before an offset of the original.
---@param self lye.plugin.Map
---@param offset integer
---@return integer? index
local function editAt(self, offset)
	local edits = self.edits
	local low, high = 1, #edits
	local found
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if edits[mid].from <= offset then
			found = mid
			low = mid + 1
		else
			high = mid - 1
		end
	end
	return found
end

--- The index of the last edit whose replacement covers an offset of the lowered text.
---@param self lye.plugin.Map
---@param offset integer
local function editCovering(self, offset)
	local edits, starts = self.edits, self.starts
	local low, high = 1, #edits
	---@type integer?
	local found
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if starts[mid] <= offset then
			found = mid
			low = mid + 1
		else
			high = mid - 1
		end
	end
	if not found then return nil end
	local edit = edits[found]
	local length = #edit.text
	-- A replacement that inserts nothing covers nothing.
	if length > 0 and offset < starts[found] + length then return found end
	return nil
end

--- The index of the last edit whose replacement ends at or before an offset of the lowered text,
--- which is the one an offset in untouched material is shifted by.
---@param self lye.plugin.Map
---@param offset integer
---@return integer? index
local function editBefore(self, offset)
	local edits, starts = self.edits, self.starts
	local low, high = 1, #edits
	local found
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if starts[mid] + #edits[mid].text <= offset then
			found = mid
			low = mid + 1
		else
			high = mid - 1
		end
	end
	return found
end

--- Where an offset of the original is written in the lowered text. A position inside a span the
--- plugin replaced answers with the start of what stands there now: the text that was there is
--- gone, and that is where a reader has to look.
---@param self lye.plugin.Map
---@param offset integer
function Map:toLowered(offset)
	local index = editAt(self, offset)
	if not index then return offset end
	local edit = self.edits[index]
	if offset >= edit.to then
		-- Past the replacement: moved by everything that edit added or removed.
		return offset + (self.starts[index] + #edit.text - edit.to)
	end
	if edit.same then return self.starts[index] + (offset - edit.from) end
	return self.starts[index]
end

--- The span of the original an offset of the lowered text was written at. An offset inside text
--- the plugin wrote answers with the whole span that was replaced, since that is the code a
--- reader at the original can be pointed to; anything else answers with the offset it kept.
---@param self lye.plugin.Map
---@param offset integer
---@return integer from
---@return integer to
function Map:toOriginal(offset)
	local index = editCovering(self, offset)
	if index then
		local edit = self.edits[index]
		if edit.same then
			local at = edit.from + (offset - self.starts[index])
			return at, at
		end
		-- The span the edit replaced, as an inclusive one: the caller's own ranges are written with
		-- the last byte in them, and an empty replacement answers with the byte it stood before.
		return edit.from, math.max(edit.to - 1, edit.from)
	end
	-- Material no replacement covers: moved back by what the edits before it changed.
	local previous = editBefore(self, offset)
	if not previous then return offset, offset end
	local edit = self.edits[previous]
	local shifted = self.starts[previous] + #edit.text - edit.to
	return offset - shifted, offset - shifted
end

--- Whether an offset of the lowered text stands inside a replacement — text the plugin wrote, which
--- the original has no bytes for. lye's own tokens are read off the lowered text, and one of those
--- has nowhere to be pointed at in the editor's: a colouring that lands on the whole statement is
--- worse than none, so the caller can ask and leave it out.
---@param self lye.plugin.Map
---@param offset integer
function Map:isWritten(offset)
	return editCovering(self, offset) ~= nil
end

--- Whether a range of the lowered text lies inside replacements, both ends of it.
---@param self lye.plugin.Map
---@param from integer
---@param to integer
function Map:rangeIsWritten(from, to)
	return self:isWritten(from) and self:isWritten(to)
end

--- A range of the lowered text, as the range of the original it came from. The two ends are
--- widened together, so a range inside one replacement answers with that replacement's span and
--- a range across several answers with all of them.
---@param self lye.plugin.Map
---@param from integer
---@param to integer
---@return integer from
---@return integer to
function Map:toOriginalRange(from, to)
	local fromStart, fromStop = self:toOriginal(from)
	local toStart, toStop = self:toOriginal(to)
	return math.min(fromStart, toStart), math.max(fromStop, toStop)
end

--- Whether this map moves anything at all, which is the case for every document no plugin has
--- something to say about.
---@param self lye.plugin.Map
function Map:isEmpty()
	return #self.edits == 0
end

--- The edits a plugin returned, in order and sound: what a plugin writes is not to be trusted,
--- and an edit list that overlaps or runs past the text is a fault to report rather than damage
--- to do. `error` is the answer, and the caller keeps the plugin's work out of the document.
---@param text string
---@param edits lye.plugin.Edit[]
---@return lye.plugin.Edit[]
local function ordered(text, edits)
	local sorted = {}
	for index, edit in ipairs(edits or {}) do
		local from, to, written = edit.from, edit.to, edit.text
		if type(from) ~= "number" or type(to) ~= "number" or type(written) ~= "string" then
			error(string.format("edit %d is not a span and its text", index), 0)
		end
		if from < 1 or to < from or to > #text + 1 then
			error(string.format("edit %d covers %d..%d, which is not in the document", index, from, to), 0)
		end
		if edit.same and #written ~= to - from then
			error(string.format("edit %d says the text stands where the original stood, but it is %d "
				.. "bytes for %d", index, #written, to - from), 0)
		end
		sorted[#sorted + 1] = { from = from, to = to, text = written, same = edit.same == true }
	end
	table.sort(sorted, function(left, right)
		if left.from ~= right.from then return left.from < right.from end
		return left.to < right.to
	end)
	for index = 2, #sorted do
		if sorted[index].from < sorted[index - 1].to then
			error(string.format("edits %d and %d overlap", index - 1, index), 0)
		end
	end
	return sorted
end

--- Lower a document through the edits a plugin returned: the text the analysis reads, and the map
--- that carries its answers back. With no edits the text is the document itself, and the map is
--- one that moves nothing.
---@param text string the original
---@param edits lye.plugin.Edit[]
function source.lower(text, edits)
	local kept = ordered(text, edits or {})
	local out, starts = {}, {}
	local at, lowered = 1, 1
	for index, edit in ipairs(kept) do
		out[#out + 1] = text:sub(at, edit.from - 1)
		lowered += edit.from - at
		starts[index] = lowered
		out[#out + 1] = edit.text
		lowered += #edit.text
		at = edit.to
	end
	out[#out + 1] = text:sub(at)
	return setmetatable({ text = table.concat(out), edits = kept, starts = starts }, Map)
end

--- Several lowerings, one after another: each plugin's edits are written against the text the one
--- before it produced. A position travels through them in order and an answer comes back through
--- them in reverse, which is what lets a plugin for a second language sit on top of a first.
---@class lye.plugin.Chain: lye.plugin.Map
---@field maps lye.plugin.Map[]
---@field text string the text the last of them produced
local Chain = {}
Chain.__index = Chain

---@param self lye.plugin.Chain
---@param offset integer
function Chain:toLowered(offset)
	for index = 1, #self.maps do offset = self.maps[index]:toLowered(offset) end
	return offset
end

---@param self lye.plugin.Chain
---@param offset integer
---@return integer from
---@return integer to
function Chain:toOriginal(offset)
	local from, to = offset, offset
	for index = #self.maps, 1, -1 do from, to = self.maps[index]:toOriginalRange(from, to) end
	return from, to
end

---@param self lye.plugin.Chain
---@param from integer
---@param to integer
---@return integer from
---@return integer to
function Chain:toOriginalRange(from, to)
	for index = #self.maps, 1, -1 do from, to = self.maps[index]:toOriginalRange(from, to) end
	return from, to
end

---@param self lye.plugin.Chain
---@param offset integer
function Chain:isWritten(offset)
	return self.maps[#self.maps]:isWritten(offset)
end

---@param self lye.plugin.Chain
---@param from integer
---@param to integer
function Chain:rangeIsWritten(from, to)
	return self.maps[#self.maps]:rangeIsWritten(from, to)
end

---@param self lye.plugin.Chain
function Chain:isEmpty()
	for _, map in ipairs(self.maps) do
		if not map:isEmpty() then return false end
	end
	return true
end

--- The lowerings a document went through, as one that a caller cannot tell from a single one.
---@param maps lye.plugin.Map[]
function source.chain(maps)
	if #maps == 1 then return maps[1] end
	return setmetatable({ maps = maps, text = maps[#maps].text, edits = {}, starts = {} }, Chain)
end

return source
