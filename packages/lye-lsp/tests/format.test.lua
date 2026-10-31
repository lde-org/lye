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

test.it("keeps a literal and a long string exactly as written", function()
	local source = "local s=  \"a  b\"\nlocal t=[[\n  keep  this\n]]\nreturn s,t\n"
	local out = format(source, { indent_style = "space", indent_size = "2" })
	test.includes(out, "local s = \"a  b\"")
	test.includes(out, "  keep  this", "the long string keeps its own indentation and spaces")
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

return true
