--[[
	`ffi.cdef`, coloured from lye's own parse of it.

	The text handed to `ffi.cdef` is C, and the editor is asked to colour it as such: a keyword, a
	type, the name of a type the block declared, a member of one, a constant an `enum` named, a
	number. Asking the editor to inject a C grammar needs that grammar installed and would not know
	LuaJIT's dialect anyway, so the parse lye already makes — lye-cdef reads the block to type what
	the cdef declares — is what the colours come from.

	The brackets that make the block a string at all are not coloured here: lye's own walk writes the
	literal as a string, and what this asks for is cut out of it.
]]

local cdef = require("lye-cdef")

local declarations = {}

--- What a name of a declaration is, in the vocabulary the server advertises.
local DECLARED = {
	keyword = "keyword", type = "type", class = "class", member = "property",
	constant = "property", ["function"] = "function", number = "number", variable = "variable",
	comment = "comment",
}

--- The blocks already parsed, by their own text: a cdef is read on every keystroke and parsing one
--- is not something to do twice for the same colouring. A handful is all a file has, and the table
--- is dropped when it grows past that rather than grown forever.
local parsed = {}

---@param text string the block
---@return table
local function parse(text)
	local held = parsed[text]
	if held then return held end
	if next(parsed) and #parsed > 16 then
		for key in pairs(parsed) do parsed[key] = nil end
	end
	held = cdef.spans(cdef.parse(text))
	parsed[text] = held
	return held
end

---@param context lye.plugin.TokenContext
---@return lye.plugin.Span[]
function declarations.tokens(context)
	local parsed_, text, map = context.parsed, context.text, context.map
	local spans = {}
	-- The calls of the document, from the index the parser keeps: a plugin is asked about
	-- the same document on every keystroke, and walking every node to find a call is the walk
	-- this one is over.
	for _, node in ipairs(parsed_.byKind.call or {}) do
		if node.kind == "call" and node.args and node.args[1] then
			local target = node.target and parsed_.nodes[node.target]
			local field = node.field or (target and target.field)
			if field == "cdef" then
				local argument = parsed_.nodes[node.args[1]]
				if argument and argument.kind == "string" and type(argument.value) == "string" then
					local from = cdef.textStart(text, argument.start, argument.stop)
					for _, span in ipairs(parse(argument.value)) do
						local kind = DECLARED[span.kind]
						local first, last = from + span.start - 1, from + span.stop - 1
						-- What lye read out of text a lowering plugin wrote has no place in the
						-- document, and a block the plugin wrote is one lye should not colour.
						if kind and not map:rangeIsWritten(first, last) then
							local at, stop = map:toOriginalRange(first, last)
							spans[#spans + 1] = { from = at, to = stop, type = kind }
						end
					end
				end
			end
		end
	end
	return spans
end

return declarations
