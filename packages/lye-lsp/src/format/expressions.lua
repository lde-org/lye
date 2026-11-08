--[[
	Expression layout. The tree already holds the grouping the parser worked out; this module
	only decides where a pair of parentheses is needed to keep the same tree when the text is
	read again, and writes the operators with the spaces the engine's style asks for.

	Everything is written into the printer's `string.buffer`. Measurement for a table, call or
	chain writes into a reusable scratch buffer, so a layout decision makes no Lua string and no
	per-node table.
]]

local ffi = require("ffi")
local Parser = require("lye-parser")
local Printer = require("lye-lsp.format.printer")

local TERNARY_LEVEL = 0
local UNARY_LEVEL = 12
local PRIMARY_LEVEL = 14

---@type table<string, integer>
local LEVEL = {}
for operator, level in pairs(Parser.BINARY_LEVEL or {}) do LEVEL[operator] = level end
LEVEL["^"] = 13

---@param node table
local function levelOf(node)
	if node.kind == "binary" then return LEVEL[node.op or ""] or 1 end
	if node.kind == "unary" then return UNARY_LEVEL end
	if node.kind == "ternary" then return TERNARY_LEVEL end
	return PRIMARY_LEVEL
end

--- Whether an operand needs a pair of parentheses of its own.
---@param node table
---@param parentLevel integer
---@param isRight boolean
---@param parentOp string?
local function needsParens(node, parentLevel, isRight, parentOp)
	if parentOp == "^" and node.kind == "unary" then return false end
	local held = levelOf(node)
	if held < parentLevel then return true end
	if held > parentLevel then return false end
	if parentOp == ".." then return false end
	if parentOp == "^" or parentOp == "??" then return not isRight end
	return isRight
end

---@param text string
local function isLineComment(text)
	return text:byte(1) == 45 and text:byte(2) == 45 and text:find("^%-%-%[=*%[") == nil
end

---@param self table
---@param index integer?
---@param indent integer
---@param parentLevel integer?
---@param isRight boolean?
---@param parentOp string?
---@param self table
function Printer:writeOperand(index, indent, parentLevel, isRight, parentOp)
	if not index then return end
	local node = self.nodes[index]
	if not node then return end
	local kind = node.kind
	if not node.isGrouped then
		if kind == "literal" then
			self:emit(node.text or "")
			return
		end
		if kind == "string" or kind == "number" then
			self:emitSource(node.start, node.stop)
			return
		end
		if kind == "name" then
			self:emit(node.name or "")
			return
		end
		if kind == "prefix" and not node.group then
			self:emit(node.callee or node.name or "")
			return
		end
	end
	local wrap = node.isGrouped
		or (parentLevel ~= nil and needsParens(node, parentLevel, isRight == true, parentOp))
	if wrap then self:emit("(") end
	if self.hasComments and self:hasDirectComment(node) then
		self:writeCommentedExpression(node, indent)
	else
		self:writePlainExpression(node, indent)
	end
	if wrap then self:emit(")") end
end

---@param index integer?
---@param indent integer
---@param self table
function Printer:writeExpression(index, indent)
	self:writeOperand(index, indent, nil, false, nil)
end

--- Write comments in one gap between two children. Returns whether the last one ended its line.
---@param from integer
---@param to integer
---@param indent integer
---@return boolean
---@param self table
function Printer:writeGapComments(from, to, indent)
	local endsLine = false
	local index = self.lines:firstCommentAtOrAfter(from)
	while index <= self.lines.commentCount do
		local start = self.lines.commentStarts[index]
		if start > to then break end
		local stop = self.lines.commentStops[index]
		if stop <= to then
			local text = self.lines:commentText(index)
			self:emit(" ")
			self:emitText(text)
			endsLine = isLineComment(text)
			if endsLine then
				self:newline()
				self:writeIndent(indent + 1)
			end
		end
		index += 1
	end
	return endsLine
end

---@param node table
---@param indent integer
---@param self table
function Printer:writeCommentedExpression(node, indent)
	local kind = node.kind

	if kind == "binary" then
		local left, right = self.nodes[node.left], self.nodes[node.right]
		self:writeOperand(node.left, indent, levelOf(node), false, node.op)
		local endsLine = self:writeGapComments(left.stop, right.start, indent)
		if not endsLine then self:emit3(" ", node.op or "?", " ")
		else self:emit2(node.op or "?", " ") end
		self:writeOperand(node.right, indent, levelOf(node), true, node.op)
		return
	end

	if kind == "unary" then
		local op = node.op or "not"
		self:emit2(op, " ")
		local operand = self.nodes[node.operand]
		local endsLine = self:writeGapComments(node.start + #op, operand.start, indent)
		if not endsLine then self:emit(" ") end
		self:writeOperand(node.operand, indent, UNARY_LEVEL, false, op)
		return
	end

	if kind == "index" then
		local target = self.nodes[node.target]
		self:writeOperand(node.target, indent, PRIMARY_LEVEL, false, "suffix")
		local endsLine = self:writeGapComments(target.stop, node.stop, indent)
		if not endsLine then self:emit(" ") end
		if node.isSafe then
			if node.isDynamic then
				self:emit("?.[")
				self:writeExpression(node.key, indent)
				self:emit("]")
			else
				self:emit2("?.", node.field or "")
			end
		elseif node.isDynamic then
			self:emit("[")
			self:writeExpression(node.key, indent)
			self:emit("]")
		else
			self:emit2(".", node.field or "")
		end
		return
	end

	if kind == "call" then
		if node.hasParens == false or node.isSafe then
			self:emitSource(node.start, node.stop)
			return
		end
		local target = self.nodes[node.target]
		self:writeOperand(node.target, indent, PRIMARY_LEVEL, false, "suffix")
		if node.isMethod then self:emit2(":", node.field or "") end
		self:emit("(")
		local previous = target.stop
		local args = node.args or {}
		for position, argument in ipairs(args) do
			local argumentNode = self.nodes[argument]
			local endsLine = self:writeGapComments(previous, argumentNode.start, indent)
			if position > 1 then self:emit(", ") end
			if #args > 0 and not endsLine and previous > target.stop then self:emit(" ") end
			self:writeExpression(argument, indent)
			previous = argumentNode.stop
		end
		local endsLine = self:writeGapComments(previous, node.stop, indent)
		if not endsLine and previous > target.stop then self:emit(" ") end
		self:emit(")")
		return
	end

	if kind == "ternary" then
		local condition = self.nodes[node.left]
		local thenNode = self.nodes[node.right]
		local alternative = self.nodes[node.alternative]
		self:writeOperand(node.left, indent, TERNARY_LEVEL, false, "?")
		local endsLine = self:writeGapComments(condition.stop, thenNode.start, indent)
		if not endsLine then self:emit(" ") end
		self:emit("? ")
		self:writeExpression(node.right, indent)
		endsLine = self:writeGapComments(thenNode.stop, alternative.start, indent)
		if not endsLine then self:emit(" ") end
		self:emit(": ")
		self:writeExpression(node.alternative, indent)
		return
	end

	if kind == "table" then return self:writeTableWithComments(node, indent) end
	if kind == "function" then
		self:emitSource(node.start, node.stop)
		return
	end
	self:emitSource(node.start, node.stop)
end

---@param node table
---@param indent integer
---@param self table
function Printer:writePlainExpression(node, indent)
	local kind = node.kind

	if kind == "prefix" then
		if node.group then
			self:emit("(")
			self:writeExpression(node.group, indent)
			self:emit(")")
			return
		end
		if node.callee then
			self:emit(node.callee)
			return
		end
		if node.name then
			self:emit(node.name)
			return
		end
		self:emitSource(node.start, node.stop)
		return
	end

	if kind == "index" or kind == "call" then
		local targetNode = node.target and self.nodes[node.target]
		if not self.noBreak and targetNode and (targetNode.kind == "call" or targetNode.kind == "index") then
			self:writeChain(node, indent)
			return
		end
		self:writeOperand(node.target, indent, PRIMARY_LEVEL, false, "suffix")
		self:writeSuffix(node, indent)
		return
	end

	if kind == "binary" then
		local level = levelOf(node)
		self:writeOperand(node.left, indent, level, false, node.op)
		self:emit3(" ", node.op or "?", " ")
		self:writeOperand(node.right, indent, level, true, node.op)
		return
	end

	if kind == "unary" then
		local op = node.op or "not"
		self:emit(op)
		local operand = self.nodes[node.operand]
		if op == "not" then
			self:emit(" ")
		elseif op == "-" and operand.kind == "unary" and operand.op == "-" then
			self:emit(" ")
		end
		self:writeOperand(node.operand, indent, UNARY_LEVEL, false, op)
		return
	end

	if kind == "ternary" then
		self:writeOperand(node.left, indent, TERNARY_LEVEL, false, "?")
		self:emit(" ? ")
		local held = node.right and self.nodes[node.right]
		if held and held.kind == "ternary" and not held.isGrouped then
			self:emit("(")
			self:writeExpression(node.right, indent)
			self:emit(")")
		else
			self:writeExpression(node.right, indent)
		end
		self:emit(" : ")
		self:writeOperand(node.alternative, indent, TERNARY_LEVEL, true, "?")
		return
	end

	if kind == "function" then
		self:writeFunction(node, indent)
		return
	end
	if kind == "table" then
		self:writeTable(node, indent)
		return
	end
	if kind == "string" or kind == "number" then
		self:emitSource(node.start, node.stop)
		return
	end
	if kind == "literal" then
		self:emit(node.text or "")
		return
	end
	if kind == "name" then
		self:emit(node.name or "")
		return
	end
	self:emitSource(node.start, node.stop)
end

---@param node table
---@param indent integer
---@param prefix string
---@param self table
function Printer:writeTableField(node, indent, prefix)
	self:emit(prefix)
	self:writeExpression(node.value, indent)
end

---@param field table
---@param indent integer
---@param self table
function Printer:writeField(field, indent)
	if field.kind == "name" then
		self:emit(field.name or "")
		self:emit(" = ")
		self:writeExpression(field.value, indent)
	elseif field.kind == "key" then
		self:emit("[")
		self:writeExpression(field.key, indent)
		self:emit("] = ")
		self:writeExpression(field.value, indent)
	else
		self:writeExpression(field.value, indent)
	end
end

---@param node table
---@return boolean
---@param self table
function Printer:tableHasComments(node)
	local index = self.lines:firstCommentAtOrAfter(node.start)
	while index <= self.lines.commentCount do
		local start = self.lines.commentStarts[index]
		if start > node.stop then break end
		local stop = self.lines.commentStops[index]
		local inside = false
		for _, field in ipairs(node.fields or {}) do
			---@cast field table
			local value = self.nodes[field.value]
			---@cast value table
			if start >= value.start and stop <= value.stop then inside = true break end
			if field.kind == "key" then
				local key = self.nodes[field.key]
				if start >= key.start and stop <= key.stop then inside = true break end
			end
		end
		if not inside then return true end
		index += 1
	end
	return false
end

---@param node table
---@param indent integer
---@param self table
function Printer:writeTableInline(node, indent)
	local fields = node.fields or {}
	if #fields == 0 then
		self:emit("{}")
		return
	end
	local trail = self.settings.trailing_table_separator == "always"
	self:emit("{ ")
	for position, field in ipairs(fields) do
		self:writeField(field, indent)
		if position < #fields then
			self:emit2(self:fieldSeparator(field), " ")
		elseif trail then
			self:emit(self:fieldSeparator(field))
		end
	end
	self:emit(" }")
end

---@param node table
---@param indent integer
---@param self table
function Printer:writeTableBroken(node, indent)
	local fields = node.fields or {}
	local trail = self.settings.trailing_table_separator == "always"
	self:emit("{")
	for position, field in ipairs(fields) do
		self:newline()
		self:writeIndent(indent + 1)
		self:writeField(field, indent + 1)
		if position < #fields or trail then self:emit(self:fieldSeparator(field)) end
	end
	self:newline()
	self:writeIndent(indent)
	self:emit("}")
end

---@param node table
---@param indent integer
---@param self table
function Printer:writeTable(node, indent)
	if self:tableHasComments(node) then
		self:writeTableWithComments(node, indent)
		return
	end
	if self.noBreak or self:shortEnough(node) then
		self:writeTableInline(node, indent)
		return
	end
	self:beginMeasure()
	self:writeTableInline(node, indent)
	local length, column, hadNewline = self:endMeasure()
	if hadNewline or self.column - 1 + length > self.maxLineLength then
		self:writeTableBroken(node, indent)
	else
		self:acceptMeasure()
		self.column = column
	end
end

---@param node table
---@param indent integer
---@param self table
function Printer:writeTableWithComments(node, indent)
	local fields = node.fields or {}
	local trail = self.settings.trailing_table_separator == "always"
	local index = self.lines:firstCommentAtOrAfter(node.start)

	---@param start integer
	---@param stop integer
	---@return boolean
	local function insideField(start, stop)
		for _, field in ipairs(fields) do
			---@cast field table
			local value = self.nodes[field.value]
			---@cast value table
			if start >= value.start and stop <= value.stop then return true end
			if field.kind == "key" then
				local key = self.nodes[field.key]
				if start >= key.start and stop <= key.stop then return true end
			end
		end
		return false
	end

	---@param offset integer
	local function before(offset)
		while index <= self.lines.commentCount do
			local start = self.lines.commentStarts[index]
			if start >= offset then break end
			local stop = self.lines.commentStops[index]
			if not insideField(start, stop) then
				self:newline()
				self:writeIndent(indent + 1)
				self:emitText(self.lines:commentText(index))
			end
			index += 1
		end
	end

	---@param offset integer
	local function sameLine(offset)
		local line = self.lines:lineOf(offset)
		while index <= self.lines.commentCount do
			local start = self.lines.commentStarts[index]
			if start <= offset or self.lines:lineOf(start) ~= line then break end
			local stop = self.lines.commentStops[index]
			if not insideField(start, stop) then
				self:emit(" ")
				self:emitText(self.lines:commentText(index))
			end
			index += 1
		end
	end

	self:emit("{")
	local firstStart = fields[1] and self:fieldStart(fields[1]) or node.stop
	before(firstStart)
	for position, field in ipairs(fields) do
		before(self:fieldStart(field))
		self:newline()
		self:writeIndent(indent + 1)
		self:writeField(field, indent + 1)
		if position < #fields or trail then self:emit(self:fieldSeparator(field)) end
		---@cast field table
		local value = self.nodes[field.value]
		---@cast value table
		sameLine(value.stop)
	end
	while index <= self.lines.commentCount and self.lines.commentStarts[index] <= node.stop do
		local start = self.lines.commentStarts[index]
		local stop = self.lines.commentStops[index]
		if not insideField(start, stop) then
			self:newline()
			self:writeIndent(indent + 1)
			self:emitText(self.lines:commentText(index))
		end
		index += 1
	end
	self:newline()
	self:writeIndent(indent)
	self:emit("}")
end

---@param node table
---@return integer
---@param self table
function Printer:fieldStart(node)
	if node.kind == "name" and node.nameStart then return node.nameStart end
	local index = node.kind == "key" and node.key or node.value
	local held = self.nodes[index]
	return held.start
end

---@param field table
---@return string
---@param self table
function Printer:fieldSeparator(field)
	if self.settings.table_separator_style then return self.separator end
	return field.separator or self.separator
end

---@param node table
---@param self table
function Printer:writeParameters(node)
	local written = false
	for _, parameter in ipairs(node.params or {}) do
		---@cast parameter table
		if not parameter.isImplicit then
			if written then self:emit(", ") end
			self:emit(parameter.name)
			if parameter.inlineOptional then self:emit("?") end
			if parameter.inlineType then
				self:emit(": ")
				self:emitText(parameter.inlineType)
			end
			written = true
		end
	end
	if node.isVariadic then
		if written then self:emit(", ") end
		self:emit("...")
		if node.inlineVariadic then
			self:emit(": ")
			self:emitText(node.inlineVariadic)
		end
	end
end

---@param node table
---@param indent integer
---@param self table
function Printer:writeFunction(node, indent)
	local body = node.bodyStatements or {}
	local count = #body
	local isStatement = node.isLocal == true or node.name ~= nil

	if node.isArrow then
		if node.isBareArrow then
			self:writeParameters(node)
			self:emit(" -> ")
		else
			self:emit("|")
			self:writeParameters(node)
			self:emit("| -> ")
		end
		self:writeExpression(node.body, indent)
		return
	end

	if isStatement then self:writeIndent(indent) end
	if node.isLocal then
		if node.name then
			self:emit3("local function ", node.name, "")
		else
			self:emit("local function")
		end
	elseif node.name then
		self:emit2("function ", node.name)
	else
		self:emit("function")
	end
	if node.inlineGenerics then self:emitText(node.inlineGenerics) end
	self:emit("(")
	self:writeParameters(node)
	self:emit(")")
	if node.inlineReturns then
		self:emit2(": ", node.inlineReturns)
	end

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
end

---@param self table
---@param node table
function Printer:writeCallPrefix(node)
	if node.isMethod then
		if node.isSafe then self:emit("?.:") else self:emit(":") end
		self:emit(node.field or "")
	elseif node.isSafe then
		self:emit("?.")
	end
end

---@param self table
---@param node table
---@param indent integer
function Printer:writeSuffixInline(node, indent)
	if node.kind == "index" then
		if node.isSafe then
			if node.isDynamic then
				self:emit("?.[")
				self:writeExpression(node.key, indent)
				self:emit("]")
			else
				self:emit2("?.", node.field or "")
			end
		elseif node.isDynamic then
			self:emit("[")
			self:writeExpression(node.key, indent)
			self:emit("]")
		else
			self:emit2(".", node.field or "")
		end
		return
	end

	self:writeCallPrefix(node)
	local args = node.args or {}
	if #args == 0 then
		self:emit("()")
		return
	end
	local hasParens = node.hasParens ~= false
	local setting = self.settings.call_arg_parentheses
	if setting == "always" then
		hasParens = true
	elseif setting == "none" then
		local only = self.nodes[args[1]]
		hasParens = not (#args == 1 and only
			and (only.kind == "string" or only.kind == "table"))
	end
	if not hasParens and not node.isSafe and #args == 1 then
		local only = self.nodes[args[1]]
		if only and (only.kind == "string" or only.kind == "table") then
			self:writeExpression(args[1], indent)
			return
		end
	end
	self:emit("(")
	self:writeExpressionList(args, #args, indent)
	self:emit(")")
end

---@param node table
---@param indent integer
---@param self table
function Printer:writeSuffixBroken(node, indent)
	self:writeCallPrefix(node)
	self:emit("(")
	local args = node.args or {}
	for position, argument in ipairs(args) do
		self:newline()
		self:writeIndent(indent + 1)
		self:writeExpression(argument, indent + 1)
		if position < #args then self:emit(",") end
	end
	self:newline()
	self:writeIndent(indent)
	self:emit(")")
end

---@param node table
---@param indent integer
---@param self table
function Printer:writeSuffix(node, indent)
	if node.kind == "index" then return self:writeSuffixInline(node, indent) end
	local args = node.args or {}
	if #args == 0 then return self:writeSuffixInline(node, indent) end
	local hasParens = node.hasParens ~= false
	local setting = self.settings.call_arg_parentheses
	if setting == "always" then
		hasParens = true
	elseif setting == "none" then
		local only = self.nodes[args[1]]
		hasParens = not (#args == 1 and only
			and (only.kind == "string" or only.kind == "table"))
	end
	if not hasParens and not node.isSafe and #args == 1 then
		local only = self.nodes[args[1]]
		if only and (only.kind == "string" or only.kind == "table") then
			return self:writeSuffixInline(node, indent)
		end
	end
	if self.noBreak or self:shortEnough(node) then return self:writeSuffixInline(node, indent) end
	self:beginMeasure()
	self:writeSuffixInline(node, indent)
	local length, column, hadNewline = self:endMeasure()
	if hadNewline or self.column - 1 + length <= self.maxLineLength then
		self:acceptMeasure()
		self.column = column
		if hadNewline then self.hadNewline = true end
	else
		self:writeSuffixBroken(node, indent)
	end
end

---@param node table
---@return ffi.cdata*
---@return integer baseIndex
---@return integer count
---@param self table
function Printer:collectChain(node)
	local depth = self.chainDepth + 1
	self.chainDepth = depth
	local slots = self.chainArrays[depth]
	if not slots then
		slots = ffi.new("int32_t[?]", 64)
		self.chainArrays[depth] = slots
	end
	local count = 0
	local current = node
	while current and (current.kind == "call" or current.kind == "index") do
		if not current.target then break end
		count += 1
		if count > ffi.sizeof(slots) / 4 - 1 then
			local bigger = ffi.new("int32_t[?]", count * 2)
			for index = 1, count - 1 do bigger[index] = slots[index] end
			slots = bigger
			self.chainArrays[depth] = slots
		end
		slots[count] = current.index
		local target = self.nodes[current.target]
		if not target or (target.kind ~= "call" and target.kind ~= "index") then
			for left = 1, math.floor(count / 2) do
				local right = count - left + 1
				slots[left], slots[right] = slots[right], slots[left]
			end
			return slots, current.target, count
		end
		current = target
	end
	-- Not a chain: the caller still owns the depth and will restore it.
	return slots, node.target or node.index, 0
end

---@param slots ffi.cdata*
---@param count integer
---@param base integer
---@param indent integer
---@param self table
function Printer:writeChainInline(slots, count, base, indent)
	self:writeExpression(base, indent)
	for index = 1, count do
		local node = self.nodes[slots[index]]
		self:writeSuffixInline(node, indent)
	end
end

---@param node table
---@param indent integer
---@param self table
function Printer:writeChain(node, indent)
	local slots, base, count = self:collectChain(node)
	---@cast slots ffi.cdata*
	---@cast base integer
	---@cast count integer
	if count < 2 then
		self.chainDepth -= 1
		self:writeOperand(node.target, indent, PRIMARY_LEVEL, false, "suffix")
		self:writeSuffix(node, indent)
		return
	end
	if self.noBreak or self:shortEnough(node) then
		self:writeChainInline(slots, count, base, indent)
		self.chainDepth -= 1
		return
	end
	self:beginMeasure()
	self:writeChainInline(slots, count, base, indent)
	local length, column, hadNewline = self:endMeasure()
	if hadNewline or self.column - 1 + length <= self.maxLineLength then
		self:acceptMeasure()
		self.column = column
		if hadNewline then self.hadNewline = true end
		self.chainDepth -= 1
		return
	end

	self:writeExpression(base, indent)
	local first = 1
	while first <= count do
		local node = self.nodes[slots[first]]
		self:writeSuffix(node, indent)
		first += 1
		if node.kind == "call" then break end
	end
	if first <= count then
		self:newline()
		self:writeIndent(indent + 1)
	end
	local padBytes = (indent + 1) * self.unitLen
	while first <= count do
		local node = self.nodes[slots[first]]
		self:beginMeasure()
		self:writeSuffixInline(node, indent + 1)
		local innerLength, innerColumn, innerHad = self:endMeasure()
		if not innerHad and self.column - 1 + innerLength <= self.maxLineLength then
			self:acceptMeasure()
			self.column = innerColumn
		else
			if self.column > padBytes + 1 then
				self:newline()
				self:writeIndent(indent + 1)
				self:beginMeasure()
				self:writeSuffixInline(node, indent + 1)
				innerLength, innerColumn, innerHad = self:endMeasure()
			end
			if not innerHad and self.column - 1 + innerLength <= self.maxLineLength then
				self:acceptMeasure()
			self.column = innerColumn
			else
				self:writeSuffixBroken(node, indent + 1)
			end
		end
		first += 1
	end
	self.chainDepth -= 1
end

return Printer
