--[[
	`lye.json`, read the same way by the editor session and by `lye check`.

	The file holds the plugins and search paths a package reads with, and the policy a diagnostic
	code is held to. A package's file is read first and the workspace's after it, matching the
	order plugins are loaded in. Nothing here is allowed to raise: a malformed file is a workspace
	that reads as it did before, and a caller can carry on.
]]

local fs = require("fs")
local json = require("lye-json")
local directives = require("lye-analyzer.directives")

local config = {}

---@class lye.Config
---@field plugins string[]?
---@field requirePaths string[]?
---@field diagnostics table?

---@type table<string, { text: string, value: lye.Config? }>
local loaded = {}

--- Drop what has been read. A configuration notification or a changed file calls this.
function config.clear()
	loaded = {}
end

---@param dir string?
---@return string?
local function fileName(dir)
	if not dir or dir == "" then return nil end
	local base = dir:gsub("[/\\]+$", "")
	if base == "" then return nil end
	return base .. "/lye.json"
end

--- The configuration in `dir`, or nil when there is none or it does not parse.
---@param dir string?
---@return lye.Config?
function config.read(dir)
	local path = fileName(dir)
	if not path then return nil end
	local text = fs.read(path)
	if type(text) ~= "string" then return nil end
	local held = loaded[path]
	if held and held.text == text then return held.value end
	local ok, value = pcall(json.decode, text)
	local parsed = ok and type(value) == "table" and value or nil
	---@cast parsed lye.Config?
	loaded[path] = { text = text, value = parsed }
	return parsed
end

---@param into lye.Config
---@param from lye.Config
local function merge(into, from)
	if type(from.plugins) == "table" then
		into.plugins = into.plugins or {}
		for _, entry in ipairs(from.plugins) do into.plugins[#into.plugins + 1] = entry end
	end
	if type(from.requirePaths) == "table" then
		into.requirePaths = into.requirePaths or {}
		for _, entry in ipairs(from.requirePaths) do into.requirePaths[#into.requirePaths + 1] = entry end
	end
	if type(from.diagnostics) == "table" then
		into.diagnostics = into.diagnostics or {}
		for key, value in pairs(from.diagnostics) do
			if key == "severity" and type(value) == "table" then
				into.diagnostics.severity = into.diagnostics.severity or {}
				for code, wanted in pairs(value) do into.diagnostics.severity[code] = wanted end
			elseif key == "disable" and type(value) == "table" then
				into.diagnostics.disable = into.diagnostics.disable or {}
				for _, code in ipairs(value) do into.diagnostics.disable[#into.diagnostics.disable + 1] = code end
			elseif key == "enable" and type(value) == "table" then
				into.diagnostics.enable = into.diagnostics.enable or {}
				for _, code in ipairs(value) do into.diagnostics.enable[#into.diagnostics.enable + 1] = code end
			else
				into.diagnostics[key] = value
			end
		end
	end
end

--- The configuration a path is read under: its package's file, then the workspace's.
---@param packageRoot string?
---@param workspaceRoot string?
---@return lye.Config?
function config.forPath(packageRoot, workspaceRoot)
	local merged = {}
	local package = config.read(packageRoot)
	if package then merge(merged, package) end
	if workspaceRoot and workspaceRoot ~= packageRoot then
		local workspace = config.read(workspaceRoot)
		if workspace then merge(merged, workspace) end
	end
	if next(merged) == nil then return nil end
	return merged
end

--- The diagnostic policy a merged configuration asks for.
---@param settings lye.Config?
---@return lye.DiagnosticPolicy?
function config.policy(settings)
	if not settings or type(settings.diagnostics) ~= "table" then return nil end
	return directives.policy(settings.diagnostics)
end

return config
