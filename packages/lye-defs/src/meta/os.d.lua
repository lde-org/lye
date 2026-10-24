---@meta os

---
---@class oslib
os = {}

---Returns an approximation of the amount in seconds of CPU time used by the program.
---@nodiscard
function os.clock(): number end

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
---@nodiscard
function os.date(format?: string, time?: integer): string|osdate|nil end

---Returns the difference, in seconds, from time `t1` to time `t2`.
---@nodiscard
function os.difftime(t2: integer, t1?: integer): integer end

---Passes `command` to be executed by an operating system shell.
function os.execute(command?: string): integer end

---Calls the ISO C function `exit` to terminate the host program.
function os.exit(code?: boolean|integer, close?: boolean) end

---Returns the value of the process environment variable `varname`.
---@nodiscard
function os.getenv(varname: string): string? end

---Deletes the file with the given name.
---@return true? suc
---@return string? errmsg
---@return integer? errcode
function os.remove(filename: string) end

---Renames the file or directory named `oldname` to `newname`.
---@return true? suc
---@return string? errmsg
---@return integer? errcode
function os.rename(oldname: string, newname: string) end

---@alias localecategory
---|>"all"
---| "collate"
---| "ctype"
---| "monetary"
---| "numeric"
---| "time"

---Sets the current locale of the program.
function os.setlocale(locale: string?, category?: localecategory): string? end

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
---@nodiscard
function os.time(date?: osdateparam): integer end

---Returns a string with a file name that can be used for a temporary file.
---@nodiscard
function os.tmpname(): string end

return os
