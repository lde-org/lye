# FFI migration reference

lye's FFI support starts at `ffi.cdef`. The plugin parses every block in the file being checked and
turns structs, unions, enums, typedefs, function pointers, arrays, and bitfields into ordinary
types. `ffi.new`, `ffi.cast`, `ffi.typeof`, `ffi.load`, and `ffi.C` read from those declarations.

## Delete duplicate C classes

LuaLS projects often describe a cdef'd struct twice:

```lua
ffi.cdef [[
	typedef struct { double x, y; } Vec;
]]

---@class Vec: ffi.cdata*
---@field x number
---@field y number
```

Keep the `ffi.cdef`; delete the `---@class` and its fields. lye already gives a `Vec` made by the
constructor the fields, and reports `v.nope = 1` as a missing field of `Vec`.

The same applies to:

- enum tables hand-written as `---@class`/`---@field`
- `ffi.load` function signatures
- function pointer typedefs
- arrays and bitfields written out manually

A `---@meta` or `.d.lua` file for a **pure Lua** library is still a legitimate type source. Remove
it only when the same type is already written in `ffi.cdef` or in the project's Lua source.

## Use the built-in memory types

| Written with | lye type |
|---|---|
| `ffi.typeof("float[4]")()`, a `T name[4]` member | `ffi.array<T, 4>` |
| `ffi.typeof("float[?]")(n)` | `ffi.array<T>` with an unknown length |
| `ffi.cast("float*", value)`, `T *` | `ffi.ptr<T>` |
| a scalar C type | `ffi.int`, `ffi.size_t`, `ffi.uint8_t`, … |
| a callback typedef | `ffi.cb` or the declared function pointer |

An unknown array length fits any fixed length. Do not write `ffi.cdata*` for a value that is
indexed by number; that is the declaration of "some cdata", not an array or pointer.

```lua
---@param pixels ffi.array<ffi.uint8_t>
local function filter(pixels)
	pixels[0] = 0 -- indexing is typed
end
```

For a fixed-size array:

```lua
---@field map ffi.array<ffi.float, 4>
```

Use `ffi.cdata*` only where the value genuinely has no shape the code can rely on.

## Keep a cached constructor

`ffi.typeof` returns the engine's constructor for a C type, already typed: it is callable, and
calling it gives a value of that type. If the project already caches one, call it; no annotation is
needed.

```lua
local byteArray = ffi.typeof("uint8_t[?]")
local bytes = byteArray(count)          -- ffi.array<ffi.uint8_t>

local Vec = ffi.typeof("Vec")
local v = Vec()                         -- Vec, with the fields the cdef declares
```

`ffi.new("uint8_t[?]", count)` parses the type string on every call. That is fine for a one-off,
but do not replace an existing `ffi.typeof` constructor with it: the cached constructor already
knows its type and is the right call in a hot loop. Do not put `---@type fun(...)` beside
`ffi.typeof`: the constructor is a typed ctype whose `__call` already says what it makes, and an
annotation hides what lye knows.

Remove LuaLS-era workarounds:

```lua
---@diagnostic disable-next-line: assign-type-mismatch
local type_ = ffi.typeof("Thing")
```

A cast may cache the type the same way when it repeats:

```lua
local floatPointer = ffi.typeof("float*")
local scratch = floatPointer()
```

## cdefs are per file

lye parses the `ffi.cdef` blocks in the file it is reading. A type declared by another module's cdef
is not automatically imported into this file. Either:

- move the declaration into the file that uses it, or
- add the forward typedef that matches the runtime namespace, when the engine accepts it:
  ```lua
  ffi.cdef [[
      typedef struct LupaMat4 LupaMat4;
  ]]
  ```

Do not duplicate a full struct definition unless the engine accepts the duplicate; a forward
declaration is the safe form.

## Callbacks

A callback typedef gives the function literal its C parameters and required return:

```lua
ffi.cdef [[
	typedef unsigned long size_t;
	typedef size_t (*write_cb)(char *ptr, size_t size, size_t nmemb, void *userdata);
]]

local write = ffi.cast("write_cb", function(ptr, size, nmemb, userdata)
	return size * nmemb
end)
```

`ptr` is `ffi.ptr<ffi.char>`, `size` and `nmemb` are `ffi.size_t`, and the return is checked as
`ffi.size_t`.

## What not to do

- Do not keep a manual `---@class` for every C type beside its cdef.
- Do not annotate a constructor's result with `ffi.cdata*` when the value is indexed.
- Do not use `---@type ffi.cdata*` to silence an array or pointer mismatch.
- Do not suppress a cdef error; fix the declaration the engine rejects.
