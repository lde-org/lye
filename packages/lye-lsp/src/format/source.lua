--[[
	The parts of a source the formatter needs to read without scanning it: line boundaries, the
	comments the lexer found, and the literals that span more than one line.

	The indexes are FFI arrays: a source can hold thousands of lines and comments, and one Lua
	table per entry is memory the formatter does not need to keep. Offsets are 1-based bytes, the
	same units every token and node reports.
]]

local ffi = require("ffi")
local lexer = require("lye-lexer")

---@class lye.Source
---@field text string
---@field lineStarts ffi.cdata*
---@field lineCount integer
---@field commentStarts ffi.cdata*
---@field commentStops ffi.cdata*
---@field commentTokens ffi.cdata*
---@field commentCount integer
---@field texts string[]
---@field protectedStarts ffi.cdata*
---@field protectedStops ffi.cdata*
---@field protectedCount integer
---@field cachedLine integer?
---@field cachedStart integer?
---@field cachedStop integer?
---@field cachedCommentOffset integer
---@field cachedCommentIndex integer
local Source = {}
Source.__index = Source

---@param text string
---@param tokens lye.lexer.Tokens
function Source.new(text, tokens)
	local self = setmetatable({}, Source)
	self:reset(text, tokens)
	return self
end

--- Point an existing source index at another file, reusing its FFI arrays when they are large
--- enough. The formatter handles many files in one process, and a fresh array per file is memory
--- and allocation it does not need.
---@param text string
---@param tokens lye.lexer.Tokens
function Source:reset(text, tokens)
	self.text = text
	self.texts = tokens.texts
	self.cachedLine = nil
	self.cachedStart = nil
	self.cachedStop = nil
	self.cachedCommentOffset = 0
	self.cachedCommentIndex = 1

	local count = 1
	local at = 1
	while true do
		local newline = text:find("\n", at, true)
		if not newline then break end
		count += 1
		at = newline + 1
	end
	local starts = self.lineStarts
	if not starts or ffi.sizeof(starts) / 4 <= count then
		starts = ffi.new("int32_t[?]", count + 32)
		self.lineStarts = starts
	end
	starts[1] = 1
	local line = 2
	at = 1
	while true do
		local newline = text:find("\n", at, true)
		if not newline then break end
		starts[line] = newline + 1
		line += 1
		at = newline + 1
	end
	self.lineCount = count

	local comments, protected = 0, 0
	for index = 1, tokens.count do
		local token = tokens.arena[index]
		if token.kind == lexer.KIND.comment then
			comments += 1
		elseif token.kind == lexer.KIND.string then
			local newline = text:find("\n", token.start, true)
			if newline and newline <= token.stop then protected += 1 end
		end
	end
	if not self.commentStarts or ffi.sizeof(self.commentStarts) / 4 <= comments then
		self.commentStarts = ffi.new("int32_t[?]", comments + 32)
		self.commentStops = ffi.new("int32_t[?]", comments + 32)
		self.commentTokens = ffi.new("int32_t[?]", comments + 32)
	end
	if not self.protectedStarts or ffi.sizeof(self.protectedStarts) / 4 <= protected then
		self.protectedStarts = ffi.new("int32_t[?]", protected + 32)
		self.protectedStops = ffi.new("int32_t[?]", protected + 32)
	end
	self.commentCount = comments
	self.protectedCount = protected

	local comment, held = 0, 0
	for index = 1, tokens.count do
		local token = tokens.arena[index]
		if token.kind == lexer.KIND.comment then
			comment += 1
			self.commentStarts[comment] = token.start
			self.commentStops[comment] = token.stop
			self.commentTokens[comment] = token.index
		elseif token.kind == lexer.KIND.string then
			local newline = text:find("\n", token.start, true)
			if newline and newline <= token.stop then
				held += 1
				self.protectedStarts[held] = token.start
				self.protectedStops[held] = token.stop
			end
		end
	end
end

--- The 1-based line an offset is on.
---@param offset integer
---@return integer
function Source:lineOf(offset)
	local cached = self.cachedLine
	if cached and offset >= self.cachedStart and offset <= self.cachedStop then
		return cached
	end
	local starts = self.lineStarts
	local low, high = 1, self.lineCount
	while low <= high do
		local middle = math.floor((low + high) / 2)
		if starts[middle] <= offset then low = middle + 1 else high = middle - 1 end
	end
	local line = math.max(1, high)
	self.cachedLine = line
	self.cachedStart = starts[line]
	self.cachedStop = (line < self.lineCount) and (starts[line + 1] - 1) or #self.text
	return line
end

--- The byte the line starts at.
---@param offset integer
---@return integer
function Source:lineStartOf(offset)
	return self.lineStarts[self:lineOf(offset)]
end

--- The byte the line stops at, before its newline.
---@param offset integer
---@return integer
function Source:lineEndOf(offset)
	local line = self:lineOf(offset)
	if line < self.lineCount then return self.lineStarts[line + 1] - 2 end
	return #self.text
end

--- The text of a comment by its 1-based index.
---@param index integer
---@return string
function Source:commentText(index)
	return self.texts[self.commentTokens[index]]
end

--- The first comment that starts at or after an offset, or one past the last comment.
---@param offset integer
---@return integer
function Source:firstCommentAtOrAfter(offset)
	local starts = self.commentStarts
	if offset >= self.cachedCommentOffset then
		local index = self.cachedCommentIndex
		while index <= self.commentCount and starts[index] < offset do index += 1 end
		self.cachedCommentOffset = offset
		self.cachedCommentIndex = index
		return index
	end
	local low, high = 1, self.commentCount
	while low <= high do
		local middle = math.floor((low + high) / 2)
		if starts[middle] < offset then low = middle + 1 else high = middle - 1 end
	end
	self.cachedCommentOffset = offset
	self.cachedCommentIndex = low
	return low
end

--- Whether a comment starts inside a span. The common answer is no, and this answer allocates
--- nothing.
---@param from integer
---@param to integer
---@return boolean
function Source:hasCommentIn(from, to)
	local index = self:firstCommentAtOrAfter(from)
	return index <= self.commentCount and self.commentStarts[index] <= to
end

--- Whether a line begins inside a literal that runs over more than one line.
---@param offset integer
---@return boolean
function Source:isProtectedLine(offset)
	local starts = self.protectedStarts
	local low, high = 1, self.protectedCount
	while low <= high do
		local middle = math.floor((low + high) / 2)
		if starts[middle] <= offset then low = middle + 1 else high = middle - 1 end
	end
	if high == 0 then return false end
	return offset <= self.protectedStops[high]
end

return Source
