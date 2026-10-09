--[[
	Fixture for the `lye-lsp` session tests.

	This is the real server, reached through the same wiring `src/main.lua` uses. The
	harness runs it as a subprocess, so it must not require `lde-test`.
]]

require("lye-lsp.language").start()
