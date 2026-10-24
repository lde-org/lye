---@meta coroutine

---
---@class coroutinelib
coroutine = {}

---Creates a new coroutine, with body `f`. `f` must be a function. Returns this new coroutine, an object with type `"thread"`.
---@nodiscard
function coroutine.create(f: function): thread end



---Starts or continues the execution of coroutine `co`.
---@return boolean success
---@return any ...
function coroutine.resume(co: thread, val1?: any, ...: any) end

---Returns the running coroutine, or nil when called by the main thread.
---@nodiscard
function coroutine.running(): thread? end

---Returns the status of coroutine `co`.
---@return
---| '"running"'   # Is running.
---| '"suspended"' # Is suspended or not started.
---| '"normal"'    # Is active but not running.
---| '"dead"'      # Has finished or stopped with an error.
---@nodiscard
function coroutine.status(co: thread) end

---Creates a new coroutine, with body `f`; `f` must be a function. Returns a function that resumes the coroutine each time it is called.
---@nodiscard
function coroutine.wrap(f: function): function end

---Suspends the execution of the calling coroutine.
function coroutine.yield(...: any): any ... end

return coroutine
