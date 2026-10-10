--[[
	Derive lye's LuaJIT definitions from a LuaLS installation.

	A LuaLS meta file is a template: `---#if` guards pick the entries for an edition, `---#DES` and
	`---#DESTAIL` pull their documentation out of `locale/en-us/meta.lua`, and `DISABLE()` says the
	whole file belongs to another edition. lye targets LuaJIT, so `VERSION` is 5.1 and `JIT` is true,
	and every guard is decided rather than carried.

	Both outputs are written: `meta/`, which is the editable copy this repository keeps, and
	`src/init.lua`, which embeds the same text so `lde compile` can produce a standalone binary.

	    lde run -C packages/lye-defs tools/derive.lua [luaLSRoot] [--check]

	With `--check` it reports what would change and writes nothing.
]]

--- Three entries are written differently from the template, because the difference is the point:
--- an analysis that knows `assert` narrows, that `error` does not come back and that
--- `setmetatable` answers with its metatable's class is worth more than an exact copy. Each
--- deviation is checked, so a template that changes shape fails loudly instead of drifting.
local DEVIATIONS = {
	basic = {
		{
			from = "---@param table      table\n---@param metatable? metatable|table\n---@return table\nfunction setmetatable(table, metatable) end",
			to = "---@generic T: table\n---@param table      T\n---@param metatable? lye.Metatable<table>\n---@return T\nfunction setmetatable(table, metatable) end",
		},
		{
			from = "---@return T\n---@return any ...\nfunction assert(v, message, ...) end",
			to = "---@return T\n---@return any ...\n---@return v is -nil\nfunction assert(v, message, ...) end",
		},
		{
			from = "---@param level?  integer\nfunction error(message, level) end",
			to = "---@param level?  integer\n---@return never\nfunction error(message, level) end",
		},
		{
			-- Ten parameters and ten fields to imitate a tuple, where a variadic generic says the
			-- same thing in one line: `unpack` is `T...` however many values there are.
			from = "---@generic T1, T2, T3, T4, T5, T6, T7, T8, T9, T10\n---@param list {\n--- [1]?: T1,\n--- [2]?: T2,\n--- [3]?: T3,\n--- [4]?: T4,\n--- [5]?: T5,\n--- [6]?: T6,\n--- [7]?: T7,\n--- [8]?: T8,\n--- [9]?: T9,\n--- [10]?: T10,\n---}\n---@param i?   integer\n---@param j?   integer\n---@return T1, T2, T3, T4, T5, T6, T7, T8, T9, T10\n---@nodiscard\nfunction unpack(list, i, j) end",
			to = "---@generic T...\n---@param list { [integer]: T }\n---@param i?   integer\n---@param j?   integer\n---@return T...\n---@nodiscard\nfunction unpack(list, i, j) end",
		},
		{
			from = "---@generic T1, T2, T3, T4, T5, T6, T7, T8, T9\n---@param list {[1]: T1, [2]: T2, [3]: T3, [4]: T4, [5]: T5, [6]: T6, [7]: T7, [8]: T8, [9]: T9 }\n---@return T1, T2, T3, T4, T5, T6, T7, T8, T9\n---@nodiscard\nfunction unpack(list) end",
			to = "---@generic T...\n---@param list { [integer]: T }\n---@return T...\n---@nodiscard\nfunction unpack(list) end",
		},
	},
	ffi = {
		{
			-- A Lua string is what `ffi.string` casts from: the engine takes one directly, which is
			-- how `ffi.string("abc")` answers with itself.
			from = "---@param ptr  any",
			to = "---@param ptr  ffi.cdata*|string",
		},
		{
			-- `ffi.copy(dst, src, len)`: the destination is written to, so it is a cdata; the
			-- source may be a Lua string, which needs no length of its own.
			from = "---@param dst any\n---@param src any\n---@param len integer",
			to = "---@param dst ffi.cdata*\n---@param src ffi.cdata*|string\n---@param len integer",
		},
		{
			from = "---@overload fun(dst: any, str: string)",
			to = "---@overload fun(dst: ffi.cdata*, str: string)",
		},
		{
			-- `ffi.fill` writes bytes into memory, so there is nothing else it could fill.
			from = "---@param dst any\n---@param len integer",
			to = "---@param dst ffi.cdata*\n---@param len integer",
		},
		{
			-- The C scalars are named types: a reader annotating a header wants `ffi.size_t`, and
			-- the metamethods are what makes arithmetic on one legal to a type checker.
			from = "---@class ffi.VLS*:   userdata",
			to = "---@class ffi.VLS*:   userdata\n" .. [[

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
]],
		},
		{
			-- The one function whose argument and result are the same piece of data: `ffi.gc`
			-- hands back the cdata it was given, so a caller keeps the type it had.
			from = "---@param cdata     ffi.cdata*\n---@param finalizer? function\n---@return ffi.cdata* cdata",
			to = "---@generic T: ffi.cdata*\n---@param cdata T\n---@param finalizer? fun(obj: T)\n---@return T cdata",
		},
	},
}

--- What the type system needs to describe Lua itself rather than the library Lua ships with.
--- The template has no way to say "this table is a metatable", so the shape of one is written
--- here and carried by both outputs like any other definition.
local LYE_ONLY = {
	basic = [[
---@class lye.Metatable<T: table> the fields Lua consults for the operations a value does not
---@field __index? table|fun(self: T, key: any): any read a field the value does not have
---@field __newindex? table|fun(self: T, key: any, value: any) write a field the value does not have
---@field __add? fun(a: T, b: T): T
---@field __sub? fun(a: T, b: T): T
---@field __mul? fun(a: T, b: T): T
---@field __div? fun(a: T, b: T): T
---@field __mod? fun(a: T, b: T): T
---@field __pow? fun(a: T, b: T): T
---@field __unm? fun(self: T): T
---@field __concat? fun(a: T, b: T): string|T
---@field __len? fun(self: T): number
---@field __eq? fun(a: T, b: T): boolean
---@field __lt? fun(a: T, b: T): boolean
---@field __le? fun(a: T, b: T): boolean
---@field __call? fun(self: T, ...): any
---@field __tostring? fun(self: T): string
---@field __pairs? fun(self: T): fun(): any, any
---@field __metatable? any
---@field __mode? string
---@field __name? string
]],
}

---@param name string
---@param text string
---@return string
local function deviate(name, text)
	for _, change in ipairs(DEVIATIONS[name] or {}) do
		local found = text:find(change.from, 1, true)
		if not found then
			error(string.format("%s: the definitions no longer have:\n%s", name, change.from))
		end
		text = text:sub(1, found - 1) .. change.to .. text:sub(found + #change.from)
	end
	return text
end

--- LuaLS writes the numeric functions that only hand their argument back as
--- `@generic Number: number`, which is how it keeps `integer` distinct from `number`: the answer
--- is whatever was passed in. LuaJIT has no such distinction — `math.type` does not exist and
--- every number is a double — so the generic says nothing about the value a caller gets, and lye
--- binds a generic per call from the argument's *literal* type, which made `math.abs(-3)` the
--- literal `-3` and `math.max(1, 2)` the literal `1`. A program comparing either to the truth
--- would be told it is wrong.
---
--- The rule is structural rather than an exact rewrite: what has to go is the generic and the
--- name it introduces, not the whitespace a future template happens to put around the parameters.
---@param name string
---@param text string
---@return string
local function withoutNumberGeneric(name, text)
	if name ~= "math" then return text end
	local out, dropped = {}, 0
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line == "---@generic Number: number" then
			dropped += 1
		else
			-- Only in an annotation: the prose above a function is documentation, and the word
			-- there is not a type.
			out[#out + 1] = line:sub(1, 4) == "---@"
				and line:gsub("%f[%w]Number%f[%W]", "number")
				or line
		end
	end
	assert(dropped > 0, "math: no `Number` generic left to drop — has the template changed?")
	return table.concat(out, "\n")
end

local HERE = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE = assert(HERE:match("^(.*)/tools$"))

local VERSION = 5.1
local JIT = true

--- The known LuaLS installations, newest first, for when no root is given.
local DEFAULT_ROOTS = {
	"/home/once/.vscode/extensions/sumneko.lua-3.19.1-linux-x64/server",
	"/home/once/.local/share/zed/extensions/work/lua/lua-language-server-3.18.2",
}

---@param candidate string
---@return boolean
local function isLuaLS(candidate)
	local handle = io.open(candidate .. "/meta/template/basic.lua", "rb")
	if handle then
		handle:close()
		return true
	end
	return false
end

---@return string
local function findRoot()
	for _, candidate in ipairs(DEFAULT_ROOTS) do
		if isLuaLS(candidate) then return candidate end
	end
	error("no LuaLS installation found; pass its root directory")
end

--- A table that records what is assigned to it, and answers any read with one of its own: the
--- documentation is a plain Lua file of nested assignments (`loadmode.b = ...`, `load['<5.1'] =
--- ...`), and a key that does not start with a word character joins the one before it rather than
--- being nested under it, which is how `load['<5.1']` becomes the key the markers use.
---@param docs table<string, string>
---@param prefix string
---@return table
local function store(docs, prefix)
	---@param key any
	---@return string
	local function merge(key)
		key = tostring(key)
		if prefix == "" then return key end
		if key:sub(1, 1):match("%w") then return prefix .. "." .. key end
		return prefix .. key
	end
	return setmetatable({}, {
		__index = function(_, key) return store(docs, merge(key)) end,
		__newindex = function(_, key, value) docs[merge(key)] = value end,
	})
end

--- The documentation a `---#DES` or `---#DESTAIL` marker refers to, keyed by name. The file is
--- Lua: bare assignments into a table we provide, with an entry qualified by version written
--- `load['<5.1']`, which flattens to the key `load<5.1` the markers use.
---@param file string
---@return table<string, string>
local function readLocale(file)
	local handle = assert(io.open(file, "rb"), file)
	local text = handle:read("*a")
	handle:close()
	local docs = {}
	local loaded = loadstring(text, "@" .. file)
	assert(loaded, "the locale file does not compile: " .. file)
	setfenv(loaded, store(docs, ""))
	loaded()
	return docs
end

--- `$tostring` is how LuaLS's documentation refers to another entry: a link in its own editor, the
--- name of the thing in a reader's editor.
---@param text string
---@return string
local function plain(text)
	return (text:gsub("%$([%w_%.]+)", "`%1`"))
end

---@param condition string
---@return boolean
local function evaluate(condition)
	local chunk = loadstring(string.format("local VERSION, JIT = %s, %s return (%s)",
		tostring(VERSION), tostring(JIT), condition))
	if not chunk then error("cannot read the condition: " .. condition) end
	return chunk() == true
end

--- Whether a version selector describes this target. `---@version` writes only the comparison —
--- `>5.4`, `=5.1`, `<5.2`, `JIT`, `!JIT`, `5.1` — where the version number is understood on the
--- left, so the selector is completed into an expression before it is evaluated.
---@param selector string
---@return boolean
local function matchesVersion(selector)
	local text = (selector:gsub("^%s+", ""):gsub("%s+$", ""))
	if text == "" then return false end
	text = text:gsub("!", " not ")
	text = text:gsub("([<>=]+)%s*([%d%.]+)", "VERSION %1 %2")
	text = text:gsub("=(=?)", "==")
	if text:match("^[%d%.]+$") then text = "VERSION == " .. text end
	return evaluate(text)
end

--- Drop the entries whose `---@version` says another edition, together with the declaration they
--- annotate. The guards decide whole blocks; this decides single entries, and it is what keeps
--- `math.tointeger` and `math.type` — Lua 5.3 and up — out of a LuaJIT target that has neither.
---@param lines string[]
---@return string[]
local function dropForeignVersions(lines)
	local out, block, stated, wanted = {}, {}, false, false

	--- Decide the entry that has just ended: its annotations, and the declaration they describe.
	---@param declaration string?
	local function flush(declaration)
		if not stated or wanted then
			for _, held in ipairs(block) do
				-- The selector has been decided, so it is not carried: what is left is the entry as
				-- this edition reads it, which is what the definitions are for.
				if not held:match("^%-%-%-@version") then out[#out + 1] = held end
			end
			if declaration then out[#out + 1] = declaration end
		end
		block, stated, wanted = {}, false, false
	end

	for _, line in ipairs(lines) do
		local selectors = line:match("^%-%-%-@version%s+(.*)$")
		if selectors then
			stated = true
			for selector in selectors:gmatch("[^,]+") do
				if matchesVersion(selector) then wanted = true end
			end
		end

		if line:match("^%-%-") then
			block[#block + 1] = line
		elseif line:match("^%s*$") then
			flush(nil)
			out[#out + 1] = line
		else
			flush(line)
		end
	end
	flush(nil)
	return out
end

--- The value a definition names. A dotted path is a global first, and then a field of the module
--- the file describes: `jit.profile` declares `local profile = {}`, so `profile.start` is
--- `require("jit.profile").start`, and `util.funcinfo` is `require("jit.util").funcinfo`.
---@param file string the meta file, whose name is the module it describes
---@param name string
---@return any
local function resolveDefined(file, name)
	local first, rest = name:match("^([^.]+)%.(.*)$")
	local direct = _G
	for part in name:gmatch("[^.]+") do
		if type(direct) ~= "table" then
			direct = nil
			break
		end
		direct = direct[part]
	end
	if direct ~= nil then return direct end

	local isOk, module = pcall(require, file)
	if isOk and type(module) == "table" then
		if rest then return module[rest] end
		return module[first]
	end
end

--- Drop the entries the running engine does not have. LuaLS marks `table.pack` as `>5.2, JIT`
--- because the LuaJIT it targets was built with the 5.2 extensions; this one was not, and a
--- definition for a function that is not there is a completion that lies. The tool runs inside the
--- engine the server runs on, so it can simply ask.
---@param lines string[]
---@return string[], string[] dropped
local function dropMissingFunctions(file, lines)
	local out, block, gone = {}, {}, {}
	---@param declaration string?
	local function flush(declaration)
		local name = declaration and declaration:match("^function%s+([%w_%.]+)%s*%(")
		if name and not declaration:find(":", 1, true) and resolveDefined(file, name) == nil then
			gone[#gone + 1] = name
			block = {}
			return
		end
		for _, held in ipairs(block) do out[#out + 1] = held end
		if declaration then out[#out + 1] = declaration end
		block = {}
	end

	for _, line in ipairs(lines) do
		if line:match("^%-%-") then
			block[#block + 1] = line
		elseif line:match("^%s*$") then
			flush(nil)
			out[#out + 1] = line
		else
			flush(line)
		end
	end
	flush(nil)
	return out, gone
end

--- A template turned into the definitions lye reads, with its guards decided and its documentation
--- filled in. Returns nothing when the file belongs to another edition.
---@param source string the template
---@param docs table<string, string>
---@return string?
local function derive(name, source, docs)
	local lines = {}
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end

	-- A file guard says the whole file is another edition's: `utf8` is 5.2 and below, `bit32` is
	-- 5.2, and the LuaJIT modules are dropped when JIT is off.
	local guard, tail = (lines[1] or ""):match("^%-%-%-#if%s+(.-)%s+then%s*(.*)$")
	if guard and (tail or ""):match("^DISABLE%(%)") and evaluate(guard) then return nil end

	local out, active, stack = {}, true, {}
	---@param line string
	local function emit(line)
		if active then out[#out + 1] = line end
	end

	for index = 1, #lines do
		local line = lines[index]
		local condition, rest = line:match("^%-%-%-#if%s+(.-)%s+then%s*(.*)$")
		local elseIf = line:match("^%-%-%-#elseif%s+(.-)%s+then%s*$")
		if condition then
			if (rest or ""):match("^DISABLE%(%)") then
				-- `---#if <condition> then DISABLE() end`: the entry belongs to another edition and
				-- there is no `#end` to close it, so it decides on its own line and nothing else.
				active = active and not evaluate(condition)
			else
				stack[#stack + 1] = { parent = active, taken = false }
				local wanted = evaluate(condition)
				active = active and wanted
				stack[#stack].taken = wanted
			end
		elseif elseIf then
			local frame = assert(stack[#stack], "#elseif without #if")
			local wanted = not frame.taken and evaluate(elseIf)
			active = frame.parent and wanted
			frame.taken = frame.taken or wanted
		elseif line:match("^%-%-%-#else%s*$") then
			local frame = assert(stack[#stack], "#else without #if")
			active = frame.parent and not frame.taken
			frame.taken = true
		elseif line:match("^%-%-%-#end%s*$") then
			local frame = assert(table.remove(stack), "#end without #if")
			active = frame.parent
		else
			emit(line)
		end
	end
	if #stack > 0 then error("unclosed #if") end

	-- The entries another edition declares go first, so their documentation is never looked up.
	-- Then every marker is replaced by what it names: the documentation LuaLS shows for an entry.
	local kept = dropForeignVersions(out)
	local resolved, missing = {}, {}
	for _, line in ipairs(kept) do
		local des = line:match("^%-%-%-#DES%s+'(.-)'%s*$") or line:match('^%-%-%-#DES%s+"(.-)"%s*$')
		local tail = line:match("^.-%-%-%-#DESTAIL%s+'(.-)'")
		if des then
			local text = docs[des]
			if text then
				for part in (plain(text) .. "\n"):gmatch("([^\n]*)\n") do
					resolved[#resolved + 1] = "---" .. part
				end
			else
				missing[des] = true
			end
		elseif tail then
			local text = docs[tail]
			if text then
				-- The tail goes on one line, and the parentheses matter: `gsub` answers with the
				-- string and the number of replacements, and that number would be read as the
				-- *limit* of the outer call — which is zero when the text is one line already, so
				-- nothing would be replaced at all.
				local oneLine = (plain(text):gsub("%s*\n%s*", " "))
				resolved[#resolved + 1] = (line:gsub("%-%-%-#DESTAIL%s+'.+'", (oneLine:gsub("%%", "%%%%"))))
			else
				missing[tail] = true
			end
		else
			resolved[#resolved + 1] = line
		end
	end
	local absent = {}
	for key in pairs(missing) do absent[#absent + 1] = key end
	if #absent > 0 then
		table.sort(absent)
		io.stderr:write(string.format("no documentation for: %s\n", table.concat(absent, ", ")))
	end

	local kept2, gone = dropMissingFunctions(name, resolved)
	for _, entry in ipairs(gone) do
		io.stderr:write(string.format("%s: %s is not in this engine\n", name, entry))
	end
	local text = table.concat(kept2, "\n"):gsub("\n+$", "") .. "\n"
	return withoutNumberGeneric(name, deviate(name, text))
		.. (LYE_ONLY[name] or "")
end

---@param text string
---@return string
local function embed(text)
	return "[==[\n" .. text .. "]==]"
end

---@param argv string[]
local function main(argv)
	local root, check = nil, false
	for _, argument in ipairs(argv) do
		if argument == "--check" then check = true else root = argument end
	end
	root = root or findRoot()

	local docs = readLocale(root .. "/locale/en-us/meta.lua")
	local templateDir = root .. "/meta/template"
	local listing = {}
	local pipe = assert(io.popen(string.format("ls %q", templateDir)))
	for entry in pipe:lines() do listing[#listing + 1] = entry end
	pipe:close()
	assert(#listing > 0, "no templates in " .. templateDir)

	local derived, dropped = {}, {}
	for _, entry in ipairs(listing) do
		local name = entry:match("^(.-)%.lua$")
		if name then
			local handle = assert(io.open(templateDir .. "/" .. entry, "rb"))
			local source = handle:read("*a")
			handle:close()
			local text = derive(name, source, docs)
			if text then
				derived[name] = text
			else
				dropped[#dropped + 1] = name
			end
		end
	end
	table.sort(dropped)

	local changes = 0
	for name, text in pairs(derived) do
		local target = PACKAGE .. "/src/meta/" .. name .. ".lua"
		local handle = io.open(target, "rb")
		local existing = handle and handle:read("*a")
		if handle then handle:close() end
		if existing ~= text then
			changes = changes + 1
			if not check then
				local write = assert(io.open(target, "wb"))
				write:write(text)
				write:close()
			end
		end
	end

	local names = {}
	for name in pairs(derived) do names[#names + 1] = name end
	table.sort(names)

	-- The entry point is a loader, not a copy of every definition: `build.lua` gathers `src/meta/`
	-- into the package's output, so the module is built rather than stored.
	-- A level-1 long bracket would end at the `]]` of the comment inside it, so this one is
	-- written at level two.
	local embeddedText = [==[--[[
	The LuaJIT definitions the analyzer parses, from the files in `src/meta/`.

	`build.lua` combines them into `defs.lua` in the output directory, which is this package's
	target: the module is written per library so that each can be read and edited on its own, and
	gathered at build time so that nothing in the repository has to be regenerated by hand.
]]

return require("lye-defs.defs")
]==]

	local target = PACKAGE .. "/src/init.lua"
	local handle = io.open(target, "rb")
	local existing = handle and handle:read("*a")
	if handle then handle:close() end
	local embeddedChanged = existing ~= embeddedText
	if embeddedChanged and not check then
		local write = assert(io.open(target, "wb"))
		write:write(embeddedText)
		write:close()
	end

	print(string.format("%s: %d definitions, %d dropped (%s), %d files rewritten%s",
		root, #names, #dropped, table.concat(dropped, " "), changes, check and " [check]" or ""))
	if check then
		print(string.format("entry point %s", embeddedChanged and "would change" or "is current"))
	end
end

main(arg)
