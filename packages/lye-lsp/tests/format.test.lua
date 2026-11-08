--[[
	Tests for the formatter: the text it produces, and the command line that writes it.
]]

local test = require("lde-test")
local formatter = require("lye-lsp.format")
local Parser = require("lye-parser")
local fs = require("fs")

local sourcePath = assert(debug.getinfo(1, "S").source):sub(2)
local TESTS_DIR = assert(sourcePath:match("^(.*)/[^/]+$"))
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local MAIN = PACKAGE_DIR .. "/src/main.lua"
local FILE = "/tmp/lye-format-test.lua"

---@param source string
---@param settings table?
---@return string
local function format(source, settings)
	local parsed = Parser.new(source):parse()
	return formatter.text(source, parsed, settings)
end

---@param command string
---@return string
local function run(command)
	local pipe = assert(io.popen(command))
	local output = pipe:read("*a") or ""
	pipe:close()
	return output
end

test.it("lays out indentation and token spacing", function()
	local source = "local x=1+2\nif x then\nreturn x\nend\n"
	local expected = "local x = 1 + 2\nif x then\n  return x\nend\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("keeps exponent signs inside numbers", function()
	local source = "local a=1e-6\nlocal b=1E+9\nlocal c=0x1.8p-2\nlocal d=-1e-6\n"
	local expected = "local a = 1e-6\nlocal b = 1E+9\nlocal c = 0x1.8p-2\nlocal d = -1e-6\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("does not read an identifier ending in e as a number", function()
	local source = "local x1e=3\nreturn x1e-2\n"
	local expected = "local x1e = 3\nreturn x1e - 2\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("keeps a vararg as one token", function()
	local source = "local function f(...)\nreturn ...\nend\nlocal x=f(...)..\"a\"\nreturn f(...),x\n"
	local expected = "local function f(...)\n  return ...\nend\nlocal x = f(...) .. \"a\"\nreturn f(...), x\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("indents a loop body once, not once per scope", function()
	local source = "for i = 1, 2 do\nprint(i)\nend\nfor _, item in ipairs(items) do\nprint(item)\nend\n"
	local expected = "for i = 1, 2 do\n  print(i)\nend\nfor _, item in ipairs(items) do\n  print(item)\nend\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("keeps a table on one line while it fits", function()
	local source = "local t = {\na = 1,\nb = {\nc = 2,\n},\n}\n"
	local expected = "local t = { a = 1, b = { c = 2 } }\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("writes an inline table with one space inside its braces", function()
	local source = "local t = { a = 1 }\nlocal u = {a=1}\nlocal v = {}\nreturn t,u,v\n"
	local expected = "local t = { a = 1 }\nlocal u = { a = 1 }\nlocal v = {}\nreturn t, u, v\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("breaks a table that no longer fits", function()
	local source = "local t = { a = 1, b = 2, c = 3 }\n"
	local expected = "local t = {\n  a = 1,\n  b = 2,\n  c = 3\n}\n"
	test.equal(format(source, {
		indent_style = "space",
		indent_size = "2",
		max_line_length = 20,
	}), expected)
end)

test.it("keeps a literal and a long string exactly as written", function()
	local source = "local s=  \"a  b\"\nlocal t=[[\n  keep  this\n]]\nreturn s,t\n"
	local out = format(source, { indent_style = "space", indent_size = "2" })
	test.includes(out, "local s = \"a  b\"")
	test.includes(out, "  keep  this", "the long string keeps its own indentation and spaces")
end)

test.it("keeps a short function's parameter bars tight", function()
	-- `|a, b| -> value` is one function expression. A binary `|` has a space on either side, but
	-- the bars around the parameters belong to the parameters: `| a |` reads as a bit operation.
	local source = "local f=|x| ->x+1\nlocal g=|a,b| -> a+b\nlocal h=|| -> 5\nlocal i = |x| -> x | 1\n"
	local expected = "local f = |x| -> x + 1\nlocal g = |a, b| -> a + b\nlocal h = || -> 5\nlocal i = |x| -> x | 1\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("formats a file in place, and --check reports without writing", function()
	fs.write(FILE, "local x=1+2\nreturn x\n")
	local check = run(string.format(
		"lde run %q -- format --check %q 2>&1; echo EXIT:$?", MAIN, FILE))
	test.includes(check, FILE, "the file that would change is named")
	test.includes(check, "EXIT:1", "and the check exits 1")
	test.equal(assert(fs.read(FILE)), "local x=1+2\nreturn x\n", "--check does not write")

	run(string.format("lde run %q -- format %q 2>&1", MAIN, FILE))
	test.equal(assert(fs.read(FILE)), "local x = 1 + 2\nreturn x\n")

	local clean = run(string.format(
		"lde run %q -- format --check %q 2>&1; echo EXIT:$?", MAIN, FILE))
	test.includes(clean, "EXIT:0", "a formatted file passes the check")
	os.remove(FILE)
end)

test.it("reads and writes stdin with -", function()
	local output = run(string.format(
		"printf 'local x=1+2\\n' | lde run %q -- format - 2>&1", MAIN))
	test.equal(output, "local x = 1 + 2\n")
end)

test.it("keeps comments and collapses a run of blank lines", function()
	local source = "local x=1 -- trailing\n-- leading\n\n\nlocal y=2\n"
	local expected = "local x = 1 -- trailing\n-- leading\n\nlocal y = 2\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("keeps a group and a unary operator where they change the value", function()
	-- The parser erases a group that nothing wraps, but `(f())` gives one value and `f()` gives
	-- all of them. `-2^2` and `(-2)^2` are the two answers of the same expression.
	local source = "local a,b=(f())\nlocal y=-2^2\nlocal z=(-2)^2\nreturn a,b,y,z\n"
	local expected = "local a, b = (f())\nlocal y = -2 ^ 2\nlocal z = (-2) ^ 2\nreturn a, b, y, z\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("writes the values of a multiple assignment as they were given", function()
	-- Filling the third name from the second value is a type rule; writing it out would run the
	-- call twice.
	local source = "a,b,c=1,f()\nok,err=pcall(f)\n"
	local expected = "a, b, c = 1, f()\nok, err = pcall(f)\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("keeps a compound assignment's operator", function()
	local source = "x+=1\nt..=\"a\"\n"
	local expected = "x += 1\nt ..= \"a\"\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("writes a table's fields in the order they were read", function()
	local source = "local t = { z=1, [k]=2, 3 }\n"
	local expected = "local t = { z = 1, [k] = 2, 3 }\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("honours the table separator a project asks for", function()
	local source = "local t = {\na = 1,\nb = 2\n}\n"
	local expected = "local t = {\n\ta = 1;\n\tb = 2;\n}\n"
	test.equal(format(source, {
		indent_style = "tab",
		table_separator_style = "semicolon",
		trailing_table_separator = "always",
		max_line_length = 20,
	}), expected)
end)

test.it("lays out a block's statements from the tree", function()
	local source = "do local x=1 end\n::top::\ngoto top\nfor i=1,3 do continue end\n"
	local expected = "do local x = 1 end\n::top::\ngoto top\nfor i = 1, 3 do continue end\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("keeps a method's implicit self out of its parameter list", function()
	local source = "local function f(a,b,...) return a end\nfunction M:m(x) return x end\n"
	local expected = "local function f(a, b, ...) return a end\nfunction M:m(x) return x end\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("copies a comment inside an expression and formats around it", function()
	local source = "local x=1\nlocal a=f(1) --[[why]]+2\nlocal y=2\n"
	local expected = "local x = 1\nlocal a = f(1) --[[why]] + 2\nlocal y = 2\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("continues after a line comment inside an expression", function()
	local source = "local a=b -- why\n+ c\n"
	local expected = "local a = b -- why\n  + c\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("keeps a call chain on one line while it fits", function()
	local source = "div():foo():bar():baz():qux():bar()\n"
	local expected = "div():foo():bar():baz():qux():bar()\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("packs a long call chain onto continuation lines", function()
	local source = "div():foo():bar():baz():qux():bar()\n"
	local expected = "div()\n  :foo():bar():baz()\n  :qux():bar()\n"
	test.equal(format(source, {
		indent_style = "space",
		indent_size = "2",
		max_line_length = 25,
	}), expected)
end)

test.it("breaks a call with many arguments when it does not fit", function()
	local source = "local x = foo(a, b, c)\n"
	local expected = "local x = foo(\n  a,\n  b,\n  c\n)\n"
	test.equal(format(source, {
		indent_style = "space",
		indent_size = "2",
		max_line_length = 10,
	}), expected)
end)

test.it("keeps a call that fits within the line limit on one line", function()
	-- A call that already fits must not be split just because it was written across lines.
	local source = "local function f(job)\n\ttest.truthy(\n\t\tjob:isDone(), \"the worker has already said it is done\")\nend\n"
	local expected = "local function f(job)\n\ttest.truthy(job:isDone(), \"the worker has already said it is done\")\nend\n"
	test.equal(format(source, {
		indent_style = "tab",
		indent_size = 4,
		max_line_length = 180,
	}), expected)
end)

test.it("keeps a table's comments between its members", function()
	local source = "local t = { -- head\na = 1, -- one\n-- note\nb = 2\n}\n"
	local expected = "local t = {\n  -- head\n  a = 1, -- one\n  -- note\n  b = 2\n}\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), expected)
end)

test.it("leaves a file the parser could not read unchanged", function()
	local source = "local = 2\n"
	test.equal(format(source, { indent_style = "space", indent_size = "2" }), source)
end)

return true
