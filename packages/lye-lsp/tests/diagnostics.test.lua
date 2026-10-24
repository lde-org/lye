--[[
	End-to-end tests for `lye-lsp`.

	These drive the real server the way an editor does: framed bytes in, framed bytes
	out. Every unit of this package works when it is called directly, so only a session
	can catch a fault in how they are wired together.
]]

local test = require("lde-test")
local json = require("lye-json")
local fs = require("fs")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local FIXTURE = TESTS_DIR .. "/fixtures/server.lua"
local CACHE = PACKAGE_DIR .. "/target/session-cache"

-- Every session of the suite reads and writes under one directory of its own, wiped first: the
-- entries and the definitions are written there rather than beside the workspace the session was
-- handed, and the first test that reaches a module reads it while the ones after it read the
-- answer, so the whole file runs the same way every time rather than depending on what an earlier
-- run — or another session — left behind.
os.execute("rm -rf " .. string.format("%q", CACHE))
local INPUT = PACKAGE_DIR .. "/target/lsp-test-input.bin"

local URI = "file:///tmp/lye-session.lua"

local BROKEN = "local x = 1\nlocal = 2\n"
local VALID = "local x = 1\nlocal y = 2\n"

---@param value any
---@return string
local function frame(value)
	local body = json.encode(value)
	return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

--- Drive a session. `initialize` is always prepended: a notification sent before the
--- handshake is dropped, so a session that forgot it would assert on silence.
---@param messages table[]
---@param root string? a workspace to open, for what a document names without requiring it
---@param cache boolean|string? where the session keeps what it works out — the suite's own
--- directory, one it names, or `false` for none named at all, which leaves the workspace's own
---@return table[] frames
---@return integer exitCode
local function run(messages, root, cache)
	local handle = assert(io.open(INPUT, "wb"))
	handle:write(frame({
		jsonrpc = "2.0",
		id = 1,
		method = "initialize",
		params = { capabilities = {}, rootUri = root and ("file://" .. root) or nil },
	}))
	for _, message in ipairs(messages) do
		handle:write(frame(message))
	end
	handle:close()

	-- `lde run` resolves package dependencies from the working directory, and `io.popen`
	-- close reports the shell's status rather than the child's, so the child prints its
	-- own exit code as the final line.
	local env = cache == false and "" or ("LYE_CACHE_DIR=" .. string.format("%q", cache or CACHE))
	local pipe = assert(io.popen(string.format(
		"cd %q && %s cat %q | lde run %q 2>/dev/null; echo \"EXIT:$?\"",
		PACKAGE_DIR, env, INPUT, FIXTURE
	)))
	local output = pipe:read("*a")
	pipe:close()

	local code = tonumber(output:match("EXIT:(%d+)%s*$")) or 0
	output = output:gsub("EXIT:%d+%s*$", "")

	local frames, i = {}, 1
	while true do
		local _, stop = output:find("\r\n\r\n", i, true)
		if not stop then break end
		local length = tonumber(output:sub(i, stop - 4):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
		if not length then break end
		frames[#frames + 1] = json.decode(output:sub(stop + 1, stop + length))
		i = stop + 1 + length
	end
	return frames, code
end

--- Write a file a test needs. `target/` is where lde links a package's dependencies, so the
--- repository's `.gitignore` leaves it out: a fixture's linked module is written when the suite
--- runs, not kept in the tree.
---@param path string
---@param content string
local function writeFile(path, content)
	local dir = path:match("^(.*)/[^/]+$")
	os.execute("mkdir -p " .. string.format("%q", dir))
	local handle = assert(io.open(path, "wb"))
	handle:write(content)
	handle:close()
end

--- A real session ends with `shutdown` then `exit`, and the exit code proves both arrived.
---@param messages table[]
---@return table[]
local function endingWithShutdown(messages)
	messages[#messages + 1] = { jsonrpc = "2.0", id = 2, method = "shutdown" }
	messages[#messages + 1] = { jsonrpc = "2.0", method = "exit" }
	return messages
end

---@param text string
---@param uri string? the document to open, for what its types resolve against
---@return table
local function didOpen(text, uri)
	return {
		jsonrpc = "2.0",
		method = "textDocument/didOpen",
		params = { textDocument = { uri = uri or URI, languageId = "lua", version = 1, text = text } },
	}
end

--- A change with no range replaces the whole document.
---@param version integer
---@param text string
---@return table
local function didReplace(version, text)
	return {
		jsonrpc = "2.0",
		method = "textDocument/didChange",
		params = {
			textDocument = { uri = URI, version = version },
			contentChanges = { { text = text } },
		},
	}
end

--- Replace all of line 1, which held a valid statement.
---@param version integer
---@param text string
---@return table
local function didEdit(version, text)
	return {
		jsonrpc = "2.0",
		method = "textDocument/didChange",
		params = {
			textDocument = { uri = URI, version = version },
			contentChanges = {
				{
					range = {
						start = { line = 1, character = 0 },
						["end"] = { line = 1, character = 11 },
					},
					text = text,
				},
			},
		},
	}
end

---@param frames table[]
---@param method string
---@return table?
local function findMethod(frames, method)
	for _, message in ipairs(frames) do
		if message.method == method then return message end
	end
end

---@param frames table[]
---@return table[]
--- The diagnostics an editor shows as a problem, in the order they were published. An unused
--- local, whose warning every snippet here would otherwise carry, is dropped by name: these tests
--- are about the diagnostics of the code itself.
---@param frames table[]
---@return table[]
local function publishedDiagnostics(frames)
	local published = {}
	for _, message in ipairs(frames) do
		if message.method == "textDocument/publishDiagnostics" then
			local kept = {}
			for _, entry in ipairs(message.params.diagnostics or {}) do
				if not (entry.message or ""):match("^unused local") then kept[#kept + 1] = entry end
			end
			message.params.diagnostics = kept
			published[#published + 1] = message.params
		end
	end
	return published
end

test.it("reads a lowered document, and reports where the reader wrote it", function()
	-- The fixture plugin compiles `let name: type = value` to a `---@type` annotation over a
	-- `local`. The annotation is text the plugin wrote, so the fault lye finds inside it has to
	-- come back to the line the reader wrote — and the tokens the plugin coloured come back with it.
	local workspace = TESTS_DIR .. "/fixtures/syntax"
	local uri = "file://" .. workspace .. "/main.toy"
	local source = "let holding: number = \"not a number\"\nlet plain: number = 1\n"
	local frames = run(endingWithShutdown({
		didOpen(source, uri),
		{
			jsonrpc = "2.0", id = 7, method = "textDocument/semanticTokens/full",
			params = { textDocument = { uri = uri } },
		},
	}), workspace)

	local params = assert(publishedDiagnostics(frames)[1])
	test.equal(#params.diagnostics, 1, "the value contradicts the type the line declares")
	test.truthy(params.diagnostics[1].message:find("number", 1, true), params.diagnostics[1].message)
	test.equal(params.diagnostics[1].range.start.line, 0, "reported on the line the reader wrote")
	test.equal(params.diagnostics[1].range["end"].line, 0, "and within it")

	-- What the plugin coloured is in the lowered text's offsets and is answered in the reader's.
	local answer
	for _, message in ipairs(frames) do
		if message.id == 7 then answer = message.result end
	end
	local data = assert(answer and answer.data, "the token answer")
	local lines = {}
	for piece in (source .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = piece end
	local seen, marked = {}, {}
	local line, character = 0, 0
	for index = 1, #data, 5 do
		line = line + data[index]
		character = data[index] == 0 and (character + data[index + 1]) or data[index + 1]
		local text = lines[line + 1] and lines[line + 1]:sub(character + 1, character + data[index + 2])
		seen[data[index + 3]] = true
		marked[#marked + 1] = { line = line, text = text, kind = data[index + 3] }
	end
	test.equal(seen[11], true, "a property is coloured, which is the plugin's own kind")
	test.equal(seen[1], nil, "and nothing lye read out of the text the plugin wrote is sent: a "
		.. "string that exists in the lowered line has no place in the one the reader wrote")

	local names = {}
	for _, token in ipairs(marked) do
		if token.line == 0 then names[#names + 1] = token.text end
	end
	test.equal(table.concat(names, " "), "holding",
		"the name the plugin coloured, in the reader's own offsets")
end)

test.it("answers initialize with a capabilities object", function()
	local frames = run(endingWithShutdown({}))
	test.equal(frames[1].id, 1)
	test.truthy(frames[1].result.capabilities, "capabilities is required by every client")
end)

test.it("publishes a syntax diagnostic when a document with an error is opened", function()
	local frames = run(endingWithShutdown({ didOpen(BROKEN) }))

	test.truthy(findMethod(frames, "textDocument/publishDiagnostics"), "didOpen must publish")
	local params = assert(publishedDiagnostics(frames)[1])
	test.equal(params.uri, URI)
	test.equal(params.version, 1)
	test.equal(#params.diagnostics, 1, "`local = 2` is a syntax error")
	test.equal(params.diagnostics[1].source, "lye")
	test.equal(params.diagnostics[1].severity, 1)
	test.equal(params.diagnostics[1].range.start.line, 1)
	test.equal(params.diagnostics[1].range.start.character, 6)
end)

test.it("publishes the hint that `fun(...):...` says what `function` says", function()
	-- The permissive callable written out is not wrong, so it is published as a hint at the type
	-- it is written in rather than as something to fix.
	local source = "---@param cb fun(...):...\nlocal function take(cb) end\nreturn take\n"
	local frames = run(endingWithShutdown({ didOpen(source) }))

	local params = assert(publishedDiagnostics(frames)[1])
	test.equal(#params.diagnostics, 1, "the hint, and nothing wrong with the code")
	test.equal(params.diagnostics[1].severity, 3, "a hint rather than a warning")
	test.equal(params.diagnostics[1].message,
		"`fun(...):...` is identical to `function`")
	test.equal(params.diagnostics[1].range.start.line, 0)
	test.equal(params.diagnostics[1].range.start.character, 13, "the type is what is marked")
	test.equal(params.diagnostics[1].range["end"].character, 25)
end)

test.it("clears diagnostics when the document is fixed", function()
	local frames = run(endingWithShutdown({ didOpen(BROKEN), didReplace(2, VALID) }))

	local published = publishedDiagnostics(frames)
	test.equal(#published, 2, "an open and a change each publish a full replacement set")
	test.equal(#published[2].diagnostics, 0)
	test.equal(published[2].version, 2)
end)

test.it("publishes a diagnostic after an incremental change introduces an error", function()
	-- The ranged edit changes line 1 from a valid statement into `local = 2`.
	local frames = run(endingWithShutdown({ didOpen(VALID), didEdit(2, "local = 2") }))

	local published = publishedDiagnostics(frames)
	test.equal(#published, 2)
	test.equal(#published[1].diagnostics, 0, "the opening text is valid")
	test.equal(#published[2].diagnostics, 1)
	test.equal(published[2].diagnostics[1].range.start.line, 1)
	test.equal(published[2].diagnostics[1].range.start.character, 6)
end)

test.it("resolves a class another workspace file declares for a document that never requires it", function()
	-- The editor opens one document at startup and has read no other: a parameter typed as
	-- another file's class has to mean that class all the same, or every table built for it is
	-- refused. No document is opened here, so only the workspace scan can know it — which is what
	-- `lye check` reads the pair of files as too.
	local workspace = TESTS_DIR .. "/fixtures/workspace"
	local uri = "file://" .. workspace .. "/use.lua"
	local source = table.concat({
		"---@param p Point\n",
		"local function f(p)\n",
		"\treturn p.x\n",
		"end\n",
		"f({ x = 1, y = 2 })\n",
	}, "")
	local published = publishedDiagnostics(run(endingWithShutdown({ didOpen(source, uri) }), workspace))

	test.equal(#published, 1, "opening the document publishes its diagnostics")
	test.equal(#published[1].diagnostics, 0,
		"a table built for the class fits it: "
			.. (published[1].diagnostics[1] and published[1].diagnostics[1].message or "none"))
end)

test.it("resolves a class the document's package has linked into target", function()
	-- `target/` is left out of the workspace walk — it mirrors other packages — and what a
	-- document can reach is what lde linked into its own package: the same resolution a check
	-- does for the package's links.
	local project = TESTS_DIR .. "/fixtures/package"
	local uri = "file://" .. project .. "/src/use.lua"
	local source = table.concat({
		"---@param d Dep\n",
		"local function f(d)\n",
		"\treturn d.amount\n",
		"end\n",
		"f({ amount = 1 })\n",
	}, "")
	local published = publishedDiagnostics(run(endingWithShutdown({ didOpen(source, uri) }), project))

	test.equal(#published, 1, "opening the document publishes its diagnostics")
	test.equal(#published[1].diagnostics, 0,
		"a table built for the linked class fits it: "
			.. (published[1].diagnostics[1] and published[1].diagnostics[1].message or "none"))
end)

test.it("keeps what a module came to for the session after it", function()
	-- The first session analyses `dep` to answer `require`; the second reads that answer instead
	-- of the file. Both must report the same thing about the caller.
	local project = TESTS_DIR .. "/fixtures/interface"
	local uri = "file://" .. project .. "/src/use.lua"
	local source = table.concat({
		"local dep = require(\"dep\")\n",
		"local total = dep() + 1\n",
		"return total\n",
	}, "")
	writeFile(project .. "/target/dep.lua", "local function value() return \"x\" end\nreturn value\n")

	local cold = publishedDiagnostics(run(endingWithShutdown({ didOpen(source, uri) }), project))
	local warm = publishedDiagnostics(run(endingWithShutdown({ didOpen(source, uri) }), project))

	test.equal(#cold, 1, "the first session publishes on open")
	test.equal(#cold[1].diagnostics, 1, "a string is refused where a number is")
	test.truthy(cold[1].diagnostics[1].message:find("needs numbers", 1, true))
	test.equal(#warm, 1, "so does the second")
	test.equal(warm[1].diagnostics[1].message, cold[1].diagnostics[1].message,
		"and the answer it kept says the same thing")
end)

test.it("reads a module again when the file it names has changed", function()
	-- What a session keeps for a module is only the answer for the links it read it against, so a
	-- dependency that changed on disk is read again rather than answered for.
	local project = TESTS_DIR .. "/fixtures/interface"
	local uri = "file://" .. project .. "/src/use.lua"
	local module = project .. "/target/dep.lua"
	local source = table.concat({
		"local dep = require(\"dep\")\n",
		"local total = dep() + 1\n",
		"return total\n",
	}, "")

	local text = "local function value() return \"x\" end\nreturn value\n"
	writeFile(module, text)
	local cold = publishedDiagnostics(run(endingWithShutdown({ didOpen(source, uri) }), project))

	writeFile(module, "local function value() return 7 end\nreturn value\n")
	local changed = publishedDiagnostics(run(endingWithShutdown({ didOpen(source, uri) }), project))
	writeFile(module, text)

	test.equal(#cold[1].diagnostics, 1, "a string is refused where a number is")
	test.equal(#changed[1].diagnostics, 0, "and the module that now gives a number is read again")
end)

test.it("keeps what it works out beside the workspace it was handed", function()
	-- No directory named: an editor session writes beside the project it opened, so a session
	-- after it on the same project reads what this one worked out, definitions and all.
	local project = TESTS_DIR .. "/fixtures/interface"
	local uri = "file://" .. project .. "/src/use.lua"
	local source = "local ffi = require(\"ffi\")\nreturn ffi\n"
	local beside = project .. "/.lye"
	os.execute("rm -rf " .. string.format("%q", beside))

	local published = publishedDiagnostics(run(endingWithShutdown({ didOpen(source, uri) }), project, false))

	test.equal(#published, 1, "opening the document publishes its diagnostics")
	test.equal(fs.isdir(beside), true, "the session kept its answers beside the workspace")
	test.equal(fs.isdir(beside .. "/defs"), true, "and the definitions a client opens are there too")
	os.execute("rm -rf " .. string.format("%q", beside))
end)

test.it("holds a `.d.lua` document to its annotations, not to bodies it does not have", function()
	-- A definition file has no bodies: `---@return true?` over `function file:write(...) end` is the
	-- whole of that function, and a name ending `.d.lua` says so without a `---@meta` marker.
	local source = "---@type string\nlocal held = 1\nreturn held\n"
	local asDefinition = publishedDiagnostics(
		run(endingWithShutdown({ didOpen(source, "file:///tmp/held.d.lua") }), nil))
	test.equal(#asDefinition, 1, "the document publishes")
	test.equal(#asDefinition[1].diagnostics, 0, "and a definition file reports nothing")

	local asSource = publishedDiagnostics(
		run(endingWithShutdown({ didOpen(source, "file:///tmp/held.lua") }), nil))
	test.equal(#asSource[1].diagnostics, 1,
		"while the same text in a `.lua` file is held to what it writes")
end)

test.it("reads ffi types only while the ffi plugin is on", function()
	-- The analyzer has no cdef code left in it: the shipped ffi plugin contributes the classes a
	-- block declares and the type of `ffi.new`. Turning it off in `lye.json` removes both, which is
	-- the proof that a dialect can be a plugin rather than a branch in the analyzer.
	local project = PACKAGE_DIR .. "/target/ffi-toggle"
	os.execute("rm -rf " .. string.format("%q", project))
	writeFile(project .. "/lye.json", "{\"plugins\":[\"!ffi\"]}\n")
	local uri = "file://" .. project .. "/main.lua"
	local source = table.concat({
		"local ffi = require(\"ffi\")\n",
		"ffi.cdef[[ typedef struct { int x; } Vec; ]]\n",
		"local v = ffi.new(\"Vec\")\n",
		"v.nope = 1\n",
		"return v\n",
	}, "")

	---@param published table[]
	---@return boolean
	local function reportsVec(published)
		for _, message in ipairs(published) do
			for _, entry in ipairs(message.diagnostics) do
				if entry.message:match("`nope` is not a field of Vec") then return true end
			end
		end
		return false
	end

	local off = publishedDiagnostics(run(endingWithShutdown({ didOpen(source, uri) }), project))
	test.falsy(reportsVec(off), "without the plugin the generated class is not there")

	writeFile(project .. "/lye.json", "{\"plugins\":[]}\n")
	local on = publishedDiagnostics(run(endingWithShutdown({ didOpen(source, uri) }), project))
	test.truthy(reportsVec(on), "with it, the member the block never declared is reported")
	os.execute("rm -rf " .. string.format("%q", project))
end)

test.it("exits 0 when exit follows shutdown", function()
	local _, code = run(endingWithShutdown({}))
	test.equal(code, 0)
end)

return true
