local test = require("lde-test")
local pos = require("lye-framework.position")

test.it("splits lines on LF, CRLF and lone CR", function()
	local text = "a\nb\r\nc\rd"
	local index = pos.buildLineIndex(text)
	test.equal(#index.starts, 4)
	test.equal(pos.lineText(text, index, 0), "a")
	test.equal(pos.lineText(text, index, 1), "b")
	test.equal(pos.lineText(text, index, 2), "c")
	test.equal(pos.lineText(text, index, 3), "d")
end)

test.it("treats CRLF as one terminator, not two", function()
	local text = "ab\r\ncd"
	local index = pos.buildLineIndex(text)
	test.equal(#index.starts, 2)
	test.equal(index.starts[2], 5)
	test.equal(pos.lineText(text, index, 1), "cd")
end)

test.it("maps positions to offsets under utf-8", function()
	local text = "local x = 1\nlocal y = 2"
	local index = pos.buildLineIndex(text)
	test.equal(pos.toOffset(text, index, 0, 0, pos.UTF8), 1)
	test.equal(pos.toOffset(text, index, 0, 5, pos.UTF8), 6)
	test.equal(pos.toOffset(text, index, 1, 6, pos.UTF8), 19)
end)

test.it("clamps a character past the end of a line", function()
	local text = "ab\ncd"
	local index = pos.buildLineIndex(text)
	test.equal(pos.toOffset(text, index, 0, 999, pos.UTF8), 3)
end)

test.it("clamps a line past the end of the document", function()
	local text = "ab"
	local index = pos.buildLineIndex(text)
	test.equal(pos.toOffset(text, index, 99, 0, pos.UTF8), 3)
end)

test.it("counts utf-16 code units for multibyte characters", function()
	-- "é" is U+00E9: 2 UTF-8 bytes, 1 UTF-16 unit.
	local text = "a\195\169b"
	local index = pos.buildLineIndex(text)
	test.equal(pos.utf16Length("a\195\169b", 3), 2)
	test.equal(pos.toPosition(text, index, 4, pos.UTF16), 0, 3)
	test.equal(pos.toOffset(text, index, 0, 2, pos.UTF16), 4)
end)

test.it("counts an astral character as two utf-16 units", function()
	-- U+1F600 is 4 UTF-8 bytes and a surrogate pair (2 UTF-16 units).
	local text = "a\240\159\152\128b"
	local index = pos.buildLineIndex(text)
	test.equal(pos.utf16Length(text, #text), 4)
	test.equal(pos.toOffset(text, index, 0, 3, pos.UTF16), 6)
	test.equal(pos.toPosition(text, index, 6, pos.UTF16), 0, 3)
end)

test.it("round-trips a position through both encodings", function()
	local text = "local s = \"caf\195\169\240\159\152\128\"\nreturn s"
	local index = pos.buildLineIndex(text)
	for _, encoding in ipairs({ pos.UTF8, pos.UTF16 }) do
		for _, offset in ipairs({ 1, 5, 11, 15, #text }) do
			local line, character = pos.toPosition(text, index, offset, encoding)
			test.equal(pos.toOffset(text, index, line, character, encoding), offset, encoding .. " offset " .. offset)
		end
	end
end)

return true
