--[[
	What a cache directory may contain and still be no worse than no cache.

	Every entry is disposable: a truncated one, one whose magic or body is rubbish, one left under
	the version directory of another build, and a half-written temporary beside a good entry all
	have to be a miss. The run then checks the code and reports what it always did — it does not
	crash, and it does not run what the bytes say. The last part is the one worth a test of its own:
	the bytes are read by `lye-doc.serial` rather than loaded, so an entry that spells a command is
	text.

	Each case wipes `target/robustness-cache` and checks once to make the entries it then breaks, so
	the cases do not depend on each other or on what an earlier run left behind.
]]

local test = require("lde-test")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local ROOT = PACKAGE_DIR .. "/target/robustness-fixture"
local CACHE = PACKAGE_DIR .. "/target/robustness-cache"
local MAIN = PACKAGE_DIR .. "/src/main.lua"
local MARKER = CACHE .. "/executed"

---@param path string
---@param content string
local function write(path, content)
	local dir = path:match("^(.*)/[^/]+$")
	os.execute("mkdir -p " .. string.format("%q", dir))
	local handle = assert(io.open(path, "wb"))
	handle:write(content)
	handle:close()
end

---@param path string
local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

---@param path string
local function exists(path)
	local handle = io.open(path, "rb")
	if handle then handle:close() end
	return handle ~= nil
end

local function remove(path)
	os.execute("rm -rf " .. string.format("%q", path))
end

--- A package the way lde lays one out: a manifest and the files a check is given.
local function fixture()
	remove(ROOT)
	write(ROOT .. "/lde.json", "{ \"name\": \"robustness-fixture\", \"version\": \"0.1.0\" }\n")
	write(ROOT .. "/src/clean.lua", "local x = 1\nreturn x\n")
	write(ROOT .. "/src/warn.lua", "local unused = 1\nreturn 2\n")
	write(ROOT .. "/src/other.lua", "return 3\n")
end

--- Run the real entry point against the fixture, with the cache this file owns. The status is
--- printed after the output so a crash and a report can be told apart without losing either.
---@return string output
---@return integer status
local function check()
	local command = string.format(
		"cd %q && LYE_CACHE_DIR=%q lde run %q -- check %q 2>&1; printf '\\nstatus=%%s\\n' \"$?\"",
		PACKAGE_DIR, CACHE, MAIN, ROOT .. "/src")
	local pipe = assert(io.popen(command))
	local output = pipe:read("*a")
	pipe:close()
	local status = tonumber(output:match("\nstatus=(%d+)\n?$"))
	return (output:gsub("\nstatus=%d+\n?$", "")), status or -1
end

---@param output string
local function findings(output)
	return (output:gsub("\nlye: %d+ files checked[^\n]*\n?$", ""))
end

---@return string[] every entry, wherever the version directory under the cache is
local function entries()
	local found = {}
	local pipe = assert(io.popen(string.format("find %q -name '*.entry' 2>/dev/null | sort", CACHE)))
	for line in pipe:lines() do found[#found + 1] = line end
	pipe:close()
	return found
end

--- The version directory an entry lives under, which is the one a build of other code would use.
---@param entry string
local function versionOf(entry)
	return assert(entry:match("^(.*)/[^/]+$"))
end

local baseline
local baseStatus

--- Wipe the cache, check once, and keep what a clean run says: every case compares against this.
local function reset()
	remove(CACHE)
	remove(MARKER)
	fixture()
	local output, status = check()
	baseline, baseStatus = findings(output), status
	test.truthy(output:find("lye: %d+ files checked"), "a clean run checks the tree: " .. output)
	test.truthy(status == 0 or status == 1, "and exits with a check's status, not a crash: " .. output)
	local found = entries()
	test.truthy(#found > 0, "and keeps its answers there: " .. output)
	return found
end

--- A run that falls back says what the clean run said, exits 0, and has not executed an entry.
---@param label string
local function sameAnswer(label)
	local output, status = check()
	test.truthy(output:find("lye: %d+ files checked"), label .. ": the run completes: " .. output)
	test.truthy(status == 0 or status == 1, label .. ": a check's status, not a crash: " .. output)
	test.equal(findings(output), baseline, label .. ": the answer is the code's own: " .. output)
	test.equal(exists(MARKER), false, label .. ": no cache byte was executed")
end

fixture()

test.it("truncating an entry makes it a miss", function()
	local found = reset()
	-- Half an entry: the lengths the reader trusts are the first thing that goes.
	local text = assert(read(found[1]))
	write(found[1], text:sub(1, math.max(1, math.floor(#text / 2))))
	sameAnswer("truncated entry")
end)

test.it("an entry whose magic is not LYE1 is a miss", function()
	local found = reset()
	local text = assert(read(found[1]))
	write(found[1], "NOPE" .. text:sub(5))
	sameAnswer("corrupt magic")
end)

test.it("an entry's bytes are read, never run", function()
	local found = reset()
	-- Valid magic, then a Lua program. A reader that loaded what it found would run it; the
	-- serial reader refuses the shape instead.
	write(found[1], "LYE1" .. string.format("os.execute(%q)\n", "touch " .. MARKER))
	-- The other entries get rubbish too, so every path through the cache meets one.
	for index = 2, #found do
		local text = assert(read(found[index]))
		write(found[index], text:sub(1, 4) .. string.rep("\255", 64))
	end
	sameAnswer("executable-looking bytes")
	test.equal(exists(MARKER), false, "the command in the entry never ran")
end)

test.it("entries under another version directory are not read", function()
	local found = reset()
	local dir = versionOf(found[1])
	local foreign = CACHE .. "/0000000000000000"
	os.execute(string.format("cp -r %q %q", dir, foreign))
	local before = #entries()
	sameAnswer("foreign version directory")
	test.equal(#entries(), before, "the current version's entries were used, not the foreign ones")
	test.truthy(exists(foreign .. "/" .. found[1]:match("([^/]+)$")), "the foreign copy was left alone")
end)

test.it("a version directory of an older build is a miss and is rebuilt", function()
	local found = reset()
	local dir = versionOf(found[1])
	local old = dir .. ".old"
	os.execute(string.format("mv %q %q", dir, old))
	local output, status = check()
	test.truthy(output:find("lye: %d+ files checked"), "the run completes: " .. output)
	test.truthy(status == 0 or status == 1, "a check's status, not a crash: " .. output)
	test.equal(findings(output), baseline, "the answer is the code's own: " .. output)
	local rebuilt = 0
	for _, entry in ipairs(entries()) do
		if versionOf(entry) == dir then rebuilt = rebuilt + 1 end
	end
	test.truthy(rebuilt > 0, "a new entry was written under the current version: " .. output)
	test.truthy(exists(old), "the old version's directory is still there, unread")
end)

test.it("a half-written temp beside an entry is ignored", function()
	local found = reset()
	local before = #entries()
	for _, entry in ipairs(found) do
		local text = assert(read(entry))
		-- The name `cache.writeWhole` gives its temporary, holding half of it.
		write(entry .. ".tmp.999-1", text:sub(1, math.max(1, math.floor(#text / 2))))
	end
	-- A complete entry from another key under a temp name: complete is not the same as current.
	write(found[1] .. ".tmp.999-2", assert(read(found[2])))
	local output, status = check()
	test.truthy(output:find("lye: %d+ files checked"), "the run completes: " .. output)
	test.truthy(status == 0 or status == 1, "a check's status, not a crash: " .. output)
	test.equal(findings(output), baseline, "the answer is the code's own: " .. output)
	test.equal(#entries(), before, "a temp is not an entry")
	test.truthy(#found > 0, "and the real entries are still used")
end)

return true
