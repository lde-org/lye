---@meta bit

---@class bitlib
bit = {}

---@nodiscard
function bit.tobit(x: integer): integer end

---@nodiscard
function bit.tohex(x: integer, n?: integer): string end

---@nodiscard
function bit.bnot(x: integer): integer end

---@nodiscard
function bit.bor(x: integer, ...: integer): integer end

---@nodiscard
function bit.band(x: integer, ...: integer): integer end

---@nodiscard
function bit.bxor(x: integer, ...: integer): integer end

---@nodiscard
function bit.lshift(x: integer, n: integer): integer end

---@nodiscard
function bit.rshift(x: integer, n: integer): integer end

---@nodiscard
function bit.arshift(x: integer, n: integer): integer end

---@nodiscard
function bit.rol(x: integer, n: integer): integer end

---@nodiscard
function bit.ror(x: integer, n: integer): integer end

---@nodiscard
function bit.bswap(x: integer): integer end

return bit
