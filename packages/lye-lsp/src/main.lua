--[[
	lye entry point.

	Serves the LSP over stdio by default and falls back to headless checking, so the same binary
	works in a build step.
]]

local check = require("lye-lsp.check")
local report = require("lye-lsp.report")
local cache = require("lye-lsp.cache")

local USAGE = [[
usage: lye [options] [files...]

  (no arguments)   serve the language server over stdio
  --stdio          the same, and what editors pass
  check [paths...] check every Lua file under the paths, or the working directory
  --check <file>   the same for the files named, kept for scripts that pass it
  --cache <dir>    keep what a run worked out there, instead of ./.lye
  --cold           check everything again, keeping nothing (as LYE_CACHE=off does)
  --no-color       report without colour, as a pipe or a log file wants
  --color          report with it, for a log that will render it
  --version        print the version
  --help           print this message
]]

local args = arg or {}
local paths = {}
local isCheck = false
local reporter = report.new()

--- Options an editor adds on its own account. `vscode-languageclient` appends these to whatever
--- arguments it was given, so a server that accepts only silence treats them as files to check
--- and dies on start — which the client then reports as the server crashing. The pid is not
--- needed: the read loop sees end of file when the editor goes away.
---@param value string
local function isClientOption(value)
	return value == "--stdio" or value:sub(1, 18) == "--clientProcessId="
end

local index = 1
if args[1] == "check" then
	isCheck = true
	index = 2
end
while args[index] do
	local value = args[index]
	index += 1
	if value == "--check" then
		isCheck = true
	elseif value == "--cache" then
		-- Where this run keeps what it works out. A build that wants its own directory, or one
		-- that has a shared cache for a whole tree, says so here.
		local dir = args[index]
		if not dir then
			io.stderr:write("lye: --cache needs a directory\n" .. USAGE)
			os.exit(2)
		end
		index += 1
		cache.setRoot(dir)
	elseif value == "--cold" then
		-- Everything again, as a first run does it, and nothing kept: what a run that wants to
		-- measure itself, or to distrust what was kept, asks for.
		cache.setEnabled(false)
	elseif value == "--version" or value == "-v" then
		print("lye " .. "0.1.0")
		return
	elseif value == "--help" or value == "-h" then
		io.stdout:write(USAGE)
		return
	elseif value == "--no-color" then
		report.plain(reporter)
	elseif value == "--color" then
		report.plain(reporter, true)
	elseif isClientOption(value) then
		-- Nothing to do: serving stdio is already the default.
	elseif value:sub(1, 1) == "-" then
		-- An unknown option is a mistake, not a file named after it.
		io.stderr:write(string.format("lye: unknown option '%s'\n", value) .. USAGE)
		os.exit(2)
	else
		paths[#paths + 1] = value
	end
end

-- A server is driven over a pipe, never by hand: with nothing named and a terminal watching, what
-- is wanted is the usage rather than a prompt that never comes back. This is also what `lye` with
-- no arguments looked like before — a hang.
if not isCheck and #paths == 0 and report.terminal() then
	io.stdout:write(USAGE)
	os.exit(0)
end

-- Files with no other instruction means a check: running the server would make no sense.
if isCheck or #paths > 0 then
	-- Nothing named means the working directory, which is what a build step wants: the check runs
	-- from the project root and finds its own files.
	local named = check.expand(#paths > 0 and paths or { "." })
	if #named == 0 then
		io.stderr:write("lye: no Lua files to check\n")
		os.exit(1)
	end
	-- A check is a process that exits when it is done, where the collector's defaults are those of
	-- one that runs on: it stops the world to walk a live set that is a document's tables and will
	-- not be read again, several times per file. Collecting less often hands back about a tenth of
	-- the run on a project this size, and the memory it costs goes away with the process. Set
	-- before the batch is split, so the workers are given it too.
	collectgarbage("setpause", 1200)
	local isOk = check.files(named, reporter)
	report.summary(reporter, #named)
	os.exit(isOk and 0 or 1)
end

require("lye-lsp.language").start()
