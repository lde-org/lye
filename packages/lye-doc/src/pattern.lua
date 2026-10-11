--[[
	What a Lua pattern says about what a call returns.

	Only the shape is read: how many captures, whether each is a position, whether the pattern is
	anchored at both ends, whether it is malformed. What the captures match is not modelled.
]]

local pattern = {}

--- Reads a written pattern.
---@param text string
---@return integer captures how many captures it makes, `()` among them
---@return boolean[] positions which of them are position captures, which are numbers
---@return boolean anchored it starts with `^` and ends with `$`, so it cannot fail to match
---@return string? malformed what is wrong with it, when something is
function pattern.read(text)
	local captures, positions = 0, {}
	local anchored = text:sub(1, 1) == "^" and text:sub(-1) == "$"
	-- How many captures are open at this point: a `)` closes one, and only a `)` with nothing open
	-- is malformed. Returning on the first one called every pattern with a capture broken.
	local open = 0
	local index = 1
	while index <= #text do
		local char = text:sub(index, index)
		if char == "%" then
			if index == #text then return captures, positions, anchored, "a `%` with nothing after it" end
			index += 2
		elseif char == "[" then
			-- A set is one term: `[(]` is a literal bracket and nothing inside it captures.
			local close = index + 1
			if text:sub(close, close) == "^" then close += 1 end
			if text:sub(close, close) == "]" then close += 1 end
			local stop = text:find("]", close, true)
			if not stop then return captures, positions, anchored, "a `[` with no `]`" end
			index = stop + 1
		elseif char == "(" then
			captures += 1
			open += 1
			positions[captures] = text:sub(index + 1, index + 1) == ")"
			index += 1
		elseif char == ")" then
			if open == 0 then return captures, positions, anchored, "a `)` with no `(`" end
			open -= 1
			index += 1
		else
			index += 1
		end
	end
	if open > 0 then return captures, positions, anchored, "a `(` with no `)`" end
	return captures, positions, anchored, nil
end

--- The calls whose pattern decides what they give back, by the field they are written with. The
--- pattern is the first argument of a method call — `s:find(p)` — and the second of a dotted one,
--- `string.find(s, p)`, which is the only difference between the two spellings.
---@type table<string, boolean>
pattern.CALLS = { find = true, match = true, gsub = true }

--- The values a pattern call gives back, or nil when this cannot say: the captures the pattern
--- makes, and whether they may be absent. `find` reports the match before its captures, `match`
--- the captures themselves, and `gsub` a result and a count that are never nil.
---@param subject string the field it was called with, `find` or `match`
---@param text string the pattern as written
---@return lye.doc.Type[]?
function pattern.values(subject, text)
	local types = require("lye-doc.type")
	if not pattern.CALLS[subject] then return nil end
	local captures, positions, anchored, malformed = pattern.read(text)
	if malformed then return nil end
	local values = {}
	---@param held lye.doc.Type
	---@param always boolean? a value this call always gives, whatever the pattern does
	local function add(held, always)
		if always or anchored then
			values[#values + 1] = held
		else
			values[#values + 1] = types.union({ held, types.NIL_TYPE })
		end
	end
	if subject == "find" then
		add(types.NUMBER)
		add(types.NUMBER)
		for index = 1, captures do add(positions[index] and types.NUMBER or types.STRING) end
	elseif subject == "match" then
		if captures == 0 then
			add(types.STRING)
		else
			for index = 1, captures do add(positions[index] and types.NUMBER or types.STRING) end
		end
	else
		add(types.STRING, true)
		add(types.NUMBER, true)
	end
	return values
end

return pattern
