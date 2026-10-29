<div align="center">

<img src="demo.png" alt="lye inferring types for ffi code" width="400" />

# lye

**The LuaJIT-first language server.**
`4.8 ms` to diagnostics on a 63-line file · `14.6 MiB` resident · one standalone binary.

</div>

`lye` is a language server for [LuaJIT](https://luajit.org): inferred types, completion, hover,
definitions, references, rename, symbols, signature help, inlay hints, semantic tokens, formatting
and diagnostics. It is written in LuaJIT: it parses the engine's 3.0 syntax backports and needs no
Lua runtime, no `lde`, and no packages to install.

## Why lye

| Capability | lye | LuaLS | EmmyLua-RS |
|---|:---:|:---:|:---:|
| LuaJIT FFI: `ffi.cdef` parsed into typed C declarations | ✅ | partial [^5] | — |
| Generic classes and generic functions | ✅ | partial [^1] | ✅ |
| Overloads with call-site signature narrowing | ✅ | partial [^2] | ✅ |
| Type mismatches are LSP Errors by default | ✅ | config [^3] | config [^3] |
| Dialect plugins: lowering, tokens, types, `require` completion | ✅ | partial [^4] | — |
| lde `target/` module resolution | ✅ | — | — |

[^1]: LuaLS generics — [#1861](https://github.com/LuaLS/lua-language-server/issues/1861).
[^2]: LuaLS overloads — [#1456](https://github.com/LuaLS/lua-language-server/issues/1456).
[^3]: Both servers expose configurable diagnostic severities; lye defaults type mismatches to Error.
[^4]: LuaLS has plugin hooks for text/AST transforms and require resolution, but no unified lower/tokens/types/completion pipeline.
[^5]: LuaLS parses cdefs through the manual `Lua: Reload luajit ffi meta` command and maps 64-bit scalars to `integer`; lye parses every block automatically and keeps the C types.

## Types

`lye`'s type system is built for LuaJIT:

- inference from assignments, calls, tables and returns; a local's type evolves as it is reassigned
- flow narrowing for truthiness, `nil` comparisons, `type(x)` guards, discriminated unions and
  early returns
- generic classes and functions with constraints; overloads are checked at the call site and
  narrowed in signature help
- LuaLS `---@` annotations: classes, aliases, literal/union/`never`/`const` types, casts and `as`
- type-level forms: intersections (`A & B`), `keyof`, indexed access (`T["k"]`), conditional types
  (`T extends U ? X : Y`), mapped types (`{ [K in keyof T]: U }`) and template literal types
- assignment-aware field narrowing, optional-chain (`?.`) typing, and correlated `pcall` values
- LuaJIT's and Lua 5.1's standard library, from eighteen definition files, drives hover and
  completion
- FFI types are ordinary types, not `cdata` boxes
- type mismatches are LSP **Errors** and fail `lye --check`; they are never downgraded to hints

LuaLS still tracks generics in [#1861](https://github.com/LuaLS/lua-language-server/issues/1861);
`lye` implements generics and overloads now, and neither competitor makes FFI-derived types
first-class.

```lua
---@generic T
---@param value T
---@return T
local function id(value) return value end

---@param n number
local function takesNumber(n) end

local s = id("lye") -- string
takesNumber(s)      -- error: takesNumber expects number, got string
```

## LuaJIT and FFI

The shipped `ffi` plugin parses every `ffi.cdef` block in a file:

- structs, unions, enums, typedefs, function pointers, arrays and bitfields
- fixed arrays as `ffi.array<T, N>`, scalar pointers as `ffi.ptr<T>`, 64-bit scalars as
  `ffi.size_t`/`ffi.int64_t`/…, callbacks as `ffi.cb`
- `ffi.new`, `ffi.cast`, `ffi.typeof`, `ffi.load` and `ffi.C` typed from the file's declarations
- inline callbacks get the header's parameter types, and their returns are checked
- semantic tokens colour the C inside the cdef block

```lua
local ffi = require("ffi")
ffi.cdef[[
	typedef unsigned long size_t;
	typedef struct { double x, y; } Vec;
	typedef size_t (*write_cb)(char *ptr, size_t size, void *userdata);
]]

local v = ffi.new("Vec")      -- Vec
v.x = 1.5                     -- ok
v.nope = 1                    -- error: `nope` is not a field of Vec

local write = ffi.cast("write_cb", function(ptr, size, _)
	return size * 2           -- ptr: ffi.ptr<ffi.char>, size: ffi.size_t
end)

local ints = ffi.new("int[4]") -- ffi.array<ffi.int, 4>
local first = ints[0]          -- ffi.int
```

`!ffi` turns it off; the same file still reads as plain Lua.

## Speed

Measured on one machine with one harness; medians:

| | lye | LuaLS | EmmyLua-RS |
|---|---:|---:|---:|
| keystroke → diagnostics (63-line fixture) | **4.78 ms** | 201.73 ms | 503.37 ms |
| resident (63-line fixture) | **14.6 MiB** | 35.0 MiB | 66.0 MiB |
| keystroke → diagnostics (2331-line file) | **82.6 ms** | 207.52 ms | 514.06 ms |
| resident (2331-line file) | **42.4 MiB** | 47.9 MiB | 76.9 MiB |

## Plugins

A workspace lists plugins in `lye.json` — a path, an installed module name, or `!name` to disable
a shipped plugin (`patterns`, `formats`, `ffi`):

```json
{ "plugins": ["./tools/moonscript.lua", "lye-plugin-moonscript", "!patterns"] }
```

A plugin answers one or more hooks:

| Hook | Adds |
|---|---|
| `lower` | edits that turn another language into Lua, with positions mapped back to the original |
| `tokens` | semantic tokens; a plugin's span wins over the built-in walk |
| `types` | classes, aliases and providers for calls, fields, parameters and callback returns |
| `complete` | module names inside `require("...")` |

The built-in `lye-plugin-require` supplies the `require` completion hook. A plugin's
`extensions = { "moon" }` makes `lye check .` walk a dialect's files, and an editor that supports
LSP dynamic registration receives those extensions as document selectors, so a `.moon` document gets
the same diagnostics, hover and completion as a `.lua` one; one plugin can carry syntax, colour,
types and autocomplete. `packages/lye-plugin` documents the interface.

## lde

`lye` is [lde](https://lde.sh)-first. `lde run -C <package>` resolves a module against
`<package>/target/?.lua` and `<package>/target/?/init.lua`, and `target/` holds a link per
dependency. `lye` finds the nearest `lde.json`, resolves `require` through the same target layout,
indexes the types linked into `target/`, and offers those modules in completion — with nothing to
configure. A document resolves against its own package, so siblings, dependencies and monorepo
packages all work.

For a project not laid out that way, `lye.json` can name search paths the way `package.path` does:

```json
{ "requirePaths": ["lib/?.lua", "vendor/?/init.lua"] }
```

## Command line

`lye check [paths...]` checks a tree in CI, handing each package to a worker (`LYE_WORKERS=1` for
one). Results are cached under `./.lye`; `--cache <dir>` or `LYE_CACHE_DIR` moves it, `--cold` and
`LYE_CACHE=off` disable reuse. `lye init` writes `lye.json`; `lye extensions [dir]` prints the
file extensions the workspace's plugins claim, which is what an editor wrapper needs to attach a
dialect's buffers.

An editor that supports LSP pull diagnostics gets `textDocument/diagnostic` for the open document
and `workspace/diagnostic` for every Lua file in the workspace; either is a full check of the files
it names. Clients without workspace pull still publish the open document's diagnostics, and
`lye check` is the whole-tree pass for CI.

## Editors

### Zed

Install `editors/zed/` as a dev extension.

### VS Code

Run `npm install && npm run package` in `editors/vscode`.

### Neovim

```lua
vim.lsp.config("lye", {
  cmd = { "lye", "--stdio" },
  root_markers = { "lde.json", "lye.json" },
  filetypes = { "lua" }
})
vim.lsp.enable("lye")
```

### Anything else

Speak LSP to `lye --stdio`.
