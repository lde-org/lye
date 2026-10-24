---@meta math

---
---@class mathlib
---A value larger than any other numeric value.
---@field huge       number
---The value of *π*.
---@field pi         number
math = {}

---Returns the absolute value of `x`.
---@nodiscard
function math.abs(x: number): number end

---Returns the arc cosine of `x` (in radians).
---@nodiscard
function math.acos(x: number): number end

---Returns the arc sine of `x` (in radians).
---@nodiscard
function math.asin(x: number): number end

---Returns the arc tangent of `x` (in radians).
---@nodiscard
function math.atan(y: number): number end

---Returns the arc tangent of `y/x` (in radians).
---@nodiscard
function math.atan2(y: number, x: number): number end

---Returns the smallest integral value larger than or equal to `x`.
---@nodiscard
function math.ceil(x: number): integer end

---Returns the cosine of `x` (assumed to be in radians).
---@nodiscard
function math.cos(x: number): number end

---Returns the hyperbolic cosine of `x` (assumed to be in radians).
---@nodiscard
function math.cosh(x: number): number end

---Converts the angle `x` from radians to degrees.
---@nodiscard
function math.deg(x: number): number end

---Returns the value `e^x` (where `e` is the base of natural logarithms).
---@nodiscard
function math.exp(x: number): number end

---Returns the largest integral value smaller than or equal to `x`.
---@nodiscard
function math.floor(x: number): integer end

---Returns the remainder of the division of `x` by `y` that rounds the quotient towards zero.
---@nodiscard
function math.fmod(x: number, y: number): number end

---Returns two numbers `m` and `e` such that `x = m * (2 ^ e)`, where `e` is an integer. When `x` is zero, NaN, +inf, or -inf, `m` is equal to `x`; otherwise, the absolute value of `m` is in the range [0.5, 1).
---@return number m
---@return integer e
---@nodiscard
function math.frexp(x: number) end

---Returns `m * (2 ^ e)`, where `e` is an integer.
---@nodiscard
function math.ldexp(m: number, e: number): number end

---Returns the logarithm of `x` in the given base.
---@nodiscard
function math.log(x: number, base?: integer): number end


---Returns the argument with the maximum value, according to the Lua operator `<`.
---@nodiscard
function math.max(x: number, ...: number): number end

---Returns the argument with the minimum value, according to the Lua operator `<`.
---@nodiscard
function math.min(x: number, ...: number): number end

---Returns the integral part of `x` and the fractional part of `x`.
---@return integer
---@return number
---@nodiscard
function math.modf(x: number) end

---Returns `x ^ y` .
---@nodiscard
function math.pow(x: number, y: number): number end

---Converts the angle `x` from degrees to radians.
---@nodiscard
function math.rad(x: number): number end

---* `math.random()`: Returns a float in the range [0,1).
---* `math.random(n)`: Returns a integer in the range [1, n].
---* `math.random(m, n)`: Returns a integer in the range [m, n].
---
---@overload fun():number
---@overload fun(m: integer):integer
---@nodiscard
function math.random(m: integer, n: integer): integer end

---Sets `x` as the "seed" for the pseudo-random generator.
function math.randomseed(x?: integer) end

---Returns the sine of `x` (assumed to be in radians).
---@nodiscard
function math.sin(x: number): number end

---Returns the hyperbolic sine of `x` (assumed to be in radians).
---@nodiscard
function math.sinh(x: number): number end

---Returns the square root of `x`.
---@nodiscard
function math.sqrt(x: number): number end

---Returns the tangent of `x` (assumed to be in radians).
---@nodiscard
function math.tan(x: number): number end

---Returns the hyperbolic tangent of `x` (assumed to be in radians).
---@nodiscard
function math.tanh(x: number): number end




return math
