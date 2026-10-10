--[[
	Tokenizer for LuaJIT, including its LuaJIT 3.0 syntax backports.

	Tokens live in an FFI arena: one struct per token holding its kind, its source span and a
	number's value, with the text beside it in a parallel array. A scan therefore allocates
	nothing per token. Whitespace is not emitted; comments are, because a comment is content
	that a later annotation pass needs.
]]

local ffi = require("ffi")
local newTable = require("table.new")

ffi.cdef[[
	typedef struct {
		int32_t index;
		int32_t kind;
		int32_t start;
		int32_t stop;
		double extra;
	} lye_token;
]]

--- Token kinds are integers, so a token is a struct rather than a table and a scan allocates
--- nothing per token. The kind names are for readers; comparisons use KIND.
local KIND = {
	name = 1, number = 2, string = 3, keyword = 4, symbol = 5, comment = 6, label = 7, eof = 8,
}
local VARIANT = { "name", "number", "string", "keyword", "symbol", "comment", "label", "eof" }

local lexer = {}
lexer.KIND = KIND

local KEYWORDS = {}
for word in string.gmatch("and break do else elseif end false for function if in local nil not or repeat return then true until while const continue", "%S+") do
	KEYWORDS[word] = true
end

--- Operators, longest first so the scanner cannot stop short of a compound form.
local OPERATORS = {
	"~>>=", "...", "..=", "::", "==", "~=", "!=", "<=", ">=", "<<=", ">>=",
	"<<", ">>", "~>>", "&&", "||", "+=", "-=", "*=", "/=", "%=", "^=", "|=",
	"&=", "?.", "??", "->", "..", "+", "-", "*", "/", "%", "^", "#", "&",
	"~", "|", "<", ">", "=", "?", ":", "(", ")", "{", "}", "[", "]", ";",
	",", ".", "!",
}
table.sort(OPERATORS, function(a, b) return #a > #b or (#a == #b and a < b) end)

--- Operators grouped by their first byte, longest first within a group, so a scan compares
--- against a handful of candidates instead of all of them.
local SYMBOLS_BY_FIRST = {}
for _, symbol in ipairs(OPERATORS) do
	local first = symbol:byte(1)
	SYMBOLS_BY_FIRST[first] = SYMBOLS_BY_FIRST[first] or {}
	local group = SYMBOLS_BY_FIRST[first]
	-- The length and second byte travel with the symbol, so a scan can rule a candidate out
	-- without searching the source for it.
	group[#group + 1] = { text = symbol, len = #symbol, second = symbol:byte(2) }
end

--- A token is a struct in an FFI array: `tokens.arena[index]` holds `kind`, the byte span and
--- a number's value. Its text lives beside it in `tokens.texts`, one entry per token, because a
--- struct cannot hold a Lua string. Keywords and operators put one shared string there.
---@class lye.lexer.ffi.token
---@field index integer its 1-based position in the arena
---@field kind integer one of KIND
---@field start integer 1-based byte offset of the first byte
---@field stop integer 1-based byte offset of the last byte
---@field extra number a number's value, or a string's escape count

--- A literal the scan could not finish. It is reported rather than raised: the tokens around
--- it are still what an editor needs, and the parser turns this into a diagnostic.
---@class lye.lexer.Problem
---@field message string the message, with the line it starts on
---@field start integer
---@field stop integer

---@class lye.lexer.Tokens
---@field arena lye.lexer.ffi.token* the struct array; index 0 is unused
---@field texts string[] one entry per token, indexed like the arena
---@field count integer how many tokens there are, the eof token included
---@field problems lye.lexer.Problem[] what a scan could not finish, empty for a whole source

---@class lye.lexer.Lexer
---@field source string
---@field pos integer
---@field arena lye.lexer.ffi.token*
---@field texts string[]
---@field capacity integer
---@field count integer
local Lexer = {}
Lexer.__index = Lexer

--- Tokens run about one per four bytes of source, so the arena starts near its final size and
--- doubles if the estimate is low.
---@param source string
---@return lye.lexer.Lexer
function Lexer.new(source)
	local capacity = math.floor(#source / 4) + 16
	return setmetatable({
		source = source, pos = 1, arena = ffi.new("lye_token[?]", capacity + 1),
		texts = newTable(capacity, 0), capacity = capacity, count = 0, problems = {},
	}, Lexer)
end

---@param self lye.lexer.Lexer
local function grow(self)
	local capacity = self.capacity * 2
	local arena = ffi.new("lye_token[?]", capacity + 1)
	ffi.copy(arena, self.arena, (self.count + 1) * ffi.sizeof("lye_token"))
	self.arena, self.capacity = arena, capacity
end

---@param token lye.lexer.ffi.token
---@return string
function lexer.variantOf(token)
	return VARIANT[token.kind]
end

lexer.Lexer = Lexer

--- A source that is being typed holds half-written literals, and refusing to tokenize it is
--- how a completion stops working the moment a quote is opened. A scanner that cannot finish
--- reads to the end of the input instead and records what it could not finish, which the
--- parser reports as the syntax error it is.
---@param self lye.lexer.Lexer
---@param at integer
---@param stop integer
---@param msg string
local function fail(self, at, stop, msg)
	local line = 1
	for i = 1, at - 1 do
		if self.source:byte(i) == 10 then line += 1 end
	end
	self.problems[#self.problems + 1] = {
		message = string.format("%s at line %d", msg, line), start = at, stop = stop,
	}
end

--- A token's text is its own source slice, except for keywords and operators, whose text is
--- one shared string. A scanner that copies a slice per operator allocates on every one.
---@param self lye.lexer.Lexer
---@param kind integer
---@param start integer
---@param stop integer
---@param extra number?
---@param text string?
local function emit(self, kind, start, stop, extra, text)
	local count = self.count + 1
	if count > self.capacity then grow(self) end
	self.count = count
	local token = self.arena[count]
	token.index = count
	token.kind = kind
	token.start = start
	token.stop = stop
	token.extra = extra or 0
	self.texts[count] = text or self.source:sub(start, stop)
end

---@param self lye.lexer.Lexer
local function scanString(self, quote)
	local source, len = self.source, #self.source
	local start = self.pos
	local escapes, i, newline = 0, start + 1, nil
	while true do
		if i > len then
			-- Nothing closes it, so the string is still being typed. The token ends with its own
			-- line and the writer keeps the rest of the file as code, which is what an editor
			-- needs while a quote is open. A string that really does span lines has its close
			-- somewhere and never reaches this.
			local resume = newline or (len + 1)
			local stop = resume - 1
			fail(self, start, stop, "unfinished string")
			self.pos = resume
			emit(self, KIND.string, start, stop, escapes)
			return
		end
		local byteAt = source:byte(i)
		if byteAt == quote then
			self.pos = i + 1
			emit(self, KIND.string, start, i, escapes)
			return
		end
		-- Remembered rather than acted on: a newline inside a short string is legal Lua, and
		-- only a string nothing closes is cut at one.
		if byteAt == 10 and not newline then newline = i end
		if byteAt == 92 then
			escapes += 1
			i += 2
		else
			i += 1
		end
	end
end

---@param self lye.lexer.Lexer
---@return string? level
---@return integer? stop
local function scanLongBracket(self, start)
	local level = self.source:match("^%[(=*)%[", start)
	if not level then return nil end
	local close = "]" .. level .. "]"
	local found = self.source:find(close, start + 2 + #level, true)
	if not found then
		fail(self, start, #self.source, "unfinished long bracket")
		return level, #self.source
	end
	return level, found + #close - 1
end

---@param self lye.lexer.Lexer
local function scanComment(self)
	local source, len = self.source, #self.source
	local start = self.pos
	local _, stop = scanLongBracket(self, start + 2)
	if stop then
		self.pos = stop + 1
		emit(self, KIND.comment, start, stop, nil)
		return
	end
	local newline = source:find("\n", start + 2, true)
	self.pos = newline or (len + 1)
	emit(self, KIND.comment, start, (newline and newline - 1) or len, nil)
end

---@param byteAt integer
---@return boolean
local function isDigit(byteAt)
	return byteAt and byteAt >= 48 and byteAt <= 57
end

---@param byteAt integer
---@return boolean
local function isHexDigit(byteAt)
	return isDigit(byteAt)
		or (byteAt and byteAt >= 97 and byteAt <= 102)
		or (byteAt and byteAt >= 65 and byteAt <= 70)
end

--- Numbers are scanned byte by byte. Reading the rest of the file into a string to match a
--- pattern against it copied the document once per number, which is quadratic in the file's
--- size and allocates on every token.
---@param self lye.lexer.Lexer
local function scanNumber(self)
	local source, len = self.source, #self.source
	local start = self.pos
	local i = start
	local value, hasDigits = 0, false

	local isHex, isBinary = false, false
	if source:byte(i) == 48 then
		local mark = source:byte(i + 1)
		if mark == 120 or mark == 88 then
			isHex = true
			i += 2
		elseif mark == 98 or mark == 66 then
			isBinary = true
			i += 2
		end
	end

	local isFloat = false
	while i <= len do
		local byteAt = source:byte(i)
		if byteAt == 95 then
			i += 1
		elseif isHex and isHexDigit(byteAt) then
			-- Letters are case-folded with an or, not a mask: masking 0x20 off 'f' gives 70.
			local digit = byteAt <= 57 and byteAt - 48 or (byteAt | 0x20) - 87
			value = value * 16 + digit
			hasDigits = true
			i += 1
		elseif not isHex and not isBinary and isDigit(byteAt) then
			value = value * 10 + (byteAt - 48)
			hasDigits = true
			i += 1
		elseif isBinary and (byteAt == 48 or byteAt == 49) then
			value = value * 2 + (byteAt - 48)
			hasDigits = true
			i += 1
		else
			break
		end
	end

	if not isBinary then
		local dot = source:byte(i)
		if dot == 46 then
			isFloat = true
			i += 1
			while i <= len do
				local byteAt = source:byte(i)
				if byteAt == 95 then
					i += 1
				elseif isHex and isHexDigit(byteAt) or not isHex and isDigit(byteAt) then
					hasDigits = true
					i += 1
				else
					break
				end
			end
		end
		local mark = source:byte(i)
		if (isHex and (mark == 112 or mark == 80)) or (not isHex and (mark == 101 or mark == 69)) then
			isFloat = true
			i += 1
			local sign = source:byte(i)
			if sign == 43 or sign == 45 then i += 1 end
			local hasExponent = false
			while isDigit(source:byte(i)) or source:byte(i) == 95 do
				if isDigit(source:byte(i)) then hasExponent = true end
				i += 1
			end
			if not hasExponent then fail(self, start, i - 1, "malformed number") end
		end
	end

	if not hasDigits then fail(self, start, i - 1, "malformed number") end
	local stop = i - 1

	local suffix = source:match("^[uUlLiI]+", i)
	if suffix then
		-- A cdata literal's value is not a Lua number, so only the span is recorded.
		i += #suffix
		stop = i - 1
	end

	self.pos = i
	local text = source:sub(start, stop)
	-- A binary literal's value came from the scan, and a float or a cdata suffix needs the
	-- engine to read it, since neither is an integer the scan could accumulate.
	if (isFloat or suffix) and not isBinary then value = tonumber((text:gsub("_", ""))) end
	-- A cdata literal's value is not a number, and `suffix and nil or value` always yields
	-- the value, so the two cases are stated rather than folded.
	local extra = value
	if suffix then extra = nil end
	emit(self, KIND.number, start, stop, extra, text)
end

---@param self lye.lexer.Lexer
---@return boolean
local function scanLabel(self, start)
	local name = self.source:match("^::%s*([_%a][_%w]*)", start)
	if not name then return false end

	-- Whitespace is allowed on either side of the name, so the close is found from the
	-- end of the name rather than from a fixed offset.
	local closeAt = self.source:find("::", start + 2 + #name, true)
	if not closeAt then
		fail(self, start, #self.source, "unfinished label")
		return false
	end

	self.pos = closeAt + 2
	emit(self, KIND.label, start, closeAt + 1, nil)
	return true
end

---@param self lye.lexer.Lexer
---@return boolean
local function scanSymbol(self)
	local group = SYMBOLS_BY_FIRST[self.source:byte(self.pos)]
	if not group then return false end
	local pos = self.pos
	local second = self.source:byte(pos + 1) or 0
	for _, symbol in ipairs(group) do
		-- A one-byte operator is decided by the first byte, which the group lookup already
		-- matched; a longer one is ruled out by its second byte almost every time, so the
		-- search below only runs for a candidate that can still match.
		if symbol.len == 1 or symbol.second == second then
			if symbol.len == 1 or self.source:find(symbol.text, pos, true) == pos then
				emit(self, KIND.symbol, pos, pos + symbol.len - 1, nil, symbol.text)
				self.pos = pos + symbol.len
				return true
			end
		end
	end
	return false
end

---@param self lye.lexer.Lexer
---@return lye.lexer.Tokens
function Lexer:tokenize()
	local source, len = self.source, #self.source

	while self.pos <= len do
		local byteAt = source:byte(self.pos)
		local nextByte = source:byte(self.pos + 1) or 0

		if byteAt == 32 or byteAt == 9 or byteAt == 10 or byteAt == 13 or byteAt == 11 or byteAt == 12 then
			self.pos += 1
		elseif byteAt == 45 and nextByte == 45 then
			scanComment(self)
		elseif byteAt == 58 and nextByte == 58 and scanLabel(self, self.pos) then
			elseif byteAt == 91 then
			local start = self.pos
			local level, stop = scanLongBracket(self, start)
			if level then
				self.pos = stop + 1
				emit(self, KIND.string, start, stop, 0)
			else
				assert(scanSymbol(self), string.format("lex error at byte %d: unexpected '['", start))
			end
		elseif byteAt == 34 or byteAt == 39 then
			scanString(self, byteAt)
		elseif byteAt >= 48 and byteAt <= 57 then
			scanNumber(self)
		elseif byteAt == 46 and nextByte >= 48 and nextByte <= 57 then
			scanNumber(self)
		else
			local word = source:match("^[_%a][_%w]*", self.pos)
			if word then
				emit(self, KEYWORDS[word] and KIND.keyword or KIND.name, self.pos,
					self.pos + #word - 1, nil, word)
				self.pos += #word
			else
				assert(scanSymbol(self), string.format(
					"lex error at byte %d: unexpected byte 0x%02x", self.pos, byteAt
				))
			end
		end
	end

	emit(self, KIND.eof, len + 1, len, nil, "")
	return { arena = self.arena, texts = self.texts, count = self.count, problems = self.problems }
end

---@return lye.lexer.Tokens
function lexer.tokenize(source)
	assert(type(source) == "string", "lexer.tokenize expects a string")
	return Lexer.new(source):tokenize()
end

return lexer
