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
	void exit(int status);
	struct pollfd { int fd; short events; short revents; };
	int poll(struct pollfd *fds, unsigned long nfds, int timeout);
	int usleep(unsigned int microseconds);
	void Sleep(unsigned int milliseconds);
]]

local C = ffi.C

-- Waiting for input with a bound is what lets the server coalesce a burst of keystrokes. A blocking
-- read cannot: the listener would sit in `read` while the debounce ran. Both `poll` and the sleep
-- used where it is absent are declared above so the checker can see what the branches call; a
-- symbol a platform does not have resolves only when the call is made, and that call is guarded.
local HAS_POLL = ffi.os ~= "Windows"

if ffi.os == "Windows" then
	local O_BINARY = 0x8000
	C._setmode(0, O_BINARY)
	C._setmode(1, O_BINARY)
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
	local got = tonumber(C.read(0, chunk.buf + chunk.n, chunk.capacity - chunk.n)) or 0
	if got <= 0 then return stdio.EOF end
	chunk.n += got
	return got
end

---@param chunk lye.rpc.Chunk
---@param from integer
---@param to integer
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
		local wrote = tonumber(C.write(1, ffi.cast("const char *", s) + sent, len - sent))
		assert(wrote > 0, "lye-rpc: write to stdout failed")
		sent += wrote
	end
end

---@param code integer
function stdio.exit(code)
	C.exit(code)
end

--- Wait until input is readable or `milliseconds` pass. True means a read will make progress (or
--- report end of stream); false means the deadline passed with nothing waiting. A system without
--- `poll` sleeps the interval and reports the deadline, so the caller retries its work rather than
--- blocking input forever.
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
		C.Sleep(milliseconds)
	else
		C.usleep(milliseconds * 1000)
	end
	return false
end

--- Whether a read would make progress now. A zero timeout is the check, not a wait; the caller
--- uses it to leave a pause for later when the editor is already sending the next key.
---@return boolean readable
function stdio.readable()
	if not HAS_POLL then return false end
	local fds = ffi.new("struct pollfd[1]")
	fds[0].fd, fds[0].events = 0, 1 -- POLLIN
	local ready = tonumber(C.poll(fds, 1, 0)) or 0
	-- A hung-up stream is not an editor about to send a key: it is the end of the session, and
	-- the work can run.
	return ready > 0 and (fds[0].revents % 2) == 1
end

return stdio
