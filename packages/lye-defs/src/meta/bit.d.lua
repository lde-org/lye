---@meta bit

---@class bitlib
bit = {}

---@nodiscard
---@overload fun(x: ffi.cnum*): integer
function bit.tobit(x: integer): integer end

---@nodiscard
---@overload fun(x: ffi.cnum*, n?: integer): string
function bit.tohex(x: integer, n?: integer): string end

---@nodiscard
---@overload fun(x: ffi.cnum*): ffi.cnum*
function bit.bnot(x: integer): integer end

---@nodiscard
---@overload fun(x: ffi.cnum*, ...: integer|ffi.cnum*): ffi.cnum*
function bit.bor(x: integer, ...: integer): integer end

---@nodiscard
---@overload fun(x: ffi.cnum*, ...: integer|ffi.cnum*): ffi.cnum*
function bit.band(x: integer, ...: integer): integer end

---@nodiscard
---@overload fun(x: ffi.cnum*, ...: integer|ffi.cnum*): ffi.cnum*
function bit.bxor(x: integer, ...: integer): integer end

---@nodiscard
---@overload fun(x: ffi.cnum*, n: integer): ffi.cnum*
function bit.lshift(x: integer, n: integer): integer end

---@nodiscard
---@overload fun(x: ffi.cnum*, n: integer): ffi.cnum*
function bit.rshift(x: integer, n: integer): integer end

---@nodiscard
---@overload fun(x: ffi.cnum*, n: integer): ffi.cnum*
function bit.arshift(x: integer, n: integer): integer end

---@nodiscard
---@overload fun(x: ffi.cnum*, n: integer): ffi.cnum*
function bit.rol(x: integer, n: integer): integer end

---@nodiscard
---@overload fun(x: ffi.cnum*, n: integer): ffi.cnum*
function bit.ror(x: integer, n: integer): integer end

---@nodiscard
---@overload fun(x: ffi.cnum*): ffi.cnum*
function bit.bswap(x: integer): integer end

return bit
