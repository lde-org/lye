--[[
	One finding, in the shape every pass reports in.
]]

local diagnostic = {}

---@param self lye.analyzer.Result
---@param message string
---@param start integer
---@param stop integer
---@param severity integer? 1 error, 2 warning, 3 hint
function diagnostic.add(self, message, start, stop, severity)
	local list = self.diagnostics
	list[#list + 1] = { message = message, start = start, stop = stop, severity = severity or 1 }
end

return diagnostic
