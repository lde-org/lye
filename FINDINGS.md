# lye findings

Date: 2026-10-31. This supersedes the 2026-10-29 performance record: that file described item
reuse as disabled and predates the workspace-index and cross-file work below.

## Verified state

| Check | Result |
|---|---|
| `lde test --jobs 1` | 647 passed |
| `lye check packages --cold` from a clean build | 108 files, nothing to report |
| `tools/compile.sh` from a dirty checkout | builds; binary prints `lye 0.1.0` |
| `lye check packages --cold` from the repository root | nothing to report |

The repository's own `lye.json` turns off `redundant-return` hints, so a clean self-check is
literally clean rather than "errors and warnings only".

## What changed

- **Item reuse is on in the server.** `Lye:analyze` passes `reuse = true, rebase = true`, and the
  parser resumes from the held tree. The 32 MiB analysis-cache budget is enforced by
  `analysis_cache.lua`.
- **Cross-file symbols.** A lexical workspace index (`workspace.lua`) records names, fields,
  annotation types and `require` strings per file. References and rename cross files; a local
  stays in its document. A module-file rename edits every `require` that resolved to it.
- **Cross-file class methods.** Methods are collected from every workspace file and seeded into
  the class table before analysis. A class whose method index is complete reports a missing method
  at a `:` call, and completion/hover see methods declared in another file.
- **Diagnostic controls.** `---@diagnostic disable-line`, `disable-next-line`, `disable` and
  `enable` are honoured. `lye.json` can set a code's severity or turn it off:
  `{"diagnostics":{"severity":{"redundant-return":"off"},"disable":["visibility"]}}`.
  `workspace/didChangeConfiguration` re-reports open documents without re-analysing them.
- **Annotation semantics.** `@deprecated` reports uses (code `deprecated`), `@nodiscard` reports a
  dropped result (code `discard`), `@async` is carried on the callable and shown in its display,
  and `@operator` contributes callable operators to a class.
- **Workspace folders.** `workspaceFolders` are all remembered; each document resolves against its
  own folder, and workspace symbols/pull diagnostics cover every folder.
- **Protocol surface.** Declaration, document links, linked editing, monikers, type hierarchy,
  inline values, semantic-token deltas, and completion/code-action/inlay-hint resolve are answered.
  Code lenses carry a real `lye.showReferences` command. Plugins answer hover, definition,
  references and code actions.
- **Shipping.** `LICENSE`, CI, a six-target release workflow, and `tools/compile.sh` (a snapshot
  build that does not read generated `target/` fixtures) are in the tree.

## Known limits

- `lye check` does not build the workspace method index. Missing-method diagnostics are therefore
  an editor feature; a method call whose class is declared in another file is not checked by the
  CI command. The call check is deliberately gated on the index being present.
- A cross-file method's placeholder callable accepts any arguments and returns `unknown` until the
  declaring file is itself analysed. The real signature is used where the declaration is in the
  analysed document.
- The formatter spaces tokens and fixes indentation; it does not wrap long lines or reorder code.
- `@async` is a marker in the type display; it does not change a call's return type.
- Multi-root file watching updates the root an event belongs to, but an event whose root index was
  never loaded falls back to full invalidation.
