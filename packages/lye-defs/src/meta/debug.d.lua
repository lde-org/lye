---@meta debug

---
---@class debuglib
debug = {}

---@class debuginfo
---@field name            string
---@field namewhat        string
---@field source          string
---@field short_src       string
---@field linedefined     integer
---@field lastlinedefined integer
---@field what            string
---@field currentline     integer
---@field nups            integer
---@field nparams         integer
---@field isvararg        boolean
---@field func            function
---@field activelines     table<integer, boolean>

---Enters an interactive mode with the user, running each string that the user enters.
function debug.debug() end

---Returns the environment of object `o` .
---@nodiscard
function debug.getfenv(o: any): table<string, any>? end

---Returns the current hook settings of the thread.
---@return fun(event: string, line: integer?)? hook
---@return string mask
---@return integer count
---@nodiscard
function debug.gethook(co?: thread) end

---@alias infowhat string
---|+"n"     # `name` and `namewhat`
---|+"S"     # `source`, `short_src`, `linedefined`, `lastlinedefined`, and `what`
---|+"l"     # `currentline`
---|+"u" # `nups`, `nparams`, and `isvararg`
---|+"f"     # `func`
---|+"L"     # `activelines`

---Returns a table with information about a function.
---@overload fun(f: integer|function, what?: infowhat):debuginfo
---@nodiscard
function debug.getinfo(thread: thread, f: integer|function, what?: infowhat): debuginfo end

---Returns the name and the value of the local variable with index `local` of the function at level `f` of the stack.
---@overload fun(f: integer|function, index: integer):string, any
---@return string name
---@return any    value
---@nodiscard
function debug.getlocal(thread: thread, f: integer|function, index: integer) end

---Returns the metatable of the given value.
---@nodiscard
function debug.getmetatable(object: any): lye.Metatable<any>? end

---Returns the registry table.
---@nodiscard
function debug.getregistry(): table end

---Returns the name and the value of the upvalue with index `up` of the function.
---@return string name
---@return any    value
---@nodiscard
function debug.getupvalue(f: function, up: integer) end



---Sets the environment of the given `object` to the given `table` .
function debug.setfenv<T>(object: T, env: table<string, any>): T end

---@alias hookmask string
---|+"c" # Calls hook when Lua calls a function.
---|+"r" # Calls hook when Lua returns from a function.
---|+"l" # Calls hook when Lua enters a new line of code.

---Sets the given function as a hook. With no hook, or a nil one, the hook is removed — and the
---thread may be named first, which is the only difference between the two shapes.
---@overload fun(hook: fun(event: string, line: integer?)?, mask?: hookmask, count?: integer)
---@overload fun(thread: thread?, hook: fun(event: string, line: integer?)?, mask?: hookmask, count?: integer)
function debug.sethook(thread: thread, hook: fun(event: string, line: integer?), mask: hookmask, count?: integer) end

---Assigns the `value` to the local variable with index `local` of the function at `level` of the stack.
---@overload fun(level: integer, index: integer, value: any):string
---@return string name
function debug.setlocal(thread: thread, level: integer, index: integer, value: any) end

---Sets the metatable for the given value to the given table (which can be `nil`).
function debug.setmetatable(value: any, meta?: lye.Metatable<any>): boolean end

---Assigns the `value` to the upvalue with index `up` of the function.
function debug.setupvalue(f: function, up: integer, value: any): string end


---Returns a string with a traceback of the call stack. The optional message string is appended at the beginning of the traceback.
---@overload fun(message?: any, level?: integer): string
---@nodiscard
function debug.traceback(thread: thread, message?: any, level?: integer): string end

---Returns a unique identifier (as a light userdata) for the upvalue numbered `n` from the given function.
---@nodiscard
function debug.upvalueid(f: function, n: integer): lightuserdata end

---Make the `n1`-th upvalue of the Lua closure `f1` refer to the `n2`-th upvalue of the Lua closure `f2`.
function debug.upvaluejoin(f1: function, n1: integer, f2: function, n2: integer) end

return debug
