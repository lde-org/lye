--[[
	The formatter, shared by the language server and `lye format`.

	It lays out the engine's own style: the indentation the parser's scopes give a line, one space
	between the tokens of an expression, no trailing whitespace, one blank line between things and
	a final newline. A quoted or long string is left alone, and so is a line that runs through a
	long string: rewriting either would change what the program says.

	An edit is a byte range in the source, `from` and `to` inclusive, and the text that stands
	there. `to = from - 1` is an insertion. The server turns those into LSP ranges; the command
	line applies them to the file.
]]

local lexer = require("lye-lexer")
local KIND = lexer.KIND

local format = {}

--- How deep a line is written: the number of blocks the parser recorded around it. The tree knows
--- which blocks are bodies, so nothing is guessed from the text.
---@param parsed lye.parser.Result
---@param offset integer
---@return integer
local function indentAt(parsed, offset)
	local depth, seen = 0, {}
	for _, scope in ipairs(parsed.scopes) do
		-- Keyed by the scope itself: an `if` clause and the block it opens begin at the same
		-- offset when the clause is the block's first statement, and keying by the offset counted
		-- one of them and threw the other away — which is a body at the depth of its own header.
		if scope.start <= offset and offset <= scope.stop and not seen[scope] then
			seen[scope] = true
			depth = depth + 1
		end
	end
	-- A line at the top of the file is inside no block at all: the chunk is not among the scopes the
	-- parser records, so what is counted here is exactly the nesting a reader sees.
	return depth
end

--- Whether a line starts inside a string that runs over more than one line, which no formatter can
--- reindent without changing what the string says.
---@param parsed lye.parser.Result
---@param source string
---@param from integer
---@return boolean
local function insideLongString(parsed, source, from)
	local tokens = parsed.tokens
	for index = 1, tokens.count do
		local token = tokens.arena[index]
		if token.kind == KIND.string and token.start <= from and from <= token.stop then
			return true
		end
	end
	_ = source
	return false
end

-- The operators a formatter puts one space on either side of. `-`, `+`, `~` and `#` are also
-- unary, and the scanner decides from the token before them which spelling this is.
local SPACED_OPERATORS = {
	"=", "==", "~=", "!=", "<", ">", "<=", ">=", "..", "//", "<<", ">>", "~>>",
	"+=", "-=", "*=", "/=", "%=", "^=", "..=", "&&", "||", "??", "->",
	"+", "-", "*", "/", "%", "^", "&", "|", "~",
}
table.sort(SPACED_OPERATORS, function(left, right) return #left > #right end)

---@param word string?
---@return boolean
local function unaryWord(word)
	return word == "return" or word == "and" or word == "or" or word == "not"
		or word == "then" or word == "else" or word == "elseif" or word == "do"
		or word == "until" or word == "in" or word == "local"
end

--- Space a line of code the way the rest of the formatter writes it, leaving literals and a
--- trailing comment alone. The line is the content after indentation; the caller puts the
--- indentation back.
---@param line string
---@return string
function format.spaceLine(line)
	local out = {}
	local count = 0
	---@param text string
	local function append(text)
		count += 1
		out[count] = text
	end
	---@return string
	local function text() return table.concat(out) end
	---@param start integer
	local function trimTrailing(start)
		while start >= 1 and out[start] == " " do
			out[start] = nil
			start -= 1
		end
		count = start
	end

	local index = 1
	while index <= #line do
		local char = line:sub(index, index)
		---@cast char string
		if char == '"' or char == "'" then
			local quote = char
			local from = index
			index += 1
			while index <= #line do
				local held = line:sub(index, index)
				if held == "\\" then index += 2
				elseif held == quote then index += 1 break
				else index += 1 end
			end
			local written = line:sub(from, index - 1)
			---@cast written string
			append(written)
		elseif char == "-" and line:sub(index + 1, index + 1) == "-" then
			local before = text():gsub("%s+$", "")
			out, count = {}, 0
			append(before)
			if before ~= "" then append(" ") end
			local rest = line:sub(index)
			---@cast rest string
			append(rest)
			return text()
		elseif char == "[" and (line:sub(index + 1, index + 1) == "["
			or line:match("^%[=+%[", index)) then
			local level = line:match("^%[(=*)%[", index) or ""
			local close = "]" .. level .. "]"
			local found = line:find(close, index + 2 + #level, true)
			local stop = found and (found + #close - 1) or #line
			local held = line:sub(index, stop)
			---@cast held string
			append(held)
			index = stop + 1
		else
			local operator
			for _, candidate in ipairs(SPACED_OPERATORS) do
				if line:sub(index, index + #candidate - 1) == candidate then
					operator = candidate
					break
				end
			end
			---@cast operator string
			if operator then
				local before = text():gsub("%s+$", "")
				local previousWord = before:match("([%a_][%w_]*)$")
				local previousChar = before:sub(-1)
				---@cast previousChar string
				local unary = (operator == "-" or operator == "+" or operator == "~")
					and (previousChar == "" or previousChar:match("[%(%[%{%,%;%:%=%<%>%+%-%*%/%%%^%&%|~!%?]") ~= nil
						or unaryWord(previousWord))
				if unary then
					append(operator)
				else
					trimTrailing(count)
					if before ~= "" and not previousChar:match("[%(%[%{%,%;%:]") then append(" ") end
					append(operator)
					append(" ")
				end
				index += #operator
				while line:sub(index, index):match("%s") do index += 1 end
			elseif char == "," or char == ";" then
				trimTrailing(count)
				append(char)
				index += 1
				while line:sub(index, index):match("%s") do index += 1 end
				local nextChar = line:sub(index, index)
				if nextChar ~= "" and nextChar ~= ")" and nextChar ~= "]" and nextChar ~= "}" then append(" ") end
			elseif char == ")" or char == "]" or char == "}" then
				trimTrailing(count)
				append(char)
				index += 1
			elseif char == " " then
				-- One space between words is the style; a run is not alignment the formatter keeps.
				if count > 0 and out[count] ~= " " then append(" ") end
				index += 1
			else
				append(char)
				index += 1
			end
		end
	end
	return (text():gsub("%s+$", ""))
end

--- The string one indentation level is written with.
---@param settings table?
---@return string
function format.unit(settings)
	settings = settings or {}
	if settings.indent_style == "space" then
		return (" "):rep(tonumber(settings.indent_size) or 2)
	end
	return "\t"
end

--- The edits for the lines in a range, and, when `whole` is true, the document-level style: no
--- run of blank lines and a final newline unless the project turned it off.
---@param source string
---@param parsed lye.parser.Result
---@param settings table?
---@param firstLine integer 0-based
---@param lastLine integer 0-based
---@param whole boolean?
---@return { from: integer, to: integer, text: string }[]
function format.edits(source, parsed, settings, firstLine, lastLine, whole)
	local edits = {}
	---@param from integer
	---@param to integer
	---@param text string
	local function add(from, to, text)
		edits[#edits + 1] = { from = from, to = to, text = text }
	end
	local unit = format.unit(settings)
	local line, at = 0, 1
	while at <= #source do
		local newline = source:find("\n", at, true)
		local stop = (newline and newline - 1) or #source
		local written = source:sub(at, stop)
		---@cast written string
		if line >= firstLine and line <= lastLine then
			local trimmed = written:gsub("%s+$", "")
			if not insideLongString(parsed, source, at) then
				local body = written:find("[^ \t]")
				local first = body and (at + body - 1) or at
				---@cast first integer
				local content = trimmed:gsub("^[ \t]+", "")
				if content ~= "" then content = format.spaceLine(content) end
				local wanted = trimmed == "" and ""
					or unit:rep(indentAt(parsed, math.min(first, #source))) .. content
				if wanted ~= written then add(at, stop, wanted) end
			elseif trimmed ~= written then
				add(at + #trimmed, stop, "")
			end
		end
		line += 1
		at = stop + 2
		if not newline then break end
	end

	if whole then
		local blankRun, at2 = 0, 1
		while at2 <= #source do
			local newline = source:find("\n", at2, true)
			local stop = (newline and newline - 1) or #source
			local written = source:sub(at2, stop)
			---@cast written string
			if written:match("^%s*$") then
				blankRun += 1
				if blankRun > 1 then
					-- Delete the blank line and its newline, so the run becomes one empty line.
					add(at2, newline and (stop + 1) or stop, "")
				end
			else
				blankRun = 0
			end
			at2 = stop + 2
			if not newline then
				if settings and settings.insert_final_newline == "false" then break end
				if written ~= "" then add(#source + 1, #source, "\n") end
				break
			end
		end
	end
	return edits
end

--- Apply edits, latest first, so an edit before one already applied keeps its own offsets.
---@param source string
---@param edits { from: integer, to: integer, text: string }[]
---@return string
function format.apply(source, edits)
	table.sort(edits, function(left, right)
		if left.from ~= right.from then return left.from > right.from end
		return left.to > right.to
	end)
	for _, edit in ipairs(edits) do
		local from = math.max(1, math.min(edit.from, #source + 1))
		local to = math.max(from - 1, math.min(edit.to, #source))
		source = source:sub(1, from - 1) .. edit.text .. source:sub(to + 1)
	end
	return source
end

--- The whole document, laid out.
---@param source string
---@param parsed lye.parser.Result
---@param settings table?
---@return string
function format.text(source, parsed, settings)
	return format.apply(source, format.edits(source, parsed, settings, 0, math.huge, true))
end

format.indentAt = indentAt
format.insideLongString = insideLongString

return format
