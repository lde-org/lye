--[[
	JSON for LSP payloads, in bytes. Lua cannot tell an empty table from an empty
	object, so `array` and `object` tag one; `null` is distinct from an absent key.
]]

---@class lye.json.null
local NULL = setmetatable({}, { __tostring = function() return "json.null" end })

local json = {}
json.null = NULL

local ARRAY_MT = { __json = "array" }
local OBJECT_MT = { __json = "object" }

---@return table
function json.array(t)
	return setmetatable(t or {}, ARRAY_MT)
end

---@return table
function json.object(t)
	return setmetatable(t or {}, OBJECT_MT)
end

local sub, byte, char, floor = string.sub, string.byte, string.char, math.floor
local find, tonumber, format = string.find, tonumber, string.format

-- This LuaJIT build has no `|` alternation in patterns, and a character class is a
-- capture, so a scanning pattern must open with `()` to yield an offset rather than
-- matched text.
local SPEC = '()["\\\1\2\3\4\5\6\7\8\9\10\11\12\13\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\31\127]'
local NON_WS = "()[^ \t\r\n]"
local NUMBER_END = "()[%s,}%]]"
local ESCAPE = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
local ESCAPE_OUT = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
	["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local MIN_SAFE_INT, MAX_SAFE_INT = -9007199254740992, 9007199254740992

local function fail(pos, msg)
	assert(false, format("JSON error at byte %d: %s", pos, msg))
end

---@return integer
local function need(pos, src, what)
	return pos or fail(#src + 1, what)
end

---@return integer
local function put(buf, n, cp)
	if cp < 0x80 then
		buf[n + 1] = char(cp)
	elseif cp < 0x800 then
		buf[n + 1] = char(0xc0 + floor(cp / 0x40), 0x80 + cp % 0x40)
	elseif cp < 0x10000 then
		buf[n + 1] = char(0xe0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	else
		buf[n + 1] = char(
			0xf0 + floor(cp / 0x40000),
			0x80 + floor(cp / 0x1000) % 0x40,
			0x80 + floor(cp / 0x40) % 0x40,
			0x80 + cp % 0x40
		)
	end
	return n + 1
end

local decodeString
---@param src string
---@param quote integer
---@param seg integer
---@param i integer
---@return string
---@return integer
local function decodeEscapes(src, quote, seg, i)
	local buf, n = {}, 0
	while true do
		local c = byte(src, i)
		if not c then fail(quote, "unterminated string") end

		if c == 92 then
			n += 1
			buf[n] = sub(src, seg, i - 1)
			local e = sub(src, i + 1, i + 1)
			local simple = ESCAPE[e]
			if simple then
				n += 1
				buf[n] = simple
				i, seg = i + 2, i + 2
			elseif e == "u" then
				local hex = sub(src, i + 2, i + 5)
				local cp = #hex == 4 ? tonumber(hex, 16) : nil
				if not cp then fail(i, "bad \\u escape") end
				-- Surrogate pairs are out of scope. Clients send non-ASCII as raw UTF-8,
				-- and half-decoding a pair is worse than refusing it.
				if cp >= 0xd800 and cp <= 0xdfff then
					fail(i, "surrogate escape unsupported; send raw UTF-8 instead")
				end
				n = put(buf, n, cp)
				i, seg = i + 6, i + 6
			else
				fail(i, "bad escape \\" .. e)
			end
		elseif c == 34 then
			buf[n + 1] = sub(src, seg, i - 1)
			return table.concat(buf, "", 1, n + 1), i + 1
		elseif c < 32 or c == 127 then
			fail(i, "raw control character in string")
		else
			i = find(src, SPEC, i + 1) or (#src + 1)
		end
	end
end

--- When the next significant byte is the closing quote the span is returned verbatim,
--- so UTF-8 payload bytes are never re-encoded.
---@param src string
---@param i integer
---@return string
---@return integer
decodeString = function(src, i)
	local nxt = find(src, SPEC, i + 1)
	if not nxt then fail(i, "unterminated string") end
	if byte(src, nxt) == 34 then return sub(src, i + 1, nxt - 1), nxt + 1 end
	return decodeEscapes(src, i, i + 1, nxt)
end

---@return number
---@return integer
local function decodeNumber(src, i)
	local stop = find(src, NUMBER_END, i) or (#src + 1)
	local text = sub(src, i, stop - 1)
	local n, j = #text, 1

	local c = byte(text, j)
	if c == 45 then
		j += 1
		c = byte(text, j)
	end

	if c == 48 then
		j += 1
		c = byte(text, j)
		if c and c >= 48 and c <= 57 then fail(i, "leading zero in number '" .. text .. "'") end
	elseif c and c >= 49 and c <= 57 then
		repeat
			j += 1
			c = byte(text, j)
		until not c or c < 48 or c > 57
	else
		fail(i, "malformed number '" .. text .. "'")
	end

	if c == 46 then
		j += 1
		local d = byte(text, j)
		if not d or d < 48 or d > 57 then fail(i, "malformed number '" .. text .. "'") end
		repeat
			j += 1
			d = byte(text, j)
		until not d or d < 48 or d > 57
		c = d
	end

	if c == 101 or c == 69 then
		j += 1
		c = byte(text, j)
		if c == 43 or c == 45 then
			j += 1
			c = byte(text, j)
		end
		if not c or c < 48 or c > 57 then fail(i, "malformed number '" .. text .. "'") end
		repeat
			j += 1
			c = byte(text, j)
		until not c or c < 48 or c > 57
	end

	if j ~= n + 1 then fail(i, "malformed number '" .. text .. "'") end
	local value = tonumber(text)
	if value == nil then fail(i, "number out of range '" .. text .. "'") end
	return value, stop
end

local decodeValue

---@return any
---@return integer
local function decodeArray(src, i)
	local arr, n = json.array(), 0
	i = need(find(src, NON_WS, i + 1), src, "unterminated array")
	if byte(src, i) == 93 then return arr, i + 1 end

	repeat
		local value
		value, i = decodeValue(src, i)
		n += 1
		arr[n] = value

		i = need(find(src, NON_WS, i), src, "unterminated array")
		local c = byte(src, i)
		if c == 44 then
			i = need(find(src, NON_WS, i + 1), src, "unterminated array")
		elseif c == 93 then
			return arr, i + 1
		else
			fail(i, "expected ',' or ']'")
		end
	until false
end

---@return table
---@return integer
local function decodeObject(src, i)
	local obj = json.object()
	i = need(find(src, NON_WS, i + 1), src, "unterminated object")
	if byte(src, i) == 125 then return obj, i + 1 end

	repeat
		if byte(src, i) ~= 34 then fail(i, "expected object key") end
		local key
		key, i = decodeString(src, i)

		i = need(find(src, NON_WS, i), src, "unterminated object")
		if byte(src, i) ~= 58 then fail(i, "expected ':' after key") end

		i = need(find(src, NON_WS, i + 1), src, "unterminated object")
		local value
		value, i = decodeValue(src, i)
		obj[key] = value

		i = need(find(src, NON_WS, i), src, "unterminated object")
		local c = byte(src, i)
		if c == 44 then
			i = need(find(src, NON_WS, i + 1), src, "unterminated object")
		elseif c == 125 then
			return obj, i + 1
		else
			fail(i, "expected ',' or '}'")
		end
	until false
end

---@return any
---@return integer
decodeValue = function(src, i)
	i = find(src, NON_WS, i)
	if not i then fail(#src + 1, "unexpected end of input") end

	local c = byte(src, i)
	if c == 123 then return decodeObject(src, i) end
	if c == 91 then return decodeArray(src, i) end
	if c == 34 then return decodeString(src, i) end
	if c == 116 and sub(src, i, i + 3) == "true" then return true, i + 4 end
	if c == 102 and sub(src, i, i + 4) == "false" then return false, i + 5 end
	if c == 110 and sub(src, i, i + 3) == "null" then return NULL, i + 4 end
	if c == 45 or (c >= 48 and c <= 57) then return decodeNumber(src, i) end
	fail(i, format("unexpected byte 0x%02x", c))
end

---@return any
function json.decode(src)
	assert(type(src) == "string", "json.decode expects a string")
	local value, i = decodeValue(src, 1)
	local tail = find(src, NON_WS, i)
	if tail then fail(tail, "trailing data after JSON value") end
	return value
end

---@return any? value
---@return string? err
function json.tryDecode(src)
	local ok, value = pcall(json.decode, src)
	if ok then return value end
	return nil, tostring(value)
end

---@return string
local function encodeString(s)
	if not find(s, '[%c"\\\127]') then return '"' .. s .. '"' end
	return '"' .. s:gsub('[%c"\\\127]', function(c)
		return ESCAPE_OUT[c] or format("\\u%04x", byte(c))
	end) .. '"'
end

---@return string
local function encodeNumber(n)
	assert(n == n and n ~= math.huge and n ~= -math.huge, "cannot encode non-finite number as JSON: " .. tostring(n))
	-- LSP fields typed `integer` must not serialize as `1.0`.
	if n == floor(n) and n >= MIN_SAFE_INT and n <= MAX_SAFE_INT then
		return format("%d", n)
	end
	return format("%.14g", n)
end

local encodeValue

---@return boolean
local function isArray(t)
	local mt = getmetatable(t)
	if mt == ARRAY_MT then return true end
	if mt == OBJECT_MT then return false end

	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" then return false end
		n += 1
	end
	return n > 0 and t[n] ~= nil
end

---@return string
encodeValue = function(value)
	local t = type(value)
	if value == nil or value == NULL then return "null" end
	if t == "boolean" then return value ? "true" : "false" end
	if t == "number" then return encodeNumber(value) end
	if t == "string" then return encodeString(value) end
	assert(t == "table", "cannot encode " .. t .. " as JSON")

	local parts, n = {}, 0
	if isArray(value) then
		for i = 1, #value do
			n += 1
			parts[n] = encodeValue(value[i])
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end

	for k, v in pairs(value) do
		n += 1
		parts[n] = encodeString(type(k) == "string" ? k : tostring(k)) .. ":" .. encodeValue(v)
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

---@return string
function json.encode(value)
	return encodeValue(value)
end

return json
