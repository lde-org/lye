# Changelog

## 0.1.0

- Starts the `lye` language server over stdio and attaches it to Lua documents.
- Contributes the `lua` language, its brackets and comments, and `lye.serverPath`.
- `tests/benchmark.mjs` measures the requests an editor makes; `tests/benchmark.js` does the same
  inside a headless VS Code instance.

- Hover shows a signature with its parameters named and the documentation above it, as markdown;
  completion items carry the same documentation, so an item expands into the same explanation.
- Colours and completion icons come from what a name resolves to: `math` is a namespace,
  `math.random` a function, `math.pi` a property, `print` and `setmetatable` functions of the
  standard library, and a class a class.

Reload the window after updating the server: the semantic token legend it negotiates has more
types than before (`namespace`, `class`, `property`, `method`), and a client keeps the legend it
was started with.
