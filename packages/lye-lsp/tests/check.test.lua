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
local CACHE = PACKAGE_DIR .. "/target/check-entries"

---@param source string
local function writeInput(source)
	local handle = assert(io.open(INPUT, "wb"))
	handle:write(source)
	handle:close()
end

--- Every command runs with the cache of this suite, so a test never reads or writes the one a
--- developer's own runs leave beside their project.
---@param command string
---@return string output
local function run(command)
	local pipe = assert(io.popen("LYE_CACHE_DIR=" .. string.format("%q", CACHE) .. " " .. command))
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
	writeInput("local x = 1\nreturn x\n")
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
	test.equal(exitCode("local x = 2\nreturn x\n", "--check"), 0)
end)

test.it("treats a bare path as a check", function()
	-- Running the server over a file argument would make no sense.
	test.equal(exitCode("local = 2\n", ""), 1)
	test.equal(exitCode("local x = 2\nreturn x\n", ""), 0)
end)

test.it("fails on a warning, since that is the level the check reports at", function()
	-- An unread local is a warning: a build step fails on it, and a name written with a leading
	-- underscore is how a writer says the name is deliberate.
	test.equal(exitCode("local x = 2\n", "--check"), 1)
	test.equal(exitCode("local _x = 2\n", "--check"), 0)
end)

test.it("fails a file whose annotation contradicts its value", function()
	-- `---@type string` on a number is an error in the code, so the check must fail.
	writeInput("---@type string\nlocal x = 5\n")
	local out = run(string.format("lde run %q -- %q >/dev/null 2>&1; echo $?", MAIN, INPUT))
	test.equal(tonumber(out), 1)

	writeInput("---@type number\nlocal x = 5\nreturn x\n")
	local ok = run(string.format("lde run %q -- %q >/dev/null 2>&1; echo $?", MAIN, INPUT))
	test.equal(tonumber(ok), 0)
end)

test.it("rejects an unknown option instead of checking a file named after it", function()
	-- A stray flag used to be treated as a path, so an editor that passes its own conventions
	-- got a usage error dressed as a failed file check.
	local out = run(string.format("lde run %q -- --bogus >/dev/null 2>&1; echo $?", MAIN))
	test.equal(tonumber(out), 2)
	local message = run(string.format("lde run %q -- --bogus 2>&1 >/dev/null", MAIN))
	test.truthy(message:match("unknown option '%-%-bogus'"), "got: " .. message)
	test.truthy(message:match("usage: lye"), "the usage line belongs in the message")
end)

test.it("refuses --cache without a directory", function()
	local out = run(string.format("lde run %q -- --cache >/dev/null 2>&1; echo $?", MAIN))
	test.equal(tonumber(out), 2)
	local message = run(string.format("lde run %q -- --cache 2>&1 >/dev/null", MAIN))
	test.truthy(message:match("%-%-cache needs a directory"), "got: " .. message)
end)

test.it("serves the protocol when an editor passes its own flags", function()
	-- `vscode-languageclient` appends exactly these, so this is the command line an editor runs.
	local frame = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
	local out = run(string.format(
		"printf 'Content-Length: %d\\r\\n\\r\\n%s' | lde run %q -- --stdio --clientProcessId=1234 2>/dev/null",
		#frame, frame, MAIN
	))
	test.truthy(out:match("Content%-Length:%s*%d+"), "the server should answer, got: " .. out)
	test.truthy(out:match('"capabilities"'), "and the answer should carry capabilities")
end)

test.it("exits quietly when the editor closes the pipe", function()
	-- A client that has gone away closes the pipe rather than sending `exit`. Reporting a
	-- failure here would read as a crash, and a client that restarts on a failed exit would
	-- bring the server back up as it shuts down.
	local out = run(string.format("lde run %q -- --stdio </dev/null >/dev/null 2>&1; echo $?", MAIN))
	test.equal(tonumber(out), 0)
end)

test.it("prints its version and exits 0", function()
	local out = run(string.format("lde run %q -- --version 2>/dev/null; echo $?", MAIN))
	test.truthy(out:match("^lye %d+%.%d+%.%d+"), "got: " .. out)
	test.truthy(out:match("0%s*$"))
end)

test.it("checks a batch across processes the way one process does", function()
	-- A batch runs as several processes when the machine has cores to spare, and a package is
	-- handed over whole so the files of one are read in the order one process would read them.
	-- What comes back has to be what one process came back with — a check that answered
	-- differently depending on how many cores the machine had would fail a build on some of them
	-- and pass it on others. The fixture is two packages: one whose files require each other in a
	-- circle, and one that requires a copy of the other through its own `target/`, which is what a
	-- dependency looks like and where the two reads meet.
	local fs = require("fs")
	local root = PACKAGE_DIR .. "/target/batch-fixture"
	local manifest = '{\n\t"name": "%s",\n\t"version": "0.1.0"\n}\n'
	local mainSource = table.concat({
		'local ring = require("ring")\n',
		'\n',
		'---@return integer\n',
		'local function go(round)\n',
		'\treturn ring.go(round)\n',
		'end\n',
		'\n',
		'return { go = go }\n',
	})
	local ringSource = table.concat({
		'local main = require("main")\n',
		'\n',
		'---@return integer\n',
		'local function go(round)\n',
		'\tif round > 0 then return main.go(round - 1) end\n',
		'\treturn 0\n',
		'end\n',
		'\n',
		'return { go = go }\n',
	})
	local sources = {
		["alpha/lde.json"] = manifest:format("fixture-alpha"),
		["alpha/src/main.lua"] = mainSource,
		["alpha/src/ring.lua"] = ringSource,
		-- `require("ring")` resolves through `<package>/target/ring.lua`, which is where lde links
		-- what a package depends on — its own files among them.
		["alpha/target/main.lua"] = mainSource,
		["alpha/target/ring.lua"] = ringSource,
		["beta/lde.json"] = manifest:format("fixture-beta"),
		["beta/src/use.lua"] = table.concat({
			'local helper = require("helper")\n',
			'\n',
			'return helper.go(3)\n',
		}),
		["beta/src/tool.lua"] = table.concat({
			'local helper = require("helper")\n',
			'\n',
			'---@param text string\n',
			'---@return string\n',
			'local function shout(text)\n',
			'\treturn text:upper()\n',
			'end\n',
			'\n',
			'return { shout = shout, go = helper.go }\n',
		}),
		-- A dependency is the same text under another package's `target/`, which is the case the
		-- order of two processes could tell apart.
		["beta/target/helper.lua"] = ringSource,
	}
	fs.mkdirAll(root)
	for path in pairs(sources) do
		local dir = path:match("^(.*)/[^/]+$")
		if dir then fs.mkdirAll(root .. "/" .. dir) end
	end
	for path, source in pairs(sources) do
		fs.write(root .. "/" .. path, source)
	end

	local function checkIn(workers)
		return run(string.format("LYE_WORKERS=%d lde run %q -- --check %q 2>/dev/null",
			workers, MAIN, root))
	end
	local one = checkIn(1)
	test.truthy(one:match(": hint: "), "the fixture has something to compare, got: " .. one)
	test.equal(checkIn(2), one, "two processes must say what one said")
	test.equal(checkIn(4), one, "and so must four")
end)

return true
