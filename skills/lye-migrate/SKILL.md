---
name: lye-migrate
description: Convert a Lua or lde project from LuaLS or EmmyLua to lye. Use when removing .luarc.json or EmmyLua config, replacing manual FFI annotations with lye's cdef-derived types, fixing lye diagnostics, or strengthening LuaCATS types with lye generics, const generics, and narrowing.
---

# Migrate a Lua project to lye

Move a project from LuaLS or EmmyLua-RS to lye without keeping two sources of type truth. lye reads LuaCATS annotations, parses `ffi.cdef` itself, and resolves lde `target/` modules without configuration.

## Goal

After this migration:

- `.luarc.json` and EmmyLua configuration are gone.
- `lye.json` exists only when the project needs plugins, non-lde search paths, or diagnostic policy.
- C types come from `ffi.cdef` and lye's built-in FFI types, not duplicate `---@class` trees.
- `lye check` reports no errors.
- Types LuaLS forced you to weaken are precise again where lye can prove them.

## 1. Inventory the project

```bash
pwd
ls -la
find . -maxdepth 2 \( \
  -name '.luarc.json*' -o -name '.emmyrc.json' -o -name '.emmylua.toml' \
  -o -name 'lde.json' -o -name 'lye.json' -o -name '*.rockspec' \
\)
```

Read `lde.json`, `lye.json`, and the old editor config. Check whether the project has `src/`, `target/`, `tests/`, `examples/`, and an existing test command.

If an `lde.json` is present, the project is an lde package. Module resolution comes from `target/`; do not add `requirePaths` that only repeat it.

## 2. Make lye runnable

Prefer an installed binary:

```bash
lye --version
```

If there is none and this skill lives in the lye checkout, build it or run the package entrypoint:

```bash
# from the lye repository
tools/compile.sh
./packages/lye-lsp/lye-lsp --version

# or without compiling
lde run -C /path/to/lye/packages/lye-lsp -- check --cold /absolute/path/to/project
```

When `lye` is run through `lde run -C <lye-lsp>`, pass absolute project paths. Relative paths resolve against `packages/lye-lsp`.

For an lde package, build first so `target/` holds current dependency sources:

```bash
lde test        # or the project's normal build/test command
```

A stale `target/` produces stale types and false errors.

## 3. Remove the old editor configuration

Delete:

- `.luarc.json`, `.luarc.jsonc`
- `.emmyrc.json`, `.emmylua.toml`, EmmyLua workspace files
- LuaLS-only helper files that exist only to describe types already present in source or `ffi.cdef`

In `.vscode/settings.json`, remove only LuaLS/EmmyLua keys such as `Lua.*` or `emmylua.*`. Do not delete unrelated editor settings.

Do not delete `---@meta` or `.d.lua` files whose types describe a library that has no `ffi.cdef` and no Lua source in the workspace. Those are still the type source.

## 4. Add `lye.json` only when needed

No `lye.json` is needed for a normal lde package. Add one for:

- workspace plugins:
  ```json
  { "plugins": ["./tools/moonscript.lua", "lye-plugin-moonscript", "!patterns"] }
  ```
- module paths for a project that is not laid out by lde:
  ```json
  { "requirePaths": ["lib/?.lua", "vendor/?/init.lua"] }
  ```
- diagnostic policy carried over from `.luarc.json`:
  ```json
  {
    "diagnostics": {
      "severity": { "redundant-return": "off", "undefined-global": "warning" },
      "disable": ["visibility"]
    }
  }
  ```

Do not translate every LuaLS setting. lye's defaults are the target.

## 5. Run the baseline check

```bash
lye check --cold .          # or the absolute path through the lye package
```

Use `--cold` after changing annotations or config so a cached answer does not hide the edit. For one file, name it directly.

Fix real code before adding annotations. A diagnostic is a claim about behavior, not a request to silence the checker.

## 6. Replace manual FFI types

Read [references/ffi.md](references/ffi.md) before editing FFI-heavy code. The rules:

- If a C type is written in `ffi.cdef`, delete duplicate `---@class` / `---@field` declarations for it. lye derives the struct, union, enum, typedef, function pointer, array, and bitfield from the cdef.
- If a function comes from `ffi.load`, the cdef declares its signature. Do not hand-write the function type.
- Use lye's built-in types for raw memory: `ffi.array<T>`, `ffi.array<T, N>`, `ffi.ptr<T>`, `ffi.cnum` and the scalar classes (`ffi.int`, `ffi.size_t`, …). Do not index `ffi.cdata*` when a real array or pointer type is known.
- Keep an existing constructor: `ffi.typeof("T[?]")` returns a typed, callable ctype, so `local byteArray = ffi.typeof("uint8_t[?]")` then `byteArray(n)` gives an `ffi.array<ffi.uint8_t>` with no annotation. `ffi.new("T[?]", n)` is fine for a one-off, but never replace a cached constructor with it; it parses the C type string on every call.
- Do not annotate the constructor: `---@type fun(...)` beside `ffi.typeof` hides the `__call` result lye already knows and is usually wrong about the engine's overloads.
- Remove `---@diagnostic disable-next-line: assign-type-mismatch` hacks that existed only because LuaLS typed `ffi.typeof` incorrectly.

## 7. Fix lye diagnostics

| Code | Action |
|---|---|
| `syntax` | Fix the Lua/LuaJIT syntax. Do not annotate around it. |
| `type` | Correct the annotation or the value. Narrow with `assert`, `if not x then return end`, or `---@cast` only when the runtime invariant is already true. |
| `missing-field` | Add the field to the class, fix the spelling, or use a declared API method. Inherited fields from other files work. |
| `missing-module` | Check `lde target/` or `requirePaths`. Fix the module layout; do not suppress. |
| `undefined-global` | Require the module or declare the global with a type. |
| `unknown` | Prove the value with a guard or `assert`, or add the missing annotation. |
| `visibility` | Read the field from the declaring class or make it public if that is the API. |
| `operator` | Fix the operands or the operator declaration. |
| `cdef` | Fix the C declaration or supply the missing type. |
| `unused-local` | Remove it; prefix a deliberate discard with `_`. |
| `deprecated` / `discard` | Use the supported API, or handle a `---@nodiscard` result. |

A blanket `---@diagnostic disable` is a last resort. A narrow `---@diagnostic disable-next-line: <code>` is acceptable only for a documented lye limitation or a third-party annotation you cannot change; leave a comment saying why.

## 8. Strengthen types

Read [references/annotations.md](references/annotations.md) for recipes. Upgrade only where the code already guarantees the type:

- Replace `any` and bare `table` with a class, record, union, or function signature.
- Add `---@field` for state that was left untyped.
- Use `---@generic T` and constraints; use variadic generics for forwarding functions.
- Use **const generics** for literal dimensions and string operations:
  ```lua
  ---@class Box<T: number, const N: integer>
  ---@field value T
  ---@type Box<number, 5>
  ```
  ```lua
  ---@type fn<const A: string, const B: string>(a: A, b: B) -> A .. B
  ```
- Use literal unions and discriminants instead of loose `string` / `number`.
- Use intersection (`A & B`), `keyof`, indexed access (`T["k"]`), conditional and mapped types only when the type is genuinely invariant. Do not encode business logic in annotations.
- Prefer flow narrowing (`type(x) ==`, nil checks, discriminated unions) over casts.

## 9. Verify

```bash
lye check --cold .          # no errors; review warnings and hints
<project test command>      # `lde test` for an lde package
```

For an lde package, run the build/test command before the final check so linked dependency types are current. Then confirm:

```bash
find . -maxdepth 2 \( -name '.luarc.json*' -o -name '.emmyrc.json' -o -name '.emmylua.toml' \)
```

There should be no old editor config left.

## Report

Summarize:

- config removed and `lye.json` added or intentionally not added
- FFI definitions deleted or converted, and any cdef fixes
- diagnostics fixed by category
- types strengthened (generics, const generics, narrowing)
- the exact check and test commands run
