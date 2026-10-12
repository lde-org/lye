---@meta ffi

---@class ffilib
---@field C    ffi.namespace* the C namespace: what a `cdef` declared, reached by name
---@field arch 'x86'|'x64'|'arm'|'arm64'|'arm64be'|'ppc'|'ppc64'|'ppc64le'|'mips'|'mipsel'|'mips64'|'mips64el'|string
---@field os   'Windows'|'Linux'|'OSX'|'BSD'|'POSIX'|'Other'|string
ffi = {}

---@class ffi.namespace*: table
---@field [string] function

---@class ffi.ctype*: userdata
---@overload fun(init?: any, ...): ffi.cdata*
---@overload fun(nelem?: integer, init?: any, ...): ffi.cdata*
local ctype

---@class ffi.cdecl*: string
---@class ffi.cdata*: userdata
---@alias ffi.ct*     ffi.ctype*|ffi.cdecl*|ffi.cdata*
---@class ffi.cb*:    ffi.cdata*
local cb
---@class ffi.VLA*:   userdata
---@class ffi.VLS*:   userdata

---A C number: cdata the engine gives arithmetic and the comparisons to. A value of one of the
---scalar types below is one of these, and a reader of `size * nmemb` is owed the metamethods that
---make that arithmetic legal rather than being told the operands are not numbers.
---@class ffi.cnum*: ffi.cdata
---@field __add fun(self: ffi.cnum*, other: any): ffi.cnum*
---@field __sub fun(self: ffi.cnum*, other: any): ffi.cnum*
---@field __mul fun(self: ffi.cnum*, other: any): ffi.cnum*
---@field __div fun(self: ffi.cnum*, other: any): ffi.cnum*
---@field __mod fun(self: ffi.cnum*, other: any): ffi.cnum*
---@field __pow fun(self: ffi.cnum*, other: any): ffi.cnum*
---@field __unm fun(self: ffi.cnum*): ffi.cnum*
---@field __eq fun(self: ffi.cnum*, other: any): boolean
---@field __lt fun(self: ffi.cnum*, other: any): boolean
---@field __le fun(self: ffi.cnum*, other: any): boolean
---@field __concat fun(self: ffi.cnum*, other: any): string
---@field __tostring fun(self: ffi.cnum*): string

---The C scalars by name, so a header's types can be written down. A 64-bit one is handed over as a
---cdata and a narrower one as a Lua number — that is what the engine does, and it is why a `size_t`
---is an `ffi.size_t` while an `int` is a `number`.
---@class ffi.char: ffi.cnum*
---@class ffi.short: ffi.cnum*
---@class ffi.int: ffi.cnum*
---@class ffi.long: ffi.cnum*
---@class ffi.longlong: ffi.cnum*
---@class ffi.unsigned: ffi.cnum*
---@class ffi.ulong: ffi.cnum*
---@class ffi.ulonglong: ffi.cnum*
---@class ffi.int8_t: ffi.cnum*
---@class ffi.int16_t: ffi.cnum*
---@class ffi.int32_t: ffi.cnum*
---@class ffi.int64_t: ffi.cnum*
---@class ffi.uint8_t: ffi.cnum*
---@class ffi.uint16_t: ffi.cnum*
---@class ffi.uint32_t: ffi.cnum*
---@class ffi.uint64_t: ffi.cnum*
---@class ffi.size_t: ffi.cnum*
---@class ffi.ssize_t: ffi.cnum*
---@class ffi.ptrdiff_t: ffi.cnum*
---@class ffi.intptr_t: ffi.cnum*
---@class ffi.uintptr_t: ffi.cnum*
---@class ffi.float: ffi.cnum*
---@class ffi.double: ffi.cnum*
---@class ffi.wchar_t: ffi.cnum*
---@class ffi.bool: ffi.cdata

---An array of C values: what `ffi.new("int[4]")` gives and what a `T name[N]` member is. It is
---indexed with a number, which is the one thing an array does that no other cdata does, and the
---length the header wrote is carried as the second argument.
---@class ffi.array<T, const N: integer>: ffi.cdata
---@field [integer] T

---A pointer to a C value: what `ffi.new("int *")` gives, what a callback receives where the header
---wrote a pointer, and what going through a pointer reads. Like an array it is indexed with a
---number, and it is not the value it points at.
---@class ffi.ptr<T: ffi.cdata*>: ffi.cdata
---@field [integer] T



---@class ffilib
---@field C    ffi.namespace*
---@field os   string
---@field arch string
local ffi = {}

---@param def     string
---@param params? any
function ffi.cdef(def, params, ...) end

---@param name    string
---@param global? boolean
---@return ffi.namespace* clib
---@nodiscard
function ffi.load(name, global) end

---@overload fun(ct: ffi.ct*, init: any, ...)
---@param ct     ffi.ct*
---@param nelem? integer
---@param init?  any
---@return ffi.cdata* cdata
---@nodiscard
function ffi.new(ct, nelem, init, ...) end

---@param ct      ffi.ct*
---@param params? any
---@return ffi.ctype* ctype
---@nodiscard
function ffi.typeof(ct, params, ...) end

---@param ct   ffi.ct*
---@param init any
---@return ffi.cdata* cdata
---@nodiscard
function ffi.cast(ct, init) end

---@param ct        ffi.ct*
---@param metatable table
---@return ffi.ctype* ctype
function ffi.metatype(ct, metatable) end

---@generic T: ffi.cdata*
---@param cdata T
---@param finalizer? fun(obj: T)
---@return T cdata
function ffi.gc(cdata, finalizer) end

---@param ct     ffi.ct*
---@param nelem? integer
---@return integer|nil size
---@nodiscard
function ffi.sizeof(ct, nelem) end

---@param ct ffi.ct*
---@return integer align
---@nodiscard
function ffi.alignof(ct) end

---@param ct    ffi.ct*
---@param field string
---@return integer  ofs
---@return integer? bpos
---@return integer? bsize
---@nodiscard
function ffi.offsetof(ct, field) end

---@param ct  ffi.ct*
---@param obj any
---@return boolean status
---@nodiscard
function ffi.istype(ct, obj) end

---@param newerr? integer
---@return integer err
---@nodiscard
function ffi.errno(newerr) end

---@param ptr  ffi.cdata*|string
---@param len? integer
---@return string str
function ffi.string(ptr, len) end

---@overload fun(dst: ffi.cdata*, str: string)
---@param dst ffi.cdata*
---@param src ffi.cdata*|string
---@param len integer
function ffi.copy(dst, src, len) end

---@param dst ffi.cdata*
---@param len integer
---@param c?  any
function ffi.fill(dst, len, c) end

---@param param string
---@return boolean status
function ffi.abi(param) end

---A table describing a C type: how large it is, how it is aligned, what it is an array or a
---pointer of, and the names and offsets of its fields.
---@param ct ffi.ct*
---@param ... any
---@return table info
---@nodiscard
function ffi.typeinfo(ct, ...) end

function cb:free() end

---@param func function
function cb:set(func) end

return ffi
