--[[
	The modules a `require("...")` can name, for completion.

	This is a plugin of its own rather than one of the hooks in `lye-plugin`: the list is a policy
	about where a project's modules live, and a project may want to replace it. `lye-plugin` is a
	dependency for the hook types only; nothing here requires it at runtime.

	The names come from three places:

	* the libraries LuaJIT itself preloads (`bit`, `ffi`, `math`, …);
	* the directories a `lye.json` names in `requirePaths`, in the shape `package.path` writes;
	* what lde linked into the package's `target/`, which is where a project's dependencies are
	  resolved from.
]]

local fs = require("fs")
local json = require("lye-json")

---@type lye.plugin.Hooks
local requirePlugin = {}

-- The modules `require` accepts without a file in the workspace. Kept here rather than read from
-- `lye-defs`, because a plugin only needs the names and this package is not the type system.
local BUILTIN = {
	"bit", "coroutine", "debug", "ffi", "io", "jit", "jit.profile", "jit.util", "math", "os",
	"package", "string", "string.buffer", "table", "table.clear", "table.new",
}

--- A directory whose name starts with a dot is never a place a module lives.
---@param name string
---@return boolean
local function ignored(name)
	return name:sub(1, 1) == "."
end

---@param root string
---@return string
local function trimmed(root)
	return (root:gsub("[/\\]+$", ""):gsub("/%./", "/"):gsub("//+", "/"))
end

--- The module name a path relative to a search root writes, with `/init` folded into its parent.
---@param relative string
---@return string
local function moduleName(relative)
	return (relative:gsub("%.lua$", ""):gsub("/init$", ""):gsub("[/\\]", "."))
end

---@param out lye.plugin.Completion[]
---@param seen table<string, boolean>
---@param name string
---@param path string?
---@param detail string
local function add(out, seen, name, path, detail)
	if name ~= "" and not seen[name] then
		seen[name] = true
		out[#out + 1] = { name = name, path = path, detail = detail }
	end
end

--- Every Lua file under a root that a search pattern can reach, named as the pattern names it.
---@param root string?
---@param mode "init"|"flat"|"target" which pattern names the file
---@param detail string
---@param out lye.plugin.Completion[]
---@param seen table<string, boolean>
local function scan(root, mode, detail, out, seen)
	if not root or not fs.isdir(root) then return end
	root = trimmed(root)
	for path in fs.scan(root, "**/*.lua", {
		absolute = true, followSymlinks = true, ignore = ignored,
	}) do
		local relative = path:sub(#root + 2)
		if relative ~= "" then
			local name, keep
			if mode == "init" then
				keep = relative:match("(^|/)init%.lua$") ~= nil
				name = keep and (relative:gsub("/init%.lua$", ""):gsub("[/\\]", ".")) or nil
			elseif mode == "flat" then
				keep = relative:sub(-4) == ".lua"
				name = keep and (relative:gsub("%.lua$", ""):gsub("[/\\]", ".")) or nil
			else
				keep = relative:sub(-4) == ".lua"
				name = keep and moduleName(relative) or nil
			end
			if keep and name then add(out, seen, name, path, detail) end
		end
	end
end

---@class lye.plugin.require.Config
---@field requirePaths string[]?

---@param dir string?
---@return lye.plugin.require.Config?
local function readConfig(dir)
	if not dir then return nil end
	local handle = io.open(trimmed(dir) .. "/lye.json", "rb")
	if not handle then return nil end
	local written = handle:read("*a")
	handle:close()
	local ok, config = pcall(json.decode, written)
	if ok and type(config) == "table" then return config end
end

--- The modules the search paths a `lye.json` names can reach. A pattern is written the way
--- `package.path` writes one: `./lib/?.lua` means a file under `lib` is its module name, and
--- `./lib/?/init.lua` means a directory under `lib` is. The two patterns name the same file
--- differently — `lib/init.lua` is `init` under the first and unreachable under the second — so
--- each pattern is applied as written rather than to a shared list of files.
---@param dir string?
---@param out lye.plugin.Completion[]
---@param seen table<string, boolean>
local function scanRequirePaths(dir, out, seen)
	if not dir then return end
	local config = readConfig(dir)
	if not config then return end
	local paths = config.requirePaths
	if type(paths) ~= "table" then return end

	for _, pattern in ipairs(paths) do
		if type(pattern) == "string" and pattern ~= "" and pattern:sub(-4) == ".lua" then
			local absolute = pattern:sub(1, 1) == "/" and pattern or (trimmed(dir) .. "/" .. pattern)
			local base = absolute:match("^(.*)/[^/]*$") or "."
			if base == "" then base = "/" end
			local initPattern = absolute:match("%?/init%.lua$") ~= nil
			local flatPattern = absolute:match("%?%.lua$") ~= nil
			if initPattern then
				scan(base, "init", "require path", out, seen)
			elseif flatPattern then
				scan(base, "flat", "require path", out, seen)
			end
		end
	end
end

---@param root string?
---@param out lye.plugin.Completion[]
---@param seen table<string, boolean>
local function scanTarget(root, out, seen)
	if not root then return end
	scan(trimmed(root) .. "/target", "target", "lde", out, seen)
end

---@param left lye.plugin.Completion
---@param right lye.plugin.Completion
---@return boolean
local function byName(left, right)
	return left.name < right.name
end

---@param context lye.plugin.CompletionContext
function requirePlugin.complete(context)
	local out, seen = {}, {}
	local prefix = context.prefix or ""

	for _, name in ipairs(BUILTIN) do
		if name:sub(1, #prefix) == prefix then add(out, seen, name, nil, "LuaJIT") end
	end

	-- The package's own configuration is read before the workspace's, the order `lye.json` is
	-- read in when a require is resolved.
	local packageRoot = context.packageRoot and trimmed(context.packageRoot) or nil
	local workspace = context.workspace and trimmed(context.workspace) or nil
	-- lde links every dependency into `<package>/target/`, and that is the layout a project using
	-- lde means by `require`. A relative `package.path` directory beside it names the same files
	-- again — often the whole tree — so when lde is detected only its target is listed.
	local usesLde = (packageRoot and (fs.exists(packageRoot .. "/lde.json")
			or fs.isdir(packageRoot .. "/target")))
		or (workspace and (fs.exists(workspace .. "/lde.json")
			or fs.isdir(workspace .. "/target")))
	if usesLde then
		scanTarget(packageRoot, out, seen)
		if workspace and workspace ~= packageRoot then scanTarget(workspace, out, seen) end
	else
		scanRequirePaths(packageRoot, out, seen)
		if workspace and workspace ~= packageRoot then scanRequirePaths(workspace, out, seen) end
	end

	table.sort(out, byName)
	-- The plugin scans everything and filters once: a prefix is what the caller has typed, and a
	-- module that cannot be completed from it is not an item.
	local kept = {}
	for _, entry in ipairs(out) do
		if entry.name:sub(1, #prefix) == prefix then kept[#kept + 1] = entry end
	end
	return kept
end

return requirePlugin
