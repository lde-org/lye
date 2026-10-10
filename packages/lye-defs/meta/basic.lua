---@meta _

---Command-line arguments of Lua Standalone.
---@type string[]
arg = {}

---Raises an error if the value of its argument v is false (i.e., `nil` or `false`); otherwise, returns all its arguments. In case of error, `message` is the error object; when absent, it defaults to `"assertion failed!"`
---@generic T
---@param v? T
---@param message? any
---@param ... any
---@return T
---@return any ...
---@return v is -nil
function assert(v, message, ...) end

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





---Opens the named file and executes its content as a Lua chunk. When called without arguments, `dofile` executes the content of the standard input (`stdin`). Returns all values returned by the chunk. In case of errors, `dofile` propagates the error to its caller. (That is, `dofile` does not run in protected mode.)
---@param filename? string
---@return any ...
function dofile(filename) end

---Terminates the last protected function called and returns message as the error object.
---
---Usually, `error` adds some information about the error position at the beginning of the message, if the message is a string.
---
---@param message any
---@param level?  integer
---@return never
function error(message, level) end

---A global variable (not a function) that holds the global environment (see §2.2). Lua itself does not use this variable; changing its value does not affect any environment, nor vice versa.
---@class _G
_G = {}

---Returns the current environment in use by the function. `f` can be a Lua function or a number that specifies the function at that stack level.
---@param f? integer|async fun(...):...
---@return table
---@nodiscard
function getfenv(f) end

---If object does not have a metatable, returns nil. Otherwise, if the object's metatable has a __metatable field, returns the associated value. Otherwise, returns the metatable of the given object.
---@param object any
---@return table metatable
---@nodiscard
function getmetatable(object) end

---Returns three values (an iterator function, the table `t`, and `0`) so that the construction
---```lua
---    for i,v in ipairs(t) do body end
---```
---will iterate over the key–value pairs `(1,t[1]), (2,t[2]), ...`, up to the first absent index.
---
---@generic T: table, V
---@param t T
---@return fun(table: V[], i?: integer):integer, V
---@return T
---@return integer i
function ipairs(t) end

---@alias loadmode
---| "b"  # Only binary chunks.
---| "t"  # Only text chunks.
---|>"bt" # Both binary and text.

---Loads a chunk.
---
---If `chunk` is a string, the chunk is this string. If `chunk` is a function, `load` calls it repeatedly to get the chunk pieces. Each call to `chunk` must return a string that concatenates with previous results. A return of an empty string, `nil`, or no value signals the end of the chunk.
---
---@param chunk      string|function
---@param chunkname? string
---@param mode?      loadmode
---@param env?       table
---@return function?
---@return string?   error_message
---@nodiscard
function load(chunk, chunkname, mode, env) end

---Loads a chunk from file `filename` or from the standard input, if no file name is given.
---@param filename? string
---@param mode?     loadmode
---@param env?      table
---@return function?
---@return string?  error_message
---@nodiscard
function loadfile(filename, mode, env) end

---Loads a chunk from the given string.
---@param text       string
---@param chunkname? string
---@return function?
---@return string?   error_message
---@nodiscard
function loadstring(text, chunkname) end

---@param proxy boolean|table|userdata
---@return userdata
---@nodiscard
function newproxy(proxy) end

---Creates a module.
---@param name string
---@param ...  any
function module(name, ...) end

---Allows a program to traverse all fields of a table. Its first argument is a table and its second argument is an index in this table. A call to `next` returns the next index of the table and its associated value. When called with `nil` as its second argument, `next` returns an initial index and its associated value. When called with the last index, or with `nil` in an empty table, `next` returns `nil`. If the second argument is absent, then it is interpreted as `nil`. In particular, you can use `next(t)` to check whether a table is empty.
---
---The order in which the indices are enumerated is not specified, *even for numeric indices*. (To traverse a table in numerical order, use a numerical `for`.)
---
---The behavior of `next` is undefined if, during the traversal, you assign any value to a non-existent field in the table. You may however modify existing fields. In particular, you may set existing fields to nil.
---
---@generic K, V
---@param table table<K, V>
---@param index? K
---@return K?
---@return V?
---@nodiscard
function next(table, index) end

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
---@generic T: table, K, V
---@param t T
---@return fun(table: table<K, V>, index?: K):K, V
---@return T
function pairs(t) end

---Calls the function `f` with the given arguments in *protected mode*. This means that any error inside `f` is not propagated; instead, `pcall` catches the error and returns a status code. Its first result is the status code (a boolean), which is true if the call succeeds without errors. In such case, `pcall` also returns all results from the call, after this first result. In case of any error, `pcall` returns `false` plus the error object.
---
---@param f     async fun(...):...
---@param arg1? any
---@param ...   any
---@return boolean success
---@return any result
---@return any ...
function pcall(f, arg1, ...) end

---Receives any number of arguments and prints their values to `stdout`, converting each argument to a string following the same rules of `tostring.`
---The function print is not intended for formatted output, but only as a quick way to show a value, for instance for debugging. For complete control over the output, use `string.format` and `io.write.`
---
---@param ... any
function print(...) end

---Checks whether v1 is equal to v2, without invoking the `__eq` metamethod.
---@param v1 any
---@param v2 any
---@return boolean
---@nodiscard
function rawequal(v1, v2) end

---Gets the real value of `table[index]`, without invoking the `__index` metamethod.
---@param table table
---@param index any
---@return any
---@nodiscard
function rawget(table, index) end


---Sets the real value of `table[index]` to `value`, without using the `__newindex` metavalue. `table` must be a table, `index` any value different from `nil` and `NaN`, and `value` any Lua value.
---This function returns `table`.
---
---@param table table
---@param index any
---@param value any
---@return table
function rawset(table, index, value) end

---If `index` is a number, returns all arguments after argument number `index`; a negative number indexes from the end (`-1` is the last argument). Otherwise, `index` must be the string `"#"`, and `select` returns the total number of extra arguments it received.
---@param index integer|"#"
---@param ...   any
---@return any
---@nodiscard
function select(index, ...) end

---Sets the environment to be used by the given function.
---@param f     (async fun(...):...)|integer
---@param table table
---@return function
function setfenv(f, table) end


---@class metatable
---@field __mode 'v'|'k'|'kv'|nil
---@field __metatable any|nil
---@field __tostring (fun(t):string)|nil
---@field __gc fun(t)|nil
---@field __add (fun(t1,t2):any)|nil
---@field __sub (fun(t1,t2):any)|nil
---@field __mul (fun(t1,t2):any)|nil
---@field __div (fun(t1,t2):any)|nil
---@field __mod (fun(t1,t2):any)|nil
---@field __pow (fun(t1,t2):any)|nil
---@field __unm (fun(t):any)|nil
---@field __concat (fun(t1,t2):any)|nil
---@field __len (fun(t):integer)|nil
---@field __eq (fun(t1,t2):boolean)|nil
---@field __lt (fun(t1,t2):boolean)|nil
---@field __le (fun(t1,t2):boolean)|nil
---@field __index table|(fun(t,k):any)|nil
---@field __newindex table|fun(t,k,v)|nil
---@field __call (fun(t,...):...)|nil

---Sets the metatable for the given table. If `metatable` is `nil`, removes the metatable of the given table. If the original metatable has a `__metatable` field, raises an error.
---
---This function returns `table`.
---
---To change the metatable of other types from Lua code, you must use the debug library (§6.10).
---
---@generic T: table
---@param table      T
---@param metatable? lye.Metatable<table>
---@return T
function setmetatable(table, metatable) end

---When called with no `base`, `tonumber` tries to convert its argument to a number. If the argument is already a number or a string convertible to a number, then `tonumber` returns this number; otherwise, it returns `fail`.
---
---The conversion of strings can result in integers or floats, according to the lexical conventions of Lua (see §3.1). The string may have leading and trailing spaces and a sign.
---
---@overload fun(e: string, base: integer):integer
---@param e any
---@return number?
---@nodiscard
function tonumber(e) end

---Receives a value of any type and converts it to a string in a human-readable format.
---
---If the metatable of `v` has a `__tostring` field, then `tostring` calls the corresponding value with `v` as argument, and uses the result of the call as its result. Otherwise, if the metatable of `v` has a `__name` field with a string value, `tostring` may use that string in its final result.
---
---For complete control of how numbers are converted, use `string.format.`
---
---@param v any
---@return string
---@nodiscard
function tostring(v) end

---@alias type
---| "nil"
---| "number"
---| "string"
---| "boolean"
---| "table"
---| "function"
---| "thread"
---| "userdata"

---Returns the type of its only argument, coded as a string. The possible results of this function are `"nil"` (a string, not the value `nil`), `"number"`, `"string"`, `"boolean"`, `"table"`, `"function"`, `"thread"`, and `"userdata"`.
---
---@param v any
---@return type type
---@nodiscard
function type(v) end

---A global variable (not a function) that holds a string containing the running Lua version.
_VERSION = "Lua 5.1"


---Calls function `f` with the given arguments in protected mode with a new message handler.
---@param f     async fun(...):...
---@param msgh  function
---@param arg1? any
---@param ...   any
---@return boolean success
---@return any result
---@return any ...
function xpcall(f, msgh, arg1, ...) end

---Returns the elements from the given `list`. This function is equivalent to
---```lua
---    return list[i], list[i+1], ···, list[j]
---```
---
---@generic T...
---@param list { [integer]: T }
---@param i?   integer
---@param j?   integer
---@return T...
---@nodiscard
function unpack(list, i, j) end

---@generic T...
---@param list { [integer]: T }
---@return T...
---@nodiscard
function unpack(list) end
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
