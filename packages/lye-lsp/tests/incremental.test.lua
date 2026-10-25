--[[
	The answers a warm session gives after a burst of changes, against the answers a cold session
	gives when it is handed the final text and nothing else.

	Resuming a parse is only worth anything if it is invisible: the same hover, the same tokens and
	the same diagnostics as a session that read the text once, from the start. These tests drive the
	real server through the same framed protocol an editor uses, because the wiring is what decides
	whether the parse, the offset and the cached annotations are the right ones for the text at hand.
]]

local test = require("lde-test")
local json = require("lye-json")
local fs = require("fs")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local FIXTURE = TESTS_DIR .. "/fixtures/server.lua"

local URI = "file:///tmp/lye-incremental.lua"

--- A session of its own: its own cache directory, its own input and its own stderr. `LYE_CACHE=off`
--- keeps persisted entries out of the comparison, and the directory is still named so the
--- definitions a client opens are written somewhere other than the workspace.
local RUN = 0
-- A tag no other test process shares: two acceptance runs of this file must not write the same
-- input, stderr or cache files, or one session reads another one's bytes. The process id is what
-- makes it unique: `math.random` is seeded identically in two copies started in the same second.
local RUN_TAG
do
	local ok, value = pcall(function()
		local ffi = require("ffi")
		pcall(ffi.cdef, "int getpid(void);")
		return tonumber(ffi.C.getpid())
	end)
	RUN_TAG = (ok and value and tostring(value) or tostring({}):match("0x(%x+)") or "0")
		.. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 1e9))
end

-- `lde` relinks a package's dependencies into the shared `target/` when it thinks they are stale,
-- and two relinks at once can leave a module half written. The lock serialises just that step, so
-- two copies of this file can run at once; where `flock` is absent the command runs unlocked.
local LOCK
if os.execute("command -v flock >/dev/null 2>&1") == 0 then
	LOCK = "flock " .. string.format("%q", PACKAGE_DIR .. "/target/.session-lock")
end

---@param value any
---@return string
local function frame(value)
	local body = json.encode(value)
	return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

---@return table
local function initialize()
	return {
		jsonrpc = "2.0", id = 1, method = "initialize",
		params = { capabilities = {} },
	}
end

---@param frames table[]
---@param id integer
---@return any
local function response(frames, id)
	for _, message in ipairs(frames) do
		if message.id == id then return message.result end
	end
end

---@param frames table[]
---@return table[]
local function parseFrames(output)
	local frames, at = {}, 1
	while true do
		local _, stop = output:find("\r\n\r\n", at, true)
		if not stop then break end
		local length = tonumber(output:sub(at, stop - 4):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
		if not length then break end
		frames[#frames + 1] = json.decode(output:sub(stop + 1, stop + length))
		at = stop + 1 + length
	end
	return frames
end

---@param messages table[]
---@param options { incremental: boolean?, timing: boolean? }?
---@return table[] frames
---@return integer exitCode
---@return string stderr
local function run(messages, options)
	options = options or {}
	RUN = RUN + 1
	local input = PACKAGE_DIR .. "/target/incremental-input-" .. RUN_TAG .. "-" .. RUN .. ".bin"
	local stderrPath = PACKAGE_DIR .. "/target/incremental-stderr-" .. RUN_TAG .. "-" .. RUN .. ".txt"
	local cacheDir = PACKAGE_DIR .. "/target/incremental-cache-" .. RUN_TAG .. "-" .. RUN
	os.execute("rm -rf " .. string.format("%q", cacheDir))

	local handle = assert(io.open(input, "wb"))
	handle:write(frame(initialize()))
	for _, message in ipairs(messages) do handle:write(frame(message)) end
	handle:close()

	local env = {
		"LYE_CACHE_DIR=" .. string.format("%q", cacheDir),
		"LYE_CACHE=off",
	}
	if options.incremental == false then env[#env + 1] = "LYE_INCREMENTAL=0" end
	if options.timing then env[#env + 1] = "LYE_TIMING=1" end

	local lock = LOCK and (LOCK .. " ") or ""
	local pipe = assert(io.popen(string.format(
		"cd %q && cat %q | %s %slde run %q 2> %q; echo \"EXIT:$?\"",
		PACKAGE_DIR, input, table.concat(env, " "), lock, FIXTURE, stderrPath
	)))
	local output = pipe:read("*a")
	pipe:close()

	local code = tonumber(output:match("EXIT:(%d+)%s*$")) or 0
	output = output:gsub("EXIT:%d+%s*$", "")
	local frames = parseFrames(output)
	local stderr = fs.read(stderrPath) or ""
	os.execute("rm -rf " .. string.format("%q", cacheDir) .. " "
		.. string.format("%q", input) .. " " .. string.format("%q", stderrPath))
	return frames, code, stderr
end

--- The last diagnostics published, which is the set for the text the session settled on.
---@param frames table[]
---@return table?
local function lastDiagnostics(frames)
	local found
	for _, message in ipairs(frames) do
		if message.method == "textDocument/publishDiagnostics" then found = message.params.diagnostics end
	end
	return found
end

--- A stable rendering of a decoded answer, so two sessions are compared by what they said rather
--- than by the order Lua happened to iterate a table in.
---@param value any
---@return string
local function canonical(value)
	local kind = type(value)
	if kind == "table" then
		if #value > 0 then
			local parts = {}
			for index = 1, #value do parts[index] = canonical(value[index]) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for key in pairs(value) do keys[#keys + 1] = key end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local parts = {}
		for _, key in ipairs(keys) do
			parts[#parts + 1] = tostring(key) .. "=" .. canonical(value[key])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif kind == "number" then
		return string.format("%.17g", value)
	end
	return tostring(value)
end

---@param text string
---@param at string? the document to open, defaulting to the file these tests edit
---@return table
local function didOpen(text, at)
	return {
		jsonrpc = "2.0", method = "textDocument/didOpen",
		params = { textDocument = { uri = at or URI, languageId = "lua", version = 1, text = text } },
	}
end

--- Replace one line, from its first column to its last.
---@param version integer
---@param line integer
---@param old string
---@param new string
---@param at string? the document to change
---@return table
local function replaceLine(version, line, old, new, at)
	return {
		jsonrpc = "2.0", method = "textDocument/didChange",
		params = {
			textDocument = { uri = at or URI, version = version },
			contentChanges = {
				{
					range = {
						start = { line = line, character = 0 },
						["end"] = { line = line, character = #old },
					},
					text = new,
				},
			},
		},
	}
end

--- One notification carrying several edits, which is what a formatter or a multi-cursor edit
--- looks like on the wire.
---@param version integer
---@param changes table[]
---@return table
local function didChangeMany(version, changes)
	return {
		jsonrpc = "2.0", method = "textDocument/didChange",
		params = { textDocument = { uri = URI, version = version }, contentChanges = changes },
	}
end

---@param line integer
---@param character integer
---@param at string? the document to ask about
---@param id integer? the request id, 10 for the single-document tests
---@return table
local function hover(line, character, at, id)
	return {
		jsonrpc = "2.0", id = id or 10, method = "textDocument/hover",
		params = { textDocument = { uri = at or URI }, position = { line = line, character = character } },
	}
end

---@return table
local function tokens()
	return {
		jsonrpc = "2.0", id = 11, method = "textDocument/semanticTokens/full",
		params = { textDocument = { uri = URI } },
	}
end

---@param messages table[]
---@return table[]
local function endingWithShutdown(messages)
	messages[#messages + 1] = { jsonrpc = "2.0", id = 2, method = "shutdown" }
	messages[#messages + 1] = { jsonrpc = "2.0", method = "exit" }
	return messages
end

-- The first statement is untouched in every edit below, so the span starts inside the second one
-- and the parser has a whole statement before it to keep.
local INITIAL = table.concat({
	"local first = 1\n",
	"local second = 2\n",
	"local third = 3\n",
	"return first + second + third\n",
}, "")
local FINAL = table.concat({
	"local first = 1\n",
	"local second = 20\n",
	"local third = 30\n",
	"return first + second + third\n",
}, "")

local FIRST_LINE = "local second = 2"
local FIRST_FINAL = "local second = 20"
local SECOND_LINE = "local third = 3"
local SECOND_FINAL = "local third = 30"

--- What the session said about the final text: its hover, its tokens and its diagnostics.
---@param frames table[]
---@return string hover
---@return string tokens
---@return string diagnostics
local function answers(frames)
	return canonical(assert(response(frames, 10), "the hover answer")),
		canonical(assert(response(frames, 11), "the token answer")),
		canonical(assert(lastDiagnostics(frames), "the published diagnostics"))
end

test.it("answers a burst of changes as a cold session on the final text does", function()
	local cold = answers(run(endingWithShutdown({
		didOpen(FINAL), hover(3, 16), tokens(),
	})))
	local warm = answers(run(endingWithShutdown({
		didOpen(INITIAL),
		replaceLine(2, 1, FIRST_LINE, FIRST_FINAL),
		replaceLine(3, 2, SECOND_LINE, SECOND_FINAL),
		hover(3, 16), tokens(),
	})))

	test.equal(warm[1], cold[1], "hover")
	test.equal(warm[2], cold[2], "semantic tokens")
	test.equal(warm[3], cold[3], "diagnostics")
end)

test.it("answers the same with resume turned off", function()
	local cold = answers(run(endingWithShutdown({
		didOpen(FINAL), hover(3, 16), tokens(),
	})))
	local warm = answers(run(endingWithShutdown({
		didOpen(INITIAL),
		replaceLine(2, 1, FIRST_LINE, FIRST_FINAL),
		replaceLine(3, 2, SECOND_LINE, SECOND_FINAL),
		hover(3, 16), tokens(),
	}), { incremental = false }))

	test.equal(warm[1], cold[1], "hover")
	test.equal(warm[2], cold[2], "semantic tokens")
	test.equal(warm[3], cold[3], "diagnostics")
end)

--- Count the stable analyze marks by whether a resume was used.
---@param stderr string
---@return integer resumed
---@return integer full
local function analyzeMarks(stderr)
	local resumed, full = 0, 0
	for line in stderr:gmatch("[^\n]+") do
		if line:match("^lye timing: analyze=") then
			if line:match("resumed=1") then resumed = resumed + 1
			elseif line:match("resumed=0") then full = full + 1 end
			test.truthy(line:match(" bytes=%d+ ") and line:match(" items=") and line:match(" reused="),
				"the analyze mark keeps its fields: " .. line)
		end
	end
	return resumed, full
end

test.it("resumes an edit after the first statement, and does not when asked not to", function()
	local _, _, stderr = run(endingWithShutdown({
		didOpen(INITIAL),
		replaceLine(2, 1, FIRST_LINE, FIRST_FINAL),
	}), { timing = true })
	local resumed, full = analyzeMarks(stderr)
	test.truthy(resumed >= 1, "the change after the first statement resumes: " .. stderr)
	test.truthy(full >= 1, "the first analysis is a full parse: " .. stderr)

	local _, _, coldStderr = run(endingWithShutdown({
		didOpen(INITIAL),
		replaceLine(2, 1, FIRST_LINE, FIRST_FINAL),
	}), { timing = true, incremental = false })
	local coldResumed, coldFull = analyzeMarks(coldStderr)
	test.equal(coldResumed, 0, "LYE_INCREMENTAL=0 never resumes: " .. coldStderr)
	test.truthy(coldFull >= 1, "and still analyses: " .. coldStderr)
end)

test.it("resumes a burst of changes carried in one notification", function()
	local cold = answers(run(endingWithShutdown({
		didOpen(FINAL), hover(3, 16), tokens(),
	})))
	local warm = answers(run(endingWithShutdown({
		didOpen(INITIAL),
		didChangeMany(2, {
			{
				range = {
					start = { line = 1, character = 0 },
					["end"] = { line = 1, character = #FIRST_LINE },
				},
				text = FIRST_FINAL,
			},
			{
				range = {
					start = { line = 2, character = 0 },
					["end"] = { line = 2, character = #SECOND_LINE },
				},
				text = SECOND_FINAL,
			},
		}),
		hover(3, 16), tokens(),
	})))

	test.equal(warm[1], cold[1], "hover")
	test.equal(warm[2], cold[2], "semantic tokens")
	test.equal(warm[3], cold[3], "diagnostics")
end)

test.it("analyses every dirty document in one idle pass, newest first", function()
	-- An idle tick is not promised again when no further message arrives, so the pass that runs
	-- has to give every changed document its diagnostics. The newest is asked about first, which
	-- is the one the writer is looking at.
	local other = "file:///tmp/lye-incremental-other.lua"
	local frames = run(endingWithShutdown({
		didOpen(INITIAL, other),
		didOpen(INITIAL),
		replaceLine(2, 1, FIRST_LINE, FIRST_FINAL, other),
		replaceLine(2, 1, FIRST_LINE, FIRST_FINAL),
	}))

	local analyzed = {}
	for _, message in ipairs(frames) do
		if message.method == "textDocument/publishDiagnostics" and message.params.version == 2 then
			analyzed[#analyzed + 1] = message.params.uri
		end
	end
	test.equal(#analyzed, 2, "both changed documents are analysed in the one pass")
	test.equal(analyzed[1], URI, "the most recently changed document is analysed first")
	test.equal(analyzed[2], other, "and the older one follows in the same pass")
end)

test.it("trims on-demand analyses even when no document is dirty", function()
	-- A read-only session between changes analyses documents from its requests, not its idle
	-- passes. Six documents are opened and then asked about after their analyses were evicted, so
	-- each hover re-analyses one on demand; the empty-dirty idle pass still has to enforce the
	-- analysis count and byte budget.
	local uris = {}
	local messages = {}
	for index = 1, 6 do
		uris[index] = "file:///tmp/lye-budget-" .. index .. ".lua"
		messages[#messages + 1] = didOpen("local value = " .. index .. "\nreturn value\n", uris[index])
	end
	for index = 1, 6 do
		messages[#messages + 1] = hover(1, 7, uris[index], 100 + index)
	end

	local _, code, stderr = run(endingWithShutdown(messages), { timing = true })
	test.equal(code, 0, "the session ended normally")

	local marks = {}
	for line in stderr:gmatch("[^\n]+") do
		if line:match("^lye timing: cache=") then
			marks[#marks + 1] = {
				analyses = tonumber(line:match(" analyses=(%d+)")),
				entries = tonumber(line:match(" entries=(%d+)")),
				bytes = tonumber(line:match(" bytes=(%d+)")),
			}
		end
	end
	test.truthy(#marks >= 12,
		"an idle pass with nothing dirty still enforces the budget: " .. tostring(#marks) .. " marks")
	local last = marks[#marks]
	test.truthy(last.analyses <= 4, "the analysis count is held while only requests arrive")
	test.truthy(last.bytes <= 32 * 1024 * 1024, "and so is the byte budget")
end)

-- An analyzer diagnostic in a function no edit touches, and a later function to edit after it.
-- The parse resumes at the second statement, so the first function's tree is kept whole: what
-- the analyzer said about it must not travel inside that tree.
local EARLIER_BROKEN = table.concat({
	"local function earlier()\n",
	"\t---@type number\n",
	"\tlocal n = \"text\"\n",
	"\treturn n\n",
	"end\n",
	"local function later()\n",
	"\treturn 1\n",
	"end\n",
	"return earlier, later\n",
}, "")

test.it("publishes an analyzer diagnostic once across a resumed parse", function()
	-- The diagnostic belongs to the analysis, not to the parse tree. Appending it to the tree
	-- made the next parse carry it and the next analysis append it again, so the editor saw the
	-- earlier function's error twice after an edit to a later one.
	local frames, code, stderr = run(endingWithShutdown({
		didOpen(EARLIER_BROKEN),
		replaceLine(2, 6, "\treturn 1", "\treturn 2"),
	}), { timing = true })
	test.equal(code, 0, "the session ended normally")
	local resumed = analyzeMarks(stderr)
	test.truthy(resumed >= 1, "the later function's edit resumes the parse: " .. stderr)
	local published = assert(lastDiagnostics(frames), "the edit is published")
	test.equal(#published, 1, "the earlier function's error is published once")
	test.truthy(published[1].message:find("declared as number", 1, true), published[1].message)
	test.equal(published[1].range.start.line, 2, "and still belongs to the earlier function")

	-- Fixing the earlier function clears it, and nothing carried it forward.
	local fixed = run(endingWithShutdown({
		didOpen(EARLIER_BROKEN),
		replaceLine(2, 6, "\treturn 1", "\treturn 2"),
		replaceLine(3, 2, '\tlocal n = "text"', "\tlocal n = 1"),
	}))
	local cleared = assert(lastDiagnostics(fixed), "the fix is published")
	test.equal(#cleared, 0, "the fixed function's error is gone")
end)

return true
