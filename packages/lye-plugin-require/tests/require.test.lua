--[[
	Tests for the require-completion plugin.

	The plugin is a normal one: it is handed a document's roots and returns module names. These
	drive `complete` directly against a workspace laid out the way lde lays one out.
]]

local test = require("lde-test")

local SOURCE = debug.getinfo(1, "S").source or ""
local TESTS_DIR = SOURCE:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local ROOT = PACKAGE_DIR .. "/target/require-fixture"
local PKG = ROOT .. "/pkg"

---@param path string
---@param content string
local function write(path, content)
	local dir = path:match("^(.*)/[^/]+$")
	os.execute("mkdir -p " .. string.format("%q", dir))
	local handle = assert(io.open(path, "wb"))
	handle:write(content)
	handle:close()
end

---@param withLde boolean? write an lde manifest and its target links
local function fixture(withLde)
	os.execute("rm -rf " .. string.format("%q", ROOT))
	write(ROOT .. "/lye.json", '{ "requirePaths": ["./lib/?.lua"] }\n')
	write(ROOT .. "/lib/thing.lua", "return {}\n")
	write(ROOT .. "/lib/nested/init.lua", "return {}\n")
	write(PKG .. "/lye.json", '{ "name": "pkg", "requirePaths": ["./mods/?.lua"] }\n')
	write(PKG .. "/mods/helper.lua", "return {}\n")
	if withLde then
		write(PKG .. "/lde.json", '{ "name": "pkg" }\n')
		write(PKG .. "/target/dep/init.lua", "return {}\n")
		write(PKG .. "/target/plain.lua", "return {}\n")
	end
end

---@param prefix string
---@return table<string, table>
local function complete(prefix)
	local found = {}
	for _, entry in ipairs(require("lye-plugin-require").complete({
		uri = "file://" .. PKG .. "/main.lua",
		source = "local x = require(\"" .. prefix .. "\")",
		text = "local x = require(\"" .. prefix .. "\")",
		offset = 1,
		prefix = prefix,
		workspace = ROOT,
		packageRoot = PKG,
	})) do
		found[entry.name] = entry
	end
	return found
end

test.it("offers the engine's modules and relative search paths without lde", function()
	fixture(false)
	local all = complete("")
	for _, name in ipairs({ "bit", "ffi", "math", "string.buffer" }) do
		test.truthy(all[name], "the engine ships " .. name)
		test.equal(all[name] and all[name].detail, "LuaJIT")
	end
	test.truthy(all["thing"], "a file a lye.json requirePaths names")
	test.equal(all["thing"] and all["thing"].detail, "require path")
	test.truthy(all["nested.init"], "a nested file under the same pattern keeps its whole name")
	test.truthy(all["helper"], "a package's own requirePaths is read too")
	test.falsy(all["dep"], "a layout lde did not make is not invented")
end)

test.it("uses only lde's target when lde is detected", function()
	fixture(true)
	local all = complete("")
	test.truthy(all["bit"], "the engine's modules are still there")
	test.truthy(all["dep"], "a module lde linked into target")
	test.equal(all["dep"] and all["dep"].path, PKG .. "/target/dep/init.lua")
	test.truthy(all["plain"], "and a plain file there")
	test.falsy(all["thing"], "a relative search path is not listed beside lde's layout")
	test.falsy(all["helper"], "nor is a package's own relative search path")
end)

test.it("filters by what has been typed", function()
	fixture()
	local some = complete("th")
	test.truthy(some["thing"])
	test.falsy(some["bit"], "a module that does not start with the prefix is not offered")
	local nested = complete("nested")
	test.truthy(nested["nested.init"])
end)

test.it("answers the builtins when there is no workspace to scan", function()
	local found = {}
	for _, entry in ipairs(require("lye-plugin-require").complete({
		uri = "file:///tmp/x.lua", source = "", text = "", offset = 1, prefix = "",
	})) do found[entry.name] = entry end
	test.truthy(found["bit"])
	test.truthy(found["ffi"])
	test.falsy(found["thing"])
end)

return true
