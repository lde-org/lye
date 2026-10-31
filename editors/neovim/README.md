# lye for Neovim

LuaJIT language support in Neovim, from the `lye-lsp` language server: types, narrowing,
diagnostics, hover, completion, navigation, semantic tokens and the rest of the protocol.

The plugin is a thin wrapper around Neovim's built-in LSP client. There is no language logic here:
the server answers, and Neovim draws what it says.

## Requirements

- Neovim 0.11 or newer, for `vim.lsp.config()` and `vim.lsp.enable()`.
- A `lye` or `lye-lsp` executable on `PATH`, or a path in `server_path`.

Build the server from this repository:

```sh
tools/compile.sh   # writes packages/lye-lsp/lye-lsp
```

It compiles a snapshot of the working tree in a temporary directory, so generated test fixtures
under `packages/lye-lsp/target/` do not end up in the binary.

Then either put that directory on `PATH`, or name the file when setting the plugin up:

```lua
require("lye").setup({ server_path = "/path/to/lye/packages/lye-lsp/lye-lsp" })
```

The plugin looks for `lye-lsp` first, then `lye`: the lde package builds the former, while the
standalone release and the command line are called the latter.

## Install

With a plugin manager, point it at `editors/neovim` in this repository. With lazy.nvim:

```lua
{
	dir = "/path/to/lye/editors/neovim",
	config = function()
		require("lye").setup()
	end,
}
```

Without one, append the directory to `runtimepath` and call `setup()`:

```lua
vim.opt.runtimepath:prepend("/path/to/lye/editors/neovim")
require("lye").setup()
```

`setup()` enables the `lye` LSP config for Lua buffers (and any plugin filetypes it discovers) and
starts a client for the ones already open. The same config is available as a plain runtime file, so the built-in activation works
without calling `setup()`:

```lua
vim.opt.runtimepath:prepend("/path/to/lye/editors/neovim")
vim.lsp.enable("lye")
```

## Configuration

`setup()` takes one option of its own and passes every other field to `vim.lsp.config("lye", ...)`:

| Option | Default | Meaning |
|---|---|---|
| `server_path` | resolved from `PATH` | Path to the executable. |
| `discover_extensions` | `true` | Ask the server for the extensions the workspace's plugins claim, then map those filetypes to the client. |

With `discover_extensions` on, `setup()` runs `lye extensions` in the working directory (or a
string `root_dir`), registers each extension with `vim.filetype.add`, and adds the filetype to the
client. A plugin that says `extensions = { "toy" }` therefore makes a `.toy` buffer start lye and
receive its diagnostics, hover, completion and semantic tokens. Set `discover_extensions = false`
to keep the filetypes exactly as written.

The defaults, also changeable through `vim.lsp.config()`:

| Field | Default | Meaning |
|---|---|---|
| `filetypes` | `{ "lua" }` | Buffers the server attaches to. |
| `root_markers` | `{ ".git", { "lye.json", "lde.json" } }` | Where the workspace starts. |
| `cmd` | `{ <executable>, "--stdio" }` | The process Neovim starts. |

A custom path and a wider set of buffer types:

```lua
require("lye").setup({
	server_path = vim.fn.expand("~/bin/lye"),
	filetypes = { "lua", "luau" },
})
```

The root is the workspace the server resolves packages and scans for declarations in. `.git` comes
first so a monorepo is one workspace; `lye.json` and `lde.json` root a project that is not in git.
To choose a root yourself, override `root_dir`.

Changing the config while a client is running does not move that client. `:LyeRestart` stops the
running ones and starts again on the new config.

## What Neovim does with it

- Diagnostics arrive as the server publishes them; `vim.diagnostic.config()` styles them.
- Semantic tokens are on by default and colour LuaJIT types, fields and annotations.
- Hover, go-to-definition, references, rename, signature help, completion, folding and document
  symbols are used through Neovim's default LSP mappings and `omnifunc`.
- Inlay hints, code lenses and document colours are off until asked for, because Neovim keeps them
  off for every server:

```lua
vim.api.nvim_create_autocmd("LspAttach", {
	callback = function(event)
		if vim.lsp.get_client_by_id(event.data.client_id).name ~= "lye" then return end
		vim.lsp.inlay_hint.enable(true, { bufnr = event.buf })
		vim.lsp.codelens.enable(true, { bufnr = event.buf })
	end,
})
```

- Formatting is the server's own: `vim.lsp.buf.format()` or `:lua vim.lsp.buf.format()`.

## Health

`:checkhealth lye` reports the executable that was found, its version, whether the config is
enabled, and the clients currently attached. A missing executable is otherwise only a log line:
`vim.lsp.enable()` validates the command lazily, when a Lua buffer tries to start it.

## If you also run lua-language-server

Neovim starts every enabled client whose `filetypes` match, so lua_ls and lye can both attach to a
Lua buffer: two sets of diagnostics and two sets of completions. Disable the other one if you want
lye alone:

```lua
vim.lsp.enable("lua_ls", false)
```

## Layout

| Path | Holds |
|---|---|
| `lsp/lye.lua` | the defaults: executable, `lua` filetype, root markers |
| `lua/lye/init.lua` | `setup()`, executable resolution, restart |
| `lua/lye/health.lua` | `:checkhealth lye` |
| `plugin/lye.lua` | `:LyeRestart` |
| `tests/smoke.lua` | a real client against a real server: attach, diagnostics, hover, restart |

## Development

The smoke test needs a built binary and no display:

```sh
LYE_BINARY="$PWD/packages/lye-lsp/lye-lsp" nvim --headless --clean -l editors/neovim/tests/smoke.lua
```
