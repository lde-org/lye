<div align="center">

<img src="demo.png" alt="lye inferring types for ffi code" width="400" />

# lye

**An incredibly fast and powerful language server written in and for LuaJIT**

`7.28 ms` to diagnostics, `11.8 MiB` resident, `7.3k` lines of Lua.

</div>

## What it is

`lye` is a language server for [LuaJIT](https://luajit.org): diagnostics, hover with an inferred type,
go-to-definition, semantic tokens and completion — including LuaJIT's LuaJIT 3.0 syntax backports.

It is written in the language it serves, compiles to one standalone executable, and needs no Lua, no
`lde` and no dependencies on the machine that runs it.

## Features

- **Types from the code** — inferred, evolved as a name is assigned, narrowed by the conditions above it
- **Annotations** — LuaLS's `---@` language: classes, generics, literal values, `as`, `never`, consts
- **`ffi`, properly** — `ffi.cdef` is parsed, so `ffi.new("Vec")` is a `Vec` and `v.nope` is reported
- **C types that are C types** — arrays are `ffi.array<T, N>` and indexable, pointers are `ffi.ptr<T>`, and a 64-bit scalar is `ffi.size_t` rather than a `number`
- **Callbacks are typed** — a function cast to a C callback keeps the header's parameter types
- **`require`, the lde way** — `<package>/target/?.lua`, plus `ffi`, `jit`, `string.buffer` and friends
- **The standard library** — LuaJIT's and Lua 5.1's, from eighteen definition files
- **Headless too** — the same binary checks files for CI: `lye --check src/**.lua`

## Examples

```lua
local ffi = require("ffi")
ffi.cdef[[
	typedef unsigned long size_t;
	typedef struct { double x, y; } Vec;
	typedef size_t (*write_cb)(char *ptr, size_t size, void *userdata);
]]

local v = ffi.new("Vec")      -- v: Vec
v.x = 1.5                     -- ok
v.nope = 1                    -- `nope` is not a field of Vec

local size = ffi.new("size_t")
local wrong = size[1]         -- ffi.size_t cannot be indexed by a number

local write = ffi.cast("write_cb", function(ptr, size, _)
	return size * 2           -- ptr: ffi.ptr<ffi.char>, size: ffi.size_t, result checked
end)
```

```lua
local numbers = ffi.new("int[4]")     -- ffi.array<ffi.int, 4>
local first = numbers[0]              -- ffi.int

local curl = ffi.load("curl")         -- the functions this file's cdef declared
local handle = curl.curl_easy_init()
curl.curl_easy_send("not a handle", nil, 0)
-- curl.curl_easy_send expects ffi.ptr<ffi.cdata*>, got "not a handle"
```

```lua
---@param name string
---@return string?
local function greet(name) end

local who = "world"
local greeting = greet(who)           -- string?
if greeting then
	local loud = greeting:upper()     -- string
end
```

## Numbers

Measured with `editors/vscode/tests/compare.mjs` on one machine, one fixture, one harness:

| | lye | LuaLS | EmmyLua |
|---|---|---|---|
| keystroke → diagnostics | **7.28 ms** | 202.08 ms | 503.98 ms |
| resident | **11.8 MiB** | 20.7 MiB | 61.2 MiB |

## Editors

| Editor | Where | Install |
|---|---|---|
| Zed | `editors/zed/` | install that directory as a dev extension |
| VS Code | `editors/vscode/` | `npm install && npm run package` |
| anything else | — | speak LSP to `lye --stdio` |

## lde projects

`lde run -C <package>` resolves a module against `<package>/target/?.lua` and
`<package>/target/?/init.lua`, and `target/` holds a link per dependency. `lye` resolves `require` the
same way, against the package the document belongs to, so a module of the package itself and a
sibling package both resolve with nothing to configure.

A project that is not laid out that way can say where its modules are, in a `lye.json` at the package
or the workspace root, using patterns the way `package.path` writes them:

```json
{ "requirePaths": ["lib/?.lua", "vendor/?/init.lua"] }
```
