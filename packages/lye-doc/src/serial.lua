--[[
	Writing a type graph out as bytes and reading it back.

	A type is plain data — variants, strings, numbers, nested tables — and two types may share a
	table or reach each other in a cycle, so a graph is written as a *flat* list of tables with
	references between them: every table is made first, then the fields that point at other tables
	are filled in. The builtin singletons and the tables a caller names — the definitions' own
	types, which the analysis reaches by identity — are written by name and read back as the very
	tables the caller holds.

	Nothing read from a file is ever loaded as code. The bytes are read by this module alone, so an
	entry somebody else wrote can be a wrong answer but not a running one.
]]

local types = require("lye-doc.type")
local buffer = require("string.buffer")

local serial = {}

-- The format this writes. A reader of another one refuses rather than guesses.
local MAGIC = "LYE1"

-- A scalar field is one of these, and nothing else: a table is written as a reference to the
-- table's own entry, so a cycle is a number rather than a walk that never ends.
local FALSE, TRUE, INTEGER, NUMBER, TEXT = 1, 2, 3, 4, 5

-- A table's entry: plain, one of the singletons, or a table the caller named.
local PLAIN, SINGLETON, KNOWN = 0, 1, 2

-- A field's key: a name, or a position in an array — `params` of a function type is one.
local BY_NAME, BY_INDEX = 0, 1

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

---@param out string.buffer
---@param value integer
local function putVarint(out, value)
	while true do
		local byte = value % 128
		value = math.floor(value / 128)
		if value == 0 then
			out:put(string.char(byte))
			return
		end
		out:put(string.char(byte + 128))
	end
end

---@param out string.buffer
---@param key string|number
---@param strings table<string, integer>
local function putKey(out, key, strings)
	if type(key) == "number" then
		out:put(string.char(BY_INDEX))
		putVarint(out, key)
	else
		out:put(string.char(BY_NAME))
		putVarint(out, assert(strings[key], "serial: a key was not written"))
	end
end

--- The name of a table this writes by name, or nil for one it writes out.
---@param value table
---@param named table<unknown, string>?
---@return integer
---@return string?
local function kindOf(value, named)
	local singleton = SINGLETON_BY_TABLE[value]
	if singleton then return SINGLETON, singleton end
	if named and named[value] then return KNOWN, named[value] end
	return PLAIN
end

--- Every string the graph writes, each once, with the index a field refers to it by. The strings
--- repeat — `variant` is a key of nearly every table — so they are written once and pointed at.
---@param order table[]
---@param named table<unknown, string>?
---@return table<string, integer>
---@return string[]
local function stringsOf(order, named)
	local at, list = {}, {}
	---@param text string
	local function add(text)
		if at[text] then return end
		at[text] = #list + 1
		list[#list + 1] = text
	end
	for _, value in ipairs(order) do
		local _, name = kindOf(value, named)
		if name then
			add(name)
		else
			for key, held in pairs(value) do
				if type(key) == "string" then add(key) end
				if type(held) == "string" then add(held) end
			end
		end
	end
	return at, list
end

--- Write a value as bytes that `serial.read` rebuilds. `known` names the tables that must come
--- back as the very tables they were — the definitions' own types, which the analysis reaches by
--- identity. Returns nil and an explanation for a graph this cannot write: a table used as a key,
--- which a type never has.
---@param root unknown
---@param known { names: table<unknown, string> }? the caller's own tables, by the name to write each as
---@return string? text
---@return string? err
function serial.write(root, known)
	local named = known and known.names
	local at, order = index(root)
	local strings, list = stringsOf(order, named)

	local out = buffer.new()
	out:put(MAGIC)
	putVarint(out, #order)
	putVarint(out, #list)
	for _, text in ipairs(list) do
		putVarint(out, #text)
		out:put(text)
	end

	for _, value in ipairs(order) do
		local kind, name = kindOf(value, named)
		out:put(string.char(kind))
		if kind ~= PLAIN then
			putVarint(out, assert(strings[name], "serial: a name was not written"))
		else
			-- A field of another table is counted apart from the scalars, so every table is made
			-- before any of them points at another: a class with a field of its own type needs it.
			local scalars, references = {}, {}
			for key, held in pairs(value) do
				if type(key) ~= "string" and type(key) ~= "number" then
					return nil, "a table is used as a key"
				end
				if type(held) == "table" then
					references[#references + 1] = { key, at[held] }
				elseif held ~= nil then
					scalars[#scalars + 1] = { key, held }
				end
			end
			putVarint(out, #scalars)
			for _, field in ipairs(scalars) do
				putKey(out, field[1], strings)
				local held = field[2]
				local heldKind = type(held)
				if heldKind == "boolean" then
					out:put(string.char(held and TRUE or FALSE))
				elseif heldKind == "number" and held >= 0 and held == math.floor(held)
					and held < 2 ^ 53 then
					out:put(string.char(INTEGER))
					putVarint(out, held)
				elseif heldKind == "number" then
					-- Exact, and rare: a literal value that is not a whole, positive number.
					out:put(string.char(NUMBER))
					local text = string.format("%.17g", held)
					putVarint(out, #text)
					out:put(text)
				elseif heldKind == "string" then
					out:put(string.char(TEXT))
					putVarint(out, strings[held])
				else
					return nil, "a field holds " .. heldKind
				end
			end
			putVarint(out, #references)
			for _, field in ipairs(references) do
				putKey(out, field[1], strings)
				putVarint(out, field[2])
			end
		end
	end
	return out:tostring()
end

---@param read table
---@param strings string[]
---@return string|number
local function readKey(read, strings)
	if read:byte() == BY_INDEX then return read:varint() end
	local key = strings[read:varint()]
	if key == nil then error("serial: a key to nothing", 0) end
	return key
end

--- A cursor over the bytes, which fails rather than reads past the end: an entry is a file
--- somebody else may have written, and a wrong one is an answer to ignore.
---@param bytes string
---@return table
local function cursor(bytes)
	local state = { bytes = bytes, at = 1, count = #bytes }
	local methods = {}
	---@param self table
	function methods.byte(self)
		if self.at > self.count then error("serial: ended early", 0) end
		local byte = string.byte(self.bytes, self.at)
		self.at = self.at + 1
		return byte
	end
	---@param self table
	function methods.varint(self)
		local value, shift = 0, 1
		while true do
			local byte = self:byte()
			value = value + (byte % 128) * shift
			if byte < 128 then return value end
			shift = shift * 128
		end
	end
	---@param self table
	---@param length integer
	function methods.take(self, length)
		if self.at + length - 1 > self.count then error("serial: ended early", 0) end
		local part = string.sub(self.bytes, self.at, self.at + length - 1)
		self.at = self.at + length
		return part
	end
	---@param self table
	function methods.text(self)
		return self:take(self:varint())
	end
	return setmetatable(state, { __index = methods })
end

--- Read a graph written by `serial.write`, with the caller's own tables for the names it was given.
---@param text string
---@param known { tables: table<string, unknown> }?
---@return unknown? value
---@return string? err
function serial.read(text, known)
	if type(text) ~= "string" or string.sub(text, 1, #MAGIC) ~= MAGIC then
		return nil, "serial: not an entry this reads"
	end
	local tables = (known and known.tables) or {}
	local read = cursor(text)
	local called, value = pcall(function()
		read.at = #MAGIC + 1
		local count = read:varint()
		local strings = {}
		for position = 1, read:varint() do
			strings[position] = read:text()
		end

		local order, pending = {}, {}
		for position = 1, count do
			local kind = read:byte()
			if kind == SINGLETON then
				local name = strings[read:varint()]
				local held = SINGLETONS[name]
				if held == nil then error("serial: unknown singleton " .. tostring(name), 0) end
				order[position] = held
			elseif kind == KNOWN then
				local name = strings[read:varint()]
				local held = tables[name]
				if held == nil then error("serial: unknown table " .. tostring(name), 0) end
				order[position] = held
			else
				local held = {}
				order[position] = held
				for _ = 1, read:varint() do
					local key = readKey(read, strings)
					local field = read:byte()
					if field == FALSE then
						held[key] = false
					elseif field == TRUE then
						held[key] = true
					elseif field == INTEGER then
						held[key] = read:varint()
					elseif field == NUMBER then
						held[key] = tonumber(read:text())
					elseif field == TEXT then
						held[key] = strings[read:varint()]
					else
						error("serial: unknown field kind " .. tostring(field), 0)
					end
				end
				for _ = 1, read:varint() do
					pending[#pending + 1] = { held, readKey(read, strings), read:varint() }
				end
			end
		end

		-- Every table is there now, so a field can point at one that was written after it.
		for _, field in ipairs(pending) do
			local target = order[field[3]]
			if target == nil then error("serial: a reference to nothing", 0) end
			field[1][field[2]] = target
		end
		return order[1]
	end)
	if not called then return nil, value end
	return value
end

serial.SINGLETONS = SINGLETONS

return serial
