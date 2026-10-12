--[[
	End-to-end tests for `lye-lsp`.

	These drive the real server the way an editor does: framed bytes in, framed bytes
	out. Every unit of this package works when it is called directly, so only a session
	can catch a fault in how they are wired together.
]]

local test = require("lde-test")
local json = require("lye-json")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local FIXTURE = TESTS_DIR .. "/fixtures/server.lua"
local CACHE = PACKAGE_DIR .. "/target/session-cache"

-- Every session of the suite reads and writes under one directory of its own, wiped first: the
-- definitions are written there rather than into the user's cache, and the first test that reaches a
-- module reads it while the ones after it read the answer, so the whole file runs the same way
-- every time rather than depending on what an earlier run — or another session — left behind.
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
---@return table[] frames
---@return integer exitCode
local function run(messages, root)
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
	local pipe = assert(io.popen(string.format(
		"cd %q && XDG_CACHE_HOME=%q cat %q | lde run %q 2>/dev/null; echo \"EXIT:$?\"",
		PACKAGE_DIR, CACHE, INPUT, FIXTURE
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

test.it("exits 0 when exit follows shutdown", function()
	local _, code = run(endingWithShutdown({}))
	test.equal(code, 0)
end)

return true
