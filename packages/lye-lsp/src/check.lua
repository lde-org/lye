

local Parser = require("lye-parser")
local analyzer = require("lye-analyzer")
local position = require("lye-framework.position")

local check = {}

---@return boolean? isOk
---@return string? err
function check.file(path)
	local handle, openErr = io.open(path, "rb")
	if not handle then
		return nil, string.format("%s: %s", path, tostring(openErr))
	end

	local source = handle:read("*a")
	handle:close()

	local result = Parser.new(source):parse()
	local index = position.buildLineIndex(source)

	-- Annotation type errors belong in the same report as syntax errors, so a declaration
	-- contradicting its `---@type` fails the check.
	local names = analyzer.analyze(source)
	local all = {}
	for _, entry in ipairs(result.diagnostics) do all[#all + 1] = entry end
	for _, entry in ipairs(names.diagnostics) do all[#all + 1] = entry end
	table.sort(all, function(a, b) return a.start < b.start end)

	for _, entry in ipairs(all) do
		-- Byte offsets mean nothing to a human reading a terminal, so report 1-based
		-- line and column here. This is the one place that wants them.
		local line, character = position.toPosition(source, index, entry.start, position.UTF8)
		io.stdout:write(string.format("%s:%d:%d: %s\n", path, line + 1, character + 1, entry.message))
	end
	return #all == 0
end

---@return boolean isOk
function check.files(paths)
	local isOk = true
	for _, path in ipairs(paths) do
		local passed, err = check.file(path)
		if passed ~= true then
			if err then io.stderr:write(err .. "\n") end
			isOk = false
		end
	end
	return isOk
end

return check
