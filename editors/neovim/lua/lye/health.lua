-- `:checkhealth lye`: whether the executable is reachable, which version answers, and whether
-- the built-in client is set up to start it. The reasons this is not obvious from a buffer:
-- a missing executable is logged by the LSP client rather than shown, and a config that was
-- never enabled looks the same as one that started nothing because no Lua file was opened.

-- Neovim injects `vim` as a global; `vim.d.lua` describes it, and the local carries that type.
local vim = _G.vim --[[@as Vim]]

local M = {}

function M.check()
	vim.health.start("lye")

	local lye = require("lye") --[[@as lye.Module]]
	local config = vim.lsp.config["lye"]
	local cmd = config and config.cmd
	-- The configured command is what runs, which is not necessarily what PATH resolves: `setup()`
	-- may have named a path, and reporting a different executable as "found" would hide that.
	local program = type(cmd) == "table" and cmd[1] or lye.executable()
	local advice = {
		"Build it: lde compile -C packages/lye-lsp",
		"Or name it: require('lye').setup({ server_path = '/path/to/lye-lsp' })",
	}

	if not program then
		vim.health.error("no executable found (looked for " .. table.concat(lye.names, ", ") .. ")", advice)
	else
		-- Nested rather than `elseif`: the branch below is the one that knows `program` is a string,
		-- and a condition in an `elseif` is checked without the negation above it.
		if vim.fn.executable(program) == 0 then
			vim.health.error(("%s is not executable"):format(program), advice)
		else
			local path = vim.fn.exepath(program)
			vim.health.ok("executable: " .. (path ~= "" and path or program))
			local version = vim.fn.system({ program, "--version" })
			if vim.v.shell_error == 0 then
				vim.health.ok("version: " .. vim.trim(version))
			else
				vim.health.error(("`%s --version` failed: %s"):format(program, vim.trim(version)))
			end
		end
	end

	if not vim.lsp.is_enabled("lye") then
		vim.health.warn("the `lye` LSP config is not enabled", {
			"Call require('lye').setup() or vim.lsp.enable('lye')",
		})
		return
	end
	vim.health.ok("the `lye` LSP config is enabled")

	if config then
		vim.health.info("cmd: " .. (type(cmd) == "table" and table.concat(cmd, " ") or "custom function"))
		vim.health.info("filetypes: " .. table.concat(config.filetypes or {}, ", "))
	end

	local clients = vim.lsp.get_clients({ name = "lye" })
	if #clients == 0 then
		vim.health.info("no running client: open a Lua file to start one")
	else
		for _, client in ipairs(clients) do
			local root = client.root_dir or "no workspace root"
			vim.health.ok(("client %d is attached: root %s"):format(client.id, root))
		end
	end
end

return M
