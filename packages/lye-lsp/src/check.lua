

local Parser = require("lye-parser")
local doc = require("lye-doc")
local analyzer = require("lye-analyzer")
local position = require("lye-framework.position")

local check = {}

--- The LuaJIT definitions, prepared once, so a headless check sees the same standard library an
--- editor session does.
local PRELUDE = analyzer.prelude(require("lye-defs"))

---@return boolean? isOk
---@return string? err
---@param elsewhere table<string, boolean>? type names the other files in this batch declare
function check.file(path, elsewhere)
	local handle, openErr = io.open(path, "rb")
	if not handle then
		return nil, string.format("%s: %s", path, tostring(openErr))
	end

	local source = handle:read("*a")
	handle:close()

	-- A directory opens as a handle on Linux and then reads as nil, and `--check` is pointed at
	-- folders all the time: say so instead of handing the parser nothing to work with.
	if type(source) ~= "string" then
		return nil, string.format("%s: not a readable file", path)
	end

	local result = Parser.new(source):parse()
	local index = position.buildLineIndex(source)

	-- Annotation type errors belong in the same report as syntax errors, so a declaration
	-- contradicting its `---@type` fails the check.
	local names = analyzer.analyze(source, PRELUDE, elsewhere)
	local all = {}
	for _, entry in ipairs(result.diagnostics) do all[#all + 1] = entry end
	for _, entry in ipairs(names.diagnostics) do all[#all + 1] = entry end
	table.sort(all, function(a, b) return a.start < b.start end)

	local failed = false
	for _, entry in ipairs(all) do
		-- Byte offsets mean nothing to a human reading a terminal, so report 1-based
		-- line and column here. This is the one place that wants them.
		local line, character = position.toPosition(source, index, entry.start, position.UTF8)
		io.stdout:write(string.format("%s:%d:%d: %s\n", path, line + 1, character + 1, entry.message))
		-- An unused local is a hint, and a build step that fails on one is a build step nobody
		-- keeps: it is printed and it does not decide the exit code.
		-- A parser diagnostic carries no severity: a syntax error is the loudest thing there is.
		if entry.severity == nil or entry.severity <= 2 then failed = true end
	end
	return not failed
end

---@return boolean isOk
function check.files(paths)
	-- Every file in the batch is read first, so a name one of them declares is not a typo in
	-- another: annotations are workspace-wide even though a document is analysed on its own.
	local declared = {}
	for _, path in ipairs(paths) do
		local handle = io.open(path, "rb")
		if handle then
			local source = handle:read("*a")
			handle:close()
			if type(source) == "string" then
				for _, annotation in ipairs(doc.parse(source).annotations) do
					if (annotation.tag == "class" or annotation.tag == "alias") and annotation.name then
						declared[annotation.name] = true
					end
				end
			end
		end
	end

	local isOk = true
	for _, path in ipairs(paths) do
		local passed, err = check.file(path, declared)
		if passed ~= true then
			if err then io.stderr:write(err .. "\n") end
			isOk = false
		end
	end
	return isOk
end

return check
