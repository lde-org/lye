# lye-defs

LuaJIT's standard library, as `---@` annotations the analyzer reads.

Written by hand against the engine rather than derived from another editor's definitions: what
matters is that a signature is what LuaJIT does, and lye's type system can say more of it than
LuaCATS can — types are written inline where a reader sees them, so a signature is one line:

```lua
function table.move<T>(a1: T[], f: integer, e: integer, t: integer, a2?: T[]): T[] end
```

`?` marks a parameter a caller may leave out, `...: T` says what the extra arguments are, `<T>`
declares a generic, and everything after `):` is what the call gives back. Only what cannot be
written that way stays an annotation: `---@overload` for the other shapes a call may take,
`---@nodiscard`, `---@deprecated`, a `---@return` of several values, and the prose above each
entry.

Where the shape of a value decides what a caller may write, it is written out: `debug.sethook`'s
hook is `fun(event: string, line: integer?)`, `table.concat` takes `(string|number)[]`, `ffi.cast`
gives back `ffi.cdata*`, and `getmetatable` answers `lye.Metatable<any>?`. Where nothing is known —
the chunk `load` hands back, the callback `jit.attach` is given — the definition says `function`,
and a table whose contents do not matter says `table`. A precise spelling that says no more than
those is noise, and the analyzer says so: writing `fun(...):...` is hinted as identical to
`function`, since every parameter of it is `any`, it takes any number of them and it gives back
`any`.

Classes are declared with `---@field` rather than a table literal: the fields are the class, and a
local that exists only to carry them is a value nothing reads. Where a name is only another type's
name, it is an `---@alias` (`---@alias jit.snap integer[]`, `---@alias ffi.ct* ffi.ctype*|ffi.cdecl*|ffi.cdata*`).

A module (`jit.util`, `jit.profile`, `string.buffer`) declares the class its own table is, so
`require` answers with a name rather than a shape. It also keeps the `---@overload` shapes on
`util.tracesnap`, `profile.dumpstack` and `buffer.new` reachable: an overload written on a plain
table's field is not consulted today, which made `buffer.new({ dict = ... })` a false positive.

## Layout

`src/meta/` holds one file per library. `build.lua` gathers them into `defs.lua`, which `src/init.lua`
requires — so the files are read and edited one at a time and nothing generated is stored in the
repository.

The analyzer reads them as a **prelude**: `analyzer.prelude(require("lye-defs"))` parses them once
per process, and `analyze(source, prelude)` folds their classes, aliases, signatures and returns in
under the document's own declarations. Both the editor and `lye check` pass it, so they see the same
standard library.

## Engines and editions

Only what the running engine has is declared. `table.pack`, `table.unpack`, `rawlen` and
`debug.setuservalue` are not in this LuaJIT and are not here; `bit.lua` and `jit.lua` are, because
this engine has them. `utf8` is absent for the same reason. A definition for a function that is not
there is a completion that lies.

`ffi` and the rest are what `require` hands back: `local ffi = require("ffi")` is the module table
each file returns, and `os`, `io`, `string`, `table`, `math`, `debug`, `coroutine`, `package`,
`bit` and `jit` are also globals, which the file declares as well.

## Entries written to say more

| Entry | Difference | Why |
|---|---|---|
| `setmetatable` | `---@generic T: table` with `---@return T` | the result is the metatable's class, which is what makes `setmetatable({}, Point)` a `Point` |
| `assert` | `---@return v is -nil` | a predicate: the call proves its argument is not nil |
| `error` | `---@return never` | the call does not come back, so what follows it is dead code |
| `unpack` (two entries) | `---@generic T...` | ten parameters and ten indexed fields imitating a tuple, where a variadic generic says the same |

**The shape of a metatable is written here rather than described**, because LuaCATS has no other way
to say "this table is a metatable": `lye.Metatable<T>` in `basic` lists every metamethod as optional
and typed as the function the engine calls it as. The analyzer enforces that shape on every
`setmetatable` call — a `__add` that is not a function, a name Lua does not have, or an operand of
the wrong kind is an error.

Everything else keeps the documentation the entry came with, which is what hover and completion show:

    math.floor(x: number) -> integer

    Returns the largest integral value smaller than or equal to `x`.
