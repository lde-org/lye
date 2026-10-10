--[[
	The LuaJIT definitions the analyzer parses, from the files in `src/meta/`.

	`build.lua` gathers them into `defs.lua` when this package is built: the module is written per
	library so that each can be read and edited on its own, and combined at build time so that
	nothing generated is stored in the repository. Both the package's own output and its source
	directory are written, because a package that depends on this one is given the source.
]]

return require("lye-defs.defs")
