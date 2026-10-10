--[[
	Time the analyzer on files that exist, and report the best round rather than an average: a
	single run measures the JIT warming up as much as the code.

	    lde run -C packages/lye-lsp tools/bench.lua <file.lua> ...
]]

local analyzer = require("lye-analyzer")
local PRELUDE = analyzer.prelude(require("lye-defs"))

---@param path string
---@return string? text
local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

local ROUNDS = tonumber(os.getenv("ROUNDS") or "12")
local ROOT = os.getenv("LYE_ROOT") or "."
local wanted = {}
for index = 1, #arg do wanted[#wanted + 1] = arg[index] end
for path in (os.getenv("LYE_FILES") or ""):gmatch("[^:]+") do wanted[#wanted + 1] = path end
if #wanted == 0 then
	-- The files lye is made of, largest first: they are real code rather than a synthetic fixture.
	wanted = {
		"packages/lye-analyzer/src/init.lua",
		"packages/lye-lsp/src/language.lua",
		"packages/lye-doc/src/type.lua",
		"packages/lye-parser/src/init.lua",
		"test.lua",
	}
end
local targets = {}
for _, path in ipairs(wanted) do
	local full = path:sub(1, 1) == "/" and path or (ROOT .. "/" .. path)
	local text = read(full)
	if text then targets[#targets + 1] = { path = path, text = text } end
end

print(string.format("%-46s %6s %9s %9s", "file", "lines", "best ms", "us/line"))
for _, target in ipairs(targets) do
	local best = math.huge
	for _ = 1, ROUNDS do
		local started = os.clock()
		analyzer.analyze(target.text, PRELUDE)
		local taken = (os.clock() - started) * 1000
		if taken < best then best = taken end
	end
	local lines = select(2, target.text:gsub("\n", "\n"))
	print(string.format("%-46s %6d %9.2f %9.2f", target.path, lines, best, best * 1000 / math.max(lines, 1)))
end
