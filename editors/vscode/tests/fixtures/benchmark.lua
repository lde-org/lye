---@class Vector
---@field x number
---@field y number
local Vector = {}
Vector.__index = Vector

---@param x number
---@param y number
---@return Vector
function Vector.new(x, y)
	return setmetatable({ x = x, y = y }, Vector)
end

---@param other Vector
---@return Vector
function Vector:add(other)
	return Vector.new(self.x + other.x, self.y + other.y)
end

---@param names string[]
---@return string
local function join(names)
	return table.concat(names, ", ")
end

---@param values number[]
---@return number
local function total(values)
	local sum = 0
	for index = 1, #values do
		sum = sum + math.floor(values[index])
	end
	return sum
end

---@param path string
---@return string?
local function read(path)
	local handle = io.open(path, "r")
	if not handle then
		error("cannot open " .. path)
	end
	local body = handle:read("*a")
	handle:close()
	return body
end

---@param name string?
---@return string
local function greet(name)
	assert(name)
	return string.format("hello %s", name)
end

local numbers = { 1, 2, 3 }
local labels = { "a", "b" }

local first = Vector.new(1, 2)
local second = first:add(Vector.new(3, 4))

print(join(labels), total(numbers), greet("world"), first.x + second.y)

local TINT = 0x336699
