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
		"cd %q && cat %q | lde run %q 2>/dev/null; echo \"EXIT:$?\"", PACKAGE_DIR, INPUT, FIXTURE
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

test.it("exits 0 when exit follows shutdown", function()
	local _, code = run(endingWithShutdown({}))
	test.equal(code, 0)
end)

return true
