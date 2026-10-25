---@meta _

---Command-line arguments of Lua Standalone.
---@type string[]
arg = {}

---Raises an error if the value of its argument v is false (i.e., `nil` or `false`); otherwise, returns all its arguments. In case of error, `message` is the error object; when absent, it defaults to `"assertion failed!"`
---@return T
---@return any ...
---@return v is -nil
function assert<T>(v?: T, message?: any, ...: any) end

---This function is a generic interface to the garbage collector. It performs different functions according to its first argument, opt:
---
---* `"collect"`: performs a full garbage-collection cycle. This is the default option.
---* `"stop"`: stops the garbage collector.
---* `"restart"`: restarts the garbage collector.
---* `"count"`: returns the total memory in use by Lua (in Kbytes).
---* `"step"`: performs a garbage-collection step. The step "size" is controlled by arg (larger values mean more steps) in a non-specified way. If you want to control the step size you must experimentally tune the value of arg. Returns true if the step finished a collection cycle.
---* `"setpause"`: sets arg as the new value for the pause of the collector (see §2.10). Returns the previous value for pause.
---* `"setstepmul"`: sets arg as the new value for the step multiplier of the collector (see §2.10). Returns the previous value for step.
---
---@overload fun(opt?: "collect")
---@overload fun(opt: "stop")
---@overload fun(opt: "restart")
---@overload fun(opt: "count"): number
---@overload fun(opt: "step", arg: integer): true
---@overload fun(opt: "setpause", arg: integer): integer
---@overload fun(opt: "setstepmul", arg: integer): integer
function collectgarbage(...) end

---How much memory the collector has taken, in kilobytes. Lua 5.1 and LuaJIT only, and the same
---number `collectgarbage("count")` gives.
---@nodiscard
function gcinfo(): number end





---Opens the named file and executes its content as a Lua chunk. When called without arguments, `dofile` executes the content of the standard input (`stdin`). Returns all values returned by the chunk. In case of errors, `dofile` propagates the error to its caller. (That is, `dofile` does not run in protected mode.)
function dofile(filename?: string): any ... end

---Terminates the last protected function called and returns message as the error object.
---
---Usually, `error` adds some information about the error position at the beginning of the message, if the message is a string.
---
function error(message: any, level?: integer): never end

---A global variable (not a function) that holds the global environment (see §2.2). Lua itself does not use this variable; changing its value does not affect any environment, nor vice versa.
---@class _G
_G = {}

---Returns the current environment in use by the function. `f` can be a Lua function or a number that specifies the function at that stack level.
---@nodiscard
function getfenv(f?: integer|function): table<string, any> end

---If object does not have a metatable, returns nil. Otherwise, if the object's metatable has a __metatable field, returns the associated value. Otherwise, returns the metatable of the given object.
---@nodiscard
function getmetatable(object: any): lye.Metatable<any>? end

---Returns three values (an iterator function, the table `t`, and `0`) so that the construction
---```lua
---    for i,v in ipairs(t) do body end
---```
---will iterate over the key–value pairs `(1,t[1]), (2,t[2]), ...`, up to the first absent index.
---
---@return fun(table: V[], i?: integer):integer, V
---@return T
---@return integer i
function ipairs<T: table, V>(t: T) end

---@alias loadmode
---| "b"  # Only binary chunks.
---| "t"  # Only text chunks.
---|>"bt" # Both binary and text.

---Loads a chunk.
---
---If `chunk` is a string, the chunk is this string. If `chunk` is a function, `load` calls it repeatedly to get the chunk pieces. Each call to `chunk` must return a string that concatenates with previous results. A return of an empty string, `nil`, or no value signals the end of the chunk.
---
---@return function?
---@return string?   error_message
---@nodiscard
function load(chunk: string|fun(): string?, chunkname?: string, mode?: loadmode, env?: table<string, any>) end

---Loads a chunk from file `filename` or from the standard input, if no file name is given.
---@return function?
---@return string?  error_message
---@nodiscard
function loadfile(filename?: string, mode?: loadmode, env?: table<string, any>) end

---Loads a chunk from the given string.
---@return function?
---@return string?   error_message
---@nodiscard
function loadstring(text: string, chunkname?: string) end

---@nodiscard
function newproxy(proxy: boolean|table|userdata): userdata end

---Creates a module.
function module(name: string, ...: any) end

---Allows a program to traverse all fields of a table. Its first argument is a table and its second argument is an index in this table. A call to `next` returns the next index of the table and its associated value. When called with `nil` as its second argument, `next` returns an initial index and its associated value. When called with the last index, or with `nil` in an empty table, `next` returns `nil`. If the second argument is absent, then it is interpreted as `nil`. In particular, you can use `next(t)` to check whether a table is empty.
---
---The order in which the indices are enumerated is not specified, *even for numeric indices*. (To traverse a table in numerical order, use a numerical `for`.)
---
---The behavior of `next` is undefined if, during the traversal, you assign any value to a non-existent field in the table. You may however modify existing fields. In particular, you may set existing fields to nil.
---
---@return K?
---@return V?
---@nodiscard
function next<K, V>(table: table<K, V>, index?: K) end

---If `t` has a metamethod `__pairs`, calls it with t as argument and returns the first three results from the call.
---
---Otherwise, returns three values: the `next` function, the table `t`, and `nil`, so that the construction
---```lua
---    for k,v in pairs(t) do body end
---```
---will iterate over all key–value pairs of table `t`.
---
---See function `next` for the caveats of modifying the table during its traversal.
---
---@return fun(table: table<K, V>, index?: K):K, V
---@return T
function pairs<T: table, K, V>(t: T) end

---Calls the function `f` with the given arguments in *protected mode*. This means that any error inside `f` is not propagated; instead, `pcall` catches the error and returns a status code. Its first result is the status code (a boolean), which is true if the call succeeds without errors. In such case, `pcall` also returns all results from the call, after this first result. In case of any error, `pcall` returns `false` plus the error object.
---
---@return boolean success
---@return any result
---@return any ...
function pcall(f: function, arg1?: any, ...: any) end

---Receives any number of arguments and prints their values to `stdout`, converting each argument to a string following the same rules of `tostring.`
---The function print is not intended for formatted output, but only as a quick way to show a value, for instance for debugging. For complete control over the output, use `string.format` and `io.write.`
---
function print(...: any) end

---Checks whether v1 is equal to v2, without invoking the `__eq` metamethod.
---@nodiscard
function rawequal(v1: any, v2: any): boolean end

---Gets the real value of `table[index]`, without invoking the `__index` metamethod.
---@nodiscard
function rawget<K, V>(table: table<K, V>, index: K): V? end


---Sets the real value of `table[index]` to `value`, without using the `__newindex` metavalue. `table` must be a table, `index` any value different from `nil` and `NaN`, and `value` any Lua value.
---This function returns `table`.
---
function rawset<K, V>(table: table<K, V>, index: K, value: V): table<K, V> end

---If `index` is a number, returns all arguments after argument number `index`; a negative number indexes from the end (`-1` is the last argument). Otherwise, `index` must be the string `"#"`, and `select` returns the total number of extra arguments it received.
---@nodiscard
function select(index: integer|"#", ...: any): any end

---Sets the environment to be used by the given function.
function setfenv(f: function|integer, table: table<string, any>): function end



---Sets the metatable for the given table. If `metatable` is `nil`, removes the metatable of the given table. If the original metatable has a `__metatable` field, raises an error.
---
---This function returns `table`.
---
---To change the metatable of other types from Lua code, you must use the debug library (§6.10).
---
function setmetatable<T: table>(table: T, metatable?: lye.Metatable<table>): T end

---When called with no `base`, `tonumber` tries to convert its argument to a number. If the argument is already a number or a string convertible to a number, then `tonumber` returns this number; otherwise, it returns `fail`.
---
---The conversion of strings can result in integers or floats, according to the lexical conventions of Lua (see §3.1). The string may have leading and trailing spaces and a sign.
---
---@overload fun(e: string, base: integer):integer
---@nodiscard
function tonumber(e: any): number? end

---Receives a value of any type and converts it to a string in a human-readable format.
---
---If the metatable of `v` has a `__tostring` field, then `tostring` calls the corresponding value with `v` as argument, and uses the result of the call as its result. Otherwise, if the metatable of `v` has a `__name` field with a string value, `tostring` may use that string in its final result.
---
---For complete control of how numbers are converted, use `string.format.`
---
---@nodiscard
function tostring(v: any): string end

---@alias type
---| "nil"
---| "number"
---| "string"
---| "boolean"
---| "table"
---| "function"
---| "thread"
---| "userdata"
---| "cdata"

---Returns the type of its only argument, coded as a string. The possible results of this function are `"nil"` (a string, not the value `nil`), `"number"`, `"string"`, `"boolean"`, `"table"`, `"function"`, `"thread"`, `"userdata"`, and `"cdata"` (LuaJIT).
---
---@nodiscard
function type(v: any): type end

---A global variable (not a function) that holds a string containing the running Lua version.
_VERSION = "Lua 5.1"


---Calls function `f` with the given arguments in protected mode with a new message handler.
---@return boolean success
---@return any result
---@return any ...
function xpcall(f: function, msgh: fun(message: any): any, arg1?: any, ...: any) end

---Returns the elements from the given `list`. This function is equivalent to
---```lua
---    return list[i], list[i+1], ···, list[j]
---```
---
---@generic T...
---@return T...
---@nodiscard
function unpack(list: { [integer]: T }, i?: integer, j?: integer) end

---@generic T...
---@return T...
---@nodiscard
function unpack(list: { [integer]: T }) end
---@class lye.Metatable<T: table> the fields Lua consults for the operations a value does not
---@field __index? table|fun(self: T, key: any): any read a field the value does not have
---@field __newindex? table|fun(self: T, key: any, value: any) write a field the value does not have
---@field __add? fun(a: T, b: T): T
---@field __sub? fun(a: T, b: T): T
---@field __mul? fun(a: T, b: T): T
---@field __div? fun(a: T, b: T): T
---@field __mod? fun(a: T, b: T): T
---@field __pow? fun(a: T, b: T): T
---@field __unm? fun(self: T): T
---@field __concat? fun(a: T, b: T): string|T
---@field __len? fun(self: T): number
---@field __eq? fun(a: T, b: T): boolean
---@field __lt? fun(a: T, b: T): boolean
---@field __le? fun(a: T, b: T): boolean
---@field __call? fun(self: T, ...): any
---@field __tostring? fun(self: T): string
---@field __pairs? fun(self: T): fun(): any, any
---@field __metatable? any
---@field __mode? string
---@field __name? string
