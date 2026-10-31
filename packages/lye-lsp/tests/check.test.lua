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

--- A command with a cache of the test's own: a test that must start cold says where it starts.
---@param cacheDir string?
---@param command string
local function runWith(cacheDir, command)
	local env = cacheDir and ("LYE_CACHE_DIR=" .. string.format("%q", cacheDir) .. " ") or ""
	local pipe = assert(io.popen(env .. command))
	local output = pipe:read("*a")
	pipe:close()
	return output
end

--- Every command runs with the cache of this suite, so a test never reads or writes the one a
--- developer's own runs leave beside their project.
---@param command string
local function run(command)
	return runWith(CACHE, command)
end

-- A check in a process of its own, which is the only way to tell what came from the cache from
-- what this process still held: the counters are printed after `check.files`, and `seconds` is
-- the CPU the check itself took, without the command line's startup.
local PROBE = PACKAGE_DIR .. "/target/check-probe.lua"

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
---@param cacheDir string|false
---@return table counters
local function probe(paths, cacheDir)
	writeProbe()
	local named = {}
	for _, path in ipairs(paths) do named[#named + 1] = string.format("%q", path) end
	local command = string.format("LYE_WORKERS=1 lde run %q -- %s 2>&1",
		PROBE, table.concat(named, " "))
	local output
	if cacheDir == false then
		output = runWith(nil, "LYE_CACHE=off " .. command)
	else
		output = runWith(cacheDir, command)
	end
	local line = output:match("CHECK ([^\n]+)")
	test.truthy(line, "the probe should report what it did: " .. output)
	local counters = {}
	for key, value in line:gmatch("(%a+)=(%S+)") do counters[key] = value end
	counters.output = output
	return counters
end

---@param root string
---@param files table<string, string> by relative path
local function writeTree(root, files)
	local fs = require("fs")
	os.execute("rm -rf " .. string.format("%q", root) .. " && mkdir -p " .. string.format("%q", root))
	for path, source in pairs(files) do
		---@cast path string
		local dir = path:match("^(.*)/[^/]+$")
		if dir then fs.mkdirAll(root .. "/" .. dir) end
		fs.write(root .. "/" .. path, source)
	end
end

--- A path the index and the check both name the same way. A persisted entry is keyed by its root,
--- so a test that builds one has to spell the root as the run under test will.
---@param path string
local function absolutePath(path)
	if path:sub(1, 1) == "/" then return path end
	return env.cwd() .. "/" .. (path:gsub("^%./", ""))
end

--- An index entry written by this process, under the cache directory the probe will read it from.
--- The check never builds one; this is the earlier run it is supposed to find.
---@param root string
---@param cacheDir string
---@return boolean
local function buildIndex(root, cacheDir)
	local cache = require("lye-lsp.cache")
	local Index = require("lye-lsp.index")
	local wasEnabled, wasNamed, wasRoot = cache.enabled(), cache.named(), cache.root()
	cache.setEnabled(true)
	cache.setRoot(cacheDir)
	local index = Index.new()
	local saved = index:save(index:build(root, { kind = "workspace" }))
	cache.setEnabled(wasEnabled)
	cache.setRoot(wasNamed and wasRoot or nil --[[@as string]])
	return saved
end

--- The findings of a probe run, without its counters: two runs that found the same thing say the
--- same thing.
---@param output string
local function findingsOf(output)
	return (output:match("^(.-)CHECK ") or output)
end

test.it("accepts a file that parses", function()
	writeInput("local x = 1\nreturn x\n")
	test.equal(check.file(INPUT), true)
end)

test.it("resolves a module the definitions ship", function()
	-- `lde-test` is injected by the runner and has no file in `target/`; the definitions carry
	-- its type, so a test file is checked like any other module.
	writeInput('local test = require("lde-test")\ntest.it("works", function() end)\n')
	test.equal(check.files({ INPUT }), true)
end)

test.it("reports a require that names no module", function()
	writeInput('local missing = require("no.such.module")\nmissing.run()\n')
	test.equal(check.files({ INPUT }), false)
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
local function exitCode(source, flag)
	writeInput(source)
	local out = run(string.format(
		"lde run %q -- %s %q >/dev/null 2>&1; echo $?", MAIN, flag, INPUT
	))
	return tonumber(out) or -1
end

test.it("prints the extensions the workspace's plugins claim", function()
	-- This is what an editor wrapper asks before it can map a `.toy` buffer to a filetype: the
	-- same loader a check uses, without checking a file.
	local workspace = TESTS_DIR .. "/fixtures/syntax"
	local output = run(string.format("lye extensions %q 2>&1", workspace))
	test.equal((output:gsub("%s+$", "")), "toy")
end)

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

	-- A walk of the workspace checks what is committed, so the fixture it keeps reads cleanly.
	-- The fault is written under `target/`, which no walk of the workspace visits, and the
	-- plugin beside the fixture still lowers it: a check named the file reads it as the language
	-- its package says it is written in.
	local target = workspace .. "/target"
	os.execute("mkdir -p " .. string.format("%q", target))
	local faulty = target .. "/faulty.toy"
	local handle = assert(io.open(faulty, "wb"))
	handle:write("let holding: number = \"not a number\"\nlet plain: number = 1\n")
	handle:close()

	local output = run("lde run " .. string.format("%q", MAIN) .. " --check " .. string.format("%q", faulty)
		.. " 2>&1")
	test.includes(output, "holding is declared as number but is assigned string",
		"the fault the plugin's own line has: " .. output)
	test.includes(output, "faulty.toy:1:", "reported on the first line of the file, where it was written")

	-- The same file a second time, and the same file named the way a run in a directory names it:
	-- what is held between the two is the analysis of the lowered text, and a finding of it has to
	-- travel back once per report rather than once per analysis.
	local again = run("lde run " .. string.format("%q", MAIN) .. " --check " .. string.format("%q", faulty)
		.. " " .. string.format("%q", faulty) .. " 2>&1")
	test.equal(again, output, "a file named twice is checked once, and reported the same way")

	local relative = run("lde run " .. string.format("%q", MAIN)
		.. " --check tests/fixtures/syntax/target/faulty.toy 2>&1")
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
			written = handle:read("*a") --[[@as string? ]]
			handle:close()
		end
	end
	test.truthy(written, "lye.json is there")
	local ok, config = pcall(require("lye-json").decode, written or "")
	---@cast config { plugins: table[], requirePaths: table[] }
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

test.it("honours a diagnostic directive in a checked file", function()
	local fault = "local x = 1 + \"s\"\nreturn x\n"
	test.equal(exitCode(fault, "--check"), 1, "the arithmetic fault is an error")
	local quiet = "---@diagnostic disable-next-line\n" .. fault
	test.equal(exitCode(quiet, "--check"), 0, "and the next line's directive keeps it out")
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
		'local marker = 1\n',
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
		---@cast path string
		local dir = path:match("^(.*)/[^/]+$")
		if dir then fs.mkdirAll(root .. "/" .. dir) end
	end
	for path, source in pairs(sources) do
		---@cast path string
		fs.write(root .. "/" .. path, source)
	end

	local function checkIn(workers)
		return run(string.format("LYE_WORKERS=%d lde run %q -- --check %q 2>/dev/null",
			workers, MAIN, root))
	end
	local one = checkIn(1)
	test.truthy(one:match(": warning: "), "the fixture has something to compare, got: " .. one)
	test.equal(checkIn(2), one, "two processes must say what one said")
	test.equal(checkIn(4), one, "and so must four")
end)

test.it("reads an unchanged tree back without analysing it", function()
	-- A warm check is the cache's whole point: every file's findings are reported as they were
	-- found, and no analysis runs at all. `seconds` is the check's own CPU time, so the command
	-- line's startup — the same in both runs — does not decide the comparison.
	local root = PACKAGE_DIR .. "/target/warm-fixture"
	local cacheDir = PACKAGE_DIR .. "/target/warm-entries"
	os.execute("rm -rf " .. string.format("%q", cacheDir))
	local files = {}
	for index = 1, 16 do
		files[string.format("src/file%02d.lua", index)] = table.concat({
			string.format("local seed = %d\n", index),
			"---@param value number\n",
			"local function bump(value)\n",
			"\tlocal total = value + seed\n",
			"\tfor _ = 1, 2 do total = total + 1 end\n",
			"\treturn total\n",
			"end\n",
			"return bump\n",
		})
	end
	files["lde.json"] = '{ "name": "warm-fixture", "version": "0.1.0" }\n'
	writeTree(root, files)
	local named = {}
	for relative in pairs(files) do
		---@cast relative string
		if relative:sub(-4) == ".lua" then named[#named + 1] = root .. "/" .. relative end
	end
	table.sort(named)

	local cold = probe(named, cacheDir)
	test.equal(cold.analyses, "16", "a cold run analyses every file: " .. cold.output)
	local warm = probe(named, cacheDir)
	test.equal(warm.analyses, "0", "a warm run analyses nothing: " .. warm.output)
	test.equal(warm.ok, "true", "and finds what the cold run found: " .. warm.output)
	test.truthy(tonumber(warm.seconds) < tonumber(cold.seconds),
		"and takes less CPU than the cold run: " .. warm.seconds .. " vs " .. cold.seconds)
end)

test.it("re-checks only the files whose text changed", function()
	-- A file whose findings were kept is reported from the entry; the one that changed is read
	-- again. The fixture is one package of three independent files, so the reachable slice of a
	-- change is the file itself.
	local root = PACKAGE_DIR .. "/target/slice-fixture"
	local cacheDir = PACKAGE_DIR .. "/target/slice-entries"
	os.execute("rm -rf " .. string.format("%q", cacheDir))
	local files = {
		["lde.json"] = '{ "name": "slice-fixture", "version": "0.1.0" }\n',
		["src/a.lua"] = "local a = 1\nreturn a\n",
		["src/b.lua"] = "local b = 2\nreturn b\n",
		["src/c.lua"] = "local c = 3\nreturn c\n",
	}
	writeTree(root, files)
	local named = {}
	for relative in pairs(files) do
		---@cast relative string
		if relative:sub(-4) == ".lua" then named[#named + 1] = root .. "/" .. relative end
	end
	table.sort(named)

	local cold = probe(named, cacheDir)
	test.equal(cold.analyses, "3", "a cold run analyses the three files: " .. cold.output)

	local fs = require("fs")
	fs.write(root .. "/src/b.lua", "local b = 4\nreturn b\n")
	local warm = probe(named, cacheDir)
	test.equal(warm.analyses, "1", "only the changed file is analysed: " .. warm.output)
	test.equal(warm.ok, "true", "and the batch still passes: " .. warm.output)
end)

--- A package whose files annotate each other, which is what a batch pre-parse is for: one file
--- declares a class, another uses it in a signature, and one writes a `---@type` whose diagnostic
--- sits on the type's own span rather than on the annotation's.
---@param root string
---@return table<string, string> files
local function indexFixture(root, name)
	local files = {
		["lde.json"] = string.format('{ "name": "%s", "version": "0.1.0" }\n', name),
		["src/declares.lua"] = table.concat({
			"---@class IndexedPoint\n",
			"---@field x number\n",
			"---@field y number\n",
			"return {}\n",
		}),
		["src/uses.lua"] = table.concat({
			"---@param point IndexedPoint\n",
			"---@return number\n",
			"local function total(point)\n",
			"\treturn point.x + point.y\n",
			"end\n",
			"return total\n",
		}),
		["src/typed.lua"] = "---@type string\nlocal x = 5\nreturn x\n",
		["src/warns.lua"] = "local unused = 1\nreturn 2\n",
	}
	writeTree(root, files)
	return files
end

---@param root string
---@param files table<string, string>
---@return string[] sorted absolute paths of the Lua files
local function luaPaths(root, files)
	local named = {}
	for relative in pairs(files) do
		---@cast relative string
		if relative:sub(-4) == ".lua" then named[#named + 1] = root .. "/" .. relative end
	end
	table.sort(named)
	return named
end

test.it("reads the batch's annotations from the declaration index instead of parsing them", function()
	-- The parent reads every checked file before it forks so that a name one declares is not a typo
	-- in another. That comment-lex is what the persisted index already holds: a record whose hash
	-- is the text read here answers for the file, and only a file the index does not describe is
	-- parsed. The fixture has an annotation type error, whose span has to survive the round trip.
	local root = absolutePath(PACKAGE_DIR .. "/target/index-annotations-fixture")
	local cacheDir = absolutePath(PACKAGE_DIR .. "/target/index-annotations-entries")
	os.execute("rm -rf " .. string.format("%q", cacheDir))
	local files = indexFixture(root, "index-annotations-fixture")
	local named = luaPaths(root, files)
	test.equal(buildIndex(root, cacheDir), true, "the earlier run wrote an index entry")

	local cold = probe(named, false)
	test.equal(cold.parseddocs, tostring(#named), "an uncached run parses every file: " .. cold.output)
	test.equal(cold.loadeddocs, "0", "and reads no index: " .. cold.output)

	local warm = probe(named, cacheDir)
	test.equal(warm.parseddocs, "0", "no checked file is comment-lexed: " .. warm.output)
	test.equal(warm.loadeddocs, tostring(#named), "every file comes from the index: " .. warm.output)
	test.equal(warm.ok, cold.ok, "and the batch passes as it did: " .. warm.output)
	test.equal(findingsOf(warm.output), findingsOf(cold.output),
		"the findings are byte-for-byte what an uncached run found")
end)

test.it("parses only the file whose text the index does not hold", function()
	local root = absolutePath(PACKAGE_DIR .. "/target/index-changed-fixture")
	local cacheDir = absolutePath(PACKAGE_DIR .. "/target/index-changed-entries")
	os.execute("rm -rf " .. string.format("%q", cacheDir))
	local files = indexFixture(root, "index-changed-fixture")
	local named = luaPaths(root, files)
	test.equal(buildIndex(root, cacheDir), true, "the earlier run wrote an index entry")

	-- The first run fills the diagnostic cache too; the edit then makes exactly one file's record
	-- a miss. What the index still holds answers for the other three.
	probe(named, cacheDir)
	local written = "local unused = 2\nreturn 2\n"
	local fs = require("fs")
	fs.write(root .. "/src/warns.lua", written)

	local cold = probe(named, false)
	local warm = probe(named, cacheDir)
	test.equal(warm.parseddocs, "1", "only the changed file is comment-lexed: " .. warm.output)
	test.equal(warm.loadeddocs, tostring(#named - 1), "the rest come from the index: " .. warm.output)
	test.equal(warm.analyses, "1", "and only the changed file is analysed: " .. warm.output)
	test.equal(findingsOf(warm.output), findingsOf(cold.output),
		"the findings are what an uncached run finds for the new text")
end)

test.it("an index that cannot be read is parsed as it always was", function()
	local root = absolutePath(PACKAGE_DIR .. "/target/index-corrupt-fixture")
	local cacheDir = absolutePath(PACKAGE_DIR .. "/target/index-corrupt-entries")
	os.execute("rm -rf " .. string.format("%q", cacheDir))
	local files = indexFixture(root, "index-corrupt-fixture")
	local named = luaPaths(root, files)
	test.equal(buildIndex(root, cacheDir), true, "the earlier run wrote an index entry")

	-- Half an entry is what a crash between the write and the rename leaves; a reader refuses it
	-- rather than trusting the part that happens to parse.
	local cache = require("lye-lsp.cache")
	local Index = require("lye-lsp.index")
	local entryPath = cacheDir .. "/" .. cache.codeVersion() .. "/" .. Index.new():key(root) .. ".entry"
	local fs = require("fs")
	local written = assert(fs.read(entryPath), "the entry is where its key says")
	fs.write(entryPath, written:sub(1, math.floor(#written / 2)))

	local cold = probe(named, false)
	local warm = probe(named, cacheDir)
	test.equal(warm.parseddocs, tostring(#named), "a corrupt index leaves every file to the parser: " .. warm.output)
	test.equal(warm.loadeddocs, "0", "and nothing is read from it: " .. warm.output)
	test.equal(findingsOf(warm.output), findingsOf(cold.output), "the findings are the same either way")
end)

return true
