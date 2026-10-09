--[[
	Byte-level tests for the `lye-rpc` framing layer.

	Framing bugs do not fail where they happen. They desync the stream and show up much
	later as an unrelated error, so these tests drive real bytes through a real
	subprocess rather than mocking the transport.

	Writing the input to a file and piping that in serves two purposes: binary data
	cannot survive shell quoting reliably, and a file read produces the short reads and
	split frames that matter here.

	The child is `tests/fixtures/echo.lua`. It cannot be this file, because `lde test`
	injects the `lde-test` framework only into files it runs itself.
]]

local test = require("lde-test")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local CHILD = TESTS_DIR .. "/fixtures/echo.lua"
local INPUT = PACKAGE_DIR .. "/target/rpc-test-input.bin"

---@param body string
---@return string
local function frame(body)
	return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

---@param input string
local function writeInput(input)
	local handle = assert(io.open(INPUT, "wb"))
	handle:write(input)
	handle:close()
end

---@param command string
---@return string
local function readPipe(command)
	local pipe = assert(io.popen(command))
	local output = pipe:read("*a")
	pipe:close()
	return output
end

--- Write `input` and run the child over it.
---@param input string
---@return string output
local function runChild(input)
	writeInput(input)
	return readPipe(string.format("cat %q | lde run %q 2>/dev/null", INPUT, CHILD))
end

--- Split a byte stream into the JSON body of each frame.
---@param output string
---@return string[]
local function bodies(output)
	local out, n, i = {}, 0, 1
	while true do
		local _, stop = output:find("\r\n\r\n", i, true)
		if not stop then break end
		local length = tonumber(output:sub(i, stop - 4):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
		if not length then break end
		n += 1
		out[n] = output:sub(stop + 1, stop + length)
		i = stop + 1 + length
	end
	return out
end

---@param output string
---@param needle string
---@param id integer|string|nil
---@return boolean
local function hasFrame(output, needle, id)
	for _, body in ipairs(bodies(output)) do
		if body:find(needle, 1, true) and (id == nil or body:find('"id":' .. id, 1, true)) then
			return true
		end
	end
	return false
end

test.it("frames a response for a single request", function()
	local output = runChild(frame('{"jsonrpc":"2.0","id":1,"method":"initialize"}'))
	test.truthy(output:match("^Content%-Length: %d+\r\n\r\n"))
	test.truthy(hasFrame(output, '"method":"initialize"', 1))
end)

test.it("echoes several messages in order and never answers a notification", function()
	local output = runChild(
		frame('{"jsonrpc":"2.0","id":1,"method":"initialize"}')
		.. frame('{"jsonrpc":"2.0","method":"initialized"}')
		.. frame('{"jsonrpc":"2.0","id":2,"method":"shutdown"}')
	)

	local got = bodies(output)
	test.equal(#got, 3)
	test.truthy(got[1]:find('"id":1', 1, true))
	test.truthy(got[2]:find('"sawNotification"', 1, true))
	test.equal(got[2]:find('"id"', 1, true), nil, "a notification must not be answered")
	test.truthy(got[3]:find('"id":2', 1, true))
end)

test.it("counts Content-Length in bytes, not characters", function()
	-- é is 2 bytes and € is 3. A character-count implementation desyncs right here.
	local output = runChild(frame('{"jsonrpc":"2.0","id":1,"method":"m","params":"caf\195\169\226\130\172"}'))
	test.truthy(hasFrame(output, '"method":"m"', 1))
end)

test.it("accepts a lowercase header and extra headers", function()
	local body = '{"jsonrpc":"2.0","id":7,"method":"hello"}'
	local output = runChild(
		"content-length: " .. #body
		.. "\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n" .. body
	)
	test.truthy(hasFrame(output, '"method":"hello"', 7))
end)

test.it("reports a malformed body and keeps parsing what follows", function()
	local output = runChild(frame("{not json") .. frame('{"jsonrpc":"2.0","id":5,"method":"after"}'))

	local got = bodies(output)
	test.equal(#got, 2)
	test.truthy(got[1]:find("-32700", 1, true), "first frame is a ParseError")
	test.truthy(got[2]:find('"id":5', 1, true), "the next message is still answered")
end)

test.it("reassembles a frame that arrives in small pieces", function()
	-- dd reads and writes 5 bytes at a time, so the child sees partial frames and a
	-- header split across reads.
	writeInput(frame('{"jsonrpc":"2.0","id":1,"method":"initialize"}'))
	local output = readPipe(string.format("dd if=%q bs=5 2>/dev/null | lde run %q 2>/dev/null", INPUT, CHILD))
	test.truthy(hasFrame(output, '"method":"initialize"', 1))
end)

test.it("stops cleanly when the input ends between messages", function()
	local output = runChild(frame('{"jsonrpc":"2.0","id":1,"method":"m"}'))
	test.equal(#bodies(output), 1)
end)

test.it("produces nothing for an empty input", function()
	test.equal(runChild(""), "")
end)

return true
