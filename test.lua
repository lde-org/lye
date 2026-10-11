local start, finish, x, y = string.find("122", "^(%d+)()")
print(start, finish, x, y)

---@type fn<T: string>(t: T)
local function wrapper(s)
	return string.find("foo", s)
end

print(wrapper("^%d+()"))

local function test(a --[[string]], b --[[number]])

end
