---@meta string

---
---@class stringlib
string = {}

---Returns the internal numeric codes of the characters `s[i], s[i+1], ..., s[j]`.
---@nodiscard
function string.byte(s: string|number, i?: integer, j?: integer): integer ... end

---Returns a string with length equal to the number of arguments, in which each character has the internal numeric code equal to its corresponding argument.
---@nodiscard
function string.char(byte: integer, ...: integer): string end

---Returns a string containing a binary representation (a *binary chunk*) of the given function.
---@nodiscard
function string.dump(f: function, strip?: boolean): string end

---Looks for the first match of `pattern` (see §6.4.1) in the string.
---@return integer|nil start
---@return integer|nil end
---@return any|nil ... captured
---@nodiscard
function string.find(s: string|number, pattern: string|number, init?: integer, plain?: boolean) end

---Returns a formatted version of its variable number of arguments following the description given in its first argument.
---@nodiscard
function string.format(s: string|number, ...: any): string end

---Returns an iterator function. Each call to that iterator continues matching `pattern` (see §6.4.1) over s and returns all captures.
---
---The following example iterates over all words in string s, printing one per line:
---```lua
---    s =
---"hello world from Lua"
---    for w in string.gmatch(s, "%a+") do
---        print(w)
---    end
---```
---
---@return fun():string|number, ...
---@nodiscard
function string.gmatch(s: string|number, pattern: string|number) end

---Returns a copy of s where all occurrences of `pattern` (or the first n occurrences if n is given) are replaced by repl (see §6.4.1).
---@return string
---@return integer count
function string.gsub(s: string|number, pattern: string|number, repl: string|number|table<any, any>|fun(...: string|number): string|number|false|nil, n?: integer) end

---Returns its length.
---@nodiscard
function string.len(s: string|number): integer end

---Returns a copy of this string with all uppercase letters changed to lowercase.
---@nodiscard
function string.lower(s: string|number): string end

---Looks for the first match of `pattern` (see §6.4.1) in the string. If it finds one, `match` returns the captures; otherwise it returns nil.
---@nodiscard
function string.match(s: string|number, pattern: string|number, init?: integer): any ... end



---Returns a string that is the concatenation of `n` copies of the string `s` separated by the string `sep`.
---@nodiscard
function string.rep(s: string|number, n: integer, sep?: string|number): string end

---Returns a string that is the string `s` reversed.
---@nodiscard
function string.reverse(s: string|number): string end

---Returns the substring of the string that starts at `i` and continues until `j`.
---@nodiscard
function string.sub(s: string|number, i: integer, j?: integer): string end


---Returns a copy of this string with all lowercase letters changed to uppercase.
---@nodiscard
function string.upper(s: string|number): string end

return string
