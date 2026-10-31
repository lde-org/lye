--[[
	A smoke test against the real server, over the real client.

	It is the plugin's own assumptions that are being tested: that `lsp/lye.lua` resolves, that
	`setup()` starts a client on a Lua buffer, that diagnostics and a request travel, and that the
	restart command replaces the client rather than leaving the buffer attached to a dead one.

	    LYE_BINARY=/path/to/lye-lsp nvim --headless --clean -l tests/smoke.lua

	`LYE_BINARY` is required: a test that silently passes because no server was found would pass
	on a machine where the plugin does not work at all.
]]

-- Neovim injects `vim` as a global; `vim.d.lua` describes it, and the local carries that type.
local vim = _G.vim --[[@as Vim]]

local script = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin = vim.fn.fnamemodify(script, ":p:h:h")
vim.opt.runtimepath:prepend(plugin)
-- `--clean` still loads the runtime, but not the plugins of a runtimepath added afterwards.
vim.cmd("runtime plugin/lye.lua")
vim.cmd("filetype on")

---@param message string
---@return never
local function fail(message)
	io.stderr:write("smoke: " .. message .. "\n")
	os.exit(1)
end

---@param predicate fun(): boolean
---@param what string
---@param timeout integer?
local function waitFor(predicate, what, timeout)
	if not vim.wait(timeout or 15000, predicate, 25) then fail("timed out waiting for " .. what) end
end

local binary = os.getenv("LYE_BINARY") or fail("LYE_BINARY is not set")
if binary == "" then fail("LYE_BINARY is not set") end
if vim.fn.executable(binary) == 0 then fail("LYE_BINARY is not executable: " .. binary) end

-- The defaults the runtime file provides, before `setup()` layers anything over them.
local defaults = vim.lsp.config["lye"]
if defaults then
	if not vim.deep_equal(defaults.filetypes, { "lua" }) then fail("default filetypes are not { 'lua' }") end
	if #(defaults.root_markers or {}) ~= 2 then fail("default root markers are not .git plus lye.json/lde.json") end
else
	fail("lsp/lye.lua did not resolve a config")
end

local dir = assert(vim.fn.tempname())
local package = dir .. "/pkg"
vim.fn.mkdir(package, "p")
-- A repository root with a package inside it: `.git` has to win over the nearer `lde.json`, or
-- the server would scan and resolve within the package instead of the workspace.
vim.fn.mkdir(dir .. "/.git", "p")
local source = package .. "/smoke.lua"
vim.fn.writefile({
	'local ffi = require("ffi")',
	"ffi.cdef[[",
	"\ttypedef struct { double x, y; } Vec;",
	"]]",
	"",
	'local v = ffi.new("Vec")',
	"v.nope = 1",
}, source)
vim.fn.writefile({ "{}" }, dir .. "/lye.json")
vim.fn.writefile({ "{}" }, package .. "/lde.json")

vim.cmd("edit " .. vim.fn.fnameescape(source))
if vim.bo.filetype ~= "lua" then
	vim.bo.filetype = "lua"
	vim.api.nvim_exec_autocmds("FileType", { pattern = "lua" })
end

-- `setup()` after the buffer exists, which is the lazy-loading order and the one where enabling
-- has to attach to open buffers rather than only to future ones.
local lye = require("lye") --[[@as lye.Module]]
lye.setup({ server_path = binary })
local config = vim.lsp.config["lye"]
if config then
	local cmd = config.cmd
	if type(cmd) == "table" then
		if cmd[1] ~= binary then fail("setup() did not use server_path") end
		if cmd[2] ~= "--stdio" then fail("the command does not pass --stdio") end
	else
		fail("setup() did not leave a command line")
	end
else
	fail("setup() did not leave a config")
end

waitFor(function()
	return #vim.lsp.get_clients({ name = "lye", bufnr = 0 }) == 1
end, "the client to attach")

local client = assert(vim.lsp.get_clients({ name = "lye", bufnr = 0 })[1])
if client.root_dir ~= dir then fail(("root_dir is %s, expected %s"):format(tostring(client.root_dir), dir)) end

waitFor(function()
	for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
		if diagnostic.message:find("`nope` is not a field of Vec", 1, true) then return true end
	end
	return false
end, "the ffi diagnostic")

-- The diagnostic proves the analysis; a request proves the client did not merely receive a
-- notification the server had queued before it attached.
local hover = vim.lsp.buf_request_sync(0, "textDocument/hover", {
	textDocument = { uri = vim.uri_from_bufnr(0) },
	position = { line = 5, character = 6 },
}, 5000)
local value = hover and hover[client.id]
if value and value.result then
	local contents = vim.inspect(value.result.contents)
	if not contents:find("Vec", 1, true) then fail("hover does not mention Vec: " .. contents) end
else
	fail("hover returned nothing")
end

-- Semantic tokens are what Neovim colours with, and they are enabled by default for every server
-- that advertises them. The API that checks where a token landed is newer than the plugin's floor.
if vim.lsp.semantic_tokens.get_at_pos then
	waitFor(function()
		local tokens = vim.lsp.semantic_tokens.get_at_pos(0, 5, 6)
		return tokens ~= nil and #tokens > 0
	end, "the semantic token on `v`")
end

-- Restarting is what makes a changed `server_path` take effect; it has to leave exactly one live
-- client, not a new one beside a stopped one.
vim.cmd("LyeRestart")
waitFor(function()
	if vim.lsp.get_client_by_id(client.id) then return false end
	local clients = vim.lsp.get_clients({ name = "lye", bufnr = 0 })
	return #clients == 1
end, "the old client to exit and the new one to attach")

for _, running in ipairs(vim.lsp.get_clients({ name = "lye" })) do
	running:stop()
end
vim.fn.delete(dir, "rf")
print("smoke: ok")
