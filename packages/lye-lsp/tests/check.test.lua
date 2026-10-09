--[[
	Tests for headless checking.

	The CLI has to work without an editor, so this drives the module and the real entry
	point. Output goes to the C `io.stdout`, which cannot be intercepted from Lua, so the
	observable contract is tested instead: the returned status and the process exit code.
]]

local test = require("lde-test")
local check = require("lye-lsp.check")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local INPUT = PACKAGE_DIR .. "/target/check-input.lua"
local MAIN = PACKAGE_DIR .. "/src/main.lua"

---@param source string
local function writeInput(source)
	local handle = assert(io.open(INPUT, "wb"))
	handle:write(source)
	handle:close()
end

---@param command string
---@return string output
local function run(command)
	local pipe = assert(io.popen(command))
	local output = pipe:read("*a")
	pipe:close()
	return output
end

test.it("accepts a file that parses", function()
	writeInput("local x = 1\nreturn x\n")
	test.equal(check.file(INPUT), true)
end)

test.it("rejects a file with a syntax error", function()
	writeInput("local x = 1\nlocal = 2\n")
	test.equal(check.file(INPUT), false)
end)

test.it("fails on a file it cannot read", function()
	local isOk, err = check.file(PACKAGE_DIR .. "/target/does-not-exist.lua")
	test.equal(isOk, nil, "a missing file must not be reported as clean")
	test.truthy(err)
end)

test.it("fails the whole batch when one file is bad", function()
	writeInput("local x = 1\n")
	test.equal(check.files({ INPUT }), true)

	writeInput("local = 1\n")
	test.equal(check.files({ INPUT }), false)
end)

-- The exit code is the whole contract for a build step, so it is checked through the real
-- entry point rather than the module.
---@param source string
---@param flag string
---@return integer
local function exitCode(source, flag)
	writeInput(source)
	local out = run(string.format(
		"lde run %q -- %s %q >/dev/null 2>&1; echo $?", MAIN, flag, INPUT
	))
	return tonumber(out) or -1
end

test.it("exits 1 for a file with an error and 0 for a clean one", function()
	test.equal(exitCode("local = 2\n", "--check"), 1)
	test.equal(exitCode("local x = 2\n", "--check"), 0)
end)

test.it("treats a bare path as a check", function()
	-- Running the server over a file argument would make no sense.
	test.equal(exitCode("local = 2\n", ""), 1)
	test.equal(exitCode("local x = 2\n", ""), 0)
end)

test.it("fails a file whose annotation contradicts its value", function()
	-- `---@type string` on a number is an error in the code, so the check must fail.
	writeInput("---@type string\nlocal x = 5\n")
	local out = run(string.format("lde run %q -- %q >/dev/null 2>&1; echo $?", MAIN, INPUT))
	test.equal(tonumber(out), 1)

	writeInput("---@type number\nlocal x = 5\n")
	local ok = run(string.format("lde run %q -- %q >/dev/null 2>&1; echo $?", MAIN, INPUT))
	test.equal(tonumber(ok), 0)
end)

test.it("prints its version and exits 0", function()
	local out = run(string.format("lde run %q -- --version 2>/dev/null; echo $?", MAIN))
	test.truthy(out:match("^lye %d+%.%d+%.%d+"), "got: " .. out)
	test.truthy(out:match("0%s*$"))
end)

return true
