--[[
	Tests for headless checking.

	The CLI has to work without an editor, so this drives the module and the real entry
	point. Output goes to the C `io.stdout`, which cannot be intercepted from Lua, so the
	observable contract is tested instead: the returned status and the process exit code.
]]

local test = require("lde-test")
local check = require("lye-lsp.check")
local env = require("env")

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

test.it("checks a file of a language a plugin reads, and reports it where it is written", function()
	-- The fixture plugin compiles `let name: type = value` to a `---@type` annotation over a
	-- `local`. Handed the file as it stands, a check would report a syntax error on the first
	-- word; what it reports instead is the fault lye found inside the line the plugin wrote, at
	-- the line of the file whose reader wrote it.
	local workspace = TESTS_DIR .. "/fixtures/syntax"
	local toy = workspace .. "/main.toy"

	local discovered = {}
	for _, path in ipairs(check.discover(workspace)) do discovered[path] = true end
	test.truthy(discovered[toy], "the walk finds the file its plugin claims: "
		.. table.concat(check.discover(workspace), " "))

	local output = run("lde run " .. string.format("%q", MAIN) .. " --check " .. string.format("%q", toy)
		.. " 2>&1")
	test.includes(output, "holding is declared as number but is assigned string",
		"the fault the plugin's own line has: " .. output)
	test.includes(output, "main.toy:1:", "reported on the first line of the file, where it was written")

	-- The same file a second time, and the same file named the way a run in a directory names it:
	-- what is held between the two is the analysis of the lowered text, and a finding of it has to
	-- travel back once per report rather than once per analysis.
	local again = run("lde run " .. string.format("%q", MAIN) .. " --check " .. string.format("%q", toy)
		.. " " .. string.format("%q", toy) .. " 2>&1")
	test.equal(again, output, "a file named twice is checked once, and reported the same way")

	local relative = run("lde run " .. string.format("%q", MAIN)
		.. " --check tests/fixtures/syntax/main.toy 2>&1")
	test.includes(relative, "holding is declared as number but is assigned string",
		"and a path relative to the run finds the plugin beside it: " .. relative)
end)

test.it("finds the package of a file named relatively", function()
	-- A file named on the command line keeps the spelling it was given, and `src/x.lua` has a
	-- package above it that a walk over that spelling never reaches: the run's own directory is
	-- where the walk has to end. What the package links into `target/` is only known once it is
	-- found, so a file using it says so when it is not.
	local dir = PACKAGE_DIR .. "/target"
	local dep = io.open(dir .. "/relative-dep.lua", "wb")
	dep:write("---@class RelativeDep\n---@field amount integer\nreturn {}\n")
	dep:close()
	writeInput("---@param d RelativeDep\nlocal function f(d)\n\treturn d.amount\nend\n"
		.. "f({ amount = 1 })\n")

	local previous = env.cwd()
	env.chdir(PACKAGE_DIR)
	local isOk = check.file("target/check-input.lua")
	env.chdir(previous)
	test.equal(isOk, true, "the package's own link answers for a relatively named file")
end)

test.it("writes a configuration where there is none, and never over one", function()
	-- A workspace says what it wants in a file beside it: `lye init` writes the shape of that file
	-- and nothing else, since what goes in it is the workspace's own answer.
	local dir = PACKAGE_DIR .. "/target/init-fixture"
	os.execute("rm -rf " .. string.format("%q", dir) .. " && mkdir -p " .. string.format("%q", dir))
	local command = "lde run " .. string.format("%q", MAIN) .. " init " .. string.format("%q", dir)

	local first = run(command .. " 2>&1")
	test.includes(first, "init-fixture/lye.json", "the file is written: " .. first)
	---@type string?
	local written
	do
		local handle = io.open(dir .. "/lye.json", "rb")
		if handle then
			written = handle:read("*a")
			handle:close()
		end
	end
	test.truthy(written, "lye.json is there")
	local ok, config = pcall(require("lye-json").decode, written or "")
	test.equal(ok, true, "and it parses")
	test.equal(#config.plugins, 0, "with the keys lye reads, and nothing said yet")
	test.equal(#config.requirePaths, 0)

	local second = run(command .. " 2>&1; echo EXIT:$?")
	test.includes(second, "already here", "a second run leaves the file alone: " .. second)
	test.equal(tonumber(second:match("EXIT:(%d+)")), 1, "and refuses with a failure, since it did not do it")
end)

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
