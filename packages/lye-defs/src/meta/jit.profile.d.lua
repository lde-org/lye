---@meta jit.profile

---@class jit.profile
local profile = {}

function profile.start(mode?: string, func: fun(L: thread, samples: integer, vmst: string)) end

function profile.stop() end

---@overload fun(th: thread, fmt: string, depth: integer): string
function profile.dumpstack(fmt: string, depth: integer): string end

return profile
