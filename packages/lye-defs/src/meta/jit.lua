---@meta jit

---@class jitlib
---@field version     string
---@field version_num number
---@field os          'Windows'|'Linux'|'OSX'|'BSD'|'POSIX'|'Other'
---@field arch        'x86'|'x64'|'arm'|'arm64'|'arm64be'|'ppc'|'ppc64'|'ppc64le'|'mips'|'mipsel'|'mips64'|'mips64el'|string
jit = {}

---@param func?      function
---@param recursive? boolean
function jit.on(func, recursive)
end

---@param func?      function
---@param recursive? boolean
function jit.off(func, recursive)
end

---@overload fun(tr: number)
---@param func?      function
---@param recursive? boolean
function jit.flush(func, recursive)
end

---@return boolean status
---@return string ...
---@nodiscard
function jit.status()
end

---Attaches a callback to a JIT event — `jit.attach(fn, "trace")` calls `fn` for every trace the
---engine records — and detaches the one a name was attached under when no event is given.
---@param callback function
---@param event? 'trace'|'record'|'texit'|'function'
---@param ... any
---@return boolean ok
---@nodiscard
function jit.attach(callback, event, ...) end

---Whether a security option is on: `jit.security("prng")` and `jit.security("strhash")`.
---@param option string
---@return boolean on
---@nodiscard
function jit.security(option) end

jit.opt = {}

---@param ... string|integer flags
function jit.opt.start(...)
end

return jit
