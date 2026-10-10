# lye for Zed

LuaJIT language support in Zed, from the `lye-lsp` language server: types, diagnostics, hover,
completion, navigation into the definitions and the rest of the protocol.

## The Lua language comes with it

Zed has no built-in Lua: the language, its grammar and its highlighting come from an extension.
This one is that extension for lye — it carries the `lua` and `emmyluadoc` languages (the second is
what highlights the annotations inside a doc comment) using the same grammar and the same queries
as the [official Lua extension](https://github.com/zed-extensions/lua), which is MIT licensed along
with the queries copied from it. Install this one **or** that one, not both: two extensions
declaring the same language is a conflict.

The server attaches to `Lua` only. An `emmyluadoc` buffer is a fragment of an annotation rather than
a Lua file, so analysing it as Lua would report the annotations themselves as syntax errors; the
language is there for highlighting, not for the server.

### LuaJIT and the grammar

The grammar is the one for Lua 5.4, which parses LuaJIT's syntax as it is: LuaJIT is 5.1 with `goto`
and a few additions, not a different language. Two things it does not cover, and neither can be
fixed from here — they are grammar-level, not query-level:

- cdata number suffixes, as in `112512ULL`. The tree-sitter grammar reads the number and then the
  suffix as a separate identifier, so the suffix is not coloured as part of the number. lye's own
  analyzer reads it as a number.
- the dialect operators lde accepts (`&&`, `||`, `!`, `??`, `//`, compound assignment). The grammar
  sees an error node, so no query can colour them. If you use them, a fork of the grammar is the
  only way to highlight them.

## What it does

Zed already highlights Lua, so this extension is only a way to run the server: it looks up
`lye-lsp` on your `PATH` and starts it over stdio for Lua buffers. Nothing is bundled, so the
version that runs is the one you installed.

## Requirements

`lye-lsp` on your `PATH`:

```
lde install lye-lsp      # or build it: lde compile -C packages/lye-lsp
```

If it lives somewhere else, point Zed at it rather than moving it:

```json
{
  "lsp": {
    "lye-lsp": {
      "binary": { "path": "/full/path/to/lye-lsp" }
    }
  }
}
```

## If you also run lua-language-server

Zed runs every server configured for a language, so LuaLS and lye can both be attached to the same
buffer: you would see two sets of diagnostics and two sets of completions. Turn the other one off
in your settings if you want lye alone.

## Jumps into the definitions

Ctrl+click on a builtin — `math.floor`, `table.insert`, a type named in an annotation — opens the
definition the server writes into its cache directory (`$XDG_CACHE_HOME/lye/defs`, or
`~/.cache/lye/defs`). Those copies come from the definitions embedded in the binary and are never
read back, so editing one changes nothing; the server rewrites them from the embedded text.
