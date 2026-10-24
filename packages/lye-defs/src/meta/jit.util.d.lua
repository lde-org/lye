---@meta jit.util

---@class Trace
---@class Proto

---@class jit.util
local util = {}

---@class jit.funcinfo.lua
---@field linedefined integer
---@field lastlinedefined integer
---@field stackslots integer
---@field params integer
---@field bytecodes integer
---@field gcconsts integer
---@field nconsts integer
---@field upvalues integer
---@field currentline integer
---@field isvararg boolean
---@field children boolean
---@field source string
---@field loc string
---@field proto Proto[]

---@class jit.funcinfo.c
---@field addr integer
---@field upvalues integer
---@field ffid integer?

function util.funcinfo(func: fn(), pc: integer?): jit.funcinfo.c | jit.funcinfo.lua end

---@return integer? ins
---@return integer? m
function util.funcbc(func: function, pc: integer) end

function util.funck(func: function, idx: integer): any? end

function util.funcuvname(func: function, idx: integer): string? end

---@class jit.traceinfo
---@field nins integer
---@field nk integer
---@field link integer
---@field nexit integer
---@field linktype string

function util.traceinfo(tr: integer): jit.traceinfo? end

---@return integer? m
---@return integer? ot
---@return integer? op1
---@return integer? op2
---@return integer? prev
function util.traceir(tr: integer, ref: integer) end

---@return any? k
---@return integer? t
---@return integer? slot
function util.tracek(tr: integer, idx: integer) end

---@alias jit.snap integer[]

---@overload fun(tr: integer, sn: integer, getpos: boolean): jit.snap, integer
function util.tracesnap(tr: integer, sn: integer): jit.snap? end

---@return string? mcode
---@return integer? addr
---@return integer? loop
function util.tracemc(tr: integer) end

---@overload fun(exitno: integer): integer
function util.traceexitstub(tr: integer, exitno: integer): integer? end

function util.ircalladdr(idx: integer): integer? end

return util
