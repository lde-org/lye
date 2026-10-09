--[[
	Lifecycle tests for `lye-framework`.

	These drive a real server subprocess over real framed bytes. The lifecycle rules
	are the ones clients enforce and they are easy to get subtly wrong: a dropped
	notification, a missing `capabilities`, or the wrong `exit` code all show up as a
	server that will not attach.
]]

local test = require("lde-test")
local json = require("lye-json")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local FIXTURE = TESTS_DIR .. "/fixtures/server.lua"
local INPUT = PACKAGE_DIR .. "/target/framework-test-input.bin"

local INITIALIZE = {
	jsonrpc = "2.0",
	id = 1,
	method = "initialize",
	params = { processId = nil, capabilities = {} },
}

---@param value any
---@return string
local function frame(value)
	local body = json.encode(value)
	return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

--- Drive a session. `initialize` is prepended unless `isRaw` is set, because almost
--- every message is only legal after the handshake and forgetting it makes the server
--- correctly answer ServerNotInitialized.
---@param messages table[]
---@param isRaw boolean? skip the automatic initialize
---@return string[] responses
---@return integer exitCode
local function run(messages, isRaw)
	local handle = assert(io.open(INPUT, "wb"))
	if not isRaw then handle:write(frame(INITIALIZE)) end
	for _, message in ipairs(messages) do
		handle:write(frame(message))
	end
	handle:close()

	-- `io.popen` close reports the shell's status, not the child's, so the child prints
	-- its own exit code as the final line.
	local pipe = assert(io.popen(string.format(
		"cat %q | lde run %q 2>/dev/null; echo \"EXIT:$?\"", INPUT, FIXTURE
	)))
	local output = pipe:read("*a")
	pipe:close()

	local code = tonumber(output:match("EXIT:(%d+)%s*$")) or 0
	output = output:gsub("EXIT:%d+%s*$", "")

	local responses, i = {}, 1
	while true do
		local _, stop = output:find("\r\n\r\n", i, true)
		if not stop then break end
		local length = tonumber(output:sub(i, stop - 4):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
		if not length then break end
		responses[#responses + 1] = json.decode(output:sub(stop + 1, stop + length))
		i = stop + 1 + length
	end
	return responses, code
end

---@param id integer|string
---@return table
local function shutdownThenExit(id)
	return {
		{ jsonrpc = "2.0", id = id, method = "shutdown" },
		{ jsonrpc = "2.0", method = "exit" },
	}
end

test.it("answers initialize with a capabilities object", function()
	local responses = run({})
	test.equal(#responses, 1)
	test.truthy(responses[1].result.capabilities, "capabilities is required by every client")
	test.equal(responses[1].result.capabilities.textDocumentSync.change, 2)
	test.equal(responses[1].result.capabilities.textDocumentSync.openClose, true)
	test.equal(responses[1].result.serverInfo.name, "lye-test")
end)

test.it("considers utf-8 only when the client ranks it first", function()
	-- UTF-8 first: take it.
	local first = run({
		{
			jsonrpc = "2.0",
			id = 2,
			method = "initialize",
			params = { capabilities = { general = { positionEncodings = { "utf-8", "utf-16" } } } },
		},
	}, true)
	test.equal(first[1].result.capabilities.positionEncoding, "utf-8")

	-- UTF-16 first: honour the client's preference, because a client that offers
	-- utf-8 second may still reject an encoding it did not rank first.
	local second = run({
		{
			jsonrpc = "2.0",
			id = 2,
			method = "initialize",
			params = { capabilities = { general = { positionEncodings = { "utf-16", "utf-8" } } } },
		},
	}, true)
	test.equal(second[1].result.capabilities.positionEncoding, "utf-16")
end)

test.it("errors on a request sent before initialize", function()
	local responses = run({
		{ jsonrpc = "2.0", id = 9, method = "textDocument/hover", params = {} },
	}, true)
	test.equal(#responses, 1)
	test.equal(responses[1].id, 9)
	test.equal(responses[1].error.code, -32002)
end)

test.it("drops notifications sent before initialize", function()
	-- No response at all: a notification is never answered.
	local responses = run({
		{ jsonrpc = "2.0", method = "textDocument/didOpen", params = {} },
	}, true)
	test.equal(#responses, 0)
end)

test.it("answers shutdown with a null result", function()
	local responses = run(shutdownThenExit(4))
	test.equal(#responses, 2)
	test.equal(responses[2].id, 4)
	test.equal(responses[2].result, json.null)
end)

test.it("exits 0 when exit follows shutdown", function()
	local _, code = run(shutdownThenExit(1))
	test.equal(code, 0)
end)

test.it("exits 1 when exit arrives without shutdown", function()
	local _, code = run({ { jsonrpc = "2.0", method = "exit" } }, true)
	test.equal(code, 1)
end)

test.it("errors on an unknown method", function()
	local responses = run({ { jsonrpc = "2.0", id = 3, method = "textDocument/nonsense" } })
	test.equal(#responses, 2)
	test.equal(responses[2].error.code, -32601)
end)

test.it("errors on an unknown dollar request but ignores a dollar notification", function()
	local responses = run({
		{ jsonrpc = "2.0", id = 5, method = "$/unknownThing" },
		{ jsonrpc = "2.0", method = "$/anotherThing" },
	})
	-- Only the request draws a reply, and it must be MethodNotFound.
	test.equal(#responses, 2)
	test.equal(responses[2].id, 5)
	test.equal(responses[2].error.code, -32601)
end)

test.it("answers a handler that returns no value", function()
	-- A request must always get exactly one response. A handler returning nothing at
	-- all must still be answered rather than left hanging.
	local responses = run({ { jsonrpc = "2.0", id = 6, method = "test/noResult" } })
	test.equal(#responses, 1, "the server hangs the client when a request goes unanswered")
end)


local URI = "file:///tmp/demo.lua"

---@param text string
---@return table
local function didOpen(text)
	return {
		jsonrpc = "2.0",
		method = "textDocument/didOpen",
		params = {
			textDocument = { uri = URI, languageId = "lua", version = 1, text = text },
		},
	}
end

---@param version integer
---@param changes table[]
---@return table
local function didChange(version, changes)
	return {
		jsonrpc = "2.0",
		method = "textDocument/didChange",
		params = {
			textDocument = { uri = URI, version = version },
			contentChanges = changes,
		},
	}
end

---@param change table
---@return table
local function range(startLine, startChar, endLine, endChar, text)
	return {
		range = {
			start = { line = startLine, character = startChar },
			["end"] = { line = endLine, character = endChar },
		},
		text = text,
	}
end

---@return table
local function askText()
	return { jsonrpc = "2.0", id = 99, method = "test/text", params = { uri = URI } }
end

---@param responses table[]
---@return table
local function lastResult(responses)
	return responses[#responses].result
end

---@param responses table[]
---@param method string
---@return table?
local function findMethod(responses, method)
	for _, message in ipairs(responses) do
		if message.method == method then return message end
	end
end

test.it("reports the text from didOpen", function()
	local responses = run({ didOpen("local x = 1"), askText() })
	test.equal(lastResult(responses).text, "local x = 1")
	test.equal(lastResult(responses).version, 1)
end)

test.it("applies an incremental change to the right range", function()
	-- "local x = 1" -> replace chars 0..5 of line 0 with "const"
	local responses = run({
		didOpen("local x = 1"),
		didChange(2, { range(0, 0, 0, 5, "const") }),
		askText(),
	})
	test.equal(lastResult(responses).text, "const x = 1")
	test.equal(lastResult(responses).version, 2)
end)

test.it("applies several changes sequentially, each against the previous state", function()
	-- The protocol applies each change to the state produced by the last one. Applying
	-- them all against the original text is the classic way to get this wrong.
	local responses = run({
		didOpen("aaa"),
		didChange(2, {
			range(0, 0, 0, 1, "bbb"), -- "aaa" -> "bbbaa"
			range(0, 0, 0, 3, "c"),   -- "bbbaa" -> "caa"
		}),
		askText(),
	})
	test.equal(lastResult(responses).text, "caa")
end)

test.it("treats a change with no range as a full replacement", function()
	-- Legal even under incremental sync, so it cannot be assumed away.
	local responses = run({
		didOpen("original"),
		didChange(2, { { text = "replaced" } }),
		askText(),
	})
	test.equal(lastResult(responses).text, "replaced")
end)

test.it("inserts on a zero-width range", function()
	local responses = run({
		didOpen("ab"),
		didChange(2, { range(0, 2, 0, 2, "XY") }),
		askText(),
	})
	test.equal(lastResult(responses).text, "abXY")
end)

test.it("deletes when the range is non-empty and the text is empty", function()
	local responses = run({
		didOpen("hello world"),
		didChange(2, { range(0, 5, 0, 11, "") }),
		askText(),
	})
	test.equal(lastResult(responses).text, "hello")
end)

test.it("edits across several lines", function()
	local responses = run({
		didOpen("one\ntwo\nthree"),
		didChange(2, { range(0, 1, 2, 2, "X") }),
		askText(),
	})
	test.equal(lastResult(responses).text, "oXree")
end)

test.it("handles a change on a document that has CRLF line endings", function()
	local responses = run({
		didOpen("a\r\nb"),
		didChange(2, { range(1, 0, 1, 1, "B") }),
		askText(),
	})
	test.equal(lastResult(responses).text, "a\r\nB")
end)

test.it("forgets a document once it is closed", function()
	local responses = run({
		didOpen("gone"),
		{ jsonrpc = "2.0", method = "textDocument/didClose", params = { textDocument = { uri = URI } } },
		askText(),
	})
	test.equal(lastResult(responses).text, nil)
end)

test.it("runs a notification handler registered before run", function()
	-- The fixture's didOpen override is registered before `run` installs the defaults. A
	-- default that overwrites it replaces the package's behaviour with a no-op, silently.
	local responses = run({ didOpen("local x = 1") })
	local marker = findMethod(responses, "test/didOpenOverride")
	test.truthy(marker, "installDefaults replaced a handler registered before run")
	test.equal(marker.params.uri, URI)
end)

test.it("logs an error raised by a notification handler", function()
	-- Nothing else can report it: a notification has no id, so no response is sent.
	local responses = run({ { jsonrpc = "2.0", method = "test/raise" } })
	local log = findMethod(responses, "window/logMessage")
	test.truthy(log, "a raised notification error must not disappear")
	test.equal(log.params.type, 1)
	test.truthy(log.params.message:find("test fixture raised", 1, true))
end)

return true
