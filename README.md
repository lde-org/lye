# lye

A language server for [LuaJIT](https://luajit.org), built on [lde](https://lde.sh).

`lye` gives LuaJIT real editor support — syntax diagnostics, a nested outline, hover,
go-to-definition and semantic tokens — from a small, modular codebase written in the language
it serves, including LuaJIT's LuaJIT 3.0 syntax backports. It compiles to a single standalone executable with `lde compile`, so
it needs no Lua, no lde, and no dependencies on the machine that runs it.

> Status: **all features work** — diagnostics, a nested outline, hover with an inferred
> type, go-to-definition, semantic tokens, and completion (the fields of a table after a `.`
> or a `[`, the names in scope elsewhere — the definitions' globals included — the workspace's
> modules inside `require("`, and the modules the engine ships, `require("ffi")` and
> `require("string.buffer")` among them) — with 274 tests. The same binary also checks files
> headlessly for CI. See `docs/PLAN.md` §7 for the `---@type` annotations, evolving types,
> narrowing and call checking. The AST and the token stream are flat arenas; see `docs/PLAN.md`
> §7 for the measurements behind both.
>
> Measured against the alternatives on the same machine and the same harness: a keystroke
> reaches diagnostics in **6.3 ms** against LuaLS's 201 ms and EmmyLua's 503 ms, and the
> server holds **11.9 MiB** against 20.8 and 60.5.

## Why it exists

`LuaLS` is ~126k lines and runs on Lua 5.5 with a C LPeg dependency. `EmmyLua` is ~198k
lines of Rust. Both are excellent and both are far larger than they need to be to make an
editor pleasant. `lye` targets the opposite tradeoff: a server two orders of magnitude
smaller than either, with every layer a separately usable package.

The original ceiling was 2000 lines and it is now **6854**, of which the type analyzer is
1969 — it was given 1500 and asked to be fully featured. The rest of the library (transport,
protocol, parser, definitions, the server's own features) is 4885. `docs/PLAN.md` §3 and §7
carry the per-package numbers, counted as source lines with blank lines, comment-only lines
and tests excluded.

## Layout

Seven packages plus the server. Each is independently useful; nothing depends on the server.

| Package | Role | Status |
|---|---|---|
| `lye-json` | Minimal JSON encode/decode, strict enough to never desync the protocol. | done — 259 lines, 23 tests |
| `lye-rpc` | `Content-Length` framing and JSON-RPC 2.0 over a byte stream, with a read buffer that grows to hold the frame. | done — 171 lines, 9 tests |
| `lye-framework` | Language-agnostic server: lifecycle, dispatch, document store, position mapping, LSP constants. | done — 352 lines, 29 tests |
| `lye-lexer` | LuaJIT-aware tokenizer; tokens are FFI structs in one arena, comments kept for annotation passes, half-written literals reported instead of raised. | done — 299 lines, 15 tests |
| `lye-parser` | Span-tracking parser, error recovery, parse-time scope stack. | done — 810 lines, 14 tests |
| `lye-doc` | LuaLS annotation parsing, the type system, and type comparison. | done — 1243 lines, 43 tests |
| `lye-analyzer` | Name resolution, recursive arena typing to a fixpoint, evolving types, narrowing, call checking. | done — 2009 lines, 105 tests |
| `lye-lsp` | The server itself: wires the above together and implements the features. | done — 1773 lines, 36 tests |
| `lye-defs` | The LuaJIT and Lua 5.1 definitions, from eighteen files gathered at build time. | done — generated, 18 meta files |

**6905 lines and 274 tests**, or **7232** counting the generated definitions. A client can
attach, sync a document, edit it incrementally, and shut the server down with the correct exit
code. The lexer and parser handle LuaJIT including its 3.0 syntax, and syntax errors are
published as diagnostics that clear when the document is fixed. See `docs/PLAN.md` §3 for the
budget and §7 for what each round added.

## Editors

The server speaks the LSP over stdio, so an editor integration is a wrapper that starts it.

| Editor | Where | State |
|---|---|---|
| VS Code | `editors/vscode/` | diagnostics, hover, definition, outline, semantic tokens, completion |
| Zed | `editors/zed/` | the same features, plus the Lua and EmmyLuaDoc grammars |

The VS Code extension carries no language logic: it starts `lye` and attaches it to Lua
documents. It needs the executable on `PATH`, or `lye.serverPath` set to it.

```sh
cd editors/vscode
npm install
npm run compile       # tsc to dist/
npm run package       # a .vsix
```

`npm test` drives the built binary over stdio the way the client does — initialize, an
incremental edit, hover past an astral character, shutdown — so it checks the wrapper's
assumptions rather than the server's own tests:

```sh
LYE_BINARY=../../packages/lye-lsp/lye-lsp npm test
```

## Development

This is an lde monorepo. `lde` discovers packages by scanning for `lde.json`, and sibling
packages depend on each other through path dependencies — installed as symlinks to `src/`,
so edits propagate across packages with no rebuild step.

```sh
lde test                          # from the repo root: runs every package's tests
lde test -C packages/lye-json     # scope to one package
lde run -C packages/lye-lsp       # run the server
lde compile -C packages/lye-lsp   # produce a standalone executable
```

The compiled binary serves the LSP with no arguments, and checks files headlessly when given
paths, so the same artifact works in an editor and in a build step:

```sh
lye                        # language server over stdio
lye --stdio                # the same, which is what editors pass
lye --check src/main.lua   # report what it finds, exit non-zero on an error or a warning
lye src/**.lua             # a bare path implies --check
lye --version
```

Editors that speak the protocol add their own conventions to that command line:
`vscode-languageclient` appends `--stdio` and `--clientProcessId=<pid>`, so both are accepted
and ignored. An unknown option is a usage error rather than a file check, because a flag
mistaken for a path fails in a way that reads as the server crashing.

Test files live in `packages/<name>/tests/*.test.lua` and use the `lde-test` framework,
which lde injects automatically — there is nothing to declare as a devDependency.

A test that needs a subprocess cannot be its own fixture: `lde test` injects the framework
only into the files it runs, so a fixture must live in `tests/fixtures/` and be started with
`lde run`. It also runs from the package root, not the target directory.
