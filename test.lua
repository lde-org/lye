local start, finish, x, y = string.find("122", "^(%d+)()")
print(start, finish, x, y)

---@param s string
---@return integer?
---@return integer?
---@return integer?
local function wrapper(s)
	return string.find("foo", s)
end

print(wrapper("^%d+()"))

local function _test(a --[[string]], b --[[number]])

end
return _test
