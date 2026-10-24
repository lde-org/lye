--[[
	Format strings, coloured as what they are.

	A literal handed to `string.format`, `string.pack`, `string.unpack`, `string.packsize` or
	`os.date` is not text: `"%d/%s"` holds two conversions and a reader wants them marked rather than
	spelled. Which argument of which function is interpreted that way is a property of the library
	rather than of Lua, so it lives here instead of in the server.
]]

local cdef = require("lye-cdef")

local formats = {}

--- A conversion in a format string: `%d`, `%.2f`, `%%`, with the flags and the width a reader may
--- write between the `%` and the letter.
local SPECIFIER = "^%%[-+ #0]*%d*%.?%d*[cdiouxXeEfgGqs%%]"

--- Which argument of which function is a format: all of them write it first, so a dotted call and
--- a method call differ only in where the subject sits.
---@type table<string, integer>
local FORMAT_ARGUMENT = {
	["string.format"] = 1,
	["string.pack"] = 1,
	["string.unpack"] = 1,
	["string.packsize"] = 1,
	["os.date"] = 1,
}

--- The conversions of a format string.
---@param content string the text between the delimiters
---@return { start: integer, stop: integer }[] offsets into the content, 1-based
local function conversions(content)
	local marks = {}
	local at = 1
	while true do
		local percent = content:find("%", at, true)
		if not percent then break end
		local spec = content:match(SPECIFIER, percent)
		if spec then
			marks[#marks + 1] = { start = percent, stop = percent + #spec - 1 }
			at = percent + #spec
		else
			at = percent + 1
		end
	end
	return marks
end

---@param context lye.plugin.TokenContext
---@return lye.plugin.Span[]
function formats.tokens(context)
	local text, parsed, map = context.text, context.parsed, context.map
	local spans = {}
	-- The calls of the document, from the index the parser keeps: a plugin is asked about
	-- the same document on every keystroke, and walking every node to find a call is the walk
	-- this one is over.
	for _, node in ipairs(parsed.byKind.call or {}) do
		if node.kind == "call" and node.args and node.args[1] then
			local target = node.target and parsed.nodes[node.target]
			local field = node.field or (target and target.field)
			-- Who the field belongs to, as it is written where a namespace is named — the
			-- definitions call the `string` table's class `stringlib`, so a dotted call is read by
			-- the name in the source — and by the receiver's own type for a method call.
			local owner
			if field then
				if node.isMethod then
					owner = context.ownerOf(context.typeOf(node.target))
				else
					local base = target and target.target and parsed.nodes[target.target]
					owner = base and base.callee
				end
			end
			local index = owner and FORMAT_ARGUMENT[owner .. "." .. field]
			-- The format of a method call is the receiver — `("%d"):format(1)` — and of a dotted
			-- one it is the first argument.
			local argument = index and parsed.nodes[node.args[index] or 0]
			local from = argument and argument.kind == "string"
				and cdef.textStart(text, argument.start, argument.stop)
			-- Only where the literal reads as it was written: an escape inside it moves every offset
			-- after it, and marking the wrong bytes is worse than marking none.
			local plain = from and text:sub(from, argument.stop - 1) == argument.value
			if plain then
				for _, mark in ipairs(conversions(argument.value)) do
					local first, last = from + mark.start - 1, from + mark.stop - 1
					local sameLine = not text:find("\n", first, true) or text:find("\n", first, true) > last
					if sameLine and not map:rangeIsWritten(first, last) then
						local at, stop = map:toOriginalRange(first, last)
						spans[#spans + 1] = { from = at, to = stop, type = "regexp" }
					end
				end
			end
		end
	end
	return spans
end

return formats
