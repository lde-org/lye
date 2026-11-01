---@type fn<const A: string, const B: string>(a: A, b: B) -> A .. B
local function foo(a, b)
	return a .. b
end

local _ = foo("bar", "qux")
