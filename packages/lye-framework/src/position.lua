--[[
	Conversion between LSP positions and byte offsets, and the only place allowed to do
	it. A `Position.character` counts code units in the negotiated encoding while
	everything else counts bytes, and a UTF-16 offset can land inside a UTF-8 sequence.
]]

local position = {}

position.UTF8 = "utf-8"
position.UTF16 = "utf-16"

---@class lye.framework.LineIndex
---@field starts integer[]
---@field length integer

---@return lye.framework.LineIndex
function position.buildLineIndex(text)
	local starts, count = { 1 }, 1
	local i, len = 1, #text
	while i <= len do
		local byteAt = text:byte(i)
		if byteAt == 10 then
			count += 1
			starts[count] = i + 1
		elseif byteAt == 13 then
			-- \r\n is one terminator, not two.
			if text:byte(i + 1) == 10 then i += 1 end
			count += 1
			starts[count] = i + 1
		end
		i += 1
	end
	return { starts = starts, length = len }
end

--- Binary search, because a linear scan on every conversion is unusable in a large file.
---@param index lye.framework.LineIndex
---@param offset integer 1-based
---@return integer line
---@return integer lineStart 1-based byte offset of that line's first byte
local function lineAt(index, offset)
	local starts = index.starts
	local low, high = 1, #starts
	while low < high do
		-- `//` is not available on this LuaJIT build, so floor explicitly.
		local mid = math.floor((low + high + 1) / 2)
		if starts[mid] <= offset then low = mid else high = mid - 1 end
	end
	return low - 1, starts[low]
end

position.lineAt = lineAt

---@return integer?
function position.lineStart(index, line)
	return index.starts[line + 1]
end

---@return string
function position.lineText(text, index, line)
	local start = index.starts[line + 1]
	if not start then return "" end
	local stop = (index.starts[line + 2] or (index.length + 1)) - 1
	-- Trim the terminator: \r\n is two bytes.
	while stop >= start and (text:byte(stop) == 10 or text:byte(stop) == 13) do
		stop -= 1
	end
	return text:sub(start, stop)
end

---@return integer
local function utf16Length(line, byteCount)
	if not line:find("[\128-\255]") then return byteCount end

	local units, i = 0, 1
	while i <= byteCount do
		local byteAt = line:byte(i)
		if byteAt < 0x80 then
			units += 1
			i += 1
		elseif byteAt < 0xe0 then
			units += 1
			i += 2
		elseif byteAt < 0xf0 then
			units += 1
			i += 3
		else
			units += 2
			i += 4
		end
	end
	return units
end

position.utf16Length = utf16Length

---@return integer
local function utf16ToBytes(line, units)
	if not line:find("[\128-\255]") then return math.min(units, #line) end

	local used, bytes, i = 0, 0, 1
	while i <= #line and used < units do
		local byteAt = line:byte(i)
		local width = byteAt < 0x80 and 1 or (byteAt < 0xe0 and 2 or (byteAt < 0xf0 and 3 or 4))
		local cost = width == 4 ? 2 : 1
		if used + cost > units then break end
		used += cost
		bytes += width
		i += width
	end
	return bytes
end

--- Clamped: the end of the line, or the end of the file.
---@param text string
---@param index lye.framework.LineIndex
---@param line integer
---@param character integer
---@param encoding string
---@return integer
function position.toOffset(text, index, line, character, encoding)
	local start = index.starts[line + 1]
	if not start then return index.length + 1 end

	local lineText = position.lineText(text, index, line)
	if encoding == position.UTF16 then
		local byteCount = utf16ToBytes(lineText, character)
		return start + byteCount
	end
	return start + math.min(character, #lineText)
end

---@param text string
---@param index lye.framework.LineIndex
---@param offset integer
---@param encoding string
---@return integer line
---@return integer character
function position.toPosition(text, index, offset, encoding)
	if offset < 1 then return 0, 0 end
	local line, start = lineAt(index, offset)
	if encoding == position.UTF8 then return line, offset - start end

	local lineText = position.lineText(text, index, line)
	local byteCount = math.min(offset - start, #lineText)
	return line, utf16Length(lineText, byteCount)
end

return position
