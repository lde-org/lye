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

## Layout

| Path | Holds |
|---|---|
| `src/extension.ts` | the whole wrapper: server command, document selector, error message |
| `language-configuration.json` | comments, brackets and indentation for Lua |
| `package.json` | the language and settings this extension contributes |

## With another Lua extension installed

This extension contributes the `lua` language id, and so does every other Lua extension. Two
language servers attached to the same document both publish diagnostics, so disable one of them
if you see every problem twice.

