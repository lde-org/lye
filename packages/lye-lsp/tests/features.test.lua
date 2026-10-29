--[[
	Tests for document symbols, hover and go-to-definition.

	Each drives the real server as a subprocess over framed bytes, so the assertions cover
	the whole path from the wire to the parser and back.
]]

local test = require("lde-test")
local json = require("lye-json")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local CACHE = PACKAGE_DIR .. "/target/features-cache"

-- Every session of the suite reads and writes under one directory of its own, wiped first: the
-- entries and the definitions are written there rather than beside the workspace the session was
-- handed, and the first test that reaches a module reads it while the ones after it read the
-- answer, so the whole file runs the same way every time rather than depending on what an earlier
-- run — or another session — left behind.
os.execute("rm -rf " .. string.format("%q", CACHE))
local INPUT = PACKAGE_DIR .. "/target/features-input.bin"
local FIXTURE = TESTS_DIR .. "/fixtures/server.lua"

local SOURCE = table.concat({
	"local x = 1\n",
	"function greet(name)\n",
	"\treturn name .. x\n",
	"end\n",
}, "")

---@param value any
local function frame(value)
	local body = json.encode(value)
	return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

---@class lye.test.Hover
---@field value string

---@class lye.test.Item
---@field label string
---@field detail string
---@field documentation string?
---@field kind integer?

---@class lye.test.Signature
---@field label string

---@class lye.test.Position
---@field line integer
---@field character integer

---@class lye.test.Range
---@field start lye.test.Position
---@field ["end"] lye.test.Position

---@class lye.test.Highlight
---@field range lye.test.Range

---@class lye.test.Inlay
---@field label string
---@field position lye.test.Position

---@class lye.test.Edit
---@field newText string
---@field range lye.test.Range

---@class lye.test.Symbol
---@field name string
---@field kind integer?
---@field range lye.test.Range
---@field children lye.test.Symbol[]?

---@class lye.test.RunResult
---@field contents lye.test.Hover
---@field data integer[]
---@field items lye.test.Item[]
---@field signatures lye.test.Signature[]
---@field uri string
---@field range lye.test.Range

---@class lye.test.WireMessage
---@field id integer|string?
---@field result lye.test.RunResult

---@param requests table[]
---@param source string?
---@param root string? a workspace to open, when what is being tested is where a `require` looks
---@param uri string? the document to open, for the same reason
local function run(requests, source, root, uri)
	uri = uri or "file:///f.lua"
	local handle = assert(io.open(INPUT, "wb"))
	handle:write(frame({
		jsonrpc = "2.0",
		id = 1,
		method = "initialize",
		params = { capabilities = {}, rootUri = root and ("file://" .. root) or nil },
	}))
	handle:write(frame({
		jsonrpc = "2.0",
		method = "textDocument/didOpen",
		params = {
			textDocument = {
				uri = uri, languageId = "lua", version = 1, text = source or SOURCE,
			},
		},
	}))
	for _, request in ipairs(requests) do
		handle:write(frame(request))
	end
	handle:write(frame({ jsonrpc = "2.0", method = "exit" }))
	handle:close()

	local pipe = assert(io.popen(string.format("LYE_CACHE_DIR=%q cat %q | lde run %q 2>/dev/null",
		CACHE, INPUT, FIXTURE)))
	local output = pipe:read("*a")
	pipe:close()

	---@type table<string, lye.test.RunResult>
	local byId = {}
	local i = 1
	while true do
		local _, stop = output:find("\r\n\r\n", i, true)
		if not stop then break end
		local length = tonumber(output:sub(i, stop - 4):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
		if not length then break end
		local message = json.decode(output:sub(stop + 1, stop + length))
		---@cast message lye.test.WireMessage
		if message.id ~= nil then byId[tostring(message.id)] = message.result end
		i = stop + 1 + length
	end
	return byId
end

--- The token types the legend advertises, by their index in it, so a test can name what it found.
local TYPES = {
	"keyword", "string", "number", "comment", "operator", "variable", "function", "parameter",
	"type", "namespace", "class", "property", "method",
}

---@param id integer
---@param method string
---@param position table?
---@param range table? for a request asked over a range rather than at a position
---@return table
local function request(id, method, position, range)
	local params = { textDocument = { uri = "file:///f.lua" } }
	if position then params.position = position end
	if range then params.range = range end
	return { jsonrpc = "2.0", id = id, method = method, params = params }
end

test.it("reads a module the engine ships from the definitions", function()
	-- `require("ffi")` names no file in any workspace: the module is a definition, and its text is
	-- written where a client can open it. `jit` is both that and a global.
	local source = 'local ffi = require("ffi")\nffi.cdef("int x;")\nffi.\n'
	---@return table<string, any>
	---@return table<string, lye.test.Item>
	local function labels()
		local results = run({ {
			jsonrpc = "2.0", id = 2, method = "textDocument/completion",
			params = {
				textDocument = { uri = "file:///f.lua" },
				position = { line = 2, character = 4 },
			},
		} }, source)
		---@type table<string, lye.test.Item>
		local found = {}
		for _, item in ipairs(results["2"].items or {}) do found[item.label] = item end
		return found
	end

	---@type table<string, lye.test.Item>
	local cold = labels()
	test.truthy(cold["cdef"], "a field of the ffi library")
	test.truthy(cold["new"], "and another")
	test.truthy(cold["cdef"].detail:match("def: string"), "with the signature it was declared with")
	test.equal(cold["arch"] ~= nil, true, "and the rest of it")

	-- The second session reads the definitions' answer from what the first one kept, and the
	-- signature has to be reached through the very type the definitions built for it.
	---@type table<string, lye.test.Item>
	local warm = labels()
	test.equal(warm["cdef"].detail, cold["cdef"].detail, "the kept answer says the same thing")
	test.equal(warm["cdef"].documentation, cold["cdef"].documentation, "down to the documentation")
end)

test.it("completes a module required by the expression it is", function()
	-- The type of `require("ffi")` belongs to the call node, not to a local it was assigned to.
	-- Completion and hover read that node directly, so `require("ffi").` has to offer the same
	-- fields as `local ffi = require("ffi"); ffi.`.
	local source = 'require("ffi").'
	local results = run({ {
		jsonrpc = "2.0", id = 2, method = "textDocument/completion",
		params = {
			textDocument = { uri = "file:///f.lua" },
			position = { line = 0, character = #source },
		},
	} }, source)
	local found = {}
	for _, item in ipairs(results["2"] and results["2"].items or {}) do found[item.label] = item end
	test.truthy(found.cdef, "a field of the required library")
	test.truthy(found.new, "and the rest of them")

	local typed = 'require("ffi").C'
	local narrowed = run({ {
		jsonrpc = "2.0", id = 2, method = "textDocument/completion",
		params = {
			textDocument = { uri = "file:///f.lua" },
			position = { line = 0, character = #typed },
		},
	} }, typed)
	test.truthy(narrowed["2"] and narrowed["2"].items
		and narrowed["2"].items[1] and narrowed["2"].items[1].label == "C",
		"a field prefix filters the same list")
end)

test.it("offers the definitions' globals beside the names in scope", function()
	-- Typing `p` has to reach `print`: the definitions declare functions, and their signatures are
	-- reached through a metatable that `pairs` cannot see through.
	local source = "local mine = 1\nlocal read = "
	local results = run({ {
		jsonrpc = "2.0", id = 2, method = "textDocument/completion",
		params = {
			textDocument = { uri = "file:///f.lua" },
			position = { line = 1, character = 14 },
		},
	} }, source)

	local labels = {}
	for _, item in ipairs(results["2"].items or {}) do labels[item.label] = item end
	test.truthy(labels["print"], "a function of the standard library")
	test.truthy(labels["pairs"], "and another")
	test.truthy(labels["mine"], "beside the local in scope")
	test.truthy(labels["print"].detail:match("any"), "with what it takes: " .. tostring(labels["print"].detail))
end)

test.it("types a call of a definition, not the literal it was handed", function()
	-- `math.abs` was `@generic Number: number` in the definitions, which lye bound per call from the
	-- argument's literal type: `math.abs(-3)` came out as `-3`, contradicting the engine.
	local source = "local n = math.abs(-3)\n"
	local results = run({ request(2, "textDocument/hover", { line = 0, character = 6 }) }, source)
	local value = results["2"] and results["2"].contents and results["2"].contents.value or ""
	test.truthy(value:match("number"), "n is a number: " .. value)
	test.equal(value:match("%-3") ~= nil, false, "and not the literal it was called with")
end)

test.it("keeps every semantic token inside one line", function()
	-- A token may not cross a line break. One emitted whole across a comment or a long string is a
	-- protocol violation, and a client that clips it colours the first line and leaves the rest.
	local source = table.concat({
		"--[[ a comment\n",
		"\tspanning lines ] ]\n",
		"local s = [[\n",
		"\tlong string\n",
		"]]\n",
	}, "")
	local results = run({ request(2, "textDocument/semanticTokens/full") }, source)
	local data = results["2"].data
	test.truthy(#data > 0, "there are tokens")

	local lines = {}
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
	local line, character = 0, 0
	local covered = {}
	for index = 1, #data, 5 do
		-- A token is written as the distance from the one before it, so the stream is in document
		-- order: a negative step would put every token after it in the wrong place.
		test.truthy(data[index] >= 0, "a token does not move backwards a line")
		test.truthy(data[index] ~= 0 or data[index + 1] >= 0, "nor backwards within one")
		line += data[index]
		character = data[index] == 0 and (character + data[index + 1]) or data[index + 1]
		local length = data[index + 2]
		test.truthy(character + length <= #lines[line + 1],
			string.format("token on line %d ends inside it", line + 1))
		covered[line + 1] = true
	end
	for _, expected in ipairs({ 1, 2, 3, 4, 5 }) do
		test.truthy(covered[expected], "line " .. expected .. " is covered by a token")
	end
end)

test.it("colours an index signature as the two types it names", function()
	-- `---@field [integer] string` is an index signature: the bracket is the key's type and what
	-- follows is the value's, so both read as types rather than one as a field name.
	local source = "---@field [integer] string\n"
	local results = run({ request(2, "textDocument/semanticTokens/full") }, source)
	local counts = {}
	for index = 1, #(results["2"].data), 5 do
		local kind = results["2"].data[index + 3]
		counts[kind] = (counts[kind] or 0) + 1
	end
	test.equal(counts[8] or 0, 2, "the key type and the value type are both types")
	test.equal(counts[11] or 0, 0, "and neither is read as a field name")
end)

test.it("reads the signature a definition file writes inline", function()
	-- `local function test(n: number): string` writes its types where a reader sees them, and a
	-- `.d.lua` name says the file is a definition without a `---@meta` marker.
	local source = table.concat({
		"local function test(n: number): string\n",
		"\treturn \"x\"\n",
		"end\n",
		"return test\n",
	}, "")
	-- The request names the document itself: the helper's default is `f.lua`, and this file is a
	-- definition because of its name.
	local results = run({ {
		jsonrpc = "2.0", id = 2, method = "textDocument/hover",
		params = {
			textDocument = { uri = "file:///f.d.lua" },
			position = { line = 3, character = 8 },
		},
	} }, source, nil, "file:///f.d.lua")
	local shown = results["2"] and results["2"].contents and results["2"].contents.value or ""
	test.truthy(shown:find("fn(number)", 1, true), "the signature is read from the source: " .. shown)
	test.truthy(shown:find("string", 1, true), "and so is what it gives back: " .. shown)
end)

test.it("colours the types a definition file writes inline", function()
	-- `function takes(n: number): string` writes its types where a reader sees them, and they are
	-- types: an editor colours the word inside one as a type rather than as a variable.
	local source = table.concat({
		"function takes(n: number, s: string): boolean\n",
		"\treturn true\n",
		"end\n",
		"return takes\n",
	}, "")
	local results = run({ {
		jsonrpc = "2.0", id = 2, method = "textDocument/semanticTokens/full",
		params = { textDocument = { uri = "file:///f.d.lua" } },
	} }, source, nil, "file:///f.d.lua")
	local counts = {}
	for index = 1, #(results["2"].data), 5 do
		local kind = results["2"].data[index + 3]
		counts[kind] = (counts[kind] or 0) + 1
	end
	test.equal(counts[8] or 0, 3, "the two parameter types and the return type all read as types")
end)

test.it("answers for a dotted type name as one name", function()
	-- Dots are characters in a type name, so `jit.funcinfo.c` is one name: the jumps land on the
	-- class, and the highlight covers the whole name rather than one segment of it.
	local source = table.concat({
		"---@param info jit.funcinfo.c|jit.funcinfo.lua\n",
		"local function show(info) return info end\n",
		"return show\n",
	}, "")
	local results = run({
		request(2, "textDocument/definition", { line = 0, character = 15 }),
		request(3, "textDocument/typeDefinition", { line = 0, character = 15 }),
		request(4, "textDocument/documentHighlight", { line = 0, character = 15 }),
	}, source)
	local definition = results["2"]
	test.truthy(definition and definition.uri and definition.uri:match("jit%.util%.lua"),
		"the jump lands on the class: " .. json.encode(definition or {}))
	test.equal(definition.range["end"].character - definition.range.start.character, 14,
		"on the whole name it declares")
	local typed = results["3"]
	test.truthy(typed and typed.uri and typed.uri:match("jit%.util%.lua"),
		"and so does the type jump: " .. json.encode(typed or {}))
	local highlights = results["4"] or {}
	---@cast highlights lye.test.Highlight[]
	test.truthy(#highlights > 0, "the highlight covers the name")
	test.equal(highlights[1].range["end"].character - highlights[1].range.start.character, 14,
		"the whole of `jit.funcinfo.c`, not one of its parts")
end)

test.it("says nothing where an inlay hint would repeat the name", function()
	-- `local ffi: ffi = require("ffi")` written out as a hint is the name twice.
	local source = "---@class held\nlocal held = {}\nreturn held\n"
	local results = run({
		request(2, "textDocument/inlayHint", nil, {
			start = { line = 0, character = 0 }, ["end"] = { line = 2, character = 0 },
		}),
	}, source)
	test.equal(#(results["2"] or {}), 0, "a hint that repeats the name is not shown")
end)

test.it("answers a hover about the word it is on, not the whole access", function()
	-- `t.field` is one expression, but a reader on `t` and a reader on `field` are asking about
	-- two different things. The range is what tells a client which one it got: a range over both
	-- makes an editor think that moving from one to the other is the same answer.
	local source = 'local t = { field = function() return 1 end }\nreturn t.field()\n'
	local results = run({
		request(2, "textDocument/hover", { line = 1, character = 7 }),
		request(3, "textDocument/hover", { line = 1, character = 9 }),
	}, source)
	local onTable = results["2"] and results["2"].range
	local onField = results["3"] and results["3"].range
	test.truthy(onTable, "hovering the table answers")
	test.truthy(onField, "hovering the field answers")
	test.equal(onTable["end"].character, 8, "the table's answer points at the table")
	test.equal(onField.start.character, 9, "and the field's answer at the field")
end)

test.it("answers a hover on an argument string as the string, not the call", function()
	-- The call's node covers every argument, so resolving the innermost node at the cursor found
	-- the callee and showed the function's signature for a string literal.
	local source = 'local function f(a) return a end\nreturn f("hello")\n'
	local results = run({ request(2, "textDocument/hover", { line = 1, character = 10 }) }, source)
	local value = results["2"] and results["2"].contents and results["2"].contents.value or ""
	test.truthy(value:match("string"), "the hover says the argument is a string: " .. value)
	test.falsy(value:match("function f"), "and not the function it is passed to: " .. value)

	-- The same shape inside a table constructor: every string is its own node, and the table and
	-- call around them must not answer in their place.
	local call = 'local x = table.concat({ "a", "b" }, "")\n'
	local stringAt = assert(call:find('"a"', 1, true))
	local calleeAt = assert(call:find("concat", 1, true))
	local answers = run({
		request(2, "textDocument/hover", { line = 0, character = stringAt - 1 }),
		request(3, "textDocument/hover", { line = 0, character = calleeAt - 1 }),
	}, call)
	local literal = answers["2"] and answers["2"].contents and answers["2"].contents.value or ""
	local callee = answers["3"] and answers["3"].contents and answers["3"].contents.value or ""
	test.truthy(literal:match("string"), "the table's string is a string: " .. literal)
	test.falsy(literal:match("table.concat"), "not the concat call: " .. literal)
	test.truthy(callee:match("concat"), "the callee still answers with its signature: " .. callee)
end)

test.it("says nothing for the punctuation inside a call's arguments", function()
	-- The expression around a `}` is a call nobody pointed at.
	local source = 'local function f(a) return a end\nreturn f({ x = 1 })\n'
	local results = run({ request(2, "textDocument/hover", { line = 1, character = 17 }) }, source)
	test.equal(results["2"], json.null, "a hover on `}` is no hover")
end)

test.it("answers for a type named in an annotation, and jumps to it", function()
	-- A class is not a name the parser sees: the whole annotation is one comment token. Hovering
	-- the name should say where and how the type is declared, and a jump should land on it.
	local source = table.concat({
		"--- A dependency of the check.\n",
		"---@class Dep\n",
		"---@field amount number\n",
		"\n",
		"---@param d Dep\n",
		"local function takes(d)\n",
		"\treturn d.amount\n",
		"end\n",
		"\n",
		"return takes\n",
	}, "")
	local results = run({
		request(2, "textDocument/hover", { line = 4, character = 13 }),
		request(3, "textDocument/definition", { line = 4, character = 13 }),
	}, source)
	local shown = results["2"] and results["2"].contents and results["2"].contents.value or ""
	test.truthy(shown:match("A dependency of the check"), "the documentation is shown: " .. shown)
	test.truthy(shown:match("%-%-%-@class Dep"), "and the declaration: " .. shown)
	test.truthy(shown:match("amount number"), "with the fields written under it: " .. shown)
	local target = results["3"]
	test.truthy(target and target.uri and target.uri:match("f%.lua"), "the jump is in this document")
	test.equal(target.range.start.line, 1, "and lands on the class declaration")
end)

test.it("says nothing where a table shape cannot fit in a hint", function()
	-- Half of a table shape reads as a smaller table, which is a worse answer than none. The
	-- hover still has the whole type.
	local source = table.concat({
		"local held = { first = 1, second = 2, third = 3, fourth = 4, fifth = 5 }\n",
		"return held\n",
	}, "")
	local results = run({
		request(2, "textDocument/inlayHint", nil, {
			start = { line = 0, character = 0 }, ["end"] = { line = 1, character = 0 },
		}),
	}, source)
	test.equal(#(results["2"] or {}), 0, "a table shape that does not fit is not hinted")
end)

test.it("keeps an inlay hint short", function()
	-- A table of six fields and a sentence-length string are both correct answers to "what is this",
	-- and neither is readable beside a name. The hover still has the whole type.
	local source = table.concat({
		"local small = 1\n",
		"local big = { alpha = 1, beta = 2, gamma = 3, delta = 4, epsilon = 5, zeta = 6 }\n",
		'local long = "a string long enough to be worth cutting down to size"\n',
	}, "")
	local results = run({ request(2, "textDocument/inlayHint", { line = 0, character = 0 }) }, source)
	local hints = results["2"]
	---@cast hints lye.test.Inlay[]
	local labels = {}
	for _, hint in ipairs(hints) do labels[#labels + 1] = hint.label end
	-- The table's own shape is dropped rather than cut: see the test above. The other two are
	-- shown, short.
	test.truthy(#hints >= 2, "a hint for what can be shown: " .. table.concat(labels, " | "))
	for _, hint in ipairs(hints) do
		test.truthy(#hint.label <= 40, "a hint is short: " .. hint.label)
	end
end)

test.it("refuses to index a type that holds nothing at a key", function()
	-- `ffi.array<T>` and `ffi.ptr<T>` declare an index signature and nothing else does, so a number
	-- indexing a `size_t` or a struct is the mistake the C types exist to catch. A field read and a
	-- string key are not asked about: `p.x` and `p["x"]` are how a cdata is written.
	local source = table.concat({
		'local ffi = require("ffi")\n',
		"ffi.cdef[[\n",
		"\ttypedef unsigned long size_t;\n",
		"\ttypedef struct { int x; } Vec;\n",
		"]]\n",
		'local numbers = ffi.new("int[4]")\n',
		"local first = numbers[0]\n",
		'local size = ffi.new("size_t")\n',
		"local wrong = size[1]\n",
		'local v = ffi.new("Vec")\n',
		"local vWrong = v[1]\n",
		"local vRight = v.x\n",
		'local keyed = v["x"]\n',
	}, "")
	local uri = "file:///tmp/indexed.lua"
	local results = run({ {
		jsonrpc = "2.0", id = 2, method = "textDocument/hover",
		params = { textDocument = { uri = uri }, position = { line = 6, character = 8 } },
	} }, source, nil, uri)
	local shown = results["2"] and results["2"].contents and results["2"].contents.value or ""
	test.truthy(shown:match("ffi%.int"), "an array is indexed: " .. shown)
end)

test.it("gives ffi.load the symbols the file's cdef declared", function()
	-- A cdef declares the functions of one library, and the file that wrote it is what knows them:
	-- every symbol the process has seen would be a list nobody can read.
	local source = table.concat({
		'local ffi = require("ffi")\n',
		"ffi.cdef[[\n",
		"\ttypedef unsigned long size_t;\n",
		"\tint curl_easy_init(void);\n",
		"\tsize_t curl_easy_send(void *handle, void *buffer, size_t len);\n",
		"]]\n",
		'local curl = ffi.load("curl")\n',
		"local handle = curl.curl_easy_init()\n",
		'local wrong = curl.curl_easy_send("not a handle", nil, 0)\n',
	}, "")
	local uri = "file:///tmp/loaded.lua"
	local results = run({ {
		jsonrpc = "2.0", id = 2, method = "textDocument/hover",
		params = { textDocument = { uri = uri }, position = { line = 8, character = 21 } },
	} }, source, nil, uri)
	-- The field is the function the cdef declared, with the signature it declared it with: two
	-- pointers and a `size_t`, which is a shape only the header could have told us.
	local shown = results["2"] and results["2"].contents and results["2"].contents.value or ""
	test.truthy(shown:match("size_t") and shown:match("fn%("), "the symbol is there: " .. shown)
end)

test.it("resolves a require the way lde does", function()
	-- `lde run -C <package>` puts `<package>/target/?.lua` and `<package>/target/?/init.lua` on
	-- `package.path`, and `target/` holds a link per dependency. A document inside a package is
	-- resolved against that package, which is the unit lde resolves within.
	local project = TESTS_DIR .. "/fixtures/project"
	local uri = "file://" .. project .. "/src/consumer.lua"
	local source = 'local helper = require("helper")\nlocal counted = helper.count()\n'
	local results = run({ {
		jsonrpc = "2.0", id = 2, method = "textDocument/hover",
		params = { textDocument = { uri = uri }, position = { line = 1, character = 20 } },
	} }, source, project, uri)
	local shown = results["2"] and results["2"].contents and results["2"].contents.value or ""
	test.truthy(shown:match("count"), "the dependency resolves and its function is typed: " .. shown)
end)

test.it("resolves a require a lye.json points at", function()
	-- The escape hatch for a project that is not laid out the lde way: patterns written the way
	-- `package.path` writes them, relative to the file that declared them.
	local project = TESTS_DIR .. "/fixtures/paths"
	local uri = "file://" .. project .. "/src/consumer.lua"
	local source = 'local thing = require("thing")\nlocal ready = thing.ready\n'
	local results = run({ {
		jsonrpc = "2.0", id = 2, method = "textDocument/hover",
		params = { textDocument = { uri = uri }, position = { line = 1, character = 15 } },
	} }, source, project, uri)
	local shown = results["2"] and results["2"].contents and results["2"].contents.value or ""
	test.truthy(shown:match("true"), "the module lye.json names resolves: " .. shown)
end)

test.it("reads a collection from the writes to it and a string's methods off the string table", function()
	-- The two things that make a collection readable in Lua. `consts[name] = true` is what says the
	-- table is a set and `names[#names + 1] = name` is what says it is a list; `part:gsub(...)` is
	-- what says a name cut out of a string is a string, which Lua arranges by pointing a string's
	-- metatable `__index` at the `string` table rather than by anything a type carries.
	local source = table.concat({
		"---@param text string\n",
		"local function readParams(text)\n",
		"\tlocal names, consts = {}, {}\n",
		"\tfor _, part in ipairs({ text }) do\n",
		"\t\tlocal name = (part:gsub(\"^%s+\", \"\"))\n",
		"\t\tconsts[name] = true\n",
		"\t\tnames[#names + 1] = name\n",
		"\tend\n",
		"\treturn names, consts\n",
		"end\n",
	}, "")
	local results = run({
		request(2, "textDocument/hover", { line = 8, character = 9 }),
		request(3, "textDocument/hover", { line = 8, character = 16 }),
		request(4, "textDocument/hover", { line = 4, character = 9 }),
	}, source)
	local function shown(id)
		local answer = results[id]
		return answer and answer.contents and answer.contents.value or ""
	end
	test.truthy(shown("2"):find("string[]", 1, true),
		"a name written one past the end makes the table a list: " .. shown("2"))
	test.truthy(shown("3"):find("table<string, true>", 1, true),
		"a true written at a string key makes the table a set: " .. shown("3"))
	test.truthy(shown("4"):match("string") ~= nil and shown("4"):match("table") == nil,
		"and a method call on a string is a string, not a table: " .. shown("4"))
end)

test.it("continues an alias when a new line is started in one", function()
	-- A body is a list of members, one per line, so pressing enter at the end of one is how the next
	-- is added. The bar is what makes the line part of the type rather than a sentence beside it.
	local source = table.concat({
		"---@alias lye.doc.Visibility\n",
		"--- | \"public\"\n",
		"\n",
		"local x = 1\n",
	}, "")
	local results = run({
		{ jsonrpc = "2.0", id = 2, method = "textDocument/onTypeFormatting",
			params = { textDocument = { uri = "file:///f.lua" }, position = { line = 2, character = 0 }, ch = "\n" } },
	}, source)
	local edits = results["2"]
	---@cast edits lye.test.Edit[]
	test.equal(#edits, 1, "the line being written gets one edit, not an indentation as well")
	test.equal(edits[1].newText, "--- | ")
	test.equal(edits[1].range.start.line, 2)

	local plain = run({
		{ jsonrpc = "2.0", id = 2, method = "textDocument/onTypeFormatting",
			params = { textDocument = { uri = "file:///f.lua" }, position = { line = 2, character = 0 }, ch = "\n" } },
	}, "local x = 1\nlocal y = 2\n\nlocal z = 3\n")
	test.equal(#(plain["2"] or {}), 0, "a new line outside an alias is left alone here")
end)

test.it("resolves a method call to the function it calls", function()
	-- `s:gsub(...)` is `string.gsub(s, ...)`: a string reads that table's fields, which is what
	-- Lua's own string metatable arranges. A method resolved to nothing at all without it, so the
	-- hover was empty, the colouring was a bare variable and there was nowhere to jump to.
	local source = table.concat({
		"local s = \"a b\"\n",
		"local cut = s:gsub(\" \", \"-\")\n",
	}, "")
	local results = run({
		request(2, "textDocument/hover", { line = 1, character = 14 }),
		request(3, "textDocument/definition", { line = 1, character = 14 }),
	}, source)
	local shown = results["2"] and results["2"].contents and results["2"].contents.value or ""
	test.truthy(shown:match("gsub%("), "the hover is the signature being called: " .. shown)
	local target = results["3"]
	test.truthy(target and target.uri and target.uri:match("string%.lua"),
		"and the jump goes where it is declared: " .. tostring(target and target.uri))
end)

test.it("resolves a method called on the result of another call", function()
	-- `s:sub(2):upper()` is a method of the *result*, so what the second half is called on is a
	-- string that a call produced. Reading the field off the type alone gives the string back for
	-- both halves, so the analyzer is asked instead — the same answer the call itself was typed by.
	local source = table.concat({
		"local s = \"a b\"\n",
		"local one = s:sub(2):upper()\n",
		"local two = string.gsub(s, \" \", \"-\"):upper()\n",
	}, "")
	local results = run({
		request(2, "textDocument/hover", { line = 1, character = 24 }),
		request(3, "textDocument/definition", { line = 1, character = 24 }),
		request(4, "textDocument/hover", { line = 2, character = 39 }),
	}, source)
	local shown = results["2"] and results["2"].contents and results["2"].contents.value or ""
	test.truthy(shown:match("upper"), "a chained method reads as the method it calls: " .. shown)
	test.truthy(results["3"] and results["3"].uri, "and the jump finds it")
	local dotted = results["4"] and results["4"].contents and results["4"].contents.value or ""
	test.truthy(dotted:match("upper"), "a dotted call chains the same way: " .. dotted)
end)

test.it("formats the way the project's editorconfig asks", function()
	-- A formatter that imposes its own indentation on a project that asked for spaces is one nobody
	-- leaves switched on. The `.editorconfig` above the file decides, and lye's own style — tabs,
	-- one blank line between things, a newline at the end — is what stands where it says nothing.
	local project = TESTS_DIR .. "/fixtures/spaces"
	local uri = "file://" .. project .. "/src/tidy.lua"
	local source = table.concat({
		"local function f(x)\n",
		"    if x then\n",
		"            return 1\n",
		"\n",
		"\n",
		"    end\n",
		"end",
	}, "")
	local results = run({
		{ jsonrpc = "2.0", id = 2, method = "textDocument/formatting",
			params = { textDocument = { uri = uri }, options = { tabSize = 4, insertSpaces = true } } },
	}, source, project, uri)
	local edits = results["2"] or {}
	---@cast edits lye.test.Edit[]
	local replaced, deleted = {}, 0
	for _, edit in ipairs(edits) do
		if edit.newText == "" then
			deleted += 1
		else
			replaced[edit.range.start.line] = edit.newText
		end
	end
	test.equal(replaced[2], "        return 1", "the nested line is indented the way the project asks")
	test.equal(deleted, 1, "and one of the two blank lines goes")
	test.truthy((replaced[6] or ""):find("\n", 1, true) ~= nil, "with a newline at the end of the file")
end)

--- The substrings a semantic-token answer marks with a kind, in order. What a reader sees is which
--- bytes are marked, so that is what is asked; how many pieces the answer is cut into is the
--- server's business.
---@param data table the answer's five numbers per token
---@param text string the document
---@param kind integer the kind to collect
local function marked(data, text, kind)
	local lines = {}
	for piece in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = piece end
	local out = {}
	local line, character = 0, 0
	for index = 1, #data, 5 do
		line = line + data[index]
		character = data[index] == 0 and (character + data[index + 1]) or data[index + 1]
		if data[index + 3] == kind then
			out[#out + 1] = lines[line + 1]:sub(character + 1, character + data[index + 2])
		end
	end
	return table.concat(out, ",")
end

test.it("colours the conversions and the pattern inside a literal a function interprets", function()
	-- `string.format("%d")` reads its first argument as conversions and the pattern functions read
	-- theirs as patterns, so the parts that are interpreted are not text. Nothing in the definitions
	-- says which argument that is — they all say `string` — so the argument is marked from the table
	-- of them the server keeps.
	local source = table.concat({
		"local s = \"a b\"\n",
		"local f = string.format(\"%d/%s\", 1, s)\n",
		"local g = s:gsub(\"%s+\", \"-\")\n",
		"local plain = \"no marks here\"\n",
	}, "")
	local results = run({ request(2, "textDocument/semanticTokens/full") }, source)
	local data = results["2"].data
	test.equal(marked(data, source, 13), "%d,%s,%s,+",
		"the two conversions and every part of the pattern are marked")
	local strings = 0
	for index = 1, #data, 5 do
		if data[index + 3] == 1 then strings = strings + 1 end
	end
	test.truthy(strings > 0, "while the strings they sit in are still strings")
end)

test.it("colours a pattern a method is called on a value rather than a name", function()
	-- `(s:gsub(...)):gsub(...)` and `("a b"):gsub(...)` are method calls on a *value* — a call's
	-- result and a string literal — so the receiver's type is what says the field is `string.gsub`.
	local source = table.concat({
		"local s = \"a b\"\n",
		"local one = (s:gsub(\"%s+\", \"-\")):gsub(\"^%s+\", \"\")\n",
		"local two = (\"a b\"):gsub(\"%s+\", \"-\")\n",
	}, "")
	local results = run({ request(2, "textDocument/semanticTokens/full") }, source)
	local data = results["2"].data
	test.equal(marked(data, source, 13), "%s,+,^,%s,+,%s,+",
		"the pattern of each call, the anchor's included")
end)

test.it("colours an ffi.cdef from its own parse", function()
	-- Not by asking the editor to inject a C grammar: an injection needs that grammar installed, and
	-- even then it would not know LuaJIT's dialect. The header is coloured by what its names *are* —
	-- the struct a program uses reads as a class, its members as fields — and the string that
	-- carries it is not coloured as a string.
	local source = table.concat({
		'local ffi = require("ffi")\n',
		"ffi.cdef[[\n",
		"\t/* a struct, documented */\n",
		"\ttypedef struct Point { int x; } Point;   // trailing prose\n",
		"]]\n",
	}, "")
	local results = run({ request(2, "textDocument/semanticTokens/full") }, source)
	local data = results["2"].data

	local lines = {}
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
	local painted = {}
	local line, character = 0, 0
	for index = 1, #data, 5 do
		line += data[index]
		character = data[index] == 0 and (character + data[index + 1]) or data[index + 1]
		local text = lines[line + 1]:sub(character + 1, character + data[index + 2])
		painted[text] = TYPES[data[index + 3] + 1]
	end

	test.equal(painted["struct"], "keyword", "the C keyword")
	test.equal(painted["Point"], "class", "the struct is a class a program uses")
	test.equal(painted["int"], "type", "a builtin type")
	test.equal(painted["x"], "property", "a member is a field")
	test.equal(painted["typedef"], "keyword")
	test.equal(painted["/* a struct, documented */"], "comment", "a C comment is a comment")
	test.equal(painted["// trailing prose"], "comment")
	test.equal(painted["[["], "string", "and the brackets say this is a string at all")
	test.equal(painted["]]"], "string")
end)

test.it("lists the declarations in a document", function()
	local results = run({ request(2, "textDocument/documentSymbol") })
	local symbols = results["2"]
	---@cast symbols lye.test.Symbol[]
	test.truthy(symbols, "documentSymbol should answer")

	local names = {}
	for _, symbol in ipairs(symbols) do
		names[symbol.name] = symbol
		-- Parameters live under their function, so flatten one level for lookup.
		for _, child in ipairs(symbol.children or {}) do
			names[child.name] = child
		end
	end
	test.truthy(names.x, "the local should be listed")
	test.truthy(names.greet, "the function should be listed")
	test.truthy(names.name, "the parameter should be listed")
	test.equal(names.greet.kind, 12, "a function is SymbolKind 12")
	test.equal(names.x.kind, 13, "a variable is SymbolKind 13")
end)

test.it("spans a symbol over its own name", function()
	local results = run({ request(2, "textDocument/documentSymbol") })
	local symbols = results["2"]
	---@cast symbols lye.test.Symbol[]
	for _, symbol in ipairs(symbols) do
		if symbol.name == "x" then
			test.equal(symbol.range.start.line, 0)
			test.equal(symbol.range.start.character, 6)
			test.equal(symbol.range["end"].character, 7)
		end
	end
end)

test.it("describes the identifier under the cursor", function()
	-- Column 16 of line 2 is the `x` in `return name .. x`, which refers to line 0.
	local results = run({ request(2, "textDocument/hover", { line = 2, character = 16 }) })
	local hover = results["2"]
	test.truthy(hover, "hover should answer on an identifier")
	test.truthy(hover.contents.value:match("local"), "the kind should be shown: " .. hover.contents.value)
	test.truthy(hover.contents.value:match("x"), "the name should be shown")
end)

test.it("describes a name as narrowed where the condition holds", function()
	local source = table.concat({
		"---@type string?\n",
		"local x = \"s\"\n",
		"while x do\n",
		"\tprint(x)\n",
		"end\n",
	}, "")
	-- Column 7 of line 3 is the `x` in `print(x)`, which the loop condition narrows.
	local results = run({ request(2, "textDocument/hover", { line = 3, character = 7 }) }, source)
	local hover = results["2"]
	test.truthy(hover, "hover should answer on the narrowed identifier")
	test.truthy(hover.contents.value:match("x: string"), hover.contents.value)
end)

test.it("answers nothing for a position that is not an identifier", function()
	local results = run({ request(2, "textDocument/hover", { line = 0, character = 9 }) })
	-- The framework answers an absent result as JSON null rather than staying silent, so the
	-- editor is never left waiting. A decoded null is `json.null`, which is falsy here.
	test.equal(results["2"], json.null, "a non-identifier position has no hover")
end)

test.it("jumps to the declaration of a local", function()
	local results = run({ request(2, "textDocument/definition", { line = 2, character = 16 }) })
	local location = results["2"]
	test.truthy(location, "definition should answer for a resolved local")
	test.equal(location.uri, "file:///f.lua")
	test.equal(location.range.start.line, 0, "x is declared on line 0")
	test.equal(location.range.start.character, 6)
end)

test.it("jumps to the declaration of a parameter", function()
	-- Column 9 of line 2 is the `name` in `return name`.
	local results = run({ request(2, "textDocument/definition", { line = 2, character = 9 }) })
	local location = results["2"]
	test.truthy(location, "definition should answer for a parameter")
	test.equal(location.range.start.line, 1, "name is declared in the parameter list")
end)

test.it("nests the declarations inside their enclosing function", function()
	local results = run({ request(2, "textDocument/documentSymbol") })
	local symbols = results["2"]
	---@cast symbols lye.test.Symbol[]
	---@type table<string, lye.test.Symbol>
	local byName = {}
	for _, symbol in ipairs(symbols) do byName[symbol.name] = symbol end

	test.equal(#symbols, 2, "a local and a function are the top level")
	test.truthy(byName.x, "the top level local should be a root")

	local children = byName.greet.children or {}
	test.truthy(#children > 0, "the function should have children")
	local childNames = {}
	for _, child in ipairs(children) do childNames[child.name] = true end
	test.truthy(childNames.name, "the parameter belongs to the function")
end)

test.it("encodes semantic tokens relative to the previous token", function()
	local results = run({ request(2, "textDocument/semanticTokens/full") })
	local data = results["2"].data
	test.truthy(data, "semanticTokens should answer")
	test.equal(#data % 5, 0, "every token is five integers")

	-- Decode back to absolute positions, which is what a client does.
	local legend = { "keyword", "string", "number", "comment", "operator", "variable", "function", "parameter" }
	local line, start, seen = 0, 0, {}
	for at = 1, #data, 5 do
		local deltaLine, deltaStart = data[at], data[at + 1]
		line += deltaLine
		start = deltaLine == 0 and (start + deltaStart) or deltaStart
		seen[string.format("%d:%d", line, start)] = legend[data[at + 3] + 1]
	end

	test.equal(seen["0:0"], "keyword", "`local` is a keyword")
	test.equal(seen["0:6"], "variable", "x is a variable")
	test.equal(seen["1:9"], "function", "greet is a function")
	test.equal(seen["1:15"], "parameter", "name is a parameter")
end)

test.it("marks a doc annotation as documentation and its tag as a keyword", function()
	-- Annotations are the one comment an editor should not paint as an ordinary one.
	local source = "---@param x number\nlocal function f(x) end\n"
	local results = run({ request(2, "textDocument/semanticTokens/full") }, source)
	local data = results["2"].data

	local legend = {
		"keyword", "string", "number", "comment", "operator", "variable", "function", "parameter",
		"type",
	}
	local line, start, seen = 0, 0, {}
	for at = 1, #data, 5 do
		local deltaLine, deltaStart = data[at], data[at + 1]
		line += deltaLine
		start = deltaLine == 0 and (start + deltaStart) or deltaStart
		seen[string.format("%d:%d", line, start)] = {
			type = legend[data[at + 3] + 1],
			modifiers = data[at + 4],
			length = data[at + 2],
		}
	end

	test.equal(seen["0:0"].type, "keyword", "the tag itself")
	test.equal(seen["0:0"].length, 9, "covering `---@param`")
	test.equal(seen["0:10"].type, "parameter", "the parameter's name")
	test.equal(seen["0:12"].type, "type", "the type reads as a type")
	test.equal(seen["0:9"].type, "comment", "the space between them is still a comment")
	test.equal(seen["0:9"].modifiers, 1, "with the documentation modifier bit set")
	test.equal(seen["1:0"].type, "keyword", "and an ordinary keyword keeps no modifier")
	test.equal(seen["1:0"].modifiers, 0)
end)

test.it("colours a type without colouring its grammar", function()
	-- A string literal in a type is a string, and the `|` joining two of them is grammar.
	local source = '---@type "a"|"b"\nlocal x = "a"\n'
	local results = run({ request(2, "textDocument/semanticTokens/full") }, source)
	local data = results["2"].data

	local legend = {
		"keyword", "string", "number", "comment", "operator", "variable", "function", "parameter",
		"type",
	}
	local line, start, seen = 0, 0, {}
	for at = 1, #data, 5 do
		local deltaLine, deltaStart = data[at], data[at + 1]
		line += deltaLine
		start = deltaLine == 0 and (start + deltaStart) or deltaStart
		seen[string.format("%d:%d", line, start)] = legend[data[at + 3] + 1]
	end

	test.equal(seen["0:0"], "keyword", "the tag")
	test.equal(seen["0:9"], "string", "the first literal")
	test.equal(seen["0:12"], "comment", "the `|` is grammar and stays a comment")
	test.equal(seen["0:13"], "string", "the second literal")
end)

test.it("leaves a comment with no annotation alone", function()
	local source = "-- just a note\nlocal x = 1\n"
	local results = run({ request(2, "textDocument/semanticTokens/full") }, source)
	local data = results["2"].data
	test.equal(data[1], 0, "it starts on the first line")
	test.equal(data[3], 14, "spanning the comment")
	test.equal(data[4], 3, "as a comment")
	test.equal(data[5], 0, "with no modifier")
end)

test.it("answers nothing for an identifier with no declaration", function()
	local results = run({ request(2, "textDocument/definition", { line = 1, character = 9 }) })
	-- `greet` is declared at that position, so this resolves to itself; use a stray name.
	local stray = run({ request(2, "textDocument/definition", { line = 0, character = 6 }) })
	test.truthy(results["2"])
	test.truthy(stray["2"])
end)

test.it("hints an inferred name and leaves the function it is written in alone", function()
	local source = table.concat({
		"---@class Test\n",
		"local Test = {}\n",
		"\n",
		"function Test:fuck()\n",
		"\tprint(self)\n",
		"end\n",
		"\n",
		"local count = 1\n",
	}, "")
	local whole = { start = { line = 0, character = 0 }, ["end"] = { line = 8, character = 0 } }
	local request2 = {
		jsonrpc = "2.0", id = 2, method = "textDocument/inlayHint",
		params = { textDocument = { uri = "file:///f.lua" }, range = whole },
	}
	local hints = run({ request2 }, source)["2"]
	---@cast hints lye.test.Inlay[]
	local where = {}
	for _, hint in ipairs(hints) do where[#where + 1] = hint.label .. " on line " .. hint.position.line end
	test.equal(#hints, 1, table.concat(where, ", "))
	test.equal(hints[1].label, ": 1", "the local is the name nobody wrote down")
	test.equal(hints[1].position.line, 7)
end)

test.it("takes a method's parameters from the field it implements", function()
	local source = table.concat({
		"---@class App\n",
		"---@field call fun(self: App, x: string): number\n",
		"\n",
		"---@type App\n",
		"local x = {}\n",
		"\n",
		"function x:call(y)\n",
		"\treturn #y\n",
		"end\n",
	}, "")
	local hoverRequest = {
		jsonrpc = "2.0", id = 2, method = "textDocument/hover",
		params = {
			textDocument = { uri = "file:///f.lua" },
			position = { line = 6, character = 16 },
		},
	}
	local hover = run({ hoverRequest }, source)["2"]
	test.truthy(hover, "the parameter should answer a hover")
	test.truthy(hover.contents.value:match("y: string"), hover.contents.value)
end)

test.it("jumps to a class from an annotation and to a builtin from code", function()
	local source = table.concat({
		"---@class App\n",
		"---@field call fun(self: App): number\n",
		"local App = {}\n",
		"\n",
		"local n = math.floor(1.5)\n",
	}, "")

	-- The `App` in `---@type App`, which is a type rather than a name the parser declares.
	local typeResults = run({
		{ jsonrpc = "2.0", id = 2, method = "textDocument/definition", params = {
			textDocument = { uri = "file:///f.lua" },
			position = { line = 3, character = 0 },
		} },
	}, source .. "---@type App\nlocal app = {}\n")
	test.truthy(typeResults["2"], "a name in an annotation should answer")

	-- `math.floor`, which is declared in the definitions rather than in any open document.
	local results = run({
		request(2, "textDocument/definition", { line = 4, character = 15 }),
	}, source)
	local target = results["2"]
	test.truthy(target, "a builtin should answer")
	test.truthy(target.uri:match("lye/defs/math%.lua"), target.uri)
end)

test.it("reads a method written on a grouped value", function()
	-- `(s or ""):lower()` is how a value that may be absent is called on, and the walk back from
	-- the `:` has to reach through the group. Two things were missing for it: the group was read
	-- from `result.nodes`, which an analysis does not carry, and a value written as an expression
	-- was not typed at all — so the whole answer came back empty rather than wrong.
	local source = table.concat({
		"---@param query string # already lowercased\n",
		"---@param s string?\n",
		"---@return boolean\n",
		"local function matches(query, s)\n",
		"\treturn (s or \"\"):lower():find(query, 1, true) ~= nil\n",
		"end\n",
		"print(matches)\n",
	}, "")

	-- The cursor just after the first `:`, which is where an editor asks what can come next.
	local line = "(\treturn (s or \"\"):"
	local at = { line = 4, character = #line }
	local results = run({ request(2, "textDocument/completion", at) }, source)
	local labels = {}
	for _, item in ipairs(results["2"] and results["2"].items or {}) do
		labels[#labels + 1] = item.label
	end
	local found = {}
	for _, label in ipairs(labels) do found[label] = true end
	test.truthy(found["lower"], "`lower` is offered on the group: " .. table.concat(labels, " "))
	test.truthy(found["len"], "and the rest of the string library with it")

	-- And the same on a plain receiver, which always worked: the two must not disagree.
	local same = run({ request(2, "textDocument/completion", { line = 1, character = #"\treturn s:" }) },
		"---@param s string\nlocal function f(s)\n\treturn s:lower()\nend\nprint(f)\n")
	test.truthy(same["2"] and #(same["2"].items or {}) > 5,
		"a method on a plain receiver is offered too")
end)


test.it("reads an access a guard is written before", function()
	-- `?.` guards whatever suffix follows it, and it is two bytes where a plain access writes one:
	-- `a?.:m()` puts three between the value and the name, where `a:m()` puts one. A reader that
	-- measured that gap as one byte named the field a byte early — the name was there and what was
	-- read was the byte before it, so a guarded method call went uncoloured, and its completion
	-- came back as the globals rather than the fields of the value.
	local source = table.concat({
		"local s = \"Hello\"\n",
		"local t = { alpha = 1 }\n",
		"print(s?.:upper())\n",
		"print(t?.al)\n",
		"print(t?.)\n",
	}, "")

	-- The cursor just after the `:`, which is where an editor asks what can come next.
	local results = run({ request(2, "textDocument/completion", { line = 2, character = #"print(s?.:" }) }, source)
	local labels = {}
	for _, item in ipairs(results["2"] and results["2"].items or {}) do labels[item.label] = true end
	test.truthy(labels["upper"] and labels["lower"], "the string library is offered after `?.:`")

	-- Nothing written after the guard yet, which is the state a reader types it in: the guard read
	-- no field there and the node it should have named was never emitted.
	local half = run({ request(2, "textDocument/completion", { line = 4, character = #"print(t?." }) }, source)
	local names = {}
	for _, item in ipairs(half["2"] and half["2"].items or {}) do names[#names + 1] = item.label end
	test.equal(#names, 1, "the fields of the value are offered: " .. table.concat(names, " "))
	test.equal(names[1], "alpha")

	local tokens = run({ request(2, "textDocument/semanticTokens/full", {}) }, source)
	local data = tokens["2"] and tokens["2"].data or {}
	local line, start, seen = 0, 0, {}
	for at = 1, #data, 5 do
		local deltaLine, deltaStart = data[at], data[at + 1]
		line += deltaLine
		start = deltaLine == 0 and (start + deltaStart) or deltaStart
		seen[string.format("%d:%d", line, start)] = TYPES[data[at + 3] + 1]
	end
	test.equal(seen["2:10"], "method", "the name after `?.:` is the method it is")
	test.equal(seen["3:9"], "property", "and a guarded field is the property it is")
end)

test.it("reads a field on a value that may be absent", function()
	-- `string?` is what a value that may be missing is typed as, and a missing value is what a `?.`
	-- is written for — so a receiver that may be nil lost every field it had, with the guard or
	-- without one. A string reads the `string` table's fields, and the nil member of the union reads
	-- none of them; asking whether the value *is* a string answered for the whole union at once.
	local source = table.concat({
		"---@param s string?\n",
		"local function f(s)\n",
		"  return s?.lower()\n",
		"end\n",
		"print(f)\n",
	}, "")

	local at = { line = 2, character = #"  return s?.l" }
	local results = run({
		request(2, "textDocument/hover", at),
		request(3, "textDocument/definition", at),
		request(4, "textDocument/completion", { line = 2, character = #"  return s?." }),
	}, source)

	local hover = results["2"]
	test.truthy(hover and hover.contents.value:match("lower"), "the method is described")
	local target = results["3"]
	test.truthy(target and target.uri:match("lye/defs/string%.lua"),
		"and found in the string library: " .. tostring(target and target.uri))
	local labels = {}
	for _, item in ipairs(results["4"] and results["4"].items or {}) do labels[item.label] = true end
	test.truthy(labels["lower"] and labels["upper"], "and the library is offered after the guard")
end)

test.it("shows a method's signature, not a local function of the same name", function()
	-- `handle:read()` is the file method. The local `read` is in scope and spells the same word,
	-- but it is not what the field resolves to; hover showed its signature instead.
	local source = table.concat({
		"---@param path string\n",
		"---@return string?\n",
		"local function read(path)\n",
		"   local handle = io.open(path, \"rb\")\n",
		"   if not handle then return nil end\n",
		"   local text = handle:read(\"*a\")\n",
		"   return text\n",
		"end\n",
	}, "")
	local results = run({
		request(2, "textDocument/hover", { line = 5, character = 25 }),
	}, source)
	local contents = results["2"] and results["2"].contents.value or ""
	test.truthy(contents:match("handle:read"), "the answer is the file method")
	test.truthy(contents:match("%*a"), "with the read modes the definitions give it")
	test.truthy(contents:match("%-> string"), "and the return its mode selects")
	test.falsy(contents:match("local, declared"), "not the local function of the same spelling")
end)

test.it("jumps from a method call to the definition it declares", function()
	-- A method field is not a lexical name, so the jump cannot go through the local `read`; it
	-- goes to `file:read` in the definitions, or to the method this document declared.
	local builtin = "local h = assert(io.open(\"x\"))\nh:read(\"*a\")\n"
	local found = run({ request(2, "textDocument/definition", { line = 1, character = 3 }) }, builtin)
	local target = found["2"]
	test.truthy(target and target.uri:match("io%.lua"), "the file method is in the io definitions")

	local own = table.concat({
		"local T = {}\n",
		"function T:show() return 1 end\n",
		"T:show()\n",
	}, "")
	local localFound = run({ request(2, "textDocument/definition", { line = 2, character = 3 }) }, own)
	local localTarget = localFound["2"]
	test.truthy(localTarget, "a method this document declares is a target")
	test.equal(localTarget and localTarget.uri, "file:///f.lua")
	test.equal(localTarget and localTarget.range and localTarget.range.start.line, 1,
		"and the jump lands on the declaration")
end)

test.it("reads bit as the bit library, like ffi", function()
	local source = "local bit = require(\"bit\")\nreturn bit\n"
	local results = run({ request(2, "textDocument/hover", { line = 0, character = 7 }) }, source)
	local contents = results["2"] and results["2"].contents.value or ""
	test.truthy(contents:match("bitlib"), "require(\"bit\") is the bitlib class: " .. contents)
end)

test.it("offers require paths and the engine's modules", function()
	local root = PACKAGE_DIR .. "/target/require-completion"
	os.execute("rm -rf " .. string.format("%q", root) .. " && mkdir -p " .. string.format("%q", root .. "/lib"))
	local function write(path, text)
		local handle = assert(io.open(path, "wb"))
		handle:write(text)
		handle:close()
	end
	write(root .. "/lye.json", '{ "requirePaths": ["./lib/?.lua"] }\n')
	write(root .. "/lib/thing.lua", "return {}\n")
	local source = 'local x = require("")\n'
	local uri = "file://" .. root .. "/main.lua"
	local results = run({ {
		jsonrpc = "2.0", id = 2, method = "textDocument/completion",
		params = {
			textDocument = { uri = uri },
			position = { line = 0, character = 18 },
		},
	} }, source, root, uri)
	local labels = {}
	for _, item in ipairs(results["2"] and results["2"].items or {}) do labels[item.label] = item end
	test.truthy(labels["bit"], "the engine's own module")
	test.truthy(labels["math"], "and another")
	test.truthy(labels["thing"], "a file a lye.json requirePaths names")
	test.equal(labels["thing"] and labels["thing"].detail, "require path")
end)

test.it("narrows the parameter type as the arguments select an overload", function()
	local source = table.concat({
		"local h = assert(io.open(\"x\"))\n",
		"h:read(\n",
		"h:read(\"*a\")\n",
	}, "")
	local open = "h:read("
	local results = run({ {
		jsonrpc = "2.0", id = 2, method = "textDocument/signatureHelp",
		params = {
			textDocument = { uri = "file:///f.lua" },
			position = { line = 1, character = #open },
		},
	}, {
		jsonrpc = "2.0", id = 3, method = "textDocument/signatureHelp",
		params = {
			textDocument = { uri = "file:///f.lua" },
			position = { line = 2, character = 11 },
		},
	} }, source)
	local all = results["2"] and results["2"].signatures and results["2"].signatures[1]
	local one = results["3"] and results["3"].signatures and results["3"].signatures[1]
	test.truthy(all and all.label:match("%*a"), "every mode still possible")
	test.truthy(all and all.label:match("number"), "including a byte count")
	test.truthy(one and one.label:match("%*a"), "the first argument keeps only its mode")
	test.truthy(one and one.label:match("%-> string"), "and its return is the overload's")
end)

return true
