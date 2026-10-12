--[[
	A class a workspace file declares, for a document that never requires it: the editor has read
	no other file when it opens the one that names it, so the workspace scan is all the resolver
	has. `use.lua` beside it is opened with its text handed over, never read from here.
]]

---@class Point
---@field x number
---@field y number
local Point = {}
Point.__index = Point
return Point
