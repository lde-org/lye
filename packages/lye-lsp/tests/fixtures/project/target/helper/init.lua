--[[
	Stands in for a dependency lde linked into `target/`: `require("helper")` resolves to it through
	`target/helper/init.lua`, which is where `lde run` looks.
]]

---@return integer
local function count()
	return 3
end

return { count = count }
