--[[
	The document printer. It walks the parser's tree and writes the engine's style straight into
	a `string.buffer`: no intermediate strings, no per-node tables, and no line arrays.

	The tree is the source of truth for what a statement is. The lexer's comments and line
	boundaries are the only trivia that survives: one blank line between things, comments where
	they were written, and the exact bytes of a literal. A statement whose comments sit inside its
	own syntax is copied as it was written, reindented.
]]

local ffi = require("ffi")
local buffer = require("string.buffer")
local Source = require("lye-lsp.format.source")

pcall(ffi.cdef, [[void *memchr(const void *s, int c, size_t n);]])

---@class lye.Printer
---@field text string
---@field parsed lye.parser.Result
---@field nodes lye.parser.Node[]
---@field texts string[]
---@field settings table
---@field unit string
---@field unitLen integer
---@field indentByte integer
---@field separator string
---@field maxLineLength integer
---@field out ffi.cdata*
---@field data ffi.cdata*
---@field capacity integer
---@field length integer
---@field measureDepth integer
---@field measureStack table[]
---@field measureEnd integer
---@field sourcePtr ffi.cdata*
---@field column integer
---@field hadNewline boolean
---@field noBreak boolean
---@field chainDepth integer
---@field hasComments boolean
---@field chainArrays table<integer, ffi.cdata*>
---@field topStatements ffi.cdata*
---@field lines lye.Source
local Printer = {}
Printer.__index = Printer

--- The string a table's members are separated with, when the source did not say.
---@param settings table
---@return string
local function tableSeparator(settings)
	return settings.table_separator_style == "semicolon" and ";" or ","
end

---@param source string
---@param parsed lye.parser.Result
---@param settings table?
---@param unit string one indentation level
function Printer.new(source, parsed, settings, unit)
	local self = setmetatable({}, Printer)
	self.out = buffer.new(256)
	self.capacity = #source + 256
	self.data = ffi.new("uint8_t[?]", self.capacity)
	self.length = 0
	self.measureDepth = 0
	self.measureStack = {}
	self.chainDepth = 0
	self.chainArrays = {}
	self.lines = Source.new(source, parsed.tokens)
	self:reset(source, parsed, settings, unit)
	return self
end

--- Point an existing printer at another file, keeping its buffers and indexes. A process that
--- formats many files then allocates for the largest one, not for each one.
---@param source string
---@param parsed lye.parser.Result
---@param settings table?
---@param unit string one indentation level
function Printer:reset(source, parsed, settings, unit)
	self.text = source
	self.parsed = parsed
	self.nodes = parsed.nodes
	self.texts = parsed.tokens.texts
	self.settings = settings or {}
	unit = unit or "\t"
	if unit ~= self.unit then
		self.unit = unit
		self.unitLen = #unit
		self.indentByte = unit:byte(1)
	end
	self.separator = tableSeparator(self.settings)
	self.maxLineLength = tonumber(self.settings.max_line_length) or 120
	self.sourcePtr = ffi.cast("const char*", source)
	self.column = 1
	self.hadNewline = false
	self.noBreak = false
	self.measureDepth = 0
	self.chainDepth = 0
	self.out:reset()
	self.length = 0
	self.hasComments = false
	local needed = #source + 256
	if self.capacity < needed then
		self.capacity = needed
		self.data = ffi.new("uint8_t[?]", self.capacity)
	end
	self.lines:reset(source, parsed.tokens)
	self.hasComments = self.lines.commentCount > 0
end

--- Make room for `size` more bytes. The buffer grows by doubling and keeps what is written.
---@param size integer
function Printer:ensure(size)
	local needed = self.length + size
	if needed <= self.capacity then return end
	local capacity = self.capacity
	while capacity < needed do capacity *= 2 end
	local data = ffi.new("uint8_t[?]", capacity)
	if self.length > 0 then ffi.copy(data, self.data, self.length) end
	self.data = data
	self.capacity = capacity
end

--- Whether a node is short enough that even generous formatting cannot reach the line limit.
--- Measuring it would write it twice; most calls and tables are far below the limit.
---@param node lye.parser.Node
---@return boolean
function Printer:shortEnough(node)
	return self.column - 1 + (node.stop - node.start + 1) * 2 + 8 <= self.maxLineLength
end

---@param level integer
function Printer:writeIndent(level)
	local bytes = level * self.unitLen
	if bytes <= 0 then return end
	local needed = self.length + bytes
	if needed > self.capacity then self:ensure(bytes) end
	local data = self.data
	local at = self.length
	local byte = self.indentByte
	for index = 0, bytes - 1 do data[at + index] = byte end
	self.length = needed
	self.column += bytes
end

--- Write text that holds no newline.
---@param text string
function Printer:emit(text)
	local bytes = #text
	local needed = self.length + bytes
	if needed > self.capacity then self:ensure(bytes) end
	local data = self.data
	local at = self.length
	if bytes <= 32 then
		for index = 1, bytes do data[at + index - 1] = text:byte(index) end
	else
		ffi.copy(data + at, text, bytes)
	end
	self.length = needed
	self.column += bytes
end

--- Write two pieces of text that hold no newline.
---@param first string
---@param second string
function Printer:emit2(first, second)
	local a, b = #first, #second
	local needed = self.length + a + b
	if needed > self.capacity then self:ensure(a + b) end
	local data = self.data
	local at = self.length
	if a <= 32 then
		for index = 1, a do data[at + index - 1] = first:byte(index) end
	else
		ffi.copy(data + at, first, a)
	end
	at += a
	if b <= 32 then
		for index = 1, b do data[at + index - 1] = second:byte(index) end
	else
		ffi.copy(data + at, second, b)
	end
	self.length = needed
	self.column += a + b
end

--- Write three pieces of text that hold no newline.
---@param first string
---@param second string
---@param third string
function Printer:emit3(first, second, third)
	local a, b, c = #first, #second, #third
	local needed = self.length + a + b + c
	if needed > self.capacity then self:ensure(a + b + c) end
	local data = self.data
	local at = self.length
	if a <= 32 then
		for index = 1, a do data[at + index - 1] = first:byte(index) end
	else
		ffi.copy(data + at, first, a)
	end
	at += a
	if b <= 32 then
		for index = 1, b do data[at + index - 1] = second:byte(index) end
	else
		ffi.copy(data + at, second, b)
	end
	at += b
	if c <= 32 then
		for index = 1, c do data[at + index - 1] = third:byte(index) end
	else
		ffi.copy(data + at, third, c)
	end
	self.length = needed
	self.column += a + b + c
end

--- Write text that may hold newlines.
---@param text string
function Printer:emitText(text)
	local bytes = #text
	local needed = self.length + bytes
	if needed > self.capacity then self:ensure(bytes) end
	local data = self.data
	local at = self.length
	if bytes <= 32 then
		for index = 1, bytes do data[at + index - 1] = text:byte(index) end
	else
		ffi.copy(data + at, text, bytes)
	end
	self.length = needed
	local newline = text:find("\n[^\n]*$")
	if newline then
		self.column = bytes - newline + 1
		self.hadNewline = true
	else
		self.column += bytes
	end
end

--- Write a slice of the source without making a string for it.
---@param from integer
---@param to integer
function Printer:emitSource(from, to)
	local bytes = to - from + 1
	if bytes <= 0 then return end
	local needed = self.length + bytes
	if needed > self.capacity then self:ensure(bytes) end
	local data = self.data
	local at = self.length
	if bytes <= 32 then
		local hadNewline = false
		for index = 0, bytes - 1 do
			local byte = self.text:byte(from + index)
			data[at + index] = byte
			if byte == 10 then hadNewline = true end
		end
		self.length = needed
		if hadNewline then
			self.column = to - self.lines:lineStartOf(to) + 1
			self.hadNewline = true
		else
			self.column += bytes
		end
		return
	end
	local ptr = self.sourcePtr + (from - 1)
	ffi.copy(data + at, ptr, bytes)
	self.length = needed
	if ffi.C.memchr(ptr, 10, bytes) ~= nil then
		self.column = to - self.lines:lineStartOf(to) + 1
		self.hadNewline = true
	else
		self.column += bytes
	end
end

function Printer:newline()
	local at = self.length
	if at + 1 > self.capacity then self:ensure(1) end
	self.data[at] = 10
	self.length = at + 1
	self.column = 1
	self.hadNewline = true
end

--- Measure what is written next. The bytes are written into the output buffer directly; a
--- rejected measurement moves the length back and the next layout overwrites them.
function Printer:beginMeasure()
	local depth = self.measureDepth + 1
	self.measureDepth = depth
	local saved = self.measureStack[depth]
	if not saved then
		saved = {}
		self.measureStack[depth] = saved
	end
	saved.length = self.length
	saved.column = self.column
	saved.had = self.hadNewline
	saved.noBreak = self.noBreak
	self.hadNewline = false
	self.noBreak = true
end

---@return integer length
---@return integer column
---@return boolean hadNewline
function Printer:endMeasure()
	local depth = self.measureDepth
	local saved = self.measureStack[depth]
	local length = self.length - saved.length
	local column = self.column
	local hadNewline = self.hadNewline
	self.measureEnd = self.length
	self.length = saved.length
	self.column = saved.column
	self.hadNewline = saved.had
	self.noBreak = saved.noBreak
	self.measureDepth = depth - 1
	return length, column, hadNewline
end

--- Keep what the last measurement wrote.
function Printer:acceptMeasure()
	self.length = self.measureEnd
end

--- The statements of the chunk, in source order.
---@return ffi.cdata*
---@return integer
function Printer:topLevel()
	local limit = #self.parsed.statements
	local list = self.topStatements
	if not list or ffi.sizeof(list) < (limit + 1) * 4 then
		list = ffi.new("int32_t[?]", limit + 1)
		self.topStatements = list
	end
	local count = 0
	for _, index in ipairs(self.parsed.statements) do
		local node = self.nodes[index]
		if node.depth == 0 and node.isStatement then
			count += 1
			list[count] = index
		end
	end
	return list, count
end

--- Write the comments that start before an offset.
---@param from integer
---@param to integer
---@param indent integer
---@param lastLine integer?
---@param wrote boolean
---@return integer? lastLine
---@return integer cursor
---@return boolean wrote
function Printer:writeCommentsBefore(from, to, indent, lastLine, wrote)
	local index = self.lines:firstCommentAtOrAfter(from)
	while index <= self.lines.commentCount do
		local start = self.lines.commentStarts[index]
		if start >= to then break end
		local commentLine = self.lines:lineOf(start)
		if wrote then self:newline() end
		if lastLine and commentLine - lastLine > 1 then self:newline() end
		self:writeComment(index, indent)
		lastLine = self.lines:lineOf(self.lines.commentStops[index])
		from = self.lines.commentStops[index] + 1
		wrote = true
		index += 1
	end
	return lastLine, from, wrote
end

---@param index integer
---@param indent integer
function Printer:writeComment(index, indent)
	local start = self.lines.commentStarts[index]
	local stop = self.lines.commentStops[index]
	local text = self.lines:commentText(index)
	if not text:find("\n", 1, true) then
		self:writeIndent(indent)
		self:emit(text)
		return
	end

	local baseStart = self.lines:lineStartOf(start)
	local baseLen = start - baseStart
	local line = self.lines:lineOf(start)
	local first = true
	while true do
		local lineStart = self.lines.lineStarts[line]
		local lineStop = math.min(self.lines:lineEndOf(lineStart), stop)
		local from = first and start or lineStart
		if not first then
			local limit = math.min(from + baseLen - 1, lineStop)
			while from <= limit do
				local byte = self.text:byte(from)
				if byte ~= 32 and byte ~= 9 then break end
				from += 1
			end
		end
		self:writeIndent(indent)
		if from <= lineStop then self:emitSource(from, lineStop) end
		first = false
		if lineStop >= stop then break end
		self:newline()
		line += 1
	end
end

--- Write a statement copied from the source, reindented as a unit. Lines inside a multi-line
--- literal are copied exactly.
---@param node lye.parser.Node
---@param indent integer
function Printer:writeRawStatement(node, indent)
	local from = node.start
	local to = node.stop
	local baseStart = self.lines:lineStartOf(from)
	local baseLen = from - baseStart
	local line = self.lines:lineOf(from)
	local first = true
	while true do
		local lineStart = self.lines.lineStarts[line]
		local lineStop = math.min(self.lines:lineEndOf(lineStart), to)
		if first then
			self:writeIndent(indent)
			self:emitSource(from, lineStop)
			first = false
		elseif self.lines:isProtectedLine(lineStart) then
			self:emitSource(lineStart, lineStop)
		else
			local start = lineStart
			local limit = math.min(start + baseLen - 1, lineStop)
			while start <= limit do
				local byte = self.text:byte(start)
				if byte ~= 32 and byte ~= 9 then break end
				start += 1
			end
			self:newline()
			self:writeIndent(indent)
			self:emitSource(start, lineStop)
		end
		if lineStop >= to then break end
		line += 1
	end
end

--- Whether a statement can be written on the line its block header is on.
---@param node lye.parser.Node
---@param body any[]|ffi.cdata*
---@param count integer
---@return boolean
function Printer:isCompact(node, body, count)
	if self.lines:lineOf(node.start) ~= self.lines:lineOf(node.stop) then return false end
	if count > 1 then return false end
	if self.hasComments and self.lines:hasCommentIn(node.start, node.stop) then return false end
	return true
end

--- Measure one statement at indent 0 and copy it when it stays on one line.
---@param node lye.parser.Node
---@return boolean
function Printer:writeInlineStatement(node)
	self:beginMeasure()
	self:writeStatement(node, 0)
	local _, column, hadNewline = self:endMeasure()
	if hadNewline then return false end
	self:acceptMeasure()
	self.column = column
	return true
end

--- Lay out a block's statements and the comments written between them.
---@param statements any[]|ffi.cdata*
---@param count integer
---@param bodyStart integer?
---@param bodyStop integer?
---@param indent integer
---@param isChunk boolean?
---@return boolean wrote
function Printer:writeBlock(statements, count, bodyStart, bodyStop, indent, isChunk)
	local cursor = bodyStart or 1
	local limit = bodyStop or #self.text
	local lastLine
	local wrote = false
	local comments = self.lines.commentCount > 0
		and self.lines:hasCommentIn(bodyStart or 1, bodyStop or #self.text)

	for position = 1, count do
		local node = self.nodes[statements[position]]
		if comments then
			lastLine, cursor, wrote = self:writeCommentsBefore(cursor, node.start, indent, lastLine, wrote)
		end
		local nodeLine = self.lines:lineOf(node.start)
		if wrote then self:newline() end
		if lastLine and nodeLine - lastLine > 1 then self:newline() end
		self:writeStatement(node, indent)
		lastLine = self.lines:lineOf(node.stop)
		cursor = node.stop + 1
		wrote = true

		if comments then
			local nextStart = position < count and self.nodes[statements[position + 1]].start
				or (limit + 1)
			local index = self.lines:firstCommentAtOrAfter(cursor)
			if index <= self.lines.commentCount then
				local start = self.lines.commentStarts[index]
				local stop = self.lines.commentStops[index]
				local text = self.lines:commentText(index)
				if start < nextStart and start <= self.lines:lineEndOf(node.stop)
					and not text:find("\n", 1, true) then
					self:emit(" ")
					self:emitText(text)
					lastLine = self.lines:lineOf(stop)
					cursor = stop + 1
				end
			end
		end
	end

	if comments then
		lastLine, cursor, wrote = self:writeCommentsBefore(cursor, limit + 1, indent, lastLine, wrote)
	end

	if not isChunk and wrote and lastLine
		and self.lines:lineOf(limit) - lastLine > 1 then
		self:newline()
	end
	return wrote
end

---@param node lye.parser.Node
---@param indent integer
function Printer:writeStatement(node, indent)
	local kind = node.kind
	local isExpression = kind == "call" or kind == "index" or kind == "prefix"
		or kind == "binary" or kind == "unary" or kind == "ternary" or kind == "table"
	if not isExpression and self.hasComments and self.lines:hasCommentIn(node.start, node.stop) then
		if self:hasDirectComment(node) then return self:writeRawStatement(node, indent) end
	end

	if kind == "if" then
		self:writeIndent(indent)
		self:emit("if ")
		self:writeExpression(node.condition, indent)
		self:emit(" then")
		local body, count = node.thenBody or {}, #(node.thenBody or {})
		if #(node.elseIfs or {}) == 0 and node.elseBody == nil
			and self:isCompact(node, body, count) then
			if count == 0 then
				self:emit(" end")
				return
			end
			self:emit(" ")
			if self:writeInlineStatement(self.nodes[body[1]]) then
				self:emit(" end")
				return
			end
			-- The measurement wrote nothing, so lay the body out below.
			self:newline()
		else
			self:newline()
		end
		self:writeBlock(body, count, node.thenStart, node.thenStop, indent + 1)
		for _, clause in ipairs(node.elseIfs or {}) do
			self:newline()
			self:writeIndent(indent)
			self:emit("elseif ")
			self:writeExpression(clause.condition, indent)
			self:emit(" then")
			self:newline()
			self:writeBlock(clause.body, #clause.body, clause.bodyStart, clause.bodyStop, indent + 1)
		end
		if node.elseBody then
			self:newline()
			self:writeIndent(indent)
			self:emit("else")
			self:newline()
			self:writeBlock(node.elseBody, #node.elseBody, node.elseStart, node.elseStop, indent + 1)
		end
		self:newline()
		self:writeIndent(indent)
		self:emit("end")
		return
	end

	if kind == "while" then
		self:writeIndent(indent)
		self:emit("while ")
		self:writeExpression(node.condition, indent)
		self:emit(" do")
		local body, count = node.bodyStatements or {}, #(node.bodyStatements or {})
		if self:isCompact(node, body, count) then
			if count == 0 then
				self:emit(" end")
				return
			end
			self:emit(" ")
			if self:writeInlineStatement(self.nodes[body[1]]) then
				self:emit(" end")
				return
			end
			self:newline()
		else
			self:newline()
		end
		self:writeBlock(body, count, node.bodyStart, node.bodyStop, indent + 1)
		self:newline()
		self:writeIndent(indent)
		self:emit("end")
		return
	end

	if kind == "repeat" then
		self:writeIndent(indent)
		self:emit("repeat")
		local body, count = node.bodyStatements or {}, #(node.bodyStatements or {})
		if self:isCompact(node, body, count) then
			if count == 0 then
				self:emit(" until ")
				self:writeExpression(node.condition, indent)
				return
			end
			self:emit(" ")
			local index = body[1]
			if self:writeInlineStatement(self.nodes[index]) then
				self:emit(" until ")
				self:writeExpression(node.condition, indent)
				return
			end
			self:newline()
		else
			self:newline()
		end
		self:writeBlock(body, count, node.bodyStart, node.bodyStop, indent + 1)
		self:newline()
		self:writeIndent(indent)
		self:emit("until ")
		self:writeExpression(node.condition, indent)
		return
	end

	if kind == "for" then
		self:writeIndent(indent)
		self:emit("for ")
		for index, name in ipairs(node.controlNames or {}) do
			if index > 1 then self:emit(", ") end
			self:emit(name)
		end
		if node.isNumeric then
			self:emit(" = ")
			self:writeExpression(node.fromValue, indent)
			self:emit(", ")
			self:writeExpression(node.toValue, indent)
			if node.stepValue then
				self:emit(", ")
				self:writeExpression(node.stepValue, indent)
			end
		else
			self:emit(" in ")
			self:writeExpressionList(node.iteratorValues or {}, #(node.iteratorValues or {}), indent)
		end
		self:emit(" do")
		local body, count = node.bodyStatements or {}, #(node.bodyStatements or {})
		if self:isCompact(node, body, count) then
			if count == 0 then
				self:emit(" end")
				return
			end
			self:emit(" ")
			if self:writeInlineStatement(self.nodes[body[1]]) then
				self:emit(" end")
				return
			end
			self:newline()
		else
			self:newline()
		end
		self:writeBlock(body, count, node.bodyStart, node.bodyStop, indent + 1)
		self:newline()
		self:writeIndent(indent)
		self:emit("end")
		return
	end

	if kind == "do" then
		self:writeIndent(indent)
		self:emit("do")
		local body, count = node.bodyStatements or {}, #(node.bodyStatements or {})
		if self:isCompact(node, body, count) then
			if count == 0 then
				self:emit(" end")
				return
			end
			self:emit(" ")
			if self:writeInlineStatement(self.nodes[body[1]]) then
				self:emit(" end")
				return
			end
			self:newline()
		else
			self:newline()
		end
		self:writeBlock(body, count, node.bodyStart, node.bodyStop, indent + 1)
		self:newline()
		self:writeIndent(indent)
		self:emit("end")
		return
	end

	if kind == "function" then return self:writeFunction(node, indent) end

	if kind == "local" or kind == "const" then
		self:writeIndent(indent)
		self:emit2(kind, " ")
		local declarations = node.declarations or {}
		for index, declaration in ipairs(declarations) do
			if index > 1 then self:emit(", ") end
			self:emit(declaration.name)
			if declaration.inlineOptional then self:emit("?") end
			if declaration.inlineType then self:emit2(": ", declaration.inlineType) end
		end
		local values = node.children or {}
		if #values > 0 then
			self:emit(" = ")
			self:writeExpressionList(values, #values, indent)
		end
		return
	end

	if kind == "assignment" then
		self:writeIndent(indent)
		local targets = node.targets
		local targetCount = targets and #targets or 1
		for index = 1, targetCount do
			if index > 1 then self:emit(", ") end
			self:writeExpression(targets and targets[index] or node.target, indent)
		end
		self:emit2(" ", node.op or "=")
		self:emit(" ")
		local values = node.assignedValues
		local valueCount = values and #values or 1
		for index = 1, valueCount do
			if index > 1 then self:emit(", ") end
			self:writeExpression(values and values[index] or node.valueIdx, indent)
		end
		return
	end

	if kind == "return" then
		self:writeIndent(indent)
		self:emit("return")
		local values = node.children or {}
		if #values > 0 then
			self:emit(" ")
			self:writeExpressionList(values, #values, indent)
		end
		return
	end

	if kind == "break" then
		self:writeIndent(indent)
		self:emit(node.keyword or "break")
		return
	end
	if kind == "goto" then
		self:writeIndent(indent)
		self:emit2("goto ", node.name or "")
		return
	end
	if kind == "label" then
		self:writeIndent(indent)
		self:emit3("::", node.name or "", "::")
		return
	end

	if kind == "call" or kind == "index" or kind == "prefix" or kind == "binary"
		or kind == "unary" or kind == "ternary" or kind == "table" or kind == "string"
		or kind == "number" or kind == "literal" or kind == "name" then
		self:writeIndent(indent)
		self:writeExpression(node.index, indent)
		return
	end

	self:writeRawStatement(node, indent)
end

---@param values any[]|ffi.cdata*
---@param count integer
---@param indent integer
function Printer:writeExpressionList(values, count, indent)
	for index = 1, count do
		if index > 1 then self:emit(", ") end
		self:writeExpression(values[index], indent)
	end
end

--- Whether any comment in a statement is written in its own syntax, outside the expressions and
--- bodies the statement prints through a child.
---@param node lye.parser.Node
---@return boolean
function Printer:hasDirectComment(node)
	local index = self.lines:firstCommentAtOrAfter(node.start)
	local kind = node.kind
	local function inside(childIndex)
		local child = childIndex and self.nodes[childIndex]
		---@cast child table
		return child ~= nil and index <= self.lines.commentCount
			and self.lines.commentStarts[index] >= child.start
			and self.lines.commentStops[index] <= child.stop
	end
	while index <= self.lines.commentCount do
		local start = self.lines.commentStarts[index]
		if start > node.stop then break end
		local stop = self.lines.commentStops[index]
		local held = false
		if kind == "binary" then
			held = inside(node.left) or inside(node.right)
		elseif kind == "unary" then
			held = inside(node.operand)
		elseif kind == "ternary" then
			held = inside(node.left) or inside(node.right) or inside(node.alternative)
		elseif kind == "call" then
			held = inside(node.target)
			if not held then
				for _, child in ipairs(node.args or {}) do
					if inside(child) then held = true break end
				end
			end
		elseif kind == "index" then
			held = inside(node.target) or inside(node.key)
		elseif kind == "table" then
			return self:tableHasComments(node)
		elseif kind == "function" then
			held = inside(node.body)
				or (node.bodyStart ~= nil and start >= node.bodyStart and stop <= node.bodyStop)
		elseif kind == "prefix" then
			held = inside(node.group)
		elseif kind == "local" or kind == "const" or kind == "return" then
			for _, child in ipairs(node.children or {}) do
				local heldNode = self.nodes[child]
				if start >= heldNode.start and stop <= heldNode.stop then held = true break end
			end
		elseif kind == "assignment" then
			for _, child in ipairs(node.targets or { node.target }) do
				local heldNode = self.nodes[child]
				if heldNode and start >= heldNode.start and stop <= heldNode.stop then held = true break end
			end
			if not held then
				for _, child in ipairs(node.assignedValues or { node.valueIdx }) do
					local heldNode = self.nodes[child]
					if heldNode and start >= heldNode.start and stop <= heldNode.stop then held = true break end
				end
			end
		elseif kind == "if" then
			local condition = node.condition and self.nodes[node.condition]
			if condition and start >= condition.start and stop <= condition.stop then held = true end
			if not held then
				for _, clause in ipairs(node.elseIfs or {}) do
					local clauseNode = clause.condition and self.nodes[clause.condition]
					if clauseNode and start >= clauseNode.start and stop <= clauseNode.stop then
						held = true
						break
					end
				end
			end
			if not held then
				held = (node.thenStart and start >= node.thenStart and stop <= node.thenStop)
					or (node.elseStart and start >= node.elseStart and stop <= node.elseStop)
				if not held then
					for _, clause in ipairs(node.elseIfs or {}) do
						if start >= clause.bodyStart and stop <= clause.bodyStop then held = true break end
					end
				end
			end
		elseif kind == "while" or kind == "repeat" then
			local condition = node.condition and self.nodes[node.condition]
			held = (condition and start >= condition.start and stop <= condition.stop)
				or (node.bodyStart and start >= node.bodyStart and stop <= node.bodyStop)
		elseif kind == "for" then
			if start >= node.bodyStart and stop <= node.bodyStop then
				held = true
			else
				local roots = { node.fromValue, node.toValue, node.stepValue }
				for _, value in ipairs(node.iteratorValues or {}) do roots[#roots + 1] = value end
				for _, child in ipairs(roots) do
					local heldNode = child and self.nodes[child]
					if heldNode and start >= heldNode.start and stop <= heldNode.stop then held = true break end
				end
			end
		elseif kind == "do" or kind == "function" then
			held = node.bodyStart and start >= node.bodyStart and stop <= node.bodyStop
		end
		if not held then return true end
		index += 1
	end
	return false
end

--- Lay out the whole document.
---@param insertFinalNewline boolean?
---@return string
function Printer:render(insertFinalNewline)
	local statements, count = self:topLevel()
	self:writeBlock(statements, count, 1, #self.text, 0, true)
	if insertFinalNewline and self.length > 0 and self.data[self.length - 1] ~= 10 then
		self:newline()
	end
	self.out:set(self.data, self.length)
	return self.out:tostring()
end

return Printer
