-- The config Neovim's own `vim.lsp.enable("lye")` and `:lsp-enable lye` read, and the defaults
-- `require("lye").setup()` merges over. It is a plain `vim.lsp.Config`, so anything here can be
-- changed with `vim.lsp.config("lye", {...})` or `setup()` without editing this file.

local lye = require("lye") --[[@as lye.Module]]

return {
	cmd = lye.cmd(lye.executable()),
	-- The server's own language. LuaJIT's dialect is still `lua` to an editor, and an
	-- `emmyluadoc` fragment is not a document the analyzer should read as one.
	filetypes = { "lua" },
	-- `.git` first makes a monorepo one workspace, which is what the server's package resolution
	-- and its workspace scan expect. A project outside git is rooted by its own declaration.
	root_markers = { ".git", { "lye.json", "lde.json" } },
}
