--[[
	The idle checkpoint and the numbers it reports.

	A server that never collects grows for as long as the editor stays open, and one that collects
	on every pass spends a pause it cannot afford. The checkpoint is therefore a decision: a step
	when the heap has grown a little, a full collection when it has grown a lot or a document has
	closed, and nothing otherwise. These tests pin the decision at its boundaries, prove the RSS
	reader answers, and drive a session to see the stable memory mark on stderr.
]]

local test = require("lde-test")
local json = require("lye-json")
local fs = require("fs")
local timing = require("lye-lsp.timing")
local Lye = require("lye-lsp.language")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local FIXTURE = TESTS_DIR .. "/fixtures/server.lua"
local INPUT = PACKAGE_DIR .. "/target/memory-test-input.bin"
local STDERR = PACKAGE_DIR .. "/target/memory-test-stderr.txt"
local CACHE = PACKAGE_DIR .. "/target/memory-test-cache"

test.it("steps at 2 MiB of growth, collects fully at 8 MiB, and always on a close", function()
	local function decide(grown, force)
		return Lye.gcDecision(grown * 1024, force)
	end

	local collect, full = decide(0, false)
	test.equal(collect, false, "an unchanged heap is left to the pause")
	test.equal(full, false)

	collect, full = decide(2048 - 1, false)
	test.equal(collect, false, "under 2 MiB, an idle pass collects nothing")

	collect, full = decide(2048, false)
	test.equal(collect, true, "2 MiB of growth earns a step")
	test.equal(full, false)

	collect, full = decide(8 * 1024 - 1, false)
	test.equal(collect, true, "under 8 MiB it is still a step")
	test.equal(full, false)

	collect, full = decide(8 * 1024, false)
	test.equal(collect, true, "8 MiB of growth earns a full collection")
	test.equal(full, true)

	collect, full = decide(0, true)
	test.equal(collect, true, "a close collects whatever the growth")
	test.equal(full, true)
end)

test.it("reports the resident set and the heap from the running process", function()
	local rss = timing.rss()
	test.truthy(rss and rss > 0, "the resident set is a positive number of KiB: " .. tostring(rss))
	test.truthy(rss and rss < 64 * 1024 * 1024, "and a plausible one: " .. tostring(rss))

	local heap = timing.heap()
	test.truthy(heap > 0, "the heap count is positive: " .. tostring(heap))

	-- Growth is real: allocating then collecting has to move the count.
	local before = timing.heap()
	local held = {}
	for index = 1, 50000 do held[index] = { index } end
	test.truthy(timing.heap() > before, "the heap count follows an allocation")
	held = nil
	collectgarbage("collect")
	test.truthy(timing.heap() <= before + 1024, "and a collection gives it back")
end)

---@param value any
local function frame(value)
	local body = json.encode(value)
	return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

---@param body string
---@return table[]
local function messages(body)
	return {
		{ jsonrpc = "2.0", id = 1, method = "initialize", params = { capabilities = {} } },
		{
			jsonrpc = "2.0", method = "textDocument/didOpen",
			params = {
				textDocument = {
					uri = "file:///tmp/lye-memory.lua", languageId = "lua", version = 1, text = body,
				},
			},
		},
		{
			jsonrpc = "2.0", method = "textDocument/didChange",
			params = {
				textDocument = { uri = "file:///tmp/lye-memory.lua", version = 2 },
				contentChanges = {
					{
						range = {
							start = { line = 0, character = 0 },
							["end"] = { line = 0, character = 0 },
						},
						text = "-- edited\n",
					},
				},
			},
		},
		{
			jsonrpc = "2.0", method = "textDocument/didClose",
			params = { textDocument = { uri = "file:///tmp/lye-memory.lua" } },
		},
		{ jsonrpc = "2.0", id = 2, method = "shutdown" },
		{ jsonrpc = "2.0", method = "exit" },
	}
end

test.it("writes one stable memory mark per checkpoint across a session", function()
	os.execute("rm -rf " .. string.format("%q", CACHE))
	local handle = assert(io.open(INPUT, "wb"))
	for _, message in ipairs(messages(string.rep("local value = 1\n", 400))) do
		handle:write(frame(message))
	end
	handle:close()

	local pipe = assert(io.popen(string.format(
		"cd %q && cat %q | env LYE_CACHE_DIR=%q LYE_CACHE=off LYE_TIMING=1"
			.. " lde run %q 2> %q; echo \"EXIT:$?\"",
		PACKAGE_DIR, INPUT, CACHE, FIXTURE, STDERR
	)))
	local output = pipe:read("*a")
	pipe:close()
	local code = tonumber(output:match("EXIT:(%d+)%s*$")) or 0
	local stderr = fs.read(STDERR) or ""

	test.equal(code, 0, "the session ended normally: " .. stderr)

	local marks = {}
	for line in stderr:gmatch("[^\n]+") do
		local seconds, rss, heap, collected =
			line:match("^lye timing: memory=([%d%.]+)ms rss=(%d+) heap=(%d+) collected=([01])$")
		if seconds then
			marks[#marks + 1] = {
				rss = tonumber(rss), heap = tonumber(heap), collected = collected,
			}
		end
	end
	test.truthy(#marks >= 2, "idle and close each report a checkpoint: " .. stderr)
	local collected = 0
	for _, mark in ipairs(marks) do
		test.truthy(mark.rss > 0, "every mark carries a resident set: " .. stderr)
		test.truthy(mark.heap > 0, "and a heap: " .. stderr)
		if mark.collected == "1" then collected = collected + 1 end
	end
	-- The close itself forces a full collection (pinned by `gcDecision(0, true)` above); later
	-- idle passes over an unchanged heap correctly report that they collected nothing.
	test.truthy(collected >= 1, "a checkpoint in the session collected: " .. stderr)
end)

return true
