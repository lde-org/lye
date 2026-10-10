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
---@field istailcall      boolean
---@field nups            integer
---@field nparams         integer
---@field isvararg        boolean
---@field func            function
---@field activelines     table

---Enters an interactive mode with the user, running each string that the user enters.
function debug.debug() end

---Returns the environment of object `o` .
---@param o any
---@return table
---@nodiscard
function debug.getfenv(o) end

---Returns the current hook settings of the thread.
---@param co? thread
---@return function hook
---@return string mask
---@return integer count
---@nodiscard
function debug.gethook(co) end

---@alias infowhat string
---|+"n"     # `name` and `namewhat`
---|+"S"     # `source`, `short_src`, `linedefined`, `lastlinedefined`, and `what`
---|+"l"     # `currentline`
---|+"t"     # `istailcall`
---|+"u" # `nups`, `nparams`, and `isvararg`
---|+"f"     # `func`
---|+"L"     # `activelines`

---Returns a table with information about a function.
---@overload fun(f: integer|function, what?: infowhat):debuginfo
---@param thread thread
---@param f      integer|async fun(...):...
---@param what?  infowhat
---@return debuginfo
---@nodiscard
function debug.getinfo(thread, f, what) end

---Returns the name and the value of the local variable with index `local` of the function at level `f` of the stack.
---@overload fun(f: integer|async fun(...):..., index: integer):string, any
---@param thread  thread
---@param f       integer|async fun(...):...
---@param index   integer
---@return string name
---@return any    value
---@nodiscard
function debug.getlocal(thread, f, index) end

---Returns the metatable of the given value.
---@param object any
---@return table metatable
---@nodiscard
function debug.getmetatable(object) end

---Returns the registry table.
---@return table
---@nodiscard
function debug.getregistry() end

---Returns the name and the value of the upvalue with index `up` of the function.
---@param f  async fun(...):...
---@param up integer
---@return string name
---@return any    value
---@nodiscard
function debug.getupvalue(f, up) end



---Sets the environment of the given `object` to the given `table` .
---@generic T
---@param object T
---@param env    table
---@return T object
function debug.setfenv(object, env) end

---@alias hookmask string
---|+"c" # Calls hook when Lua calls a function.
---|+"r" # Calls hook when Lua returns from a function.
---|+"l" # Calls hook when Lua enters a new line of code.

---Sets the given function as a hook.
---@overload fun(hook: (async fun(...):...), mask: hookmask, count?: integer)
---@overload fun(thread: thread):...
---@overload fun(...):...
---@param thread thread
---@param hook   async fun(...):...
---@param mask   hookmask
---@param count? integer
function debug.sethook(thread, hook, mask, count) end

---Assigns the `value` to the local variable with index `local` of the function at `level` of the stack.
---@overload fun(level: integer, index: integer, value: any):string
---@param thread thread
---@param level  integer
---@param index  integer
---@param value  any
---@return string name
function debug.setlocal(thread, level, index, value) end

---Sets the metatable for the given value to the given table (which can be `nil`).
---@generic T
---@param value T
---@param meta? table
---@return T value
function debug.setmetatable(value, meta) end

---Assigns the `value` to the upvalue with index `up` of the function.
---@param f     async fun(...):...
---@param up    integer
---@param value any
---@return string name
function debug.setupvalue(f, up, value) end


---Returns a string with a traceback of the call stack. The optional message string is appended at the beginning of the traceback.
---@overload fun(message?: any, level?: integer): string
---@param thread   thread
---@param message? any
---@param level?   integer
---@return string  message
---@nodiscard
function debug.traceback(thread, message, level) end

---Returns a unique identifier (as a light userdata) for the upvalue numbered `n` from the given function.
---@param f async fun(...):...
---@param n integer
---@return lightuserdata id
---@nodiscard
function debug.upvalueid(f, n) end

---Make the `n1`-th upvalue of the Lua closure `f1` refer to the `n2`-th upvalue of the Lua closure `f2`.
---@param f1 async fun(...):...
---@param n1 integer
---@param f2 async fun(...):...
---@param n2 integer
function debug.upvaluejoin(f1, n1, f2, n2) end

return debug
