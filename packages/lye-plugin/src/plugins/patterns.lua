--[[
	Lua patterns, coloured as what they are.

	A string literal handed to a function that reads it as a pattern is not text: `s:gsub("%s+", "-")`
	holds a class and a quantifier, `s:find("^%a+")` an anchor and another, and a reader wants the
	parts that are read rather than the letters that spell them. Which argument of which function is
	a pattern is a property of the library rather than of Lua, so it lives here instead of in the
	server: the list, and what an escape, a class and a magic character look like.
]]

local cdef = require("lye-cdef")

local patterns = {}

--- Which argument of which function is read as a pattern, and what each of them is: the
--- replacement of a `gsub` is read for its escapes rather than as a pattern. Lua has no annotation
--- for that, so the list lives with the reader that knows the environment.
---@type table<string, table<integer, string>>
local INTERPRETED = {
	["string.find"] = { "pattern" },
	["string.match"] = { "pattern" },
	["string.gmatch"] = { "pattern" },
	["string.gsub"] = { "pattern", "replacement" },
}

--- The functions that take the subject they work on as their first argument, so that a dotted call
--- writes the literal one place later than a method call does.
local SUBJECT_FIRST = { find = true, match = true, gmatch = true, gsub = true }

--- The parts of a literal read as something rather than as text: a pattern's escapes and classes,
--- and the escapes of the replacement a `gsub` is handed.
---@param content string the text between the delimiters
---@param kind string `pattern` or `replacement`
---@return { start: integer, stop: integer }[] offsets into the content, 1-based
local function interpretedSpans(content, kind)
	local marks = {}
	local at = 1
	while at <= #content do
		local char = content:sub(at, at)
		if kind == "replacement" then
			if char == "%" and at < #content then
				marks[#marks + 1] = { start = at, stop = at + 1 }
				at += 2
			else
				at += 1
			end
		else
			local class = char == "[" and content:match("^%[%^?%]?[^%]]*%]", at)
			if char == "%" and at < #content then
				marks[#marks + 1] = { start = at, stop = at + 1 }
				at += 2
			elseif class then
				marks[#marks + 1] = { start = at, stop = at + #class - 1 }
				at += #class
			elseif char:match("[%^%$%.%*%+%-%?%(%)]") then
				marks[#marks + 1] = { start = at, stop = at }
				at += 1
			else
				at += 1
			end
		end
	end
	return marks
end

---@param context lye.plugin.TokenContext
---@return lye.plugin.Span[]
function patterns.tokens(context)
	local text, parsed, map = context.text, context.parsed, context.map
	local spans = {}
	-- The calls of the document, from the index the parser keeps: a plugin is asked about
	-- the same document on every keystroke, and walking every node to find a call is the walk
	-- this one is over.
	for _, node in ipairs(parsed.byKind.call or {}) do
		if node.kind == "call" and node.args then
			local target = node.target and parsed.nodes[node.target]
			local field = node.field or (target and target.field)
			-- Who the field belongs to, as it is written where a namespace is named — the
			-- definitions call the `string` table's class `stringlib`, so a dotted call is read by
			-- the name in the source — and by the receiver's own type for a method call.
			local owner
			if node.isMethod then
				local subject = node.target
				if subject then owner = context.ownerOf(context.typeOf(subject)) end
			else
				local base = target and target.target and parsed.nodes[target.target]
				owner = base and base.callee
			end
			local kinds = field and owner and INTERPRETED[owner .. "." .. field]
			---@cast kinds table<integer, string>?
			for index, kind in ipairs(kinds or {}) do
				---@cast index integer
				---@cast kind string
				-- By the position it is written in: these functions take the subject they work on
				-- first, so the pattern is the second argument of `string.find(s, p)` and the first
				-- of `s:find(p)`, which is where `shorthand` comes in.
				local shorthand = node.isMethod or not SUBJECT_FIRST[field or ""]
				local argument = parsed.nodes[node.args[shorthand and index or index + 1] or 0]
				local from = argument and argument.kind == "string"
					and cdef.textStart(text, argument.start, argument.stop)
				---@cast from integer?
				-- Only where the literal reads as it was written: an escape inside it moves every
				-- offset after it, and marking the wrong bytes is worse than marking none.
				if from then
					local content = argument.value
					---@cast content string
					local plain = text:sub(from, argument.stop - 1) == content
					if plain then
						for _, mark in ipairs(interpretedSpans(content, kind)) do
							local first, last = from + mark.start - 1, from + mark.stop - 1
							-- A token may not cross a line, and neither may this one. What lye read
							-- out of text a lowering plugin wrote has no place in the document at all.
							local sameLine = not text:find("\n", first, true)
								or text:find("\n", first, true) > last
							if sameLine and not map:rangeIsWritten(first, last) then
								local at, stop = map:toOriginalRange(first, last)
								spans[#spans + 1] = { from = at, to = stop, type = "regexp" }
							end
						end
					end
				end
			end
		end
	end
	return spans
end

return patterns
