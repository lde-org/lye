---@meta io

---
---@class iolib
---standard input.
---@field stdin  file*
---standard output.
---@field stdout file*
---standard error.
---@field stderr file*
io = {}

---@alias openmode
---|>"r"   # Read mode.
---| "w"   # Write mode.
---| "a"   # Append mode.
---| "r+"  # Update mode, all previous data is preserved.
---| "w+"  # Update mode, all previous data is erased.
---| "a+"  # Append update mode, previous data is preserved, writing is only allowed at the end of file.
---| "rb"  # Read mode. (in binary mode.)
---| "wb"  # Write mode. (in binary mode.)
---| "ab"  # Append mode. (in binary mode.)
---| "r+b" # Update mode, all previous data is preserved. (in binary mode.)
---| "w+b" # Update mode, all previous data is erased. (in binary mode.)
---| "a+b" # Append update mode, previous data is preserved, writing is only allowed at the end of file. (in binary mode.)

---Close `file` or default output file.
---@return true?    suc
---@return string?  errmsg
---@return integer? errcode
function io.close(file?: file*) end

---Saves any written data to default output file.
---@return true?    suc
---@return string?  errmsg
---@return integer? errcode
function io.flush() end

---Sets `file` as the default input file.
function io.input(file?: string|file*): file* end

---------
---```lua
---for c in io.lines(filename, ...) do
---    body
---end
---```
---
---@return fun():any
function io.lines(filename?: string, ...: readmode) end

---Opens a file, in the mode specified in the string `mode`.
---@return file*?
---@return string?  errmsg
---@return integer? errcode
---@nodiscard
function io.open(filename: string, mode?: openmode) end

---Sets `file` as the default output file.
function io.output(file?: string|file*): file* end

---@alias popenmode
---| "r" # Read data from this program by `file`.
---| "w" # Write data to this program by `file`.

---Starts program prog in a separated process.
---@return file*?
---@return string?  errmsg
---@return integer? errcode
function io.popen(prog: string, mode?: popenmode) end

---Reads the `file`, according to the given formats, which specify what to read.
---@return any
---@return any ...
---@nodiscard
function io.read(...: readmode) end

---In case of success, returns a handle for a temporary file.
---@return file*?
---@return string?  errmsg
---@return integer? errcode
---@nodiscard
function io.tmpfile() end

---@alias filetype
---| "file"        # Is an open file handle.
---| "closed file" # Is a closed file handle.
---| `nil`         # Is not a file handle.

---Checks whether `obj` is a valid file handle.
---@nodiscard
function io.type(file: any): filetype end

---Writes the value of each of its arguments to default output file.
---@return true?    suc
---@return string?  errmsg
---@return integer? errcode
function io.write(...: string|number) end

---
---@class file*
local file = {}

---@alias readmode integer|string
---| "*n" # Reads a numeral and returns it as number.
---| "*a" # Reads the whole file.
---|>"*l" # Reads the next line skipping the end of line.
---| "*L" # Reads the next line keeping the end of line.

---Close `file`.
---@return true?    suc
---@return string?  errmsg
---@return integer? errcode
function file:close() end

---Saves any written data to `file`.
---@return true?    suc
---@return string?  errmsg
---@return integer? errcode
function file:flush() end

---------
---```lua
---for c in file:lines(...) do
---    body
---end
---```
---
---@return fun():any
function file:lines(...: readmode) end

---Reads the `file`, according to the given formats, which specify what to read.
---@return any
---@return any ...
---@nodiscard
function file:read(...: readmode) end

---@alias seekwhence
---| "set" # Base is beginning of the file.
---|>"cur" # Base is current position.
---| "end" # Base is end of file.

---Sets and gets the file position, measured from the beginning of the file.
---@return integer? offset
---@return string?  errmsg
---@return integer? errcode
function file:seek(whence?: seekwhence, offset?: integer) end

---@alias vbuf
---| "no"   # Output operation appears immediately.
---| "full" # Performed only when the buffer is full.
---| "line" # Buffered until a newline is output.

---Sets the buffering mode for an output file.
---@return true?    suc
---@return string?  errmsg
---@return integer? errcode
function file:setvbuf(mode: vbuf, size?: integer) end

---Writes the value of each of its arguments to `file`.
---@return true?    suc
---@return string?  errmsg
---@return integer? errcode
function file:write(...: string|number) end

return io
