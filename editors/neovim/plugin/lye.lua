-- The plugin's only command. Everything else is `setup()` and the built-in LSP client's own
-- commands; a restart is the one action those cannot express after the executable changes.
-- Neovim injects `vim` as a global; `vim.d.lua` describes it, and the local carries that type.
local vim = _G.vim --[[@as Vim]]

vim.api.nvim_create_user_command("LyeRestart", function()
	local lye = require("lye") --[[@as lye.Module]]
	lye.restart()
end, { desc = "Start lye, or restart its running clients" })
