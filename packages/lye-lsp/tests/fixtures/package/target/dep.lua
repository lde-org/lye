--[[
	A module lde linked into the package's `target/`, which the workspace walk leaves out: what a
	document of the package can reach is what this file declares. `src/use.lua` is opened with its
	text handed over, never read from here.
]]

---@class Dep
---@field amount number
local Dep = {}
Dep.__index = Dep
return Dep
