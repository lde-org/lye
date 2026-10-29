--[[
	The `.editorconfig` a file is written under.

	The project's answer is read first and lye's own style stands where the file says nothing. The
	search goes up from the file, nearest first, stopping at a file that declares `root = true`.
]]

local editorconfig = {}

--- The `.editorconfig` in a directory, or nil.
---@param directory string
local function read(directory)
	local handle = io.open(directory .. "/.editorconfig", "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

--- The patterns a section declares, and whether one matches a path. `*` spans anything but a
--- separator and `**` spans anything at all, which is the whole of the glob language the format
--- defines. `{a,b}` is not read: a project that uses one is rare and the failure is a default
--- rather than a wrong indentation.
---@param pattern string
---@param name string the path being formatted, relative to the config
local function matches(pattern, name)
	local written = pattern:gsub("([%^%$%(%)%%%.%[%]%+%-])", "%%%1")
	written = written:gsub("%*%*", "\1"):gsub("%*", "[^/]*"):gsub("\1", ".*"):gsub("%?", ".")
	return name:match("^" .. written .. "$") ~= nil
end

---@param directory string
---@param path string
function editorconfig.forFile(directory, path)
	local properties = {}
	-- The name a pattern is matched against grows as the search goes up: the file's own name in
	-- its own directory, and the path leading to it in the ones above.
	local here, name = directory, path:gsub(".*/", "")
	while here and here ~= "" and here ~= "/" do
		local text = read(here)
		if text then
			local section, rooted
			for line in (text .. "\n"):gmatch("([^\n]*)\n") do
				local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
				if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" and trimmed:sub(1, 1) ~= ";" then
					local header = trimmed:match("^%[(.*)%]$")
					local key, value = trimmed:match("^([%w_]+)%s*=%s*(.-)%s*$")
					if header then
						section = header == "*" or matches(header, name)
					elseif key then
						if section == nil then
							-- Above any section: the file's own settings.
							if key == "root" and value == "true" then rooted = true end
						elseif section and properties[key] == nil then
							properties[key] = value:lower()
						end
					end
				end
			end
			if rooted then break end
		end
		local parent = here:match("^(.*)/[^/]+$")
		name = here:gsub(".*/", "") .. "/" .. name
		here = parent
	end
	return properties
end

return editorconfig
