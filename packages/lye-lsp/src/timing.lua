--[[
	How long the session spends on the work an editor waits for.

	An editor shows nothing a server has not answered yet. When the first file opens and colouring
	does not arrive, the useful question is whether the wait was the protocol, the workspace scan,
	one file's analysis or the token walk — and a profile taken after the fact cannot say which
	part of a session a sample belonged to. These marks can.

	They go to stderr rather than stdout: stdout is the protocol. `LYE_TIMING=1` adds the
	per-document marks a benchmark wants; the startup and workspace marks are always written, so a
	report from a user's editor has the numbers without asking them to reproduce it under a flag.
	The format is one line per mark and stable: `lye timing: label=12.3ms note`.
]]

local ffi = require("ffi")

local timing = {}

--- A clock that does not move backwards and counts wall time, which is what a user waits. `os.clock`
--- counts processor time and would call a scan that waited on `find` free. `clock_gettime` is not on
--- every system this ships to, and where it is missing the fallback is still monotonic enough for a
--- duration that spans one message.
local now
do
	local isOk = pcall(ffi.cdef, [[
		typedef struct { long tv_sec; long tv_nsec; } lye_timespec;
		int clock_gettime(int clk_id, lye_timespec *tp);
	]])
	local clock = isOk and ffi.os ~= "Windows" and pcall(function() return ffi.C.clock_gettime end)
	if clock then
		local CLOCK_MONOTONIC = 1
		local held = ffi.new("lye_timespec")
		now = function()
			if ffi.C.clock_gettime(CLOCK_MONOTONIC, held) ~= 0 then return os.clock() * 1000 end
			return tonumber(held.tv_sec) * 1000 + tonumber(held.tv_nsec) / 1e6
		end
	else
		now = function() return os.clock() * 1000 end
	end
end

--- When this module was loaded, which is the first moment the server's own cost is measurable:
--- the runtime and the command line are outside it.
local origin = now()

--- Whether the per-document marks are wanted. `LYE_TIMING=0` also turns off the always-on marks,
--- for a test suite that keeps its stderr quiet.
local detailed = os.getenv("LYE_TIMING") == "1"
local quiet = os.getenv("LYE_TIMING") == "0"

---@return number milliseconds since this module was loaded
function timing.elapsed()
	return now() - origin
end

---@return number milliseconds
function timing.now()
	return now()
end

--- Whether a caller should collect the numbers a mark would only throw away.
function timing.detailed()
	return detailed and not quiet
end

--- Write one mark, with the time it took measured from `started`.
---@param label string a stable, space-free name
---@param started number a `timing.now()` from before the work
---@param note string? anything else worth knowing, already formatted
function timing.mark(label, started, note)
	if quiet then return end
	io.stderr:write(string.format("lye timing: %s=%.1fms%s\n", label, now() - started,
		note and (" " .. note) or ""))
	io.stderr:flush()
end

--- Write one mark from the start of the process, for work whose beginning was module load.
---@param label string
---@param note string?
function timing.fromStart(label, note)
	timing.mark(label, origin, note)
end

--- A mark that benchmark runs want and an editor's log does not: one per keystroke is noise. The
--- note is a format and its arguments rather than a finished string, so a caller pays for
--- formatting only when the mark is written.
---@param label string
---@param started number
---@param fmt string?
function timing.detail(label, started, fmt, ...)
	if not detailed or quiet then return end
	timing.mark(label, started, fmt and string.format(fmt, ...) or nil)
end

return timing
