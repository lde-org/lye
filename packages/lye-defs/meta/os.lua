---@meta os

---
---@class oslib
os = {}

---Returns an approximation of the amount in seconds of CPU time used by the program.
---@return number
---@nodiscard
function os.clock() end

---@class osdate:osdateparam
---four digits
---@field year  integer
---1-12
---@field month integer
---1-31
---@field day   integer
---0-23
---@field hour  integer
---0-59
---@field min   integer
---0-61
---@field sec   integer
---weekday, 1–7, Sunday is 1
---@field wday  integer
---day of the year, 1–366
---@field yday  integer
---daylight saving flag, a boolean
---@field isdst boolean?

---Returns a string or a table containing date and time, formatted according to the given string `format`.
---@param format? string
---@param time?   integer
---@return string|osdate
---@nodiscard
function os.date(format, time) end

---Returns the difference, in seconds, from time `t1` to time `t2`.
---@param t2 integer
---@param t1 integer
---@return integer
---@nodiscard
function os.difftime(t2, t1) end

---Passes `command` to be executed by an operating system shell.
---@param command? string
---@return true?     suc
---@return exitcode? exitcode
---@return integer?  code
function os.execute(command) end

---Calls the ISO C function `exit` to terminate the host program.
---@param code?  boolean|integer
---@param close? boolean
function os.exit(code, close) end

---Returns the value of the process environment variable `varname`.
---@param varname string
---@return string?
---@nodiscard
function os.getenv(varname) end

---Deletes the file with the given name.
---@param filename string
---@return true? suc
---@return string? errmsg
---@return integer? errcode
function os.remove(filename) end

---Renames the file or directory named `oldname` to `newname`.
---@param oldname string
---@param newname string
---@return true? suc
---@return string? errmsg
---@return integer? errcode
function os.rename(oldname, newname) end

---@alias localecategory
---|>"all"
---| "collate"
---| "ctype"
---| "monetary"
---| "numeric"
---| "time"

---Sets the current locale of the program.
---@param locale    string|nil
---@param category? localecategory
---@return string localecategory
function os.setlocale(locale, category) end

---@class osdateparam
---four digits
---@field year  integer|string
---1-12
---@field month integer|string
---1-31
---@field day   integer|string
---0-23
---@field hour  (integer|string)?
---0-59
---@field min   (integer|string)?
---0-61
---@field sec   (integer|string)?
---weekday, 1–7, Sunday is 1
---@field wday  (integer|string)?
---day of the year, 1–366
---@field yday  (integer|string)?
---daylight saving flag, a boolean
---@field isdst boolean?

---Returns the current time when called without arguments, or a time representing the local date and time specified by the given table.
---@param date? osdateparam
---@return integer
---@nodiscard
function os.time(date) end

---Returns a string with a file name that can be used for a temporary file.
---@return string
---@nodiscard
function os.tmpname() end

return os
