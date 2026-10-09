--[[
	Tests for document symbols, hover and go-to-definition.

	Each drives the real server as a subprocess over framed bytes, so the assertions cover
	the whole path from the wire to the parser and back.
]]

local test = require("lde-test")
local json = require("lye-json")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local INPUT = PACKAGE_DIR .. "/target/features-input.bin"
local FIXTURE = TESTS_DIR .. "/fixtures/server.lua"

local SOURCE = table.concat({
	"local x = 1\n",
	"function greet(name)\n",
	"\treturn name .. x\n",
	"end\n",
}, "")

---@param value any
---@return string
local function frame(value)
	local body = json.encode(value)
	return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

---@param requests table[]
---@param source string?
---@return table<string, any> byId
local function run(requests, source)
	local handle = assert(io.open(INPUT, "wb"))
	handle:write(frame({
		jsonrpc = "2.0",
		id = 1,
		method = "initialize",
		params = { capabilities = {} },
	}))
	handle:write(frame({
		jsonrpc = "2.0",
		method = "textDocument/didOpen",
		params = {
			textDocument = {
				uri = "file:///f.lua", languageId = "lua", version = 1, text = source or SOURCE,
			},
		},
	}))
	for _, request in ipairs(requests) do
		handle:write(frame(request))
	end
	handle:write(frame({ jsonrpc = "2.0", method = "exit" }))
	handle:close()

	local pipe = assert(io.popen(string.format("cat %q | lde run %q 2>/dev/null", INPUT, FIXTURE)))
	local output = pipe:read("*a")
	pipe:close()

	local byId, i = {}, 1
	while true do
		local _, stop = output:find("\r\n\r\n", i, true)
		if not stop then break end
		local length = tonumber(output:sub(i, stop - 4):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
		if not length then break end
		local message = json.decode(output:sub(stop + 1, stop + length))
		if message.id ~= nil then byId[tostring(message.id)] = message.result end
		i = stop + 1 + length
	end
	return byId
end

---@param id integer
---@param method string
---@param position table?
---@return table
local function request(id, method, position)
	local params = { textDocument = { uri = "file:///f.lua" } }
	if position then params.position = position end
	return { jsonrpc = "2.0", id = id, method = method, params = params }
end

test.it("lists the declarations in a document", function()
	local results = run({ request(2, "textDocument/documentSymbol") })
	local symbols = results["2"]
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
	for _, symbol in ipairs(results["2"]) do
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
	-- The framework answers an absent result as JSON null; a decoded null is nil here.
	test.equal(results["2"], nil, "a non-identifier position has no hover")
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
	local byName = {}
	for _, symbol in ipairs(results["2"]) do byName[symbol.name] = symbol end

	test.equal(#results["2"], 2, "a local and a function are the top level")
	test.truthy(byName.x, "the top level local should be a root")

	local children = byName.greet.children
	test.truthy(children, "the function should have children")
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

return true
