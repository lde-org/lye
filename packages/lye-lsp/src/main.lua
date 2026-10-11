--[[
	lye entry point.

	Serves the LSP over stdio by default and falls back to headless checking, so the same binary
	works in a build step.
]]

local check = require("lye-lsp.check")

local USAGE = [[
usage: lye [options] [files...]

  (no arguments)   serve the language server over stdio
  --stdio          the same, and what editors pass
  check [paths...] check every Lua file under the paths, or the working directory
  --check <file>   the same for the files named, kept for scripts that pass it
  --version        print the version
  --help           print this message
]]

local args = arg or {}
local paths = {}
local isCheck = false

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
	elseif value == "--version" or value == "-v" then
		print("lye " .. "0.1.0")
		return
	elseif value == "--help" or value == "-h" then
		io.stdout:write(USAGE)
		return
	elseif isClientOption(value) then
		-- Nothing to do: serving stdio is already the default.
	elseif value:sub(1, 1) == "-" then
		-- An unknown option is a mistake, not a file named after it.
		io.stderr:write(string.format("lye: unknown option '%s'\n%s", value, USAGE))
		os.exit(2)
	else
		paths[#paths + 1] = value
	end
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
	local isOk = check.files(named)
	io.stderr:write(string.format("lye: %d file%s checked, %s\n", #named, #named == 1 and "" or "s",
		isOk and "no errors" or "errors found"))
	os.exit(isOk and 0 or 1)
end

require("lye-lsp.language").start()
