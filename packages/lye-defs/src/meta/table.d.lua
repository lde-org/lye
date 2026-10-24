---@meta table

---
---@class tablelib
table = {}

---Given a list where all elements are strings or numbers, returns the string `list[i]..sep..list[i+1] ··· sep..list[j]`.
---@nodiscard
function table.concat(list: (string|number)[], sep?: string, i?: integer, j?: integer): string end


---Inserts element `value` at position `pos` in `list`.
---@overload fun(list: table, value: any)
function table.insert<T>(list: T[], pos: integer, value: T) end


---Moves elements from table `a1` to table `a2`.
---```lua
---a2[t],··· =
---a1[f],···,a1[e]
---return a2
---```
---
function table.move<T>(a1: T[], f: integer, e: integer, t: integer, a2?: T[]): T[] end


---Removes from `list` the element at position `pos`, returning the value of the removed element.
function table.remove<T>(list: T[], pos?: integer): T? end

---Sorts list elements in a given order, *in-place*, from `list[1]` to `list[#list]`.
function table.sort<T>(list: T[], comp?: fun(a: T, b: T):boolean) end


---Executes the given f over all elements of table. For each element, f is called with the index and respective value as arguments. If f returns a non-nil value, then the loop is broken, and this value is returned as the final value of foreach.
---@return T?
---@deprecated
function table.foreach<T>(list: table, callback: fun(key: any, value: any):T|nil) end

---Executes the given f over the numerical indices of table. For each index, f is called with the index and respective value as arguments. Indices are visited in sequential order, from 1 to n, where n is the size of the table. If f returns a non-nil value, then the loop is broken and this value is returned as the result of foreachi.
---@return T?
---@deprecated
function table.foreachi<T>(list: table, callback: fun(key: integer, value: any):T|nil) end

---Returns the number of elements in the table. This function is equivalent to `#list`.
---@nodiscard
---@deprecated
function table.getn<T>(list: T[]): integer end

return table
