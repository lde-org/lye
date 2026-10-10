local analyzer = require("lye-analyzer")
local docTypes = require("lye-doc.type")
local PRELUDE = analyzer.prelude(require("lye-defs"))
local head = "---@class Config\n---@field name string?\nlocal Config = {}\n"
local cases = {
	{ name = "field check, field read", tail = "---@param config Config\n---@return string\nlocal function read(config)\n\tif config.name == nil then error(\"x\") end\n\treturn config.name\nend\n" },
	{ name = "local check, field read", tail = "---@param config Config\n---@return string\nlocal function read(config)\n\tlocal name = config.name\n\tif name == nil then error(\"x\") end\n\treturn config.name\nend\n" },
	{ name = "local check, local read", tail = "---@param config Config\n---@return string\nlocal function read(config)\n\tlocal name = config.name\n\tif name == nil then error(\"x\") end\n\treturn name\nend\n" },
	{ name = "field copy after check", tail = "---@param config Config\n---@return string\nlocal function read(config)\n\tif config.name == nil then error(\"x\") end\n\tlocal copy = config.name\n\treturn copy\nend\n" },
}
for _, case in ipairs(cases) do
	local result = analyzer.analyze(head .. case.tail, PRELUDE)
	local messages = {}
	for _, entry in ipairs(result.diagnostics) do
		if not entry.message:match("^unused") then messages[#messages + 1] = entry.message end
	end
	print(string.format("%-26s %s", case.name, #messages == 0 and "ok" or "reported"))
end
