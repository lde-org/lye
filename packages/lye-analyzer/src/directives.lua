--[[
	Diagnostic controls written in the source and in the workspace's `lye.json`.

	`---@diagnostic disable-next-line: unused-local` is a promise about a line; `disable` and
	`enable` open and close a range. A director with no codes applies to every diagnostic, and one
	with codes only to those codes. The same list applies a workspace policy: a code may be
	rewritten to another severity, or turned off.
]]

local directives = {}

local ACTIONS = {
	["disable"] = true,
	["enable"] = true,
	["disable-line"] = true,
	["disable-next-line"] = true,
}

---@param text string
---@return string
local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param source string
---@return integer[] starts
local function lineStarts(source)
	local starts = { 1 }
	local at = 1
	while true do
		local found = source:find("\n", at, true)
		if not found then break end
		starts[#starts + 1] = found + 1
		at = found + 1
	end
	return starts
end

---@param starts integer[]
---@param offset integer
---@return integer
local function lineOf(starts, offset)
	local low, high = 1, #starts
	while low <= high do
		local mid = math.floor((low + high) / 2)
		if starts[mid] <= offset then low = mid + 1 else high = mid - 1 end
	end
	return high
end

--- The codes a directive names, or nil when it names none and applies to every code.
---@param text string?
---@return table<string, boolean>?
local function codesOf(text)
	local codes
	for part in (text or ""):gmatch("[^,]+") do
		---@cast part string
		local code = trim(part)
		if code ~= "" then
			codes = codes or {}
			codes[code] = true
		end
	end
	return codes
end

---@class lye.DiagnosticPolicy
---@field severity table<string, integer|false>? code -> severity, false turns it off
---@field disable table<string, boolean>? codes a workspace turned off

---@param severity string|integer|nil
---@return integer|false|nil
local function severityOf(severity)
	if severity == "error" then return 1 end
	if severity == "warning" then return 2 end
	if severity == "hint" or severity == "information" then return 3 end
	if severity == "off" or severity == "none" then return false end
	if type(severity) == "number" then return severity end
	return nil
end

---@param value table?
---@return lye.DiagnosticPolicy?
function directives.policy(value)
	if type(value) ~= "table" then return nil end
	local policy = {}
	local severity = value.severity
	if type(severity) == "table" then
		policy.severity = {}
		for code, wanted in pairs(severity) do
			if type(code) == "string" then
				---@cast wanted string|integer|nil
				local held = severityOf(wanted)
				if held ~= nil then policy.severity[code] = held end
			end
		end
	end
	local disable = value.disable
	if type(disable) == "table" then
		policy.disable = {}
		for _, code in ipairs(disable) do
			if type(code) == "string" then policy.disable[code] = true end
		end
	end
	if not policy.severity and not policy.disable then return nil end
	return policy
end

---@param entry table an entry with a message, start, stop and optional severity/code
---@param policy lye.DiagnosticPolicy?
---@return boolean keep
local function allowed(entry, policy)
	local code = entry.code
	if not policy or not code then return true end
	if policy.disable and policy.disable[code] then return false end
	local wanted = policy.severity and policy.severity[code]
	if wanted == false then return false end
	if wanted then
		---@cast wanted integer
		entry.severity = wanted
	end
	return true
end

--- Filter and re-severity a diagnostic list according to the source's directives and a policy.
--- The returned list is a new array; entries that stay are the caller's own tables.
---@param list table[] entries with a message, start, stop and optional severity/code
---@param source string
---@param annotations lye.doc.File?
---@param policy lye.DiagnosticPolicy?
---@return table[]
function directives.apply(list, source, annotations, policy)
	if not list or #list == 0 then return list end
	local starts = lineStarts(source)
	local events = {}
	for _, annotation in ipairs(annotations and annotations.annotations or {}) do
		if annotation.tag == "diagnostic" and ACTIONS[annotation.name or ""] then
			events[#events + 1] = {
				line = lineOf(starts, annotation.start),
				action = annotation.name,
				codes = codesOf(annotation.type),
			}
		end
	end
	if #events == 0 and not policy then return list end
	if #events > 0 then
		table.sort(events, function(left, right) return left.line < right.line end)
	end

	---@param line integer
	---@param code string?
	---@return boolean disabled
	local function disabled(line, code)
		-- A range directive applies from its own line onward. The state is rebuilt per diagnostic;
		-- there are a handful of directives and a report is not on the keystroke path.
		local all, byCode = 0, {}
		for _, event in ipairs(events) do
			if event.line > line then break end
			local applies = event.codes == nil or (code ~= nil and event.codes[code])
			if event.action == "disable" and applies then
				if event.codes then
					for held in pairs(event.codes) do byCode[held] = (byCode[held] or 0) + 1 end
				else
					all += 1
				end
			elseif event.action == "enable" and applies then
				if event.codes then
					for held in pairs(event.codes) do
						if (byCode[held] or 0) > 0 then byCode[held] -= 1 end
					end
				elseif all > 0 then
					all -= 1
				end
			end
		end
		if all > 0 then return true end
		if code and (byCode[code] or 0) > 0 then return true end
		for _, event in ipairs(events) do
			if (event.action == "disable-line" and event.line == line)
				or (event.action == "disable-next-line" and event.line + 1 == line) then
				if event.codes == nil or (code ~= nil and event.codes[code]) then return true end
			end
		end
		return false
	end

	local kept = {}
	for _, entry in ipairs(list) do
		local code = entry.code
		if not disabled(lineOf(starts, entry.start), code) and allowed(entry, policy) then
			kept[#kept + 1] = entry
		end
	end
	return kept
end

return directives
