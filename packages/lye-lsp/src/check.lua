

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

--- Directories that never hold source to check: a build output and a fetched dependency tree.
--- Anything whose name begins with a dot is skipped too — version control, editor state, and the
--- like — because a walk over those is most of the cost on a project that has been built.
local SKIPPED = { ["target"] = true, ["node_modules"] = true }

--- Every Lua file under `root`, which is what a check with no paths named checks.
--- `find` does the walk: the runtime has no directory listing of its own, and a project tree is
--- the one thing here that is not worth a syscall shim to avoid a process.
---@param root string
---@return string[]
function check.discover(root)
	local found = {}
	local pipe = io.popen(string.format("find %s -type f -name '*.lua' 2>/dev/null", root:find("[%s'\"]") and string.format("%q", root) or "'" .. root .. "'"))
	if not pipe then return found end
	for path in pipe:lines() do
		local skipped = false
		-- `find .` writes every path with a leading `./`, and the dot of that is not a directory name.
		local parts = path:gsub("^%./", "")
		for part in parts:gmatch("[^/]+") do
			if SKIPPED[part] or part:sub(1, 1) == "." then
				skipped = true
				break
			end
		end
		if not skipped then found[#found + 1] = path end
	end
	pipe:close()
	table.sort(found)
	return found
end

--- Whether `path` is a directory. A directory opens as a handle on Linux and then reads as nil,
--- where an empty file reads as an empty string, which is what tells the two apart.
---@param path string
---@return boolean
local function isDirectory(path)
	local handle = io.open(path, "rb")
	if not handle then return false end
	local first = handle:read(0)
	handle:close()
	return first == nil
end

--- The files a list of arguments names: a directory stands for every Lua file under it, so
--- `lye check packages` means what it says.
---@param paths string[]
---@return string[]
function check.expand(paths)
	local named = {}
	for _, path in ipairs(paths) do
		if isDirectory(path) then
			for _, found in ipairs(check.discover(path)) do named[#named + 1] = found end
		else
			named[#named + 1] = path
		end
	end
	return named
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
