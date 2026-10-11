--[[
	A parser for the C a `ffi.cdef` call declares: the subset LuaJIT's own parser accepts.

	A declaration becomes a table naming what it declared, and `annotations` writes those out as
	`---@` classes so the analyzer can resolve `---@type Vec`. A declarator is read into a chain of
	wrappers ordered from the name outwards, then folded onto the base type from the inside out.
]]

local cdef = {}

---@class lye.cdef.Type
---@field kind string one of `void`, `bool`, `int`, `float`, `struct`, `union`, `enum`, `function`, `pointer`, `array`, `typedef`
---@field name string? the tag or typedef name this type was declared under
---@field tag string? the tag word a struct or union was written with, `struct` or `union`
---@field fields { name: string, type: lye.cdef.Type, bits: integer? }[]? members, in order
---@field target lye.cdef.Type? what a pointer points at, or an array holds
---@field length integer? an array's length, when it is a number
---@field returns lye.cdef.Type? a function's result
---@field params lye.cdef.Type[]? a function's parameters
---@field variadic boolean? the function takes `...`
---@field underlying lye.cdef.Type? what a typedef or an enum stands for
---@field isConst boolean?
---@field incomplete boolean? a tag with no body seen yet, which is what `struct Foo;` declares
---@field bitfield integer? a member's width in bits

---@class lye.cdef.Problem
---@field message string what went wrong, without the `cdef:` prefix
---@field start integer where it starts, in the text handed to `parse`
---@field stop integer where it ends, that token included

---@class lye.cdef.Namespace
---@field types table<string, lye.cdef.Type> every name a declaration introduced
---@field constants table<string, integer> the values an `enum` named
---@field order string[] the names in declaration order, which is the order to write them in
---@field problems lye.cdef.Problem[] what could not be read, so a reader can be told where
---@field text string the declaration text itself, which `spans` reads again for its tokens

--- The C scalars the engine hands Lua as cdata rather than as a Lua number, by the name each is
--- written with: 64 bits do not fit in a double, so a `long` or a `size_t` comes back as cdata.
local CDATA_SCALAR = {
	["long"] = "ffi.long", ["long long"] = "ffi.longlong",
	["unsigned long"] = "ffi.ulong", ["unsigned long long"] = "ffi.ulonglong",
	int64_t = "ffi.int64_t", uint64_t = "ffi.uint64_t", size_t = "ffi.size_t",
	ssize_t = "ffi.ssize_t", ptrdiff_t = "ffi.ptrdiff_t",
	intptr_t = "ffi.intptr_t", uintptr_t = "ffi.uintptr_t",
}

--- What each scalar C type is called in the definitions. Every one has a class there, whether
--- or not a value of it is handed over as a cdata.
local SCALAR_CLASS = {}
for name, class in pairs({
	["char"] = "ffi.char", ["short"] = "ffi.short", ["int"] = "ffi.int", ["long"] = "ffi.long",
	["long long"] = "ffi.longlong", ["unsigned"] = "ffi.unsigned", ["unsigned long"] = "ffi.ulong",
	["unsigned long long"] = "ffi.ulonglong", ["float"] = "ffi.float", ["double"] = "ffi.double",
	int8_t = "ffi.int8_t", int16_t = "ffi.int16_t", int32_t = "ffi.int32_t", int64_t = "ffi.int64_t",
	uint8_t = "ffi.uint8_t", uint16_t = "ffi.uint16_t", uint32_t = "ffi.uint32_t",
	uint64_t = "ffi.uint64_t", size_t = "ffi.size_t", ssize_t = "ffi.ssize_t",
	ptrdiff_t = "ffi.ptrdiff_t", intptr_t = "ffi.intptr_t", uintptr_t = "ffi.uintptr_t",
	wchar_t = "ffi.wchar_t", bool = "ffi.bool", ["_Bool"] = "ffi.bool",
}) do
	SCALAR_CLASS[name] = class
end

--- The words that shape a declaration rather than name anything in it. `struct`, `union`, `enum`
--- and `typedef` introduce one, and the qualifiers change how the type may be used.
local DECLARATION_WORD = {
	["struct"] = true, ["union"] = true, ["enum"] = true, ["typedef"] = true,
	["const"] = true, ["volatile"] = true, ["restrict"] = true, ["static"] = true,
	["extern"] = true, ["inline"] = true, ["register"] = true, ["auto"] = true,
	["_Noreturn"] = true, ["__attribute__"] = true, ["__declspec"] = true,
}

--- The builtin types, by the word they are written with. LuaJIT accepts the C99 and fixed-width
--- spellings, and treats `signed` and `unsigned` as part of the type.
local BUILTIN = {
	void = { kind = "void" },
	["_Bool"] = { kind = "bool" }, bool = { kind = "bool" },
	char = { kind = "int", name = "char" },
	short = { kind = "int", name = "short" },
	int = { kind = "int", name = "int" },
	long = { kind = "int", name = "long" },
	signed = { kind = "int", name = "int" },
	unsigned = { kind = "int", name = "unsigned" },
	float = { kind = "float", name = "float" },
	double = { kind = "float", name = "double" },
	int8_t = { kind = "int", name = "int8_t" }, uint8_t = { kind = "int", name = "uint8_t" },
	int16_t = { kind = "int", name = "int16_t" }, uint16_t = { kind = "int", name = "uint16_t" },
	int32_t = { kind = "int", name = "int32_t" }, uint32_t = { kind = "int", name = "uint32_t" },
	int64_t = { kind = "int", name = "int64_t" }, uint64_t = { kind = "int", name = "uint64_t" },
	intptr_t = { kind = "int", name = "intptr_t" }, uintptr_t = { kind = "int", name = "uintptr_t" },
	ptrdiff_t = { kind = "int", name = "ptrdiff_t" }, size_t = { kind = "int", name = "size_t" },
	ssize_t = { kind = "int", name = "ssize_t" }, wchar_t = { kind = "int", name = "wchar_t" },
}

--- Words that change how a type is used rather than what it is: read and dropped, because what
--- matters for an annotation is that the value is an integer.
local QUALIFIER = {
	const = true, volatile = true, restrict = true, register = true, extern = true,
	inline = true, static = true, auto = true, _Noreturn = true,
}

--- The operators a constant expression and a declaration may write in two characters. Without
--- these a tokenizer hands `<<` over as two `<`, which no level of the expression parser matches.
local DOUBLE = {
	["<<"] = true, [">>"] = true, ["&&"] = true, ["||"] = true, ["=="] = true, ["!="] = true,
	["<="] = true, [">="] = true, ["->"] = true, ["++"] = true, ["--"] = true,
}

--- Words an attribute may be written with, dropped with their parenthesised payload.
local ATTRIBUTE = { ["__attribute__"] = true, ["__declspec"] = true, ["__asm__"] = true }

---@param text string
---@return { kind: string, text: string, start: integer, stop: integer }[] tokens
local function tokenize(text)
	local tokens, i, n = {}, 1, #text
	while i <= n do
		local at = text:sub(i, i)
		if at:match("%s") then
			i += 1
		elseif text:sub(i, i + 1) == "/*" then
			local stop = text:find("*/", i + 2, true)
			local last = stop and (stop + 1) or n
			tokens[#tokens + 1] = { kind = "comment", text = text:sub(i, last), start = i, stop = last }
			i = last + 1
		elseif text:sub(i, i + 1) == "//" then
			local stop = text:find("\n", i + 2, true)
			local last = stop and (stop - 1) or n
			tokens[#tokens + 1] = { kind = "comment", text = text:sub(i, last), start = i, stop = last }
			i = last + 1
		elseif at == "#" then
			-- A preprocessor line is not part of what LuaJIT parses; skipping it keeps the rest of
			-- the header readable rather than failing on a `#if` nobody asked about.
			local stop = text:find("\n", i, true)
			i = stop and (stop + 1) or (n + 1)
		elseif at:match("[%a_]") then
			-- The branch is `at:match("[%a_]")`, so the pattern below always matches; the assert
			-- says so, and keeps the token's text a string for everything that reads it.
			local word = assert(text:match("^[%a_][%w_]*", i))
			tokens[#tokens + 1] = { kind = "name", text = word, start = i, stop = i + #word - 1 }
			i += #word
		elseif at:match("%d") or (at == "." and text:sub(i + 1, i + 1):match("%d")) then
			-- A number keeps the text it was written with: an array length is read back from it,
			-- and a hexadecimal one has to be read as what it spells.
			local number = text:match("^0[xX][%x]+", i) or text:match("^%d+%.?%d*[eE]?[%+%-]?%d*[fFlLuU]*", i)
				or text:match("^%.%d+[eE]?[%+%-]?%d*[fF]?", i)
			tokens[#tokens + 1] = { kind = "number", text = number, start = i, stop = i + #number - 1 }
			i += #number
		elseif text:sub(i, i + 2) == "..." then
			tokens[#tokens + 1] = { kind = "punct", text = "...", start = i, stop = i + 2 }
			i += 3
		elseif DOUBLE[text:sub(i, i + 1)] then
			tokens[#tokens + 1] = { kind = "punct", text = text:sub(i, i + 1), start = i, stop = i + 1 }
			i += 2
		else
			tokens[#tokens + 1] = { kind = "punct", text = at, start = i, stop = i }
			i += 1
		end
	end
	tokens[#tokens + 1] = { kind = "eof", text = "", start = n + 1, stop = n }
	return tokens
end

---@param tokens table[]
local function numberOf(tokens)
	local text = tokens.text:gsub("[uUlLfF]+$", "")
	if text:match("^0[xX]") then return tonumber(text) end
	local value = tonumber(text)
	return value and math.floor(value) or nil
end

---@class lye.cdef.Parser
---@field tokens table[]
---@field at integer
---@field namespace lye.cdef.Namespace
local Parser = {}
Parser.__index = Parser

---@return table
function Parser:peek()
	return self.tokens[self.at]
end

---@param offset integer?
---@return string
function Parser:word(offset)
	return (self.tokens[self.at + (offset or 0)] or {}).text or ""
end

---@param text string
---@return boolean
function Parser:accept(text)
	if self:word() == text then
		self.at += 1
		return true
	end
	return false
end

--- Record what could not be read and stop the declaration it was in. A header is often mostly
--- right, and the caller skips to the next `;` or `}` and carries on.
---@param message string
---@param token table?
function Parser:problem(message, token)
	local at = token or self:peek()
	self.problems[#self.problems + 1] = {
		message = message, start = at.start or 1, stop = at.stop or at.start or 0,
	}
	self.failed = true
end

---@param text string
---@return boolean
function Parser:expect(text)
	if self:accept(text) then return true end
	self:problem(string.format("expected `%s`, found `%s`", text, self:word()))
	return false
end

---@return string?
function Parser:name()
	local token = self:peek()
	if token.kind ~= "name" then
		self:problem(string.format("expected a name, found `%s`", token.text), token)
		return nil
	end
	self.at += 1
	return token.text
end

--- Record a name the declaration introduced, so a later declaration can refer to it.
---@param name string
---@param type lye.cdef.Type
function Parser:define(name, type)
	if not self.namespace.types[name] then self.namespace.order[#self.namespace.order + 1] = name end
	type.name = type.name or name
	self.namespace.types[name] = type
end

--- The binding levels of a constant expression, loosest first: what an array length or an enum
--- value may be written with.
local LEVELS = {
	{ "|" }, { "^" }, { "&" }, { "<<", ">>" }, { "+", "-" }, { "*", "/", "%" },
}

--- A constant expression, evaluated as it is parsed: array lengths and enum values are numbers a
--- reader wants, and `1 << 4` is as good as `16`.
---@param level integer?
---@return integer?
function Parser:expression(level)
	level = level or 1
	local function tighter(self_)
		if level > #LEVELS then return self_:unary() end
		return self_:expression(level + 1)
	end

	local value = tighter(self)
	if value == nil then return nil end
	while true do
		local matched
		for _, symbol in ipairs(LEVELS[level] or {}) do
			if self:word() == symbol then matched = symbol end
		end
		if not matched then break end
		self.at += 1
		local right = tighter(self)
		if right == nil then return nil end
		if matched == "|" then value = value | right
		elseif matched == "^" then value = value ~ right
		elseif matched == "&" then value = value & right
		elseif matched == "<<" then value = value << right
		elseif matched == ">>" then value = value >> right
		elseif matched == "+" then value = value + right
		elseif matched == "-" then value = value - right
		elseif matched == "*" then value = value * right
		elseif matched == "/" then value = value / right
		elseif matched == "%" then value = value % right end
	end
	return value
end

--- The smallest operands: a number, a constant an `enum` named earlier, or a parenthesised
--- expression. A name that is not a constant is not something this parser can evaluate.
function Parser:unary()
	local word = self:word()
	if word == "(" then
		self.at += 1
		local value = self:expression(1)
		self:expect(")")
		return value
	end
	if word == "-" or word == "~" or word == "+" then
		self.at += 1
		local value = self:unary()
		if value == nil then return nil end
		if word == "-" then return -value end
		if word == "~" then return ~value end
		return value
	end
	local token = self:peek()
	if token.kind == "number" then
		self.at += 1
		return numberOf(token)
	end
	if token.kind == "name" then
		self.at += 1
		return self.namespace.constants[token.text]
	end
	return nil
end

--- The type words a declaration starts with: `unsigned long int`, `const char`, `struct Foo`.
---@return lye.cdef.Type
function Parser:specifiers()
	local isConst, type
	while true do
		local word = self:word()
		if ATTRIBUTE[word] then
			self.at += 1
			if self:accept("(") then
				local depth = 1
				while depth > 0 do
					if self:accept("(") then depth += 1
					elseif self:accept(")") then depth -= 1
					else self.at += 1 end
				end
			end
		elseif word == "struct" or word == "union" then
			type = self:tagged(word)
		elseif word == "enum" then
			type = self:enumerated()
		elseif QUALIFIER[word] and word ~= "const" then
			self.at += 1
		elseif word == "const" then
			isConst = true
			self.at += 1
		elseif BUILTIN[word] then
			-- `typedef unsigned long size_t;` declares a name the builtin list also carries: with a
			-- type already read and nothing left but the declarator, the word is that name.
			local after = self:word(1)
			if type and (after == ";" or after == "," or after == ")") then break end
			self.at += 1
			-- `unsigned long long` is one type: the words combine rather than replace each other.
			if type and type.kind == "int" and BUILTIN[word].kind == "int" then
				type = { kind = "int", name = type.name .. " " .. word }
			else
				type = { kind = BUILTIN[word].kind, name = BUILTIN[word].name }
			end
		elseif word == "typedef" then
			self.at += 1
			self.isTypedef = true
		else
			break
		end
	end

	if not type then
		-- A name that is not a builtin is a type the header declared earlier.
		local word = self:word()
		local known = self.namespace.types[word]
		if not known then
			self:problem(string.format("unknown type `%s`", word), self:peek())
			self.at += 1
			return { kind = "unknown", name = word }
		end
		self.at += 1
		type = { kind = "typedef", name = word, underlying = known }
	end
	if isConst then type = { kind = type.kind, name = type.name, underlying = type.underlying,
		target = type.target, fields = type.fields, tag = type.tag, isConst = true, incomplete = type.incomplete } end
	return type
end

---@param tag string `struct` or `union`
---@return lye.cdef.Type
function Parser:tagged(tag)
	self.at += 1
	local name = self:peek().kind == "name" and self:name() or nil
	if not self:accept("{") then
		-- `struct Foo;` declares the name and nothing else, which is how a header hides its layout.
		-- The same words also spell a reference — `int tcgetattr(int fd, struct termios *t)` — and
		-- defining the forward over the definition dropped every field it had, so a struct mentioned
		-- by a function that takes one lost its members and read as unknown wherever it was used.
		local known = name and self.namespace.types[name]
		if known then return known end
		local forward = { kind = tag, tag = tag, name = name, incomplete = true }
		if name then self:define(name, forward) end
		return forward
	end

	local fields = {}
	while not self:accept("}") do
		local base = self:specifiers()
		if self:accept(";") then
			-- An unnamed struct or union member: its fields are the enclosing type's, which is a
			-- flattening LuaJIT does too, so the members are copied in.
			for _, field in ipairs(base.fields or {}) do
				fields[#fields + 1] = { name = field.name, type = field.type, bits = field.bits }
			end
		else
			while true do
				local fieldName, fieldType = self:declarator(base)
				local bits
				if self:accept(":") then bits = self:expression(1) end
				if not fieldName then break end
				fields[#fields + 1] = { name = fieldName, type = fieldType, bits = bits }
				if not self:accept(",") then break end
			end
			self:expect(";")
		end
	end
	-- The `;` is left for the caller: a member ends with one the member loop has to see, and a
	-- top-level declaration ends with one `declaration` takes.
	-- The `}` that closed the body is where this declaration ends. Clearing the failure here is
	-- what keeps the *next* declaration from being skipped as well.
	self.failed = false
	local declared = { kind = tag, tag = tag, name = name, fields = fields }
	if name then self:define(name, declared) end
	return declared
end

---@return lye.cdef.Type
function Parser:enumerated()
	self.at += 1
	local name = self:peek().kind == "name" and self:name() or nil
	if not self:accept("{") then
		local forward = { kind = "enum", name = name }
		if name then self:define(name, forward) end
		return forward
	end

	local nextValue = 0
	while not self:accept("}") do
		local constant = self:name()
		if self:accept("=") then
			local value = self:expression(1)
			if value then nextValue = value end
		end
		self.namespace.constants[constant] = nextValue
		nextValue += 1
		if not self:accept(",") then self:accept("}") break end
	end

	-- An enum's values are integers to the engine, so the enum itself gets no class: `enum Color`
	-- is a name for a number the header gave names to.
	local declared = { kind = "enum", name = name }
	if name then self:define(name, declared) end
	return declared
end

--- A declarator, read as the chain of wrappers ordered from the name outwards: this level's
--- suffixes, then its pointers, wrapped around whatever the name was nested in. The parentheses
--- are what the order turns on — `int *f(void)` is a function returning a pointer while
--- `int (*f)(void)` is a pointer to one — so the chain is folded outermost last.
---@return string? name
---@return table[] chain
function Parser:declaratorChain()
	local pointers = 0
	while true do
		local word = self:word()
		if word == "*" then
			self.at += 1
			pointers += 1
		elseif QUALIFIER[word] or ATTRIBUTE[word] then
			self.at += 1
			if word == "__attribute__" and self:accept("(") then
				local depth = 1
				while depth > 0 do
					if self:accept("(") then depth += 1
					elseif self:accept(")") then depth -= 1
					else self.at += 1 end
				end
			end
		else
			break
		end
	end

	local name, chain
	if self:accept("(") then
		name, chain = self:declaratorChain()
		self:expect(")")
	else
		chain = {}
		if self:peek().kind == "name" then name = self:name() end
	end

	local suffixes = {}
	while true do
		if self:accept("[") then
			local length
			if not self:accept("]") then
				length = self:expression(1)
				self:expect("]")
			end
			suffixes[#suffixes + 1] = { kind = "array", length = length }
		elseif self:accept("(") then
			local params, variadic = {}, false
			if not self:accept(")") then
				if self:word() == "void" and self:word(1) == ")" then
					self.at += 1
				else
					while true do
						if self:accept("...") then
							variadic = true
							break
						end
						local base = self:specifiers()
						local _, paramType = self:declarator(base)
						params[#params + 1] = paramType
						if not self:accept(",") then break end
					end
				end
				self:expect(")")
			end
			suffixes[#suffixes + 1] = { kind = "function", params = params, variadic = variadic }
		else
			break
		end
	end

	local out = {}
	for _, item in ipairs(chain) do out[#out + 1] = item end
	for _, item in ipairs(suffixes) do out[#out + 1] = item end
	for _ = 1, pointers do out[#out + 1] = { kind = "pointer" } end
	return name, out
end

--- Fold a chain onto the type the name stands for, from the inside out: the last wrapper is the
--- outermost, so it is applied last.
---@param base lye.cdef.Type
---@param chain table[]
local function fold(base, chain)
	for index = #chain, 1, -1 do
		local wrapper = chain[index]
		if wrapper.kind == "pointer" then
			base = { kind = "pointer", target = base }
		elseif wrapper.kind == "array" then
			base = { kind = "array", target = base, length = wrapper.length }
		else
			base = {
				kind = "function", returns = base, params = wrapper.params, variadic = wrapper.variadic,
			}
		end
	end
	return base
end

---@param base lye.cdef.Type
---@return string? name
---@return lye.cdef.Type
function Parser:declarator(base)
	local name, chain = self:declaratorChain()
	return name, fold(base, chain)
end

--- Skip to where the next declaration can start, so one unreadable line does not cost the rest of
--- the header. A brace is counted so a body that went wrong is left whole.
function Parser:recover()
	local depth = 0
	while self:peek().kind ~= "eof" do
		local word = self:word()
		if word == "{" then depth += 1
		elseif word == "}" then
			if depth == 0 then
				self.at += 1
				return
			end
			depth -= 1
		elseif word == ";" and depth == 0 then
			self.at += 1
			return
		end
		self.at += 1
	end
end

--- One declaration: a typedef, a struct, a union, an enum, a function or a variable.
function Parser:declaration()
	if self:accept(";") then return end
	self.isTypedef = false
	self.failed = false
	local base = self:specifiers()
	if self.failed then
		self:recover()
		return
	end
	if self:accept(";") then return end

	while true do
		local name, declared = self:declarator(base)
		if name then
			if self.isTypedef then
				self:define(name, { kind = "typedef", name = name, underlying = declared })
			else
				self:define(name, declared)
			end
		elseif self.failed then
			break
		end
		if not self:accept(",") then break end
	end
	if self.failed then
		self:recover()
		return
	end
	self:accept(";")
end

--- Parse the text of a `ffi.cdef` call. Nothing is raised: a declaration that cannot be read is
--- reported in `problems` and the rest of the header is still read.
---@param text string
function cdef.parse(text)
	assert(type(text) == "string", "cdef.parse expects a string")
	-- Comments are tokens so a reader can colour them, and not part of what is parsed: a
	-- declaration is the same with or without the prose beside it.
	local tokens = {}
	for _, token in ipairs(tokenize(text)) do
		if token.kind ~= "comment" then tokens[#tokens + 1] = token end
	end
	local self = setmetatable({
		tokens = tokens, at = 1, problems = {},
		namespace = { types = {}, constants = {}, order = {}, problems = {}, text = text },
	}, Parser)
	self.namespace.problems = self.problems
	while self:peek().kind ~= "eof" do
		local before = self.at
		self:declaration()
		-- A declaration that consumed nothing would spin: step over the token and go on.
		if self.at == before then self.at += 1 end
	end
	return self.namespace
end

--- Resolve a name to what it stands for: `size_t` is an integer, `Vec` is a struct, and a
--- typedef keeps following its own definitions until something concrete comes out.
---@param namespace lye.cdef.Namespace
---@param name string
---@return lye.cdef.Type?
function cdef.resolve(namespace, name)
	local seen, type = {}, namespace.types[name]
	while type do
		-- An array or a pointer written in a `typeof` string reaches the type it is made of.
		if type.kind ~= "typedef" then return type end
		if seen[type.name or name] then return type end
		seen[type.name or name] = true
		type = type.underlying
	end
end

--- Whether a value of a type is a cdata rather than a plain Lua number: a struct, a union, a
--- function or a pointer to a function, with typedefs followed to what they stand for.
---@param namespace lye.cdef.Namespace
---@param type lye.cdef.Type
---@return boolean
local function isCdata(namespace, type)
	local resolved = (type.name and cdef.resolve(namespace, type.name)) or type
	if resolved.kind == "struct" or resolved.kind == "union" then return true end
	if resolved.kind == "pointer" then
		local target = resolved.target
		while target and target.kind == "typedef" do
			target = cdef.resolve(namespace, target.name) or target
		end
		return target ~= nil and target.kind == "function"
	end
	return false
end

--- The type a string names, as a `ffi.typeof` or `ffi.new` writes one. A name the block never
--- declared is no type at all, which is what makes the string form of these calls checkable.
---@param namespace lye.cdef.Namespace
---@param text string
---@return lye.cdef.Type?
function cdef.typeOf(namespace, text)
	local ok, type = pcall(function()
		local self = setmetatable({ tokens = tokenize(text), at = 1, namespace = namespace }, Parser)
		local base = self:specifiers()
		local _, built = self:declarator(base)
		return built
	end)
	if not ok or not type then return nil end
	return type
end

--- The name a type is an instance of, looking through the pointers and arrays in front of it:
--- `Vec *` is a `Vec` written with a star, and that is the class a reader can name.
---@param type lye.cdef.Type
function cdef.className(type)
	local current = type
	while current and (current.kind == "pointer" or current.kind == "array") do
		current = current.target
	end
	return current and current.name
end

--- The annotation type for a C type, as the text a `---@field` or `---@type` is written with.
---
--- `where` says which side of a call the type is on, because the same C type means different things
--- there. A `char *` handed *to* Lua is a string as far as a reader is concerned — LuaJIT converts
--- both ways — while a `char *` handed *to C*, which is what a callback's parameter is, arrives as
--- the pointer it is, and code that treats it as a Lua string would be wrong.
---@param namespace lye.cdef.Namespace
---@param type lye.cdef.Type
---@param where string? `parameter` for a value crossing into C, otherwise a value read in Lua
---@return string
function cdef.notation(namespace, type, where)
	local kind = type.kind
	if kind == "typedef" then
		-- A typedef of a struct keeps its own name: `Vec` is what the header's users write, and
		-- the tag behind it may not even have one. A callback typedef keeps its name too: it is
		-- the type a `ffi.cast` is written with.
		local resolved = type.name and cdef.resolve(namespace, type.name)
		if resolved and isCdata(namespace, resolved) then return type.name end
		-- A typedef of a 64-bit scalar keeps its own name too: the header wrote `size_t` and a
		-- reader annotating with it gets the cdata type the engine hands over.
		if resolved and resolved.kind == "int" and CDATA_SCALAR[resolved.name or ""] then
			return type.name
		end
		if resolved and resolved.kind == "pointer" and resolved.target
			and resolved.target.kind == "function" then
			return type.name
		end
		return resolved and cdef.notation(namespace, resolved, where) or "ffi.cdata"
	end
	if kind == "array" then
		-- An array is indexed with a number and knows its length, which is what the C says. Its
		-- element is named as the C names it — a `char` array holds `ffi.char` — rather than as
		-- the Lua number a value read out of one would be.
		local held = SCALAR_CLASS[type.target and type.target.name or ""]
			or (type.target and cdef.notation(namespace, type.target, where))
		if type.length then return string.format("ffi.array<%s, %d>", held, type.length) end
		return string.format("ffi.array<%s>", held)
	end
	if kind == "pointer" then
		local target = type.target
		-- A pointer to a struct is the struct: LuaJIT reaches `p.x` through the pointer, and that
		-- is how the code that uses one is written.
		if target and target.kind == "typedef" then
			local named = target.name and cdef.resolve(namespace, target.name)
			if named and (named.kind == "struct" or named.kind == "union") then return target.name end
		end
		local pointed = target and cdef.resolve(namespace, target.name or "") or target
		if pointed and (pointed.kind == "struct" or pointed.kind == "union") and pointed.name then
			return pointed.name
		end
		-- A pointer to a function is the callback it is, and is not indexed at all.
		if target and target.kind == "function" then return "ffi.cb" end
		-- Anything else is the pointer it is: a `char *` is not a Lua string, it is what
		-- `ffi.string` reads, and a `void *` points at something the header does not name.
		if target and target.kind == "void" then return "ffi.ptr<ffi.cdata>" end
		local held = target and (SCALAR_CLASS[target.name or ""]
			or cdef.notation(namespace, target, where)) or "ffi.cdata"
		return string.format("ffi.ptr<%s>", held)
	end
	if kind == "function" then return "ffi.cb" end
	if kind == "float" then return "number" end
	if kind == "bool" then return "boolean" end
	if kind == "int" then
		-- A 64-bit one is a cdata and keeps its name; a narrower one is the Lua number the engine
		-- hands over, which is what makes `size * nmemb` arithmetic on two numbers rather than on
		-- two cdata values.
		return CDATA_SCALAR[type.name or ""] or "number"
	end
	if kind == "void" then return "nil" end
	if kind == "enum" then return type.name or "ffi.int" end
	if kind == "struct" or kind == "union" then
		-- An anonymous struct or union has no name to be written by, and the members it holds are
		-- what a reader reaches through it: `union { WCHAR UnicodeChar; char AsciiChar; } uChar`
		-- is those two members, not a cdata nothing can be read from. Win32 headers are full of
		-- them, and one in the middle of a chain left everything past it unknown.
		if not type.name and type.fields and #type.fields > 0 then
			local parts = {}
			for _, field in ipairs(type.fields) do
				parts[#parts + 1] = string.format("%s: %s", field.name, cdef.notation(namespace, field.type, where))
			end
			return "{ " .. table.concat(parts, ", ") .. " }"
		end
		return type.name or "ffi.cdata"
	end
	return "ffi.cdata"
end

--- The classes and aliases a cdef block declares, as `---@` text the analyzer already knows how to
--- read. A struct becomes a class extending `ffi.cdata` with a field per member; a typedef of a
--- struct is a class of the same shape; a typedef of an integer is an alias of that integer, since
--- that is what a value of it is.
---@param namespace lye.cdef.Namespace
function cdef.annotations(namespace)
	local parts = {}

	--- The members of a type, as the annotation type of each. A typedef of an anonymous struct
	--- carries them itself: the tag never had a name to write them under.
	---@param type lye.cdef.Type
	---@return table<string, string>
	local function fieldsOf(type)
		local resolved = cdef.resolve(namespace, type.name or "") or type
		local fields = {}
		for _, field in ipairs(resolved.fields or {}) do
			if not fields[field.name] then
				fields[field.name] = cdef.notation(namespace, field.type)
			end
		end
		return fields
	end

	for _, name in ipairs(namespace.order) do
		local resolved = cdef.resolve(namespace, name) or namespace.types[name]
		if resolved.kind == "enum" then
			-- An enum is a C number with names for some of its values, so it extends the class the
			-- definitions give a C number: the arithmetic on it is documented there.
			parts[#parts + 1] = string.format("---@class %s: ffi.cnum*", name)
		elseif isCdata(namespace, resolved) then
			-- A function pointer is a callback, which the definitions already name; anything else
			-- is a piece of C data.
			local isFunction = resolved.kind == "function"
				or (resolved.kind == "pointer" and resolved.target
					and (cdef.resolve(namespace, resolved.target.name or "") or resolved.target).kind == "function")
			local lines = {
				string.format("---@class %s: %s", name, isFunction and "ffi.cb" or "ffi.cdata"),
			}
			local fields = fieldsOf(namespace.types[name])
			local sorted = {}
			for field in pairs(fields) do sorted[#sorted + 1] = field end
			table.sort(sorted)
			for _, field in ipairs(sorted) do
				lines[#lines + 1] = string.format("---@field %s %s", field, fields[field])
			end
			parts[#parts + 1] = table.concat(lines, "\n")
		else
			-- An integer is what a value of it is, so `---@type size_t` should say so rather than
			-- name a class that does not behave like one.
			local notation = cdef.notation(namespace, resolved)
			if notation ~= name then
				parts[#parts + 1] = string.format("---@alias %s %s", name, notation)
			end
		end
	end
	parts[#parts + 1] = ""
	return table.concat(parts, "\n")
end

--- Where the text a `ffi.cdef` was handed begins in the source that carries it: past the quote of a
--- quoted string, or past the brackets and the `=` signs of a long one. Both the diagnostics and the
--- colouring need it — one to report a problem, the other to place a token — so it lives with the
--- parser that reports offsets into a text somebody else wrote down.
---@param written string the source
---@param from integer the first byte of the string literal
---@param stop integer its last byte
function cdef.textStart(written, from, stop)
	local literal = written:sub(from, stop)
	local level = literal:match("^%[(=*)%[")
	return from + (level and (2 + #level) or 1)
end

--- What each token of a block is, for a reader colouring it: a keyword, a type, the name of a type
--- the block declared, a member of one, a constant an `enum` named, a function or a number.
---
--- The parse already knows all of it — a name is a type because the namespace says one was declared
--- under it — so nothing extra is read here. That matters twice: the editor's own C injection needs
--- a C grammar installed and would not know LuaJIT's dialect anyway, and a reader of a header wants
--- the names their own program uses coloured as the things they are.
---@param namespace lye.cdef.Namespace
---@return { start: integer, stop: integer, kind: string }[]
function cdef.spans(namespace)
	local tokens = tokenize(namespace.text or "")
	local spans, depth = {}, 0

	for index, token in ipairs(tokens) do
		if token.kind == "comment" then
			spans[#spans + 1] = { start = token.start, stop = token.stop, kind = "comment" }
		elseif token.kind == "punct" then
			if token.text == "{" then depth += 1
			elseif token.text == "}" then depth = math.max(depth - 1, 0) end
		elseif token.kind == "number" then
			spans[#spans + 1] = { start = token.start, stop = token.stop, kind = "number" }
		elseif token.kind == "name" then
			-- The name nothing else claims is a variable, which is the default rather than the last
			-- branch: a `kind` that starts as nil is an optional one to a reader, and every entry
			-- here is a kind.
			local word, kind = token.text, "variable"
			if DECLARATION_WORD[word] then
				kind = "keyword"
			elseif BUILTIN[word] then
				kind = "type"
			elseif namespace.constants[word] ~= nil then
				kind = "constant"
			elseif tokens[index + 1] and tokens[index + 1].text == "(" then
				-- A call follows it, so it is the function being declared — `int printf(...)` —
				-- rather than a name of a type.
				kind = "function"
			elseif namespace.types[word] then
				-- A name the block declared: a struct is a class to a reader, a typedef of an
				-- integer is the integer it stands for.
				local resolved = cdef.resolve(namespace, word)
				kind = isCdata(namespace, resolved or namespace.types[word]) and "class" or "type"
			elseif depth > 0 then
				-- A name inside braces is a member: a cdef declares no function bodies, so the only
				-- braces in one are a struct, a union or an enum.
				kind = "member"
			end
			spans[#spans + 1] = { start = token.start, stop = token.stop, kind = kind }
		end
	end
	return spans
end

return cdef
