---@meta table

---
---@class tablelib
table = {}

---Given a list where all elements are strings or numbers, returns the string `list[i]..sep..list[i+1] ··· sep..list[j]`.
---@param list table
---@param sep? string
---@param i?   integer
---@param j?   integer
---@return string
---@nodiscard
function table.concat(list, sep, i, j) end


---Inserts element `value` at position `pos` in `list`.
---@overload fun(list: table, value: any)
---@param list table
---@param pos integer
---@param value any
function table.insert(list, pos, value) end


---Moves elements from table `a1` to table `a2`.
---```lua
---a2[t],··· =
---a1[f],···,a1[e]
---return a2
---```
---
---@param a1  table
---@param f   integer
---@param e   integer
---@param t   integer
---@param a2? table
---@return table a2
function table.move(a1, f, e, t, a2) end


---Removes from `list` the element at position `pos`, returning the value of the removed element.
---@param list table
---@param pos? integer
---@return any
function table.remove(list, pos) end

---Sorts list elements in a given order, *in-place*, from `list[1]` to `list[#list]`.
---@generic T
---@param list T[]
---@param comp? fun(a: T, b: T):boolean
function table.sort(list, comp) end


---Executes the given f over all elements of table. For each element, f is called with the index and respective value as arguments. If f returns a non-nil value, then the loop is broken, and this value is returned as the final value of foreach.
---@generic T
---@param list any
---@param callback fun(key: any, value: any):T|nil
---@return T|nil
---@deprecated
function table.foreach(list, callback) end

---Executes the given f over the numerical indices of table. For each index, f is called with the index and respective value as arguments. Indices are visited in sequential order, from 1 to n, where n is the size of the table. If f returns a non-nil value, then the loop is broken and this value is returned as the result of foreachi.
---@generic T
---@param list any
---@param callback fun(key: integer, value: any):T|nil
---@return T|nil
---@deprecated
function table.foreachi(list, callback) end

---Returns the number of elements in the table. This function is equivalent to `#list`.
---@generic T
---@param list T[]
---@return integer
---@nodiscard
---@deprecated
function table.getn(list) end

return table
