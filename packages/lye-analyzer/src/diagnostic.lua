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
	-- Narrowing records a contradiction through the end of its scope: no value can satisfy the
	-- guards there, so code after it cannot run and nothing it does is worth reporting.
	local unreachable = self.unreachable
	if unreachable then
		for _, range in ipairs(unreachable) do
			---@cast range { from: integer, stop: integer }
			if start >= range.from and start <= range.stop then return end
		end
	end
	local list = self.diagnostics
	list[#list + 1] = { message = message, start = start, stop = stop, severity = severity or 1 }
end

return diagnostic
