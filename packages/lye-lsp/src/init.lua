--[[
	The library entry point.

	`main.lua` is the executable: it reads the command line, serves the language server or checks a
	tree, and exits. This module is what another Lua program requires: it starts nothing, reads no
	arguments, and returns the check and the report a caller drives itself.
]]

local check = require("lye-lsp.check")
local report = require("lye-lsp.report")

local lye = {}

--- The headless check `lye check` runs: `file`, `files`, `discover`, `expand`, `extensions` and
--- `stats`. Hand `check.file` a `report.collect()` reporter to keep its findings as tables instead
--- of printing them.
lye.check = check

--- Where a check says what it found, and `collect`, which keeps findings rather than printing them.
lye.report = report

return lye
