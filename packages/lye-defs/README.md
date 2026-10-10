# lye-defs

LuaJIT standard library definitions, as `---@` annotations the analyzer can read.

They are derived from [LuaLS](https://github.com/LuaLS/lua-language-server)'s `meta/template`, with
its generator directives evaluated for this target and removed:

| Removed | Why |
|---|---|
| `---#if` / `---#elseif` / `---#else` / `---#end` | evaluated, not carried: `VERSION` is 5.1 and `JIT` is true |
| `---#DES '...'` | documentation text for LuaLS's own website |
| `---@version ...` | about the edition the entry came from, which the conditionals already decided |
| `utf8.lua` | dropped whole: its file guard is `VERSION <= 5.2`, and LuaJIT has no utf8 library |

`bit.lua` and `jit.lua` are kept for the same reason in reverse: their guard is `not JIT`.

## Regenerating

```sh
lde run -C packages/lye-defs tools/derive.lua [path/to/lua-language-server] [--check]
```

`tools/derive.lua` decides every guard for LuaJIT (`VERSION` is 5.1, `JIT` is true, `DISABLE()` marks
what belongs to another edition), drops the entries whose `---@version` says another edition, fills
in the documentation from `locale/en-us/meta.lua`, and writes both `meta/` and the embedded
`src/init.lua`. Edit the tool, not the output: regenerating overwrites it.

**It walks the result against the running engine.** The tool runs inside LuaJIT, so it asks whether
each `function lib.name` it is about to write actually exists — `table.pack`, `table.unpack`,
`rawlen`, `debug.getuservalue`, `debug.setuservalue` and `debug.setcstacklimit` do not, and are
dropped rather than offered.

**Five entries are deliberately not what the template says**, and the tool enforces each of them so
they survive a regeneration:

| Entry | Deviation | Why |
|---|---|---|
| `setmetatable` | `---@generic T: table` with `---@return T` | the result is the metatable's class, which is what makes `setmetatable({}, Point)` a `Point` |
| `assert` | `---@return v is -nil` | a predicate: the call proves its argument is not nil |
| `error` | `---@return never` | the call does not come back, so what follows it is dead code |
| `unpack` (two entries) | `---@generic T...` | ten parameters and ten indexed fields imitating a tuple, where a variadic generic says the same |

**The shape of a metatable is written here rather than derived**, because a LuaCATS template has no
way to say "this table is a metatable": `LYE_ONLY` in the tool appends `lye.Metatable<T>` to
`basic`, with every metamethod optional and typed as the function the engine calls it as. The
analyzer enforces that shape on every `setmetatable` call — a `__add` that is not a function, a
name Lua does not have, or an operand of the wrong kind is an error — since a class used as a
metatable could not satisfy a class constraint under nominal typing.

`src/meta/` is the editable copy. `src/init.lua` embeds the same text, because `lde compile` produces a
standalone binary and a path into a package would not exist on the machine running the server.

The analyzer reads them as a **prelude**: `analyzer.prelude(require("lye-defs"))` parses them once
per process, and `analyze(source, prelude)` folds their classes, aliases, signatures and returns in
under the document's own declarations. Both the editor and `lye check` pass it, so they see the
same standard library.

Three entries are written differently from the template they came from, because the difference is
worth typing:

```lua
---@generic T
---@param v? T
---@param message? any
---@param ... any
---@return T
---@return any ...
---@return v is -nil           -- a call to assert proves v is not nil
function assert(v, message, ...) end

---@param message any
---@param level?  integer
---@return never               -- error does not come back
function error(message, level) end
```

`never` makes what follows the call dead code, which the analyzer reports; the predicate narrows
the argument for the rest of the block, so `if not handle then error("...") end` leaves `handle`
non-nil. `setmetatable` is the third: the template returns `table`, and the copy here takes a
`---@generic T: table` and returns `T`, so `setmetatable({}, Point)` is a `Point`.

Everything else keeps the documentation LuaLS wrote for it, which is what hover and completion show:

    math.floor(x: number) -> integer

    Returns the largest integral value smaller than or equal to `x`.
