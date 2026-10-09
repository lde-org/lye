--[[
	lye entry point.

	Serves the LSP over stdio by default, which is what an editor expects, and falls back to
	headless checking so the same binary works in a build step. `bin` in the manifest is
	"main.lua" because a `bin` path resolves relative to the package's target directory,
	which is itself the `src/` symlink.
]]

local check = require("lye-lsp.check")

local USAGE = [[
usage: lye [options] [files...]

  (no arguments)   serve the language server over stdio
  --check <file>   parse files and report syntax errors, exit non-zero if any
  --version        print the version
  --help           print this message
]]

local args = arg or {}
local paths = {}
local isCheck = false

for _, value in ipairs(args) do
	if value == "--check" then
		isCheck = true
	elseif value == "--version" or value == "-v" then
		print("lye " .. "0.1.0")
		return
	elseif value == "--help" or value == "-h" then
		io.stdout:write(USAGE)
		return
	else
		paths[#paths + 1] = value
	end
end

-- Files with no other instruction means a check: running the server would make no sense.
if isCheck or #paths > 0 then
	if #paths == 0 then
		io.stderr:write(USAGE)
		os.exit(1)
	end
	os.exit(check.files(paths) and 0 or 1)
end

require("lye-lsp.language").start()
