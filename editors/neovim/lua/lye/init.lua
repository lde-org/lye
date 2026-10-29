--[[
	The Neovim wrapper: start `lye` on Neovim's built-in LSP client.

	The defaults live in `lsp/lye.lua`, which is what `vim.lsp.enable("lye")` and `:lsp-enable lye`
	read. That file cannot name a path, so this module adds the one option it needs — where the
	executable is — and turns the config on. Requiring this module does nothing by itself.
]]

local M = {}

--- The names the server is installed under: `lye-lsp` is what the lde package builds, and `lye`
--- is what the standalone release and the command line are called. An explicit path wins over both.
M.names = { "lye-lsp", "lye" }

--- The server on `PATH`, or nil when neither name resolves.
---@return string?
function M.executable()
	for _, name in ipairs(M.names) do
		local path = vim.fn.exepath(name)
		if path ~= "" then return path end
	end
end

--- The command line a client starts. `--stdio` is the server's default, and naming it is what
--- the other editor wrappers do; a client that appends arguments of its own still leaves it be.
---@param path string?
---@return string[]
function M.cmd(path)
	return { path or M.names[1], "--stdio" }
end

---@class lye.Config
---@field server_path string? path to the executable, looked up as `lye-lsp`/`lye` when absent
---@field [string] any any other `vim.lsp.Config` field: `cmd`, `filetypes`, `root_markers`,
--- `on_attach`, `capabilities`, and the rest. These merge over `lsp/lye.lua`.

--- Enable lye for Lua buffers, with anything the caller wants changed.
---@param opts lye.Config?
function M.setup(opts)
	opts = vim.deepcopy(opts or {})
	local path = opts.server_path
	opts.server_path = nil
	if path ~= nil then
		assert(type(path) == "string" and path ~= "", "lye.setup: server_path must be a non-empty string")
		opts.cmd = M.cmd(path)
	end
	vim.lsp.config("lye", opts)
	vim.lsp.enable("lye")
end

--- Start lye, or restart the clients already running on a config that has changed.
function M.restart()
	if not vim.lsp.is_enabled("lye") then
		vim.lsp.enable("lye")
		return
	end
	vim.lsp.enable("lye", false)
	vim.lsp.enable("lye")
end

return M
