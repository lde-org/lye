--[[
	Writing a type graph out as a Lua chunk and reading it back.

	A type is plain data — variants, strings, numbers, nested tables — and two types may share a
	table or reach each other in a cycle, so a graph is written as a *flat* list of tables with
	references between them: every table is made first, then the fields that point at other tables
	are assigned. The chunk takes the builtin singletons as its argument, so a cached `string` or
	`nil` comes back as the same table the type system uses rather than a copy of it.
]]

local types = require("lye-doc.type")

local serial = {}

--- The singletons a written graph is rebuilt with, by the name the writer gives them. A type
--- compared by identity — `returns == types.VOID` — has to come back as the very table it was.
local SINGLETONS = {
	number = types.NUMBER, string = types.STRING, boolean = types.BOOLEAN, ["nil"] = types.NIL_TYPE,
	table = types.TABLE, void = types.VOID, never = types.NEVER, any = types.ANY_TYPE,
	unknown = types.UNKNOWN_TYPE, ["function"] = types.FUNCTION,
}
local SINGLETON_BY_TABLE = {}
for name, held in pairs(SINGLETONS) do
	if held ~= nil then SINGLETON_BY_TABLE[held] = name end
end

---@param text string
local function quoted(text)
	local out = text:gsub("[%c\\\"']", function(char)
		if char == "\\" then return "\\\\" end
		if char == "\n" then return "\\n" end
		if char == "\r" then return "\\r" end
		if char == "\t" then return "\\t" end
		if char == '"' or char == "'" then return "\\" .. char end
		return string.format("\\%d", char:byte())
	end)
	return '"' .. out .. '"'
end

---@param value unknown
---@return string
local function scalar(value)
	local kind = type(value)
	if kind == "string" then return quoted(value) end
	if kind == "number" then
		if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			return string.format("%d", value)
		end
		return string.format("%.17g", value)
	end
	if kind == "boolean" then return value and "true" or "false" end
	return "nil"
end

--- The index of each table in the graph, in the order they were met, and the list itself.
---@param root unknown
---@return table<unknown, integer>
---@return table[]
local function index(root)
	local at, order = {}, {}
	---@param value unknown
	local function visit(value)
		if type(value) ~= "table" or at[value] then return end
		at[value] = #order + 1
		order[#order + 1] = value
		for key, held in pairs(value) do
			if type(key) == "table" then visit(key) end
			visit(held)
		end
	end
	visit(root)
	return at, order
end

--- Write a value as a Lua chunk that takes the singleton table and rebuilds it. Returns nil and
--- an explanation for a graph this cannot write: a table used as a key, which a type never has.
---@param root unknown
---@return string? text
---@return string? err
function serial.write(root)
	local at, order = index(root)
	local out = { "return function(S)\n", "local t = {}\n" }
	for position, value in ipairs(order) do
		local name = SINGLETON_BY_TABLE[value]
		if name then
			out[#out + 1] = string.format("t[%d] = S[%s]\n", position, quoted(name))
		else
			local fields = {}
			for key, held in pairs(value) do
				if type(key) == "string" and type(held) ~= "table" and held ~= nil then
					fields[#fields + 1] = string.format("[%s] = %s", quoted(key), scalar(held))
				end
			end
			out[#out + 1] = string.format("t[%d] = { %s }\n", position, table.concat(fields, ", "))
		end
	end
	-- The entries that point at another table, written once every table is there: a field that
	-- holds its own table — a class with a field of its own type — needs the assignment form.
	for position, value in ipairs(order) do
		if not SINGLETON_BY_TABLE[value] then
			for key, held in pairs(value) do
				if type(held) == "table" then
					local target = at[held]
					if type(key) == "number" then
						out[#out + 1] = string.format("t[%d][%d] = t[%d]\n", position, key, target)
					elseif type(key) == "string" then
						out[#out + 1] = string.format("t[%d][%s] = t[%d]\n", position, quoted(key), target)
					else
						return nil, "a table is used as a key"
					end
				end
			end
		end
	end
	out[#out + 1] = string.format("return t[%d]\nend\n", at[root] or 0)
	return table.concat(out)
end

--- Read a graph written by `serial.write`.
---@param text string
---@return unknown? value
---@return string? err
function serial.read(text)
	local chunk, err = loadstring(text)
	if not chunk then return nil, err end
	local ok, builder = pcall(chunk)
	if not ok then return nil, builder end
	if type(builder) ~= "function" then return nil, "not a builder" end
	local called, value = pcall(builder, SINGLETONS)
	if not called then return nil, value end
	return value
end

serial.SINGLETONS = SINGLETONS

return serial
