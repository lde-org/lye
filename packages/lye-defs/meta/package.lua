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
---@return any
function package.loadlib(libname, funcname) end


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
