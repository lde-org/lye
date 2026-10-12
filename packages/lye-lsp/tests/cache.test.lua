--[[
	Tests for the between-runs cache.

	Each drives the real entry point — a check of a small package written under `target/` — so the
	contract being tested is the one a build step sees: the same findings for an unchanged tree, and
	findings that follow the code when it changes.
]]

local test = require("lde-test")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local ROOT = PACKAGE_DIR .. "/target/cache-fixture"
local CACHE = PACKAGE_DIR .. "/target/cache-entries"
local MAIN = PACKAGE_DIR .. "/src/main.lua"

---@param path string
---@param content string
local function write(path, content)
	local dir = path:match("^(.*)/[^/]+$")
	os.execute("mkdir -p " .. string.format("%q", dir))
	local handle = assert(io.open(path, "wb"))
	handle:write(content)
	handle:close()
end

--- A package the way lde lays one out: a manifest, the files being checked under `src/`, and what
--- they can `require` linked into `target/`.
---@param files table<string, string> by relative path under the package
local function fixture(files)
	os.execute("rm -rf " .. string.format("%q", ROOT) .. " && mkdir -p " .. string.format("%q", ROOT))
	write(ROOT .. "/lde.json", "{ \"name\": \"cache-fixture\", \"version\": \"0.1.0\" }\n")
	for relative, content in pairs(files) do write(ROOT .. "/" .. relative, content) end
end

---@param paths string[] what to check, relative to the fixture
---@param withCache boolean? read and write the cache, rather than turning it off
---@return string output
local function check(paths, withCache)
	local named = {}
	for _, relative in ipairs(paths) do named[#named + 1] = string.format("%q", ROOT .. "/" .. relative) end
	local cache = withCache and ("XDG_CACHE_HOME=" .. string.format("%q", CACHE)) or "LYE_CACHE=off"
	local command = string.format("%s lde run %q -- check %s 2>&1",
		cache, MAIN, table.concat(named, " "))
	local pipe = assert(io.popen(command))
	local output = pipe:read("*a")
	pipe:close()
	return output
end

---@param output string
---@return string findings without the summary line the check ends with
local function findings(output)
	return (output:gsub("\nlye: %d+ files checked[^\n]*\n?$", ""))
end

test.it("a module another file requires still reports its own diagnostics", function()
	-- `a_user` sorts before `z_def`, so it is checked first and pulls `z_def` in as a module on
	-- the way: a module is read for its type alone, and that must not become the answer the file
	-- itself is given.
	fixture({
		["src/a_user.lua"] = table.concat({
			"local value = require(\"z_def\")\n",
			"return value()\n",
		}, ""),
		["src/z_def.lua"] = table.concat({
			"local function value() return \"x\" end\n",
			"local unused = 1\n",
			"return value\n",
		}, ""),
		["target/z_def.lua"] = "local function value() return \"x\" end\nreturn value\n",
	})
	local output = check({ "src/a_user.lua", "src/z_def.lua" }, true)
	test.truthy(findings(output):find("unused local", 1, true),
		"the file's own warning is reported: " .. output)
end)

test.it("an unchanged tree finds the same thing twice, with and without the cache", function()
	fixture({
		["src/clean.lua"] = "local x = 1\nreturn x\n",
		["src/warning.lua"] = "local unused = 1\nreturn 2\n",
	})
	local off = check({ "src" }, false)
	local cold = check({ "src" }, true)
	local warm = check({ "src" }, true)
	test.equal(findings(cold), findings(off), "a first cached run finds what an uncached one does")
	test.equal(findings(warm), findings(off), "and so does the run after it")
end)

test.it("a change to a file is found on the run after it", function()
	fixture({ ["src/one.lua"] = "local x = 1\nreturn x\n" })
	local before = check({ "src" }, true)
	test.equal(before:find("error", 1, true), nil, "the file is clean to begin with: " .. before)
	write(ROOT .. "/src/one.lua", "local = 1\n")
	local after = check({ "src" }, true)
	test.truthy(after:find("error", 1, true), "the new syntax error is reported: " .. after)
end)

test.it("a change to a module invalidates what required it", function()
	-- The change is in the module's body alone, so nothing but the text it was read from can say
	-- that the file which requires it has to be checked again.
	fixture({
		["src/uses.lua"] = table.concat({
			"local value = require(\"z_dep\")\n",
			"local total = value() + 1\n",
			"return total\n",
		}, ""),
		["target/z_dep.lua"] = "local function value() return \"x\" end\nreturn value\n",
	})
	local first = check({ "src/uses.lua" }, true)
	test.truthy(first:find("needs numbers", 1, true), "a string is refused where a number is: " .. first)

	write(ROOT .. "/target/z_dep.lua", "local function value() return 1 end\nreturn value\n")
	local second = check({ "src/uses.lua" }, true)
	test.equal(second:find("needs numbers", 1, true), nil,
		"and is not refused once the module gives a number: " .. second)
end)

test.it("what a reused analysis read is remembered too", function()
	-- `a_user` is checked first and pulls `z_file` in as a module: that analysis is the one
	-- `z_file`'s own check then uses. Its entry still has to know what `z_file` read — the module
	-- whose body changes here — or the change would go unnoticed.
	local user = "local z = require('z_file')\nreturn z\n"
	local file = table.concat({
		"local dep = require('z_dep')\n",
		"local total = dep() + 1\n",
		"return total\n",
	}, "")
	fixture({
		["src/a_user.lua"] = user,
		["src/z_file.lua"] = file,
		["target/z_file.lua"] = file,
		["target/z_dep.lua"] = "local function value() return \"x\" end\nreturn value\n",
	})
	local first = check({ "src" }, true)
	test.truthy(first:find("needs numbers", 1, true), "a string is refused where a number is: " .. first)

	write(ROOT .. "/target/z_dep.lua", "local function value() return 1 end\nreturn value\n")
	local second = check({ "src" }, true)
	test.equal(second:find("needs numbers", 1, true), nil,
		"the change reaches the file that read it through another: " .. second)
end)

test.it("an entry that cannot be read is checked as it always was", function()
	fixture({ ["src/one.lua"] = "local unused = 1\nreturn 2\n" })
	local first = check({ "src" }, true)
	test.truthy(findings(first):find("unused local", 1, true), "the warning is there to begin with")
	-- A cache directory full of rubbish: whatever a run finds there, the answer is the code's.
	os.execute("find " .. string.format("%q", CACHE) .. " -name '*.entry' -exec sh -c 'echo not lua > \"$1\"' _ {} \\;")
	local second = check({ "src" }, true)
	test.equal(findings(second), findings(first), "a broken entry is no entry")
end)

return true
