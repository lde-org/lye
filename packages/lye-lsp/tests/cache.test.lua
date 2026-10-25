--[[
	Tests for the between-runs cache.

	Each drives the real entry point — a check of a small package written under `target/` — so the
	contract being tested is the one a build step sees: the same findings for an unchanged tree, and
	findings that follow the code when it changes.
]]

local test = require("lde-test")
local fs = require("fs")

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
---@param cache boolean|string? read and write the cache — `true` for the suite's own directory, a
--- string for that one — rather than turning it off
---@param extra string? further options for the command line
---@return string output
local function check(paths, cache, extra)
	local named = {}
	for _, relative in ipairs(paths) do named[#named + 1] = string.format("%q", ROOT .. "/" .. relative) end
	local env = ""
	if cache == false then
		env = "LYE_CACHE=off "
	elseif cache then
		env = "LYE_CACHE_DIR=" .. string.format("%q", cache == true and CACHE or cache) .. " "
	end
	local command = string.format("cd %q && %s lde run %q -- check %s%s 2>&1",
		PACKAGE_DIR, env, MAIN, table.concat(named, " "), extra and (" " .. extra) or "")
	local pipe = assert(io.popen(command))
	local output = pipe:read("*a")
	pipe:close()
	return output
end

--- How many entries a directory holds, wherever the version directory under it is.
---@param dir string
---@return integer
local function entries(dir)
	local pipe = assert(io.popen(string.format("find %q -name '*.entry' 2>/dev/null | wc -l", dir)))
	local count = tonumber(pipe:read("*a")) or 0
	pipe:close()
	return count
end

---@param output string
---@return string findings without the summary line the check ends with
local function findings(output)
	return (output:gsub("\nlye: %d+ files checked[^\n]*\n?$", ""))
end

-- A check in a process of its own, which is the only way to tell a persisted answer from one this
-- process still holds in memory: the probe prints the check's counters, and `seconds` is the CPU
-- the check itself took.
local PROBE = PACKAGE_DIR .. "/target/cache-probe.lua"

local function writeProbe()
	local handle = assert(io.open(PROBE, "wb"))
	handle:write(table.concat({
		'local check = require("lye-lsp.check")\n',
		"local paths = {}\n",
		"for index = 1, #arg do paths[#paths + 1] = arg[index] end\n",
		"local started = os.clock()\n",
		"local ok = check.files(paths)\n",
		"local seconds = os.clock() - started\n",
		'local stats = check.stats()\n',
		'print(string.format("CHECK ok=%s analyses=%d hits=%d loaded=%d misses=%d stored=%d parseddocs=%d loadeddocs=%d seconds=%.4f",\n',
		"\ttostring(ok), stats.analyses, stats.interfaces.hits, stats.interfaces.loaded,\n",
		"\tstats.interfaces.misses, stats.interfaces.stored,\n",
		"\tstats.documents.parsed, stats.documents.loaded, seconds))\n",
	}))
	handle:close()
end

---@param paths string[]
---@param cacheDir string
---@return table counters
local function probe(paths, cacheDir)
	writeProbe()
	local named = {}
	for _, path in ipairs(paths) do named[#named + 1] = string.format("%q", path) end
	local command = string.format("cd %q && LYE_CACHE_DIR=%q LYE_WORKERS=1 lde run %q -- %s 2>&1",
		PACKAGE_DIR, cacheDir, PROBE, table.concat(named, " "))
	local pipe = assert(io.popen(command))
	local output = pipe:read("*a")
	pipe:close()
	local line = output:match("CHECK ([^\n]+)")
	test.truthy(line, "the probe should report what it did: " .. output)
	local counters = {}
	for key, value in line:gmatch("(%a+)=(%S+)") do counters[key] = value end
	counters.output = output
	return counters
end

--- The findings of a probe run, without its counters: two runs that found the same thing say the
--- same thing.
---@param output string
---@return string
local function beforeProbe(output)
	return (output:match("^(.-)CHECK ") or output)
end

-- Rewrite half of the interface entries as an older version would have left them, and the rest as
-- rubbish: both are answers a run must refuse.
local MUTATE = PACKAGE_DIR .. "/target/cache-mutate.lua"

---@param cacheDir string
local function mutate(cacheDir)
	local handle = assert(io.open(MUTATE, "wb"))
	handle:write(table.concat({
		'local fs = require("fs")\n',
		'local serial = require("lye-doc.serial")\n',
		"local count, stale, corrupt = 0, 0, 0\n",
		'for path in fs.scan(arg[1], "**/*.entry", { absolute = true }) do\n',
		"\tlocal ok, entry = pcall(serial.read, fs.read(path))\n",
		"\tif ok and type(entry) == \"table\" and entry.module ~= nil then\n",
		"\t\tcount = count + 1\n",
		"\t\tif count % 2 == 1 then\n",
		'\t\t\tentry.key = "an older version"\n',
		"\t\t\tfs.write(path, assert(serial.write(entry)))\n",
		"\t\t\tstale = stale + 1\n",
		"\t\telse\n",
		'\t\t\tfs.write(path, "not an entry this reads")\n',
		"\t\t\tcorrupt = corrupt + 1\n",
		"\t\tend\n",
		"\tend\n",
		"end\n",
		'print(string.format("MUTATED %d stale=%d corrupt=%d", count, stale, corrupt))\n',
	}))
	handle:close()
	local pipe = assert(io.popen(string.format("cd %q && lde run %q -- %q 2>&1",
		PACKAGE_DIR, MUTATE, cacheDir)))
	local output = pipe:read("*a")
	pipe:close()
	test.truthy(output:match("MUTATED [1-9]") and output:match("stale=[1-9]")
		and output:match("corrupt=[1-9]"), "the entries are there to spoil: " .. output)
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

test.it("keeps what it worked out in .lye beside the project, by default", function()
	-- A check is called from the project it checks, so that is where its answers belong: nothing
	-- about the project is written outside it, and the next run in the same tree reads them back.
	local beside = PACKAGE_DIR .. "/.lye"
	os.execute("rm -rf " .. string.format("%q", beside))
	fixture({ ["src/one.lua"] = "local x = 1\nreturn x\n" })

	local output = check({ "src" })

	test.equal(entries(beside) > 0, true, "the run kept its answers in .lye: " .. output)
	os.execute("rm -rf " .. string.format("%q", beside))
end)

test.it("keeps them where the command line says instead", function()
	local told = PACKAGE_DIR .. "/target/cache-told"
	local beside = PACKAGE_DIR .. "/.lye"
	os.execute("rm -rf " .. string.format("%q", told) .. " " .. string.format("%q", beside))
	fixture({ ["src/one.lua"] = "local x = 1\nreturn x\n" })

	local output = check({ "src" }, nil, "--cache " .. string.format("%q", told))

	test.equal(entries(told) > 0, true, "--cache is where the answers went: " .. output)
	test.equal(fs.isdir(beside), false, "and nothing was kept beside the project")
end)

test.it("--cold checks again and keeps nothing", function()
	local told = PACKAGE_DIR .. "/target/cache-cold"
	os.execute("rm -rf " .. string.format("%q", told))
	fixture({ ["src/one.lua"] = "local x = 1\nreturn x\n" })

	local cold = check({ "src" }, nil, "--cold --cache " .. string.format("%q", told))
	local warm = check({ "src" }, true)

	test.equal(findings(cold), findings(warm), "a cold run finds what a warm one does: " .. cold)
	test.equal(entries(told), 0, "and keeps nothing of its own")
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

test.it("a module interface an earlier run kept is answered without analysing it", function()
	-- A module reached as a dependency is analysed for its type alone. That answer is kept between
	-- runs, so a run that checks the same module again — from a different file, or after the
	-- requiring file's body changed — does not pay for it twice. `z_empty` returns nothing, and
	-- that answer is kept too, as `false`.
	fixture({
		["src/uses.lua"] = table.concat({
			'local dep = require("z_dep")\n',
			'require("z_empty")\n',
			"local total = dep() + 1\n",
			"return total\n",
		}),
		["target/z_dep.lua"] = "local function value() return 1 end\nreturn value\n",
		["target/z_empty.lua"] = "local x = 1\n",
	})
	local cacheDir = PACKAGE_DIR .. "/target/interface-entries"
	os.execute("rm -rf " .. string.format("%q", cacheDir))

	local first = probe({ ROOT .. "/src/uses.lua" }, cacheDir)
	test.equal(first.loaded, "0", "a first run reads no interface back: " .. first.output)
	test.equal(first.analyses, "3", "it analyses the file and its two modules: " .. first.output)
	test.equal(first.stored, "3", "and keeps the file's answer and theirs: " .. first.output)

	-- The checked file's body changes; the modules' texts and what they were read against do not,
	-- so the run after this one takes their answers rather than working them out again.
	write(ROOT .. "/src/uses.lua", table.concat({
		'local dep = require("z_dep")\n',
		'require("z_empty")\n',
		"local total = dep() + 2\n",
		"return total\n",
	}))
	local second = probe({ ROOT .. "/src/uses.lua" }, cacheDir)
	test.equal(second.loaded, "2", "both module answers come back from the cache: " .. second.output)
	test.equal(second.analyses, "1", "and only the checked file is analysed: " .. second.output)
	test.equal(beforeProbe(second.output), beforeProbe(first.output), "the findings are what they were")
end)

test.it("an interface from an older version, or a corrupt one, is a miss", function()
	fixture({
		["src/uses.lua"] = table.concat({
			'local dep = require("z_dep")\n',
			'require("z_empty")\n',
			"local total = dep() + 1\n",
			"return total\n",
		}),
		["target/z_dep.lua"] = "local function value() return 1 end\nreturn value\n",
		["target/z_empty.lua"] = "local x = 1\n",
	})
	local cacheDir = PACKAGE_DIR .. "/target/interface-stale"
	os.execute("rm -rf " .. string.format("%q", cacheDir))

	local first = probe({ ROOT .. "/src/uses.lua" }, cacheDir)
	test.equal(first.analyses, "3", "the first run works the answers out: " .. first.output)

	mutate(cacheDir)
	write(ROOT .. "/src/uses.lua", table.concat({
		'local dep = require("z_dep")\n',
		'require("z_empty")\n',
		"local total = dep() + 3\n",
		"return total\n",
	}))
	local second = probe({ ROOT .. "/src/uses.lua" }, cacheDir)
	test.equal(second.loaded, "0", "no stale or corrupt interface is read back: " .. second.output)
	test.equal(second.analyses, "3", "so every module is analysed again: " .. second.output)
	test.equal(beforeProbe(second.output), beforeProbe(first.output), "the findings are what they were")
end)

return true
