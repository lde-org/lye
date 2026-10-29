--[[
	The Neovim wrapper: start `lye` on Neovim's built-in LSP client.

	The defaults live in `lsp/lye.lua`, which is what `vim.lsp.enable("lye")` and `:lsp-enable lye`
	read. That file cannot name a path, so this module adds the one option it needs — where the
	executable is — and turns the config on. Requiring this module does nothing by itself.
]]

-- Neovim injects `vim` as a global; `vim.d.lua` describes it, and the local carries that type.
local vim = _G.vim --[[@as Vim]]

local M = {}

--- What `require("lye")` is, for the files that load it.
---@class lye.Module
---@field names string[]
---@field executable fun(): string?
---@field cmd fun(path?: string): string[]
---@field extensions fun(root?: string, path?: string): string[]
---@field setup fun(opts?: lye.Config?)
---@field restart fun()


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
function M.cmd(path)
	return { path or M.names[1], "--stdio" }
end

--- A plugin's extension, as `lye extensions` prints it.
---@param root string? the directory to read `lye.json` and its plugins from, the working directory when absent
---@param path string? the executable to ask, resolved from `PATH` when absent
---@return string[]
function M.extensions(root, path)
	local executable = path or M.executable()
	if not executable then return {} end
	local ok, result = pcall(function()
		return vim.system({ executable, "extensions", root or vim.fn.getcwd() }, { text = true }):wait()
	end)
	if not ok or result.code ~= 0 then return {} end
	local out = {}
	for extension in (result.stdout or ""):gmatch("[^\n]+") do
		extension = vim.trim(extension)
		if extension ~= "" then out[#out + 1] = extension end
	end
	return out
end

---@class lye.Config
---@field server_path string? path to the executable, looked up as `lye-lsp`/`lye` when absent
---@field discover_extensions boolean? read plugin extensions and add their filetypes; default true
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
	-- A `.toy` buffer is not a `lua` buffer to Neovim, and Neovim decides which clients to start
	-- from `filetypes` before any LSP dynamic registration exists. Ask the server's own plugin
	-- loader for the extensions this workspace claims, map each to a filetype, and let the client
	-- start on those buffers too.
	local discover = opts.discover_extensions
	opts.discover_extensions = nil
	if discover ~= false then
		local root = type(opts.root_dir) == "string" and opts.root_dir or vim.fn.getcwd()
		local executable = path or (type(opts.cmd) == "table" and opts.cmd[1]) or nil
		local extensions = M.extensions(root, executable)
		if #extensions > 0 then
			local filetypes = opts.filetypes
			if not filetypes then
				local current = vim.lsp.config["lye"]
				filetypes = current and current.filetypes or { "lua" }
			end
			filetypes = vim.deepcopy(filetypes)
			for _, extension in ipairs(extensions) do
				vim.filetype.add({ extension = { [extension] = extension } })
				if not vim.tbl_contains(filetypes, extension) then filetypes[#filetypes + 1] = extension end
			end
			opts.filetypes = filetypes
		end
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
