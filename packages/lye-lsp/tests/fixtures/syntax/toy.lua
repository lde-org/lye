--[[
	A plugin for a language that is not Lua, in the shape a workspace writes one.

	The language is `let name: type = value` and nothing else: every such line is one statement of
	Lua with the type written as an annotation, which is what a plugin for a real language does on a
	larger scale. What it buys is that lye reads the lowered text — so the annotation is checked
	against the value — while the editor keeps the line its reader wrote, which is where the fault
	is reported.

	It also colours the name of every `let` of the reader's own text as a property rather than as a
	variable, which is what a plugin for a real language does for its keywords, its strings and its
	names: a plugin's spans are in the offsets the editor holds, so a reader sees colours for the
	language they are writing.
]]

local toy = {}

--- The language is written in `.toy` files, which is what a check walking a directory walks for.
toy.extensions = { "toy" }

---@param context lye.plugin.Context
---@return lye.plugin.Edit[]
function toy.lower(context)
	local edits = {}
	local at = 1
	for line in (context.source .. "\n"):gmatch("([^\n]*)\n") do
		local name, kind = line:match("^let%s+([%a_][%w_]*)%s*:%s*([%a_][%w_]*)%s*=")
		local equal = line:find("=", 1, true)
		if name and equal then
			-- The line, without its newline, becomes two lines: the type lye is asked to hold the
			-- value to, and the local it declares.
			edits[#edits + 1] = {
				from = at, to = at + #line,
				text = string.format("---@type %s\nlocal %s =%s", kind, name, line:sub(equal + 1)),
			}
		end
		at += #line + 1
	end
	return edits
end

---@param context lye.plugin.TokenContext
---@return lye.plugin.Span[]
function toy.tokens(context)
	local spans = {}
	local from = 1
	while true do
		local start, stop, name = context.source:find("let%s+([%a_][%w_]*)", from)
		if not start then break end
		-- The name itself, which is where the match's capture begins. The offsets are the
		-- document's own, which is the text this hook colours: what it knows is the language it
		-- lowered from, and that is the one the reader is looking at.
		spans[#spans + 1] = { from = stop - #name + 1, to = stop, type = "property" }
		from = stop + 1
	end
	return spans
end

return toy
