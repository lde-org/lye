--[[
	Tests for `lye-lexer`.

	The corpus is checked against `loadstring`, because the engine is the ground truth
	for this dialect. Every case is chosen so the whole snippet is accepted or rejected by
	the engine exactly when it lexes, which keeps the two failure kinds from being
	conflated.
]]

local test = require("lde-test")
local lexer = require("lye-lexer")

--- `loadstring` returns a function *or* nil plus a message, so the result must be
--- tested for nil-ness directly rather than compared.
---@param source string
---@return boolean
local function engineAccepts(source)
	local fn = loadstring(source)
	return fn ~= nil
end

---@param source string
---@return boolean
local function lexes(source)
	local isOk = pcall(lexer.tokenize, source)
	return isOk
end

---@param tokens lye.lexer.Tokens
---@param index integer
---@return lye.lexer.ffi.token
local function at(tokens, index)
	return tokens.arena[index]
end

---@param tokens lye.lexer.Tokens
---@param index integer
---@return string
local function textAt(tokens, index)
	return tokens.texts[index]
end

---@param tokens lye.lexer.Tokens
---@param index integer
---@return string
local function variantAt(tokens, index)
	return lexer.variantOf(tokens.arena[index])
end

--- Tokens must be ordered, non-overlapping, and cover every non-whitespace byte, with
--- no gap that is not whitespace and no gap that starts inside a token. Whitespace
--- between tokens is expected, since it is not emitted.
---@param source string
local function assertSpansAreExact(source)
	local tokens = lexer.tokenize(source)
	local covered = 1
	for index = 1, tokens.count do
		local token = at(tokens, index)
		if token.kind ~= lexer.KIND.eof then
			local gap = source:sub(covered, token.start - 1)
			test.equal(gap:match("^%s*$") ~= nil, true, string.format(
				"uncovered non-whitespace %q before a %s token", gap, variantAt(tokens, index)))
			test.truthy(token.stop >= token.start, "token should not end before it starts")
			covered = token.stop + 1
		end
	end
	local tail = source:sub(covered)
	test.equal(tail:match("^%s*$") ~= nil, true, "uncovered non-whitespace in " .. string.format("%q", tail))
end

--- Pick the token variants present, for order-insensitive assertions.
---@param source string
---@return string[]
local function variants(source)
	local tokens = lexer.tokenize(source)
	local out = {}
	for index = 1, tokens.count do out[#out + 1] = variantAt(tokens, index) end
	return out
end

---@param source string
---@return string
local function variantString(source)
	return table.concat(variants(source), " ")
end

test.it("covers every byte of a realistic file with exact spans", function()
	local source = table.concat({
		"-- a comment\n",
		"local M = {}\n",
		"function M.greet(name)\n",
		'\treturn "hello, " .. name\n',
		"end\n",
		"local n = 0x1p4 + 1.5e3 + 3ULL\n",
		"local long = [[a\nb]]\n",
		"::again::\n",
		"if n > 0 then goto again end\n",
		"return M\n",
	}, "")
	assertSpansAreExact(source)
	test.truthy(engineAccepts(source))
end)

test.it("spans every kind of literal", function()
	assertSpansAreExact('local a = "esc\\naped"')
	assertSpansAreExact("local b = 'single'")
	assertSpansAreExact("local c = [[long\nstring]]")
	assertSpansAreExact("local d = [==[level 2]==]")
	assertSpansAreExact("local e = 0x1.8p-3")
	assertSpansAreExact("local f = 12ULL")
	assertSpansAreExact("local g = 1i")
end)

test.it("records a number's value and a string's escape count", function()
	local tokens = lexer.tokenize("1.5e3 0x1p4 'plain' 'with\\tescape'")
	test.equal(variantAt(tokens, 1), "number")
	test.equal(at(tokens, 1).extra, 1500)
	test.equal(variantAt(tokens, 2), "number")
	test.equal(at(tokens, 2).extra, 16)
	test.equal(at(tokens, 3).extra, 0, "a plain string needs no unescaping")
	test.equal(at(tokens, 4).extra, 1)
end)

test.it("reads every number form the engine accepts", function()
	local forms = {
		{ "0x1f", 31 }, { "0XaB", 171 }, { "0b1010", 10 }, { ".5", 0.5 }, { "1.", 1 },
		{ "1_000", 1000 }, { "0x1_f", 31 }, { "1e10", 1e10 }, { "1.5e-3", 1.5e-3 },
		{ "0x.8p1", 1 }, { "0x1p-4", 0.0625 }, { "12345678901234", 12345678901234 },
	}
	for _, form in ipairs(forms) do
		local tokens = lexer.tokenize(form[1])
		test.equal(variantAt(tokens, 1), "number", form[1])
		test.equal(at(tokens, 1).extra, form[2], form[1])
		test.equal(textAt(tokens, 1), form[1], form[1])
		test.equal(at(tokens, 1).stop, #form[1], form[1])
	end
end)

test.it("records no value for a cdata literal", function()
	-- The suffix makes it a cdata value rather than a Lua number, so only the span counts.
	local tokens = lexer.tokenize("12ULL 1i 0b1ULL")
	test.equal(at(tokens, 1).extra, 0, "a cdata literal has no number value")
	test.equal(textAt(tokens, 1), "12ULL")
	test.equal(at(tokens, 2).extra, 0)
	test.equal(at(tokens, 3).extra, 0, "a binary literal with a suffix is cdata too")
	test.equal(textAt(tokens, 3), "0b1ULL")
end)

test.it("rejects a malformed number", function()
	for _, bad in ipairs({ "0x", "0b", "1e", "1e+" }) do
		test.equal(pcall(lexer.tokenize, bad), false, bad)
	end
end)

test.it("emits comments but not whitespace", function()
	test.equal(variantString("-- only a comment"), "comment eof")
	test.equal(variantString("--[[ long\ncomment ]]"), "comment eof")
	test.equal(variantString("   \n\t  "), "eof")
	test.equal(variantString("local --[[c]] x"), "keyword comment name eof")
end)

test.it("separates keywords from names", function()
	test.equal(variantString("local function end"), "keyword keyword keyword eof")
	test.equal(variantString("_x and _G"), "name keyword name eof")
end)

test.it("treats goto as a name, since LuaJIT makes it a soft keyword", function()
	-- `local goto = 1` is accepted by the engine on this build, so `goto` cannot be
	-- reserved in the lexer. The parser decides based on what follows.
	test.equal(variantString("goto"), "name eof")
	test.equal(variantString("goto again"), "name name eof")
	test.equal(variantString("::again::"), "label eof")
	test.truthy(engineAccepts("local goto = 1"))
end)

test.it("lexes a label as a single token", function()
	-- Splitting `::name::` into three tokens would force every consumer to reassemble it.
	local tokens = lexer.tokenize("::top:: goto top")
	test.equal(variantAt(tokens, 1), "label")
	test.equal(textAt(tokens, 1), "::top::")
	test.equal(textAt(tokens, 2), "goto")
	assertSpansAreExact("::top:: goto top")

	-- Whitespace is allowed around the name.
	test.equal(textAt(lexer.tokenize(":: a ::"), 1), ":: a ::")
	test.equal(textAt(lexer.tokenize("::a:: ::b::"), 2), "::b::")
	test.equal(lexes("::unfinished"), false)
end)

test.it("prefers the longest operator", function()
	test.equal(variantString("..."), "symbol eof")
	test.equal(variantString(".."), "symbol eof")
	test.equal(variantString("."), "symbol eof")
	test.equal(variantString("<<" ), "symbol eof")
	test.equal(variantString("<="), "symbol eof")
	test.equal(variantString("~="), "symbol eof")
	test.equal(variantString("~"), "symbol eof")
end)

local LEXICALLY_VALID = {
	'local x = "a\\z\n   b"',
	"::top:: goto top",
	"local goto = 1",
	"local t = { [1] = 2, 3, four = 5 }",
	"local f = function(...) return ... end",
	"for i = 1, 10, 2 do end",
	"for k, v in pairs(t) do end",
	"while true do break end",
	"repeat until true",
	"local a = t[1]:m():n()",
	"return 0x1.8p1",
	"return 1ULL",
	"return 1LL",
	"return 1i",
	"return .5",
	'return "\\u{41}"',
	'return "\\x41"',
	"local a = 1 --[[ block ]] + 2",
	"--[[ only ]]\n",
	"local s = [==[ ]] ]==]",
	"a.b.c.d = 1",
	"local x = 1;",
}

local LEXICALLY_INVALID = {
	'local x = "unterminated',
	"local x = [[unterminated",
	"local x = --[[unterminated",
	"local x = 'mixed\"",
	"local x = [=[ unterminated ]==]",
}

test.it("agrees with the engine on valid input", function()
	for _, source in ipairs(LEXICALLY_VALID) do
		test.equal(lexes(source), true, "should lex " .. string.format("%q", source))
		test.equal(engineAccepts(source), true, "engine should accept " .. string.format("%q", source))
		assertSpansAreExact(source)
	end
end)

test.it("rejects unterminated strings and comments", function()
	for _, source in ipairs(LEXICALLY_INVALID) do
		test.equal(lexes(source), false, "should reject " .. string.format("%q", source))
	end
end)

test.it("reports a line number when it rejects", function()
	local _, err = pcall(lexer.tokenize, "local a = 1\nlocal b = 2\nlocal c = \"oops")
	test.truthy(tostring(err):match("lex error at line 3"), "got: " .. tostring(err))
end)

test.it("lexes an empty and a whitespace-only file", function()
	test.equal(variantString(""), "eof")
	test.equal(variantString("\n\n  \t\n"), "eof")
end)

return true
