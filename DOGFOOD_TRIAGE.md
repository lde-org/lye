# Dogfood triage status

The original black-box run checked `lye 0.1.0` against a Lua interpreter written in Lua, with
16 files and 75 tests. The project ends with `lye check --cold` reporting nothing and all tests
passing. This table records where the findings stand after the 2026-10-31 pass.

| ID | Status | Current behaviour |
|---|---|---|
| DOGFOOD-001 | fixed | Redundant-return hints are off in the repository's `lye.json`; a workspace can also turn the code off or set its severity. |
| DOGFOOD-002 | fixed | A fact on a field survives the read side of an assignment; a recursive `parent` walk narrows normally. |
| DOGFOOD-003 | fixed | Discriminant narrowing reads declared class fields, so a parameter in value position narrows by its tag. |
| DOGFOOD-004 | fixed | `---@cast` applies inside `elseif`, and a contradictory chain marks the rest of its scope unreachable. |
| DOGFOOD-005 | fixed | A dotted call to a function declared `---@return never` terminates flow. |
| DOGFOOD-006 | partially fixed | Missing class-field reads and `:` method calls are errors when the class's method index is complete. The editor builds that index across the workspace; `lye check` does not, so the CI command still leaves cross-file method calls alone. |
| DOGFOOD-007 | fixed | A `---@cast` on a `pcall` error value is applied before the failure unknown. |
| DOGFOOD-008 | fixed | An annotated table field with a function type supplies the function expression's parameter and return types. |
| DOGFOOD-009 | fixed | A missing module reports the lde package-qualified name when that candidate resolves. |
| DOGFOOD-010 | fixed | `lye init` appends `.lye/` to `.gitignore` when it is missing. |

## Verification

- The dogfood project: `lye check --cold` → nothing to report; `lde test` → 75/75.
- This repository: `lde test --jobs 1` → 647/647; `lye check packages --cold` → nothing to report.
