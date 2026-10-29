---@meta jit

---@class jitlib
---@field version     string
---@field version_num number
---@field os          'Windows'|'Linux'|'OSX'|'BSD'|'POSIX'|'Other'
---@field arch        'x86'|'x64'|'arm'|'arm64'|'arm64be'|'ppc'|'ppc64'|'ppc64le'|'mips'|'mipsel'|'mips64'|'mips64el'|string
---@field opt table<string, fun(...: any): any> JIT compiler options
jit = {}

function jit.on(func?: function, recursive?: boolean) end
function jit.off(func?: function, recursive?: boolean) end

---@overload fun(tr: number)
function jit.flush(func?: function, recursive?: boolean) end

---@return boolean status
---@return string ...
---@nodiscard
function jit.status() end

---Attaches a callback to a JIT event — `jit.attach(fn, "trace")` calls `fn` for every trace the
---engine records — and detaches the one a name was attached under when no event is given.
---@return boolean ok
---@nodiscard
function jit.attach(callback: function, event?: 'trace'|'record'|'texit'|'function', ...: any) end

---Whether a security option is on, as the number the engine answers with: `jit.security("prng")`
---and `jit.security("strhash")`. The second argument is accepted and ignored — this engine reads
---the option rather than setting it — and any other name is refused.
---@nodiscard
function jit.security(option: "prng"|"strhash", value?: boolean): integer end

jit.opt = {}

function jit.opt.start(...: string|integer) end

return jit
