--[[
	Byte-exact stdio for the LSP transport.

	`io.stdin:read(n)` blocks until it has all `n` bytes, which deadlocks on a partial frame, and
	`io.stdout` on Windows rewrites `\n` as `\r\n`. Hence raw syscalls.
]]

local ffi = require("ffi")

ffi.cdef [[
	long read(int fd, void *buf, size_t count);
	long write(int fd, const void *buf, size_t count);
	int _setmode(int fd, int mode);
	int _read(int fd, void *buf, unsigned int count);
	int _write(int fd, const void *buf, unsigned int count);
	void exit(int status);
	struct pollfd { int fd; short events; short revents; };
	int poll(struct pollfd *fds, unsigned long nfds, int timeout);
	int usleep(unsigned int microseconds);
	void Sleep(unsigned int milliseconds);
	intptr_t _get_osfhandle(int fd);
	int lye_rpc_PeekNamedPipe(void *pipe, void *buffer, unsigned long size, unsigned long *read,
		unsigned long *available, unsigned long *left) __asm__("PeekNamedPipe");
	uint64_t lye_rpc_GetTickCount64(void) __asm__("GetTickCount64");
	void *lye_rpc_CreateWaitableTimerExW(void *attributes, const uint16_t *name, unsigned long flags,
		unsigned long access) __asm__("CreateWaitableTimerExW");
	int lye_rpc_SetWaitableTimer(void *timer, const int64_t *due, long period, void *routine, void *arg,
		int resume) __asm__("SetWaitableTimer");
	unsigned long lye_rpc_WaitForSingleObject(void *handle, unsigned long milliseconds)
		__asm__("WaitForSingleObject");
]]

local C = ffi.C

-- Windows' C runtime has the POSIX names only as aliases, and a compiled binary links a runtime
-- without them: `read` does not resolve there, and the server failed on its first message. The
-- underscored functions are the runtime's own, the same one `_setmode` below comes from.
local readFd, writeFd
if ffi.os == "Windows" then
	readFd = function(fd, buf, count) return C._read(fd, buf, count) end
	writeFd = function(fd, buf, count) return C._write(fd, buf, count) end
else
	readFd = function(fd, buf, count) return C.read(fd, buf, count) end
	writeFd = function(fd, buf, count) return C.write(fd, buf, count) end
end

-- Waiting for input with a bound is what lets the server coalesce a burst of keystrokes. A blocking
-- read cannot: the listener would sit in `read` while the debounce ran. The wait has to end the
-- moment a message arrives, or every request an editor sends during it waits the whole bound: on
-- Windows that was a `Sleep`, and the 400 ms pause before a collection held each inlay hint, code
-- action and highlight behind it, seconds in all after a keystroke. `poll` is what the other
-- systems have; Windows has no `poll` for a pipe, so there the pipe is asked how much it holds.
-- Every function above is declared for the checker to see; a symbol a platform does not have
-- resolves only when the call is made, and that call is guarded.
local HAS_POLL = ffi.os ~= "Windows"

-- The handle the runtime's fd 0 reads, which is the pipe an editor writes to.
local stdinHandle
if ffi.os == "Windows" then
	local O_BINARY = 0x8000
	C._setmode(0, O_BINARY)
	C._setmode(1, O_BINARY)
	stdinHandle = ffi.cast("void *", C._get_osfhandle(0))
end

--- How many bytes the Windows stdin pipe holds, or nothing when it cannot say: the editor has
--- closed it, or stdin is not a pipe at all (a file, a console).
---@return integer?
local function pipeHolds()
	local available = ffi.new("unsigned long[1]")
	if C.lye_rpc_PeekNamedPipe(stdinHandle, nil, 0, nil, available, nil) == 0 then return nil end
	return tonumber(available[0])
end

-- A `Sleep(1)` sleeps until the system's next timer tick, which is 15.6 ms unless some program has
-- raised the rate, and a message that arrives inside a wait waited that long for its answer. A
-- high-resolution waitable timer (Windows 10 1803 and later) keeps the millisecond it is asked
-- for without changing the rate for the rest of the system. Made on the first wait; where the
-- system has no such timer, the step is the `Sleep` it always was.
local CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x2
local TIMER_ALL_ACCESS = 0x1F0003
local INFINITE = 0xFFFFFFFF
local stepTimer ---@type ffi.cdata*|false|nil
-- One millisecond from now, in the timer's 100 ns units; negative is relative.
local STEP_DUE = ffi.new("int64_t[1]", -10000)

local function step()
	if stepTimer == nil then
		local made = C.lye_rpc_CreateWaitableTimerExW(nil, nil, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS)
		stepTimer = made ~= nil and made or false
	end
	if stepTimer and C.lye_rpc_SetWaitableTimer(stepTimer, STEP_DUE, 0, nil, nil, 0) ~= 0 then
		C.lye_rpc_WaitForSingleObject(stepTimer, INFINITE)
		return
	end
	C.Sleep(1)
end

local stdio = {}

stdio.EOF = -1

local BUFFER_SIZE = 65536

---@class lye.rpc.Chunk
---@field buf ffi.cdata*
---@field n integer how many bytes are held
---@field capacity integer how many bytes fit before the buffer has to grow
local Chunk = {}
Chunk.__index = Chunk

function Chunk.new()
	return setmetatable({
		buf = ffi.new("char[?]", BUFFER_SIZE), n = 0, capacity = BUFFER_SIZE,
	}, Chunk)
end

stdio.Chunk = Chunk

--- A message is not bounded by the buffer: an editor sends a whole document in one frame, so a
--- file larger than the buffer arrives as a frame larger than it. Doubling the buffer is what
--- lets the read keep making progress; stopping to report EOF instead is how a 70 KB file used
--- to end the process.
---@param chunk lye.rpc.Chunk
local function grow(chunk)
	local capacity = chunk.capacity * 2
	local buf = ffi.new("char[?]", capacity)
	---@cast buf ffi.cdata*
	ffi.copy(buf, chunk.buf, chunk.n)
	chunk.buf, chunk.capacity = buf, capacity
end

--- Only a read that returns nothing at all is the end of the stream, so a short read is
--- handled where it happens rather than being mistaken for one.
---@param chunk lye.rpc.Chunk
function stdio.read(chunk)
	if chunk.n == chunk.capacity then grow(chunk) end
	local got = tonumber(readFd(0, chunk.buf + chunk.n, chunk.capacity - chunk.n)) or 0
	if got <= 0 then return stdio.EOF end
	chunk.n += got
	return got
end

---@param chunk lye.rpc.Chunk
---@param from integer
---@param to integer
---@return string
function stdio.slice(chunk, from, to)
	return ffi.string(chunk.buf + (from - 1), to - from + 1)
end

---@param chunk lye.rpc.Chunk
---@param n integer
function stdio.consume(chunk, n)
	if n <= 0 then return end
	if n >= chunk.n then
		chunk.n = 0
		return
	end
	ffi.copy(chunk.buf, chunk.buf + n, chunk.n - n)
	chunk.n -= n
end

---@param s string
function stdio.write(s)
	local len, sent = #s, 0
	while sent < len do
		local wrote = tonumber(writeFd(1, ffi.cast("const char *", s) + sent, len - sent))
		assert(wrote > 0, "lye-rpc: write to stdout failed")
		sent += wrote
	end
end

---@param code integer
function stdio.exit(code)
	C.exit(code)
end

--- Wait until input is readable or `milliseconds` pass. True means a read will make progress (or
--- report end of stream); false means the deadline passed with nothing waiting.
---@param milliseconds integer
---@return boolean readable
function stdio.wait(milliseconds)
	if milliseconds < 0 then return false end
	if HAS_POLL then
		local fds = ffi.new("struct pollfd[1]")
		fds[0].fd, fds[0].events = 0, 1 -- POLLIN
		local ready = tonumber(C.poll(fds, 1, milliseconds)) or 0
		return ready > 0
	end
	if ffi.os == "Windows" then
		-- A pipe cannot be waited on, so it is asked once a millisecond. Only a debounce waits here,
		-- and it is bounded: an idle server is in `read`, which blocks.
		local deadline = C.lye_rpc_GetTickCount64() + milliseconds
		repeat
			local holds = pipeHolds()
			-- Nothing to ask is something to read: the end of the stream, or a file or console that
			-- `read` answers by itself.
			if holds == nil or holds > 0 then return true end
			step()
		until C.lye_rpc_GetTickCount64() >= deadline
		return false
	end
	C.usleep(milliseconds * 1000)
	return false
end

--- Whether a read would make progress now. A zero timeout is the check, not a wait; the caller
--- uses it to leave a pause for later when the editor is already sending the next key.
---@return boolean readable
function stdio.readable()
	if ffi.os == "Windows" then
		-- A pipe the editor has closed says nothing, like a hung-up one does to `poll` below: the
		-- session is ending, not an editor about to send a key, and the work can run.
		local holds = pipeHolds()
		return holds ~= nil and holds > 0
	end
	if not HAS_POLL then return false end
	local fds = ffi.new("struct pollfd[1]")
	fds[0].fd, fds[0].events = 0, 1 -- POLLIN
	local ready = tonumber(C.poll(fds, 1, 0)) or 0
	-- A hung-up stream is not an editor about to send a key: it is the end of the session, and
	-- the work can run.
	return ready > 0 and (fds[0].revents % 2) == 1
end

return stdio
