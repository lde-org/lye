# lye-plugin

The plugin system: what a plugin is, how a workspace names one, and what lye hands it.

A plugin is a Lua module that returns a table of hooks. lye calls them where a document is about to
be read and where an editor has asked something about one:

| Hook | Answers | For |
|---|---|---|
| `lower(context)` | the edits that turn a document into Lua | a language that is not Lua: the plugin compiles what it can, lye reads the result |
| `tokens(context)` | extra semantic tokens | colours for a language or a library lye does not know |
| `extensions` | a list like `{ "moon" }` | the files a language is written in, so `lye check .` checks them |

A plugin is handed a **context** and nothing else — the document, the text lye reads, and what the
analysis worked out. Nothing about the server is visible, so a plugin cannot come to depend on how
the server happens to be written today.

```lua
-- toysyntax.lua — `let name: type = value` is Lua with a type annotation.
local toy = {}

function toy.lower(context)
	local edits = {}
	for each statement of context.source do
		edits[#edits + 1] = { from = …, to = …, text = "---@type number\nlocal x = 1" }
	end
	return edits
end

function toy.tokens(context)
	-- Spans are in the offsets of `context.source`, the text the editor holds.
	return { { from = 4, to = 10, type = "property" } }
end

return toy
```

The same plugin is what `lye check` reads with: a check loads the plugins a package asked for, and
a file is analysed in the language its package said it is written in. `extensions` is what makes
`lye check .` reach those files at all — a walk that only knew `.lua` would check none of a
MoonScript project.

## Naming one

`lye.json`, beside a package or at the workspace root, lists the plugins that document is read with,
in the order it wants them asked. The package's entries come first, the workspace's after them, and
a path is read from the file that wrote it:

```json
{
	"plugins": [
		"./tools/moonscript.lua",
		"lye-plugin-moonscript",
		"!patterns"
	]
}
```

A path is a file of the workspace's own. A name is a module, resolved the way `require` is: one the
package installed with `lde add`, which is what a plugin installed from lde's registry is, so there
is no plugin registry of lye's own to publish to or to search — `lye-plugin-<name>` is the
convention that keeps one findable. A `!` turns a plugin off: lye's own are on unless a workspace
says otherwise, and the name after the `!` has to be one of those. A name that resolves to nothing,
a file that does not load, and a `!` naming something lye does not ship are each reported through
`window/logMessage` (or the error stream under `lye check`) and then left out: an editor with a
mistyped plugin name still reads Lua.

`lye init [dir]` writes this file with both keys lye reads and nothing said yet.

## `lower`: a language of your own

`lower` answers a list of **edits**. Each replaces a span of the document with new text, which is what
compiling a statement of another language to Lua is:

```lua
---@class lye.plugin.Edit
---@field from integer byte offset of the first byte replaced, 1-based
---@field to integer byte offset one past the last byte replaced, so `from == to` is an insertion
---@field text string what stands there in the lowered text
---@field same boolean? the text is the original span written again, which maps one to one
```

The edits may be written in any order and must not overlap. lye reads the text they make, and carries
every position and every range the other way:

* An offset in material no edit touched is moved by the length the edits before it added or removed.
* An offset inside a replacement the plugin wrote is not moved at all when it is asked about — the
  text that was there is gone — and an answer the analysis produced inside it is reported over the
  whole span the edit replaced. That is the code a reader of the original can be pointed at: a fault
  lye finds in the Lua you wrote lands on the line the reader wrote.
* `same` is the promise that the replacement is the original span written again, which a plugin makes
  when it re-emits a statement unchanged or wraps it in something.

An edit list that overlaps or runs past the document is refused and reported: the document is read as
it was rather than damaged.

Plugins are asked in the order lye has them, and each one's edits are written against the text the
one before it produced — so a plugin for a second language can sit on top of a first.

## `tokens`: colours of your own

`tokens` answers spans to colour, in the offsets of `context.source` — the document as the editor
holds it, which is the text the colour lands on. Each names a token type from the legend lye
advertises: `keyword`, `string`, `number`, `comment`, `operator`, `variable`, `function`, `parameter`,
`type`, `namespace`, `class`, `property`, `method`, `regexp`.

```lua
---@class lye.plugin.Span
---@field from integer byte offset into `context.source`, 1-based
---@field to integer byte offset one past the last byte
---@field type string a token type from the legend
---@field modifiers integer? 1 for `documentation`, the only modifier lye asks for
```

A span a plugin asks for wins over the one lye's own walk found: the string is written around the
conversion in it, so a plugin can colour `%d` inside a literal without hiding the literal. What lye
read *inside text a plugin wrote* is not sent at all — a `local` that exists only in the lowered text
has nowhere to be pointed at in the document — so a plugin that lowers a language is also the one
that colours it.

A plugin that works from `context.parsed` is reading the *lowered* text, and its spans are in those
offsets; `context.map` carries them back, and `context.map:rangeIsWritten(from, to)` says whether a
range has a place in the document at all. Ask the parse tree for what you want rather than walking
every node — `context.parsed.byKind.call` is the index — because the hook is called again on every
keystroke. Both shipped plugins do exactly that:

```lua
local first, last = from + mark.start - 1, from + mark.stop - 1
if not map:rangeIsWritten(first, last) then
	local at, stop = map:toOriginalRange(first, last)
	spans[#spans + 1] = { from = at, to = stop, type = "regexp" }
end
```

## Context

| Field | What it is |
|---|---|
| `uri` | the document |
| `source` | the document as the editor holds it |
| `text` | what lye reads: the lowered text, once a plugin has lowered it |
| `root` | the package the document belongs to, for a plugin with files of its own |
| `parsed` | the parse tree lye read (`tokens` only) |
| `analysis` | what the analyzer worked out: declarations, variables, classes (`tokens` only) |
| `map` | the way from the text lye reads back to the document (`tokens` only) |
| `typeOf(nodeIdx)` | the type the analyzer gave a node, or nil (`tokens` only) |
| `ownerOf(type)` | the name a value's fields are found under: a class's name, or `string` (`tokens` only) |

## The plugins lye ships

* `patterns` — a literal handed to a function that reads it as a pattern is not text: the escapes
  and magic characters of `s:gsub("%s+", "-")` are marked inside it, and so are the escapes of a
  `gsub`'s replacement.
* `formats` — the same for a format string: the conversions of `string.format("%d/%s")`, and of
  `string.pack`, `string.unpack`, `string.packsize` and `os.date`.
* `cdef` — the text handed to `ffi.cdef` is C, and it is coloured from lye's own parse of it: a
  keyword, a builtin type, the name the block declared, a member, a constant an `enum` named. The
  brackets stay the string token lye's walk writes, and the plugin's spans are cut out of it.

These three were part of the server before plugins existed. They are the worked examples of one —
two of them read the parse tree and map what they find back through `context.map`, and the test
that they still colour what they used to is in `lye-lsp`'s suite.

## Layout

`src/source.lua` is the map: edits into a text, and a text's offsets back into the document's.
`src/init.lua` is the loader and the hook calls. `src/plugins/` holds the plugins lye ships, each
`require`d from `SHIPPED` in `init.lua` — a name looked up at runtime would be a file a compiled
binary does not carry.
