--[[
	The formatter, shared by the language server and `lye format`.

	A document is parsed, and the printer writes it from the tree. The parser's spans and comments
	are the only trivia that survives: comments stay where they were written, a blank run becomes
	one blank line, and every literal is copied byte for byte. A file the parser could not read is
	returned unchanged: deleting text the formatter did not understand is worse than leaving it as
	the writer left it.

	An edit is a byte range in the source, `from` and `to` inclusive, and the text that stands
	there. `to = from - 1` is an insertion. The server turns those into LSP ranges; the command
	line applies them to the file.
]]

local Printer = require("lye-lsp.format.printer")
-- The expression methods extend the printer's table; requiring the module installs them.
require("lye-lsp.format.expressions")

local format = {}
local shared
local spaceUnit, spaceSize

--- The string one indentation level is written with.
---@param settings table?
function format.unit(settings)
	settings = settings or {}
	if settings.indent_style == "space" then
		local size = tonumber(settings.indent_size) or 2
		if size ~= spaceSize then
			spaceSize = size
			spaceUnit = (" "):rep(size)
		end
		return spaceUnit
	end
	return "\t"
end

--- The whole document, laid out.
---@param source string
---@param parsed lye.parser.Result
---@param settings table?
---@return string
function format.text(source, parsed, settings)
	if #parsed.diagnostics > 0 then return source end
	local unit = format.unit(settings)
	local key = settings or {}
	---@type table
	local cache = parsed
	local same = cache.formatSource == source
		and cache.formatUnit == unit
		and cache.formatSettings == key
		and cache.formatMax == key.max_line_length
		and cache.formatSeparator == key.table_separator_style
		and cache.formatTrailing == key.trailing_table_separator
		and cache.formatParens == key.call_arg_parentheses
		and cache.formatFinal == key.insert_final_newline
	if cache.formatText and same then return cache.formatText end

	if not shared then
		shared = Printer.new(source, parsed, settings, unit)
	else
		shared:reset(source, parsed, settings, unit)
	end
	local insertNewline = not (settings and settings.insert_final_newline == "false")
	local text = shared:render(insertNewline)
	-- Keep the answer only when the same tree is formatted again. A one-shot `lye format`
	-- should not hold every output string in memory.
	if cache.formatSeen then cache.formatText = text else cache.formatSeen = true end
	cache.formatSource = source
	cache.formatUnit = unit
	cache.formatSettings = key
	cache.formatMax = key.max_line_length
	cache.formatSeparator = key.table_separator_style
	cache.formatTrailing = key.trailing_table_separator
	cache.formatParens = key.call_arg_parentheses
	cache.formatFinal = key.insert_final_newline
	return text
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

--- A line and the byte range it stands in. `text` includes the newline, so a change at the end
--- of a file and a change to a line's content are both visible as a different string.
---@class lye.format.Line
---@field text string
---@field start integer
---@field stop integer one past the line, where the next one starts

---@param text string
---@return lye.format.Line[]
local function splitLines(text)
	local lines = {}
	local at = 1
	while at <= #text do
		local newline = text:find("\n", at, true)
		local stop = newline and (newline + 1) or #text
		lines[#lines + 1] = { text = text:sub(at, stop - 1), start = at, stop = stop }
		if not newline then break end
		at = stop
	end
	return lines
end

--- The edits that turn one text into another, a line at a time. A line that stayed is the
--- anchor: the run of changed lines before the next anchor is replaced as one range, so a
--- statement that grew from one line to five is one edit rather than a replacement followed by
--- insertions in the wrong place. A one-line deletion or insertion is still one edit of its own,
--- which is what an editor wants for a blank line that collapsed.
---@param source string
---@param formatted string
---@return { from: integer, to: integer, text: string, line: integer }[]
local function diffLines(source, formatted)
	local before = splitLines(source)
	local after = splitLines(formatted)
	local edits = {}
	local left, right = 1, 1

	-- How far a change can run before the two texts are compared by replacing the rest. The
	-- formatter rewrites one statement at a time, so an anchor is found within a handful of lines.
	local WINDOW = 64

	--- The next pair of lines that are the same, after the current pair.
	---@return integer? beforeIndex
	---@return integer? afterIndex
	local function anchor()
		local lastBefore = math.min(#before, left + WINDOW)
		local lastAfter = math.min(#after, right + WINDOW)
		for written = left, lastBefore do
			for wanted = right, lastAfter do
				if (written > left or wanted > right)
					and before[written].text == after[wanted].text then
					return written, wanted
				end
			end
		end
		return nil, nil
	end

	--- Replace the lines before `left` with the lines at `right` up to the anchor.
	---@param toBefore integer one past the last source line replaced
	---@param toAfter integer one past the last target line used
	local function replaceRange(toBefore, toAfter)
		local from = before[left] and before[left].start or (#source + 1)
		local to = toBefore > left and (before[toBefore - 1].stop - 1) or (from - 1)
		local parts = {}
		for index = right, toAfter - 1 do parts[#parts + 1] = after[index].text end

		-- One line for one line: the newline stayed, so an editor sees the content change on the
		-- line it belongs to, not an edit that swallowed the line below it.
		if toBefore == left + 1 and toAfter == right + 1 then
			local written = before[left]
			local wanted = after[right]
			if written.text:sub(-1) == "\n" and wanted.text:sub(-1) == "\n" then
				edits[#edits + 1] = {
					from = written.start, to = written.stop - 2,
					text = wanted.text:sub(1, -2), line = left,
				}
				return
			end
		end
		edits[#edits + 1] = { from = from, to = to, text = table.concat(parts), line = left }
	end

	while left <= #before or right <= #after do
		local written = before[left]
		local wanted = after[right]
		if written and wanted and written.text == wanted.text then
			left += 1
			right += 1
		elseif written and wanted and before[left + 1] and before[left + 1].text == wanted.text then
			edits[#edits + 1] = {
				from = written.start, to = written.stop - 1, text = "", line = left,
			}
			left += 1
		elseif written and wanted and after[right + 1] and written.text == after[right + 1].text then
			edits[#edits + 1] = {
				from = written.start, to = written.start - 1, text = wanted.text, line = left,
			}
			right += 1
		else
			local nextBefore, nextAfter = anchor()
			if nextBefore and nextAfter then
				replaceRange(nextBefore, nextAfter)
				left, right = nextBefore, nextAfter
			elseif #before - left == #after - right then
				-- Nothing matches, but the two runs are the same length: each line is the same
				-- line rewritten. That is what an editor expects to see for a file whose every
				-- line changed.
				replaceRange(left + 1, right + 1)
				left += 1
				right += 1
			else
				replaceRange(#before + 1, #after + 1)
				left, right = #before + 1, #after + 1
			end
		end
	end
	return edits
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
	local formatted = format.text(source, parsed, settings)
	if formatted == source then return {} end
	local edits = diffLines(source, formatted)
	if whole then
		local out = {}
		for _, edit in ipairs(edits) do
			out[#out + 1] = { from = edit.from, to = edit.to, text = edit.text }
		end
		return out
	end

	firstLine = firstLine or 0
	lastLine = lastLine or firstLine
	local out = {}
	for _, edit in ipairs(edits) do
		local line = edit.line - 1
		if line >= firstLine and line <= lastLine then
			out[#out + 1] = { from = edit.from, to = edit.to, text = edit.text }
		end
	end
	return out
end

return format
