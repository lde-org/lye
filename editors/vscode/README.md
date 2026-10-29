# lye for VS Code

A thin wrapper: it starts the [`lye`](https://github.com/lde-org/lye) language server and lets it
answer. Diagnostics, hover, go-to-definition, document symbols, semantic tokens and completion all
come from the server, so this extension carries no language logic of its own.

## Requirements

The `lye` executable must be on your `PATH`. If it is somewhere else, set `lye.serverPath` to its
full path. The extension reports the path it tried when the server does not start.

Install `lye` by building it from the repository:

```sh
lde compile -C packages/lye-lsp   # writes the binary into the package's target directory
```

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `lye.serverPath` | `lye` | Path to the executable. |
| `lye.trace.server` | `off` | Trace messages between VS Code and the server, in the lye output channel. |

Changing `lye.serverPath` restarts the server.

## Plugin languages

A workspace can name a plugin that adds a language with its own file extension. When the workspace
contains a `lye.json`, the extension starts even if no Lua file is open; the server reads the
plugins, and registers their extensions with VS Code through LSP dynamic document registration.
Opening a `.toy` file (or any extension a plugin claims) then gets the same diagnostics, hover,
completion and semantic tokens as a `.lua` file.

## Development

```sh
npm install
npm run compile
```

Then press <kbd>F5</kbd> to launch an Extension Development Host with the extension loaded.

To build a `.vsix`:

```sh
npm run package
```

### Measuring what an editor waits for

`npm run benchmark` drives the server the way the client does — the same arguments, the same
framing, an open document and the requests an editor makes — and prints the round trip for each:

```sh
LYE_BINARY=../lye-lsp/lye-lsp npm run benchmark -- --iterations 50
LYE_BINARY=../lye-lsp/lye-lsp npm run benchmark -- --source ../some/big.lua
```

Each row also prints what the request answered, so a number is never about an empty reply. For the
same measurement through a real editor, `tests/benchmark.js` runs inside a headless VS Code
instance as an extension-host test; see "Running it headless" below.

### Comparing with other servers

`npm run compare` runs the same requests through lye, [LuaLS](https://github.com/LuaLS/lua-language-server)
and [emmylua-analyzer](https://github.com/EmmyLuaLs/emmylua-analyzer-rust), and prints what each one
answered and how long it took — plus the capabilities each advertises, which is the feature list a
client can rely on:

```sh
npm run compare -- --lye ../lye-lsp/lye-lsp --luals ~/Tools/lua-language-server \
	--emmylua ~/.local/bin/emmylua_ls --iterations 10 --json /tmp/compare.json
```

Every row prints a summary of the answer, so a row of dashes means the server did not answer rather
than that it answered quickly. One trap is recorded in the script: a language server sends *requests*
of its own (registering capabilities, asking for configuration) and a client that stays silent makes
it wait — LuaLS will not analyse anything until its `client/registerCapability` is answered.

## Running it headless

Both the smoke test and the in-editor benchmark need no display. VS Code runs with
`--ozone-platform=headless`, which is enough for the extension host:

```sh
code --user-data-dir=/tmp/lye-vscode/user --extensions-dir=/tmp/lye-vscode/ext \
	--ozone-platform=headless --disable-gpu --no-sandbox --disable-workspace-trust \
	--extensionDevelopmentPath=$PWD --extensionTestsPath=$PWD/tests/benchmark.js \
	/path/to/a/workspace
```

`tests/benchmark.js` is that test: it activates the extension, opens a file, and times the
commands VS Code itself runs for hover, completion, definitions, symbols and the round trip from
an edit to the diagnostics it draws. It writes JSON to `LYE_BENCH_OUT`, and `LYE_BENCH_FILE` picks
the file to open.

## Layout

| Path | Holds |
|---|---|
| `src/extension.ts` | the whole wrapper: server command, document selector, error message |
| `language-configuration.json` | comments, brackets and indentation for Lua |
| `package.json` | the language and settings this extension contributes |
| `tests/smoke.mjs` | the protocol a client speaks, against the real binary |
| `tests/benchmark.mjs` | round-trip times for the requests an editor makes |
| `tests/benchmark.js` | the same, measured inside a headless VS Code |

## With another Lua extension installed

This extension contributes the `lua` language id, and so does every other Lua extension. Two
language servers attached to the same document both publish diagnostics, hover, completion and
semantic tokens, and the editor merges what they say — which makes it hard to tell which server
answered. Disable the others for the workspace if you want to see lye alone:

| Extension | What it does on a Lua document |
|---|---|
| `sumneko.lua` (LuaLS) | its own diagnostics, completion, hover, semantic tokens |
| `pdesaulniers.vscode-teal` | activates on `onLanguage:lua` and runs a Teal server |

Command Palette → *Extensions: Disable (Workspace)*, or a workspace profile with only `lye`
enabled.

