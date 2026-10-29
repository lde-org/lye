local test = require("lde-test")
local json = require("lye-json")
local null = json.null

-- A decoded value: the decoder hands back whatever the JSON said, so a test names the table shape
-- it reads rather than the decoder guessing one.
---@alias lye.test.Json table

test.it("decodes primitives", function()
	test.equal(json.decode("null"), null)
	test.equal(json.decode("true"), true)
	test.equal(json.decode("false"), false)
	test.equal(json.decode("42"), 42)
	test.equal(json.decode("-7"), -7)
	test.equal(json.decode("1.5"), 1.5)
	test.equal(json.decode("-1.25e2"), -125)
	test.equal(json.decode('"hi"'), "hi")
end)

test.it("decodes nested structures", function()
	local v = json.decode('{"a":[1,2,{"b":null}],"c":{}}')
	---@cast v lye.test.Json
	test.equal(v.a[1], 1)
	test.equal(v.a[2], 2)
	test.equal(v.a[3].b, null)
	test.equal(type(v.c), "table")
	test.equal(next(v.c), nil)
end)

test.it("decodes the empty array as an array, not an object", function()
	local v = json.decode('{"changes":[]}')
	-- Encoded back it must still be an array; this is what breaks diagnostics
	-- clearing (`diagnostics: []`) if it round-trips as `{}`.
	test.equal(json.encode(v), '{"changes":[]}')
end)

test.it("keeps array order and 1-based indexing", function()
	local v = json.decode("[10,20,30]")
	---@cast v lye.test.Json
	test.equal(#v, 3)
	test.equal(v[1], 10)
	test.equal(v[3], 30)
end)

test.it("handles whitespace and CRLF between tokens", function()
	local v = json.decode('{\r\n\t"a" : 1 ,\r\n\t"b" : [ 2 ]\r\n}')
	---@cast v lye.test.Json
	test.equal(v.a, 1)
	test.equal(v.b[1], 2)
end)

test.it("decodes escapes", function()
	local v = json.decode('"a\\"b\\\\c\\/d\\be\\ff\\ng\\rh\\ti"')
	test.equal(v, 'a"b\\c/d\be\ff\ng\rh\ti')
end)

test.it("decodes \\u escapes to UTF-8", function()
	test.equal(json.decode('"\\u0041"'), "A")
	-- U+00E9 'é' -> C3 A9
	test.equal(json.decode('"\\u00e9"'), "\195\169")
	-- U+20AC '€' -> E2 82 AC
	test.equal(json.decode('"\\u20ac"'), "\226\130\172")
	-- Raw UTF-8 in the source must pass through untouched.
	test.equal(json.decode('"\226\130\172"'), "\226\130\172")
end)

test.it("refuses surrogate-pair escapes instead of half-decoding them", function()
	-- Non-ASCII is sent as raw UTF-8 by real clients, so surrogate pairs are out of
	-- scope. Rejecting them loudly beats producing a lone replacement character.
	local ok, err = pcall(json.decode, '"\\ud83d\\ude00"')
	test.equal(ok, false)
	test.truthy(tostring(err):match("surrogate"))
end)

test.it("decodes empty and escape-containing strings exactly", function()
	test.equal(json.decode('""'), "")
	test.equal(json.decode('"\\n"'), "\n")
	test.equal(json.decode('" "'), " ")
	test.equal(json.decode('"\\u0000"'), "\0")
end)

test.it("decodes a realistic initialize request", function()
	local msg = json.decode([[
	{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
		"processId":1234,"rootUri":"file:///home/u/proj","capabilities":{
			"general":{"positionEncodings":["utf-8","utf-16"]},
			"textDocument":{"synchronization":{"dynamicRegistration":true}}
		},"clientInfo":{"name":"Neovim","version":"0.10.0"},
		"workspaceFolders":[{"uri":"file:///home/u/proj","name":"proj"}]}}
	]])
	---@cast msg lye.test.Json
	test.equal(msg.jsonrpc, "2.0")
	test.equal(msg.id, 1)
	test.equal(msg.method, "initialize")
	test.equal(msg.params.clientInfo.name, "Neovim")
	test.equal(msg.params.capabilities.general.positionEncodings[1], "utf-8")
	test.equal(msg.params.workspaceFolders[1].name, "proj")
end)

-- Encoding ---------------------------------------------------------------

test.it("encodes primitives", function()
	test.equal(json.encode(null), "null")
	test.equal(json.encode(true), "true")
	test.equal(json.encode(1), "1")
	test.equal(json.encode("x"), '"x"')
end)

test.it("encodes integral floats without a decimal point", function()
	-- LSP fields typed `integer` must not serialize as `1.0`.
	test.equal(json.encode(1.0), "1")
	test.equal(json.encode(-0.0), "0")
	test.equal(json.encode(1234.0), "1234")
	test.equal(json.encode(1.5), "1.5")
end)

test.it("refuses to encode non-finite numbers", function()
	for _, v in ipairs({ math.huge, -math.huge, 0 / 0 }) do
		local ok = pcall(json.encode, v)
		test.equal(ok, false)
	end
end)

test.it("escapes strings that need it", function()
	test.equal(json.encode('a"b'), '"a\\"b"')
	test.equal(json.encode("a\\b"), '"a\\\\b"')
	test.equal(json.encode("a\nb"), '"a\\nb"')
	test.equal(json.encode("\0"), '"\\u0000"')
	test.equal(json.encode("\127"), '"\\u007f"')
	-- UTF-8 bytes are legal raw inside a JSON string and must not be escaped.
	test.equal(json.encode("\226\130\172"), '"\226\130\172"')
end)

test.it("encodes empty containers by tag", function()
	test.equal(json.encode(json.array()), "[]")
	test.equal(json.encode(json.object()), "{}")
	test.equal(json.encode({}), "{}")
end)

test.it("infers array vs object", function()
	test.equal(json.encode({ 1, 2, 3 }), "[1,2,3]")
	test.equal(json.encode({ a = 1 }), '{"a":1}')
end)

-- Round trips ------------------------------------------------------------

test.it("round-trips a document change notification", function()
	local original = {
		jsonrpc = "2.0",
		method = "textDocument/didChange",
		params = {
			textDocument = { uri = "file:///a.lua", version = 2 },
			contentChanges = json.array({ {
				range = {
					start = { line = 0, character = 0 },
					["end"] = { line = 0, character = 5 },
				},
				text = "local",
			} }),
		},
	}
	local encoded = json.encode(original)
	local decoded = json.decode(encoded)
	---@cast decoded lye.test.Json
	test.equal(decoded.params.textDocument.uri, "file:///a.lua")
	test.equal(decoded.params.contentChanges[1].text, "local")
	test.equal(decoded.params.contentChanges[1]["range"]["end"].character, 5)
	-- Do NOT compare encoded strings: `pairs` order is unspecified and LuaJIT
	-- randomises string hash seeds, so two structurally identical tables can encode
	-- with different key order and the assertion becomes flaky across runs.
	-- Assert the shape instead.
	---@param t table
	---@return integer
	local function keycount(t)
		local n = 0
		for _ in pairs(t) do n = n + 1 end
		return n
	end
	test.equal(keycount(original), keycount(decoded))
	test.equal(keycount(original.params), keycount(decoded.params))
	test.equal(keycount(original.params.textDocument), keycount(decoded.params.textDocument))
	test.equal(decoded.jsonrpc, "2.0")
	test.equal(decoded.method, "textDocument/didChange")
	test.equal(decoded.params.textDocument.version, 2)
	-- Note there is deliberately no byte-identical re-encode assertion here: `pairs`
	-- order is unspecified and LuaJIT randomises string hash seeds, so structurally
	-- identical tables legitimately encode with different key order. Asserting on
	-- encoded strings would be flaky. What must hold is that the *values* and the
	-- *array element order* survive, which is what the assertions above check, plus
	-- this re-decode:
	local again = json.decode(json.encode(decoded))
	---@cast again lye.test.Json
	test.equal(again.params.contentChanges[1]["range"]["start"].line, 0)
	test.equal(again.params.contentChanges[1].text, "local")
	test.equal(keycount(again), keycount(original))
end)

test.it("round-trips every escape and a surrogate pair", function()
	for _, s in ipairs({ "", "plain", 'q"q', "back\\slash", "\n\r\t\b\f", "\0\1\31\127",
		"\226\130\172", "\240\159\152\128", "mixed \195\169 and \240\159\152\128 end" }) do
		test.equal(json.decode(json.encode(s)), s)
	end
end)

test.it("round-trips an empty diagnostics array", function()
	-- The clear-diagnostics message: pushing [] must survive round trip as [].
	local msg = { uri = "file:///a.lua", diagnostics = json.array() }
	local back = json.decode(json.encode(msg))
	---@cast back lye.test.Json
	test.equal(#back.diagnostics, 0)
	test.equal(json.encode(back.diagnostics), "[]")
end)

-- Rejection --------------------------------------------------------------

local function rejects(src, label)
	local v, err = json.tryDecode(src)
	test.equal(v, nil, "should reject " .. string.format("%q", label or src))
	test.truthy(err, "should explain " .. string.format("%q", label or src))
end

test.it("rejects malformed input", function()
	rejects("")
	rejects("{")
	rejects("[")
	rejects('{"a"}')
	rejects('{"a":}')
	rejects("[1,]")
	rejects('"unterminated')
	rejects("tru")
	rejects("nul")
	rejects("01")
	rejects("1 2") -- trailing data would be a dropped message
	rejects("{} {}")
	rejects('"\\q"') -- invalid escape
	rejects('"\\u12"') -- short \u
	rejects('"\\ud801"') -- unpaired high surrogate
	rejects('"\\udc00"') -- unpaired low surrogate

	-- A literal newline inside a string. Written with string.char so the *test*
	-- contains a real control byte rather than a two-character escape sequence,
	-- and passed a plain label so the failure message does not re-escape it.
	local raw_newline = '"raw' .. string.char(10) .. 'control"'
	rejects(raw_newline, "string containing a raw newline")
	local _, err = json.tryDecode(raw_newline)
	test.truthy(err:match("control character"))
end)

test.it("accepts valid JSON numbers", function()
	for _, s in ipairs({ "0", "-0", "1", "-1", "42", "1234567890", "0.5", "-0.5",
		"1.25", "1e5", "1E5", "1e+5", "1e-5", "1.5e-3", "0e0", "1.0" }) do
		test.equal(json.decode(s), tonumber(s), "should accept " .. s)
	end
end)

test.it("rejects invalid JSON numbers that tonumber would accept", function()
	-- tonumber("01") == 1, so these only fail if the grammar check is real.
	for _, s in ipairs({ "01", "007", "1.", ".5", "1e", "1e+", "+1", "0x10",
		"1.2.3", "1e1e1", "-", "1 2" }) do
		rejects(s)
	end
end)

test.it("reports a byte position in the error", function()
	-- Byte offsets rather than line/column: the transport layer deals in bytes,
	-- and Content-Length is a byte count, so this is the useful unit here.
	-- In '{\n  "a": 1,\n  "b": bad\n}' the bare word `bad` is at byte 20.
	local _, err = json.tryDecode('{\n  "a": 1,\n  "b": bad\n}')
	test.truthy(err:match("byte 20"))
	test.truthy(err:match("0x62")) -- the offending byte, 'b'
end)

return true
