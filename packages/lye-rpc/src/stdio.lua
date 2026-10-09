--[[
	Byte-exact stdio for the LSP transport.

	`io.stdin:read(n)` blocks until it has all `n` bytes, which deadlocks on a partial
	frame, and `io.stdout` on Windows rewrites `\n` as `\r\n`. Hence raw syscalls.
]]

local ffi = require("ffi")

ffi.cdef [[
	long read(int fd, void *buf, size_t count);
	long write(int fd, const void *buf, size_t count);
	int _setmode(int fd, int mode);
	void exit(int status);
]]

local C = ffi.C

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
---@field n integer
local Chunk = {}
Chunk.__index = Chunk

---@return lye.rpc.Chunk
function Chunk.new()
	return setmetatable({ buf = ffi.new("char[?]", BUFFER_SIZE), n = 0 }, Chunk)
end

stdio.Chunk = Chunk

---@return integer
function stdio.read(chunk)
	if chunk.n == BUFFER_SIZE then return stdio.EOF end
	local got = tonumber(C.read(0, chunk.buf + chunk.n, BUFFER_SIZE - chunk.n))
	if got <= 0 then return stdio.EOF end
	chunk.n += got
	return got
end

---@return string
function stdio.slice(chunk, from, to)
	return ffi.string(chunk.buf + (from - 1), to - from + 1)
end

function stdio.consume(chunk, n)
	if n <= 0 then return end
	if n >= chunk.n then
		chunk.n = 0
		return
	end
	ffi.copy(chunk.buf, chunk.buf + n, chunk.n - n)
	chunk.n -= n
end

function stdio.write(s)
	local len, sent = #s, 0
	while sent < len do
		local wrote = tonumber(C.write(1, ffi.cast("const char *", s) + sent, len - sent))
		assert(wrote > 0, "lye-rpc: write to stdout failed")
		sent += wrote
	end
end

function stdio.exit(code)
	C.exit(code)
end

return stdio
