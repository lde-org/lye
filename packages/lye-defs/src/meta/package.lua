---@meta package

---Loads the given module, returns any value returned by the given module(`true` when `nil`).
---@param modname string
---@return unknown
function require(modname) end

---
---@class packagelib
---The path used by `require` to search for a C loader.
---@field cpath     string
---A table used by `require` to control which modules are already loaded.
---@field loaded    table
---The path used by `require` to search for a Lua loader.
---@field path      string
---A table to store loaders for specific modules.
---@field preload   table
---The loaders `require` walks, in order: the preload table, the Lua loader, the C loader.
---@field loaders   table
package = {}

---A string describing some compile-time configurations for packages.
package.config = [[
/
;
?
!
-]]


---Dynamically links the host program with the C library `libname`.
---@param libname string
---@param funcname string
---@return function? fn
---@return string? errmsg
---@return string? where which step failed: `open` or `init`
function package.loadlib(libname, funcname) end

---Makes the module's functions see the module's table as their environment, so a global written
---there is read as a global here. Lua 5.1 and LuaJIT only.
---@param module table
function package.seeall(module) end

---Creates a module, with the name a `require` of it looks up: the table is registered in
---`package.loaded` and becomes the environment of the functions that follow. Lua 5.1 and LuaJIT
---only.
---@param name string
---@param ... any
function module(name, ...) end


---Searches for the given `name` in the given `path`.
---@param name string
---@param path string
---@param sep? string
---@param rep? string
---@return string? filename
---@return string? errmsg
---@nodiscard
function package.searchpath(name, path, sep, rep) end


return package
