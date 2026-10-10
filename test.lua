--[[
	lye playground

	Everything in this file is type checked by the same analyzer the editor runs, and it is meant to
	be edited: change a number, hand a function the wrong argument, delete a `const`, and watch the
	diagnostics change as you type. `lye-lsp --check test.lua` reports the same thing headlessly.

	Nothing here is required to run — it is a tour of what the type system knows.
]]

local ffi = require("ffi")

ffi.cdef [[
	struct TestingEnum {
		int foo;
		char* bar;
	}
]]

local x = ffi.new("TestingEnum")
local _y = ffi.cast("char*", "foo")

---@alias Callback<V> fn(a: V) -> boolean

---@alias Foo<const N: number> { count: N }

--------------------------------------------------------------------------------------------------
-- A number is the number it spells

---@type 2149 | 231 | 26
local port = 2149 -- fits: it is one of the three

local base = 5
local scaled = base * 2 + 6912 -- 6922, worked out where it is written
local fuzzed = scaled + math.random(0, 1) -- plainly a number once a call is involved

---@alias Font<const Size: number> { size: Size, label: Size .. "px" }
---@alias Offset<const N: number> { from: N + 1, to: N + 2 }

---@type Font<14>
local body = { size = 14, label = "14px" }

---@type Offset<40>
local window = { from = 41, to = 42 }

--------------------------------------------------------------------------------------------------
-- A class, and a method written for a field

---@class App
---@field name string
---@field call fun(self: App, x: string): number
local App = {}

-- `__index` is what makes a method reachable at runtime; the analyzer reads the class either way,
-- which is exactly why a missing one goes unnoticed until the file runs.
App.__index = App

---@param x string
---@return number
function App:call(x)
	return #x * 2
end

---@type App
local app = setmetatable({}, App)

local length = app:call("hello") -- number, from the field's own signature
local appName = app.name -- string

--------------------------------------------------------------------------------------------------
-- A method that is written straight into a field: the signature comes from the field

---@class Cache
---@field get fn(self: Cache, key: string): string?
---@field put fn(self: Cache, key: string, value: string)
local Cache = {}
Cache.__index = Cache

function Cache:put(key, value)
	rawset(self, key, value)
end

---@type Cache
local cache = setmetatable({}, Cache)
cache:put("answer", "42")

--------------------------------------------------------------------------------------------------
-- Metatables: a type that says what Lua does with it

---@class Vec
---@field x number
---@field y number
local Vec = {}

Vec.__index = Vec

---@param a Vec
---@param b Vec
---@return Vec
function Vec.__add(a, b)
	return setmetatable({ x = a.x + b.x, y = a.y + b.y }, Vec)
end

---@param a Vec
---@param b Vec
---@return boolean
function Vec.__eq(a, b)
	return a.x == b.x and a.y == b.y
end

---@param self Vec
---@return number
function Vec.__len(self)
	return 2
end

---@param self Vec
---@param scale number
---@return Vec
function Vec.__call(self, scale)
	return setmetatable({ x = self.x * scale, y = self.y * scale }, Vec)
end

local origin = setmetatable({ x = 0, y = 0 }, Vec)
local corner = setmetatable({ x = 1, y = 1 }, Vec)

local sum = origin + corner -- Vec, from `__add`
local same = origin == corner -- boolean, from `__eq`
local fields = #origin -- number, from `__len`
local scaled2 = origin(4) -- Vec, from `__call`
local x = sum.x -- number, read through `__index`

--------------------------------------------------------------------------------------------------
-- A signature with parameters of its own, bound where it is called

---@type fn<T>(x: T) -> T
local identity = |x| -> x

---@type fn<T, U>(first: T, second: U) -> U
local second = |first, second| -> second

local five = identity(5) -- 5
local word = second(1, "two") -- "two"

--------------------------------------------------------------------------------------------------

--- A call that never comes back makes what follows it dead
---@param config { name: string? }
---@return string
local function requiredName(config)
	local name = config.name
	if name == nil then
		-- `error` is declared `---@return never` by lye's own definitions, so this branch cannot
		-- fall through and `name` below is narrowed from `string?` to a string.
		error("config.name is required")
	end

	return name
end

--------------------------------------------------------------------------------------------------
-- const: a name that holds what it was given

const DEFAULT_PORT = 8080
const HALF = DEFAULT_PORT / 2

local listening = port + DEFAULT_PORT -- both numbers, and both known

--------------------------------------------------------------------------------------------------
-- The standard library is typed from its own annotations

local rounded = math.floor(base / 2) -- integer
local random = math.random(1, 6) -- number
local text = string.format("%s:%d", appName, rounded) -- string
local list = { 3, 1, 2 }
table.insert(list, 4)
local unpacked = unpack(list) -- the element type, however many there are
local count = select("#", unpack(list)) -- the number of values

--------------------------------------------------------------------------------------------------
-- Try breaking it. Each of these reports exactly one thing:
--
-- * app.missing = 1                 `missing` is not a field of App
-- * app.call = function() end       call is declared as fn(App, string) -> number but is assigned fn()
-- * app:call(5)                     app:call expects string, got number
-- * DEFAULT_PORT = 1                `DEFAULT_PORT` is const, so it cannot be assigned to
-- * Font<number>                    `Size` is a const parameter, so it takes a literal number
-- * a 521 return                     the result is declared as 521 but is assigned number
-- * a misspelled type name           unknown type `Strng`
-- * setmetatable({}, { __add = 5 }) expects lye.Metatable, got { __add: number }

--------------------------------------------------------------------------------------------------
-- Narrowing: what a condition proves about what follows

--- A tagged union, the way `Result<T>` is written in TypeScript: the discriminant says which
--- member a value is, and a check on it narrows the whole shape.
---@alias Result<T> { ok: true, value: T } | { ok: false, message: string }

---@param parsed Result<number>
---@return string
local function describe(parsed)
	if parsed.ok then
		-- One member here: `value` is a number and `message` is not part of this shape at all.
		return string.format("%d", parsed.value)
	end
	-- And the other one below it: `message` is a string, and `value` is gone.
	return parsed.message
end

-- Until then the condition narrows by truth, by nil and by `type`, which is what the three
-- functions below show.

---@param value string|number
---@return string
local function label(value)
	-- `type()` is a test the analyzer understands, and it keeps the negative half too.
	if type(value) == "number" then
		return string.format("%d", value)
	end
	return value
end

---@param name string?
---@return string
local function required(name)
	if name == nil then
		error("a name is required")
	end
	-- `name` is a string here: the branch above cannot fall through, because `error` is `never`.
	return name
end

---@param config { name: string?, retries: number? }
---@return string
local function described(config)
	local name = config.name
	if name then
		return name
	end
	-- A local narrowed by the check above is still a string below it.
	return string.format("unnamed(%d)", config.retries or 0)
end

return {
	describe = describe({ ok = true, value = 41 }),
	label = label(1),
	required = required("lye"),
	described = described({ name = "lye", retries = 2 }),
	port = port,
	scaled = scaled,
	fuzzed = fuzzed,
	body = body,
	window = window,
	app = app,
	length = length,
	sum = sum,
	same = same,
	fields = fields,
	scaled2 = scaled2,
	x = x,
	five = five,
	word = word,
	name = requiredName({ name = "lye" }),
	half = HALF,
	listening = listening,
	random = random,
	text = text,
	unpacked = unpacked,
	count = count,
}
