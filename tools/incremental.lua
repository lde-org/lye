--[[
	The differential oracle for the incremental paths: a warm parse is the cold parse.

	Every corpus file is edited a fixed, seeded number of times — inside a string, a comment, an
	annotation, a function body, a top-level statement, and at each end of the file — and after each
	step the answer a resumed path gives is compared with the answer a fresh one gives:

	  parser     tokens, nodes, declarations, scopes, the table maps and the parse diagnostics
	  analyzer   diagnostics, the module's export type serialized to bytes, and the tree it parsed
	  lsp        semantic tokens, hover and definition, sampled through the real server

	The parser and analyzer comparisons drive `Parser.resumeAt` and the analyzer's `resume` argument
	directly. The LSP comparison starts one cold session per sampled step and one warm session that
	applies the same edits through `didChange`, then asks both the same questions; the server
	derives the resumed span from the text itself, so a whole-text change exercises it as well as a
	ranged one. Set `LSP=0` to skip it, and `LYE_INCREMENTAL=0` to skip the analyzer's warm path and
	check the cold one alone.

		lde run -C packages/lye-lsp ../../tools/incremental.lua
		STEPS=8 SEED=7 lde run -C packages/lye-lsp ../../tools/incremental.lua
		LYE_INCREMENTAL=0 lde run -C packages/lye-lsp ../../tools/incremental.lua   # cold path only
		LSP=0 lde run -C packages/lye-lsp ../../tools/incremental.lua

	A mismatch is written under `target/incremental-failures/` as the source after the edit, the
	edit that produced it, both answers and the first lines they differ on. Any mismatch exits 1.

	The corpus is the sources of every package, the tools, the assembled definitions, the 2331-line
	benchmark fixture and a set of malformed snippets, so a clean run says the same thing about a
	syntax error as about `language.lua`.
]]

local bit = require("bit")
local fs = require("fs")
local json = require("lye-json")
local lexer = require("lye-lexer")
local parser = require("lye-parser")
local analyzer = require("lye-analyzer")
local serial = require("lye-doc.serial")

local SCRIPT = assert(debug.getinfo(1, "S").source:sub(2))
local TOOLS = assert(SCRIPT:match("^(.*)/[^/]+$"))
local ROOT = os.getenv("LYE_ROOT") or assert(TOOLS:match("^(.*)/tools$"))
-- `lde run` is given the script relative to the package, so the root starts relative too. A
-- `file://` URI and a saved failure both want the same absolute path a second run can read.
if ROOT:sub(1, 1) ~= "/" then
	local pipe = io.popen("cd " .. string.format("%q", ROOT) .. " && pwd -P")
	if pipe then
		ROOT = (pipe:read("*a") or ROOT):gsub("%s+$", "")
		pipe:close()
	end
end
local FAILURES = ROOT .. "/target/incremental-failures"
local LSP_PACKAGE = ROOT .. "/packages/lye-lsp"
local LSP_FIXTURE = LSP_PACKAGE .. "/tests/fixtures/server.lua"
local INPUT = "/tmp/lye-incremental-session.bin"

local SEED = tonumber(os.getenv("SEED")) or 20261024
local STEPS = tonumber(os.getenv("STEPS")) or 6
local FILE_LIMIT = tonumber(os.getenv("FILES")) or 0
local LSP = os.getenv("LSP") ~= "0"
local LSP_FILES = tonumber(os.getenv("LSP_FILES")) or 2
local LSP_STEPS = tonumber(os.getenv("LSP_STEPS")) or 2
local VERBOSE = os.getenv("VERBOSE") == "1"
local INCREMENTAL = os.getenv("LYE_INCREMENTAL") ~= "0"

--- xorshift32, so a run of this file with the same seed edits the same bytes in the same order.
local state = SEED % 0xffffffff
if state == 0 then state = 1 end
---@return integer
local function next()
	state = bit.bxor(state, bit.lshift(state, 13))
	state = bit.bxor(state, bit.rshift(state, 17))
	state = bit.bxor(state, bit.lshift(state, 5))
	return state
end
---@param count integer
---@return integer
local function pick(count)
	if count <= 1 then return 1 end
	return next() % count + 1
end

---@param path string
---@return string?
local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

---@param path string
---@return boolean
local function exists(path)
	local handle = io.open(path, "rb")
	if handle then handle:close() end
	return handle ~= nil
end

--- Every `.lua` under `dir`, sorted, with build output and version control left out.
---@param dir string
---@param pattern string?
---@return string[]
local function sources(dir, pattern)
	local found = {}
	for path in fs.scan(dir, pattern or "**/*.lua", {
		absolute = true,
		ignore = function(name) return name == "target" or name == ".git" or name == ".lye" end,
	}) do
		found[#found + 1] = path
	end
	table.sort(found)
	return found
end

local MALFORMED = {
	{ name = "empty", text = "" },
	{ name = "unterminated-string", text = "local s = \"abc\nreturn s\n" },
	{ name = "unterminated-comment", text = "--[[ still open\nlocal x = 1\nreturn x\n" },
	{ name = "unfinished-function", text = "local function f(\n\tlocal x = 1\n" },
	{ name = "stray-end", text = "end\nlocal x = 1\nreturn x\n" },
	{ name = "bad-annotation", text = "---@param\n---@return ???\nlocal function f(x) return x end\nreturn f\n" },
	{ name = "deep-nesting", text = ("local x = " .. ("("):rep(40) .. "1" .. (")"):rep(40) .. "\n") },
	{ name = "long-string-edit", text = "local s = [[\nline\n]]\nreturn s\n" },
}

--- The corpus, each entry carrying its text so an edit can be replayed without the disk.
---@return table<integer, { name: string, text: string, uri: string }>
local function corpus()
	local entries = {}
	---@param name string
	---@param text string
	---@param uri string
	local function add(name, text, uri)
		entries[#entries + 1] = { name = name, text = text, uri = uri }
	end

	for _, path in ipairs(sources(ROOT .. "/packages")) do
		if path:find("/src/", 1, true) and not path:find("/tests/", 1, true) then
			local text = read(path)
			if text then add(path:sub(#ROOT + 2), text, "file://" .. path) end
		end
	end
	for _, path in ipairs(sources(ROOT .. "/tools")) do
		local text = read(path)
		if text then add(path:sub(#ROOT + 2), text, "file://" .. path) end
	end

	local fixture = ROOT .. "/editors/vscode/tests/fixtures/benchmark-lde.lua"
	local fixtureText = read(fixture)
	if fixtureText then add("editors/vscode/tests/fixtures/benchmark-lde.lua", fixtureText, "file://" .. fixture) end

	-- The definitions the analyzer is handed: the built file when the package has one, otherwise
	-- the meta sources the build would have combined (they are already in the packages walk).
	local defs = ROOT .. "/packages/lye-defs/target/lye-defs/defs.lua"
	local defsText = read(defs)
	if defsText then add("lye-defs (assembled)", defsText, "file://" .. defs) end

	for _, snippet in ipairs(MALFORMED) do
		add("malformed/" .. snippet.name, snippet.text, "file:///tmp/lye-incremental/" .. snippet.name .. ".lua")
	end

	if FILE_LIMIT > 0 and #entries > FILE_LIMIT then
		local held = {}
		for index = 1, FILE_LIMIT do held[index] = entries[index] end
		return held
	end
	return entries
end

--- The parse as text, with every field a later pass reads. Node and token indices are part of it:
--- a resumed parse that renumbers what it kept would make every cached node index wrong.
---@param parsed lye.parser.Result
---@return string
local function dumpParse(parsed)
	local out = {}
	out[#out + 1] = "root=" .. tostring(parsed.root)
	for index = 1, parsed.tokens.count do
		local token = parsed.tokens.arena[index]
		out[#out + 1] = string.format("T%d|%d|%d|%d|%s", index, token.kind, token.start, token.stop,
			parsed.tokens.texts[token.index] or "")
	end
	--- A field of a node: a scalar as itself, a list of indices or names as its entries, so a call's
	--- arguments are compared too.
	---@param value unknown
	---@return string
	local function scalarOf(value)
		if type(value) ~= "table" then return tostring(value) end
		local items = {}
		for key, held in pairs(value) do
			items[#items + 1] = tostring(key) .. "=" .. (type(held) == "table" and "table" or tostring(held))
		end
		table.sort(items)
		return "{" .. table.concat(items, ",") .. "}"
	end
	for index, node in ipairs(parsed.nodes) do
		local scalars = {}
		for key, value in pairs(node) do
			if key ~= "parent" and key ~= "children" and key ~= "params" then
				scalars[#scalars + 1] = key .. "=" .. scalarOf(value)
			end
		end
		table.sort(scalars)
		local params = {}
		if node.params then
			for _, param in ipairs(node.params) do
				params[#params + 1] = string.format("%s@%d-%d/%s", tostring(param.name),
					param.start or 0, param.stop or 0, tostring(param.qualifier))
			end
		end
		out[#out + 1] = string.format("N%d|%s|%d|%d|d%s|p%s|c%s|s%s|a%s", index, node.kind,
			node.start, node.stop, tostring(node.depth), tostring(node.parent),
			node.children and table.concat(node.children, ",") or "",
			table.concat(scalars, ";"), table.concat(params, ","))
	end
	for index, declaration in ipairs(parsed.declarations) do
		out[#out + 1] = string.format("D%d|%s|%s|%d|%d|d%s|f%s|i%s|v%s|a%s|n%s|vp%s", index,
			declaration.name, tostring(declaration.qualifier), declaration.start, declaration.stop,
			tostring(declaration.depth), tostring(declaration.isFunction),
			tostring(declaration.initializer), tostring(declaration.valueIdx),
			tostring(declaration.anchorIdx), tostring(declaration.position),
			tostring(declaration.valuePosition))
	end
	for index, scope in ipairs(parsed.scopes) do
		out[#out + 1] = string.format("S%d|%d|%d|d%s|b%s|c%s", index, scope.start, scope.stop,
			tostring(scope.depth), tostring(scope.branch), tostring(scope.conditionIdx))
	end
	---@param map table
	---@return string
	local function keyed(map)
		local keys = {}
		for key in pairs(map or {}) do keys[#keys + 1] = key end
		table.sort(keys)
		local held = {}
		for _, key in ipairs(keys) do
			local value = map[key]
			if type(value) == "table" then
				local inner = {}
				for name in pairs(value) do inner[#inner + 1] = name end
				table.sort(inner)
				local fields = {}
				for _, name in ipairs(inner) do fields[#fields + 1] = name .. "=" .. tostring(value[name]) end
				held[#held + 1] = tostring(key) .. ":" .. table.concat(fields, ",")
			else
				held[#held + 1] = tostring(key) .. "=" .. tostring(value)
			end
		end
		return table.concat(held, " ")
	end
	out[#out + 1] = "fields=" .. keyed(parsed.tableFields)
	out[#out + 1] = "fieldValues=" .. keyed(parsed.tableFieldValues)
	out[#out + 1] = "indexes=" .. keyed(parsed.tableIndexes)
	out[#out + 1] = "top=" .. table.concat(parsed.topLevel or {}, ",")
	local diagnostics = {}
	for _, entry in ipairs(parsed.diagnostics or {}) do
		diagnostics[#diagnostics + 1] = string.format("%d|%d|%d|%s", entry.start or -1,
			entry.stop or -1, entry.severity or 1, entry.message or "")
	end
	table.sort(diagnostics)
	out[#out + 1] = "diagnostics=" .. table.concat(diagnostics, "\n")
	return table.concat(out, "\n")
end

--- Diagnostics are compared without their order: the same finding in the same place is the same
--- finding whether a resumed pass met it before or after another.
---@param diagnostics table[]
---@return string
local function dumpDiagnostics(diagnostics)
	local out = {}
	for _, entry in ipairs(diagnostics or {}) do
		out[#out + 1] = string.format("%d|%d|%d|%s", entry.start or -1, entry.stop or -1,
			entry.severity or 1, entry.message or "")
	end
	table.sort(out)
	return table.concat(out, "\n")
end

--- A type as bytes: what a module cache would persist, so a warm result has to produce the same.
---@param value unknown
---@return string
local function dumpType(value)
	if value == nil then return "nil" end
	local ok, bytes = pcall(serial.write, value)
	if not ok then return "error: " .. tostring(bytes) end
	return bytes or "nil"
end

--- The first lines two dumps differ on, which is what a failure file is for.
---@param expected string
---@param actual string
---@return string
local function difference(expected, actual)
	local left, right = {}, {}
	for line in (expected .. "\n"):gmatch("([^\n]*)\n") do left[#left + 1] = line end
	for line in (actual .. "\n"):gmatch("([^\n]*)\n") do right[#right + 1] = line end
	local out = {}
	for index = 1, math.max(#left, #right) do
		if left[index] ~= right[index] then
			out[#out + 1] = string.format("%d\n  expected: %s\n  actual:   %s", index,
				left[index] or "<missing>", right[index] or "<missing>")
			if #out >= 8 then break end
		end
	end
	return table.concat(out, "\n")
end

local failures = 0
local failureIndex = 0

---@param kind string
---@param entry { name: string, text: string, uri: string }
---@param step integer
---@param edit { category: string, start: integer, delete: integer, text: string, from: integer }
---@param expected string
---@param actual string
local function fail(kind, entry, step, edit, expected, actual)
	failures += 1
	failureIndex += 1
	local slug = entry.name:gsub("[^%w]+", "-"):sub(1, 48)
	local dir = string.format("%s/%03d-%s-%s", FAILURES, failureIndex, kind, slug)
	os.execute("mkdir -p " .. string.format("%q", dir))
	local function write(name, text)
		local handle = assert(io.open(dir .. "/" .. name, "wb"))
		handle:write(text)
		handle:close()
	end
	write("source.lua", edit.source or entry.text)
	local history = { "history:" }
	for index, held in ipairs(edit.history or {}) do
		history[#history + 1] = string.format("  %d %s from=%d delete=%d insert=%q", index,
			held.category, held.from or 0, held.delete or 0, held.text or "")
	end
	write("case.txt", table.concat({
		"kind: " .. kind,
		"file: " .. entry.name,
		"step: " .. step,
		"category: " .. edit.category,
		"from: " .. edit.from,
		"delete: " .. edit.delete,
		"insert: " .. string.format("%q", edit.text),
		"resume: " .. tostring(edit.resume),
		table.concat(history, "\n"),
		"",
	}, "\n"))
	write("expected.txt", expected)
	write("actual.txt", actual)
	write("diff.txt", difference(expected, actual))
	print(string.format("MISMATCH %s %s step %d (%s) -> %s", kind, entry.name, step, edit.category, dir))
end

local categories = { "string", "comment", "annotation", "body", "top", "start", "end" }
local used = {}
for _, name in ipairs(categories) do used[name] = 0 end

--- Tokens of one lexical kind, by arena index.
---@param parsed lye.parser.Result
---@param kind integer
---@return integer[]
local function tokensOf(parsed, kind)
	local found = {}
	for index = 1, parsed.tokens.count do
		if parsed.tokens.arena[index].kind == kind then found[#found + 1] = index end
	end
	return found
end

--- Insert, delete or replace inside the region of one category. `from` is the byte a parser would
--- resume at: the start of the text the edit changed.
---@param category string
---@param parsed lye.parser.Result
---@param text string
---@param action integer 1 insert, 2 delete, 3 replace
---@return { category: string, start: integer, delete: integer, text: string }?
local function choose(category, parsed, text, action)
	---@param start integer
	---@param delete integer
	---@param inserted string
	---@return { category: string, start: integer, delete: integer, text: string }
	local function edit(start, delete, inserted)
		return { category = category, start = start, delete = delete, text = inserted }
	end

	if category == "string" or category == "comment" then
		local kind = category == "string" and lexer.KIND.string or lexer.KIND.comment
		local found = tokensOf(parsed, kind)
		if #found == 0 then return nil end
		local token = parsed.tokens.arena[found[pick(#found)]]
		if token.stop - token.start < 2 then return nil end
		local start = token.start + 2
		if start > token.stop then return nil end
		if action == 1 then return edit(start, 0, category == "string" and "x" or " note") end
		if action == 2 then return edit(start, 1, "") end
		return edit(start, 1, category == "string" and "y" or "!")
	end

	if category == "annotation" then
		local found = tokensOf(parsed, lexer.KIND.comment)
		local candidates = {}
		for _, index in ipairs(found) do
			local token = parsed.tokens.arena[index]
			local body = text:sub(token.start, token.stop)
			local tag = body:match("^%-%-%-@([%a_]+)")
			if tag then candidates[#candidates + 1] = { token = token, tag = tag } end
		end
		if #candidates == 0 then return nil end
		local held = candidates[pick(#candidates)]
		-- `---@tag`: four bytes of `---@`, then the tag itself.
		local at = held.token.start + 4
		if action == 1 then return edit(at + #held.tag, 0, " ") end
		if action == 2 then return edit(at, 1, "") end
		return edit(at, #held.tag, "type")
	end

	if category == "body" then
		-- Statements of a function body are emitted as depth-1 nodes, not under the function node:
		-- the kind is what says a statement, the depth what says it is inside a block.
		local statements = {
			["local"] = true, assignment = true, ["return"] = true, call = true, ["if"] = true,
			["while"] = true, ["for"] = true, ["repeat"] = true, ["do"] = true,
		}
		local functions = {}
		for _, node in ipairs(parsed.nodes) do
			if node.kind == "function" then functions[#functions + 1] = node end
		end
		local candidates = {}
		for _, node in ipairs(parsed.nodes) do
			if node.depth > 0 and statements[node.kind] then
				for _, fn in ipairs(functions) do
					if node.start > fn.start and node.stop <= fn.stop then
						candidates[#candidates + 1] = node.start
						break
					end
				end
			end
		end
		if #candidates == 0 then return nil end
		local start = candidates[pick(#candidates)]
		if action == 1 then return edit(start, 0, "-- probe\n\t") end
		if action == 2 then return edit(start, math.min(2, #text - start + 1), "") end
		return edit(start, math.min(4, #text - start + 1), "-- r")
	end

	if category == "top" then
		local top = parsed.topLevel or {}
		if #top == 0 then return nil end
		local node = parsed.nodes[top[pick(#top)]]
		if not node then return nil end
		if action == 1 then return edit(node.start, 0, "-- top\n") end
		if action == 2 then return edit(node.start, math.min(2, node.stop - node.start + 1), "") end
		return edit(node.start, math.min(3, node.stop - node.start + 1), "-- t")
	end

	if category == "start" then
		if #text == 0 and action == 2 then return nil end
		if action == 1 then return edit(1, 0, "-- head\n") end
		if action == 2 then return edit(1, 1, "") end
		return edit(1, math.min(2, #text), "-- h")
	end

	-- The end of the file: a position after the last byte, or the last byte itself for a delete.
	if action == 1 then return edit(#text + 1, 0, "\n-- tail\n") end
	if #text == 0 then return nil end
	if action == 2 then return edit(#text, 1, "") end
	return edit(#text - 1, math.min(2, #text), "\n-- e\n")
end

--- Apply an edit at a byte span, 1-based and inclusive.
---@param text string
---@param edit { start: integer, delete: integer, text: string }
---@return string
local function apply(text, edit)
	return text:sub(1, edit.start - 1) .. edit.text .. text:sub(edit.start + edit.delete)
end

--- A position an editor would send for a byte offset, for ASCII lines only — the encoding of a
--- non-ASCII line is a client detail this oracle does not need to reproduce.
---@param text string
---@param offset integer
---@return { line: integer, character: integer }?
local function positionOf(text, offset)
	local before = text:sub(1, offset - 1)
	local _, newlines = before:gsub("\n", "\n")
	local lineStart = before:match(".*()\n") or 0
	local lineText = text:sub(lineStart + 1, (text:find("\n", lineStart + 1, true) or #text + 1) - 1)
	if lineText:find("[\128-\255]") then return nil end
	return { line = newlines, character = offset - 1 - lineStart }
end

--- Sampled identifier positions, spread over the file, for hover and definition.
---@param text string
---@param limit integer
---@return table<integer, { line: integer, character: integer }>
local function probePositions(text, limit)
	local tokens = lexer.tokenize(text)
	local found = {}
	for index = 1, tokens.count do
		local token = tokens.arena[index]
		if token.kind == lexer.KIND.name and token.stop > token.start then
			local position = positionOf(text, token.start)
			if position then found[#found + 1] = position end
		end
	end
	local held = {}
	if #found == 0 then return held end
	for index = 1, math.min(limit, #found) do
		held[#held + 1] = found[math.floor((index - 1) * #found / math.min(limit, #found)) + 1]
	end
	return held
end

---@param value table
---@return string
local function frame(value)
	local body = json.encode(value)
	return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

--- Play one server session: the framed requests written, the server run over them, the results
--- back by id. A server that crashes yields whatever it wrote, and the comparison reports it.
---@param frames string[]
---@param cache string
---@return table<string, any>
---@return string
local function session(frames, cache)
	local handle = assert(io.open(INPUT, "wb"))
	for _, bytes in ipairs(frames) do handle:write(bytes) end
	handle:close()
	local command = string.format(
		"cd %q && LYE_CACHE_DIR=%q lde run -C %q tests/fixtures/server.lua < %q 2>/dev/null",
		ROOT, cache, LSP_PACKAGE, INPUT)
	local pipe = assert(io.popen(command))
	local output = pipe:read("*a")
	pipe:close()

	local byId, at = {}, 1
	while true do
		local _, stop = output:find("\r\n\r\n", at, true)
		if not stop then break end
		local length = tonumber(output:sub(at, stop - 4):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
		if not length then break end
		local ok, message = pcall(json.decode, output:sub(stop + 1, stop + length))
		if ok and type(message) == "table" and message.id ~= nil then
			byId[tostring(message.id)] = message
		end
		at = stop + 1 + length
	end
	return byId, output
end

--- A deterministic rendering of a response, so two sessions that said the same thing compare equal.
---@param value unknown
---@return string
local function canonical(value)
	local kind = type(value)
	if kind ~= "table" then return kind .. ":" .. tostring(value) end
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
	local out = { "{" }
	for _, key in ipairs(keys) do
		out[#out + 1] = tostring(key) .. "=" .. canonical(value[key])
		out[#out + 1] = ","
	end
	out[#out + 1] = "}"
	return table.concat(out)
end

--- What the editor asks for at one point in a text. The ids come from the step, so the cold and
--- the warm session ask the same questions with the same numbers and the answers line up.
---@param uri string
---@param text string
---@param step integer
---@return table[]
local function asks(uri, text, step)
	local base = step * 100
	local list = {
		{
			jsonrpc = "2.0", id = base + 1, method = "textDocument/semanticTokens/full",
			params = { textDocument = { uri = uri } },
		},
	}
	local value = 1
	for _, position in ipairs(probePositions(text, 5)) do
		value += 1
		list[#list + 1] = {
			jsonrpc = "2.0", id = base + value, method = "textDocument/hover",
			params = { textDocument = { uri = uri }, position = position },
		}
		value += 1
		list[#list + 1] = {
			jsonrpc = "2.0", id = base + value, method = "textDocument/definition",
			params = { textDocument = { uri = uri }, position = position },
		}
	end
	return list
end

local lspChecks, lspMismatches, lspSkipped = 0, 0, nil

--- One cold session per sampled step and one warm session for the sequence; the answers have to
--- agree. A mismatch is reported through the same failure directory as the other paths.
---@param entry { name: string, text: string, uri: string }
---@param steps { text: string, edit: table }[]
---@param sampled integer[]
---@param cache string
local function lspCase(entry, steps, sampled, cache)
	local base = { jsonrpc = "2.0", id = 1, method = "initialize", params = { capabilities = {} } }
	local exit = { jsonrpc = "2.0", method = "exit" }

	for _, step in ipairs(sampled) do
		local questions = asks(entry.uri, steps[step].text, step)
		local frames = { frame(base), frame({
			jsonrpc = "2.0", method = "textDocument/didOpen",
			params = { textDocument = { uri = entry.uri, languageId = "lua", version = 1, text = steps[step].text } },
		}) }
		for _, request in ipairs(questions) do frames[#frames + 1] = frame(request) end
		frames[#frames + 1] = frame(exit)
		steps[step].cold = session(frames, cache)
		steps[step].ids = questions
	end

	local frames = { frame(base), frame({
		jsonrpc = "2.0", method = "textDocument/didOpen",
		params = { textDocument = { uri = entry.uri, languageId = "lua", version = 1, text = entry.text } },
	}) }
	local wanted = {}
	for _, step in ipairs(sampled) do wanted[step] = true end
	for index, step in ipairs(steps) do
		frames[#frames + 1] = frame({
			jsonrpc = "2.0", method = "textDocument/didChange",
			params = {
				textDocument = { uri = entry.uri, version = index + 1 },
				contentChanges = { { text = step.text } },
			},
		})
		if wanted[index] then
			for _, request in ipairs(asks(entry.uri, step.text, index)) do
				frames[#frames + 1] = frame(request)
			end
		end
	end
	frames[#frames + 1] = frame(exit)
	local warm = session(frames, cache)

	for _, step in ipairs(sampled) do
		local cold = steps[step].cold
		for _, request in ipairs(steps[step].ids) do
			local key = tostring(request.id)
			local expected = canonical(cold[key] and cold[key].result)
			local actual = canonical(warm[key] and warm[key].result)
			lspChecks += 1
			if expected ~= actual then
				lspMismatches += 1
				local history = {}
				for index = 1, step do history[#history + 1] = steps[index].edit end
				fail("lsp", entry, step, {
					category = "lsp", from = 0, delete = 0, text = "", resume = nil,
					source = steps[step].text, history = history,
				}, expected, actual)
			end
		end
	end
end

--- Run the LSP sample: the benchmark fixture and one tool, touched at a couple of steps.
---@param entries table[]
---@param sequences table<string, { text: string, edit: table }[]>
local function lsp(entries, sequences)
	if not LSP then
		lspSkipped = "LSP=0"
		return
	end
	if not exists(LSP_FIXTURE) then
		lspSkipped = "tests/fixtures/server.lua is absent"
		return
	end
	local chosen = {}
	for _, entry in ipairs(entries) do
		if #chosen >= LSP_FILES then break end
		if entry.name:find("benchmark%-lde%.lua$") or entry.name == "tools/incremental.lua" then
			chosen[#chosen + 1] = entry
		end
	end
	if #chosen == 0 then
		lspSkipped = "no sampled corpus file"
		return
	end

	local cache = "/tmp/lye-V-incremental-lsp"
	os.execute("rm -rf " .. string.format("%q", cache))
	for _, entry in ipairs(chosen) do
		local steps = sequences[entry.name]
		if steps then
			local sampled = {}
			local stride = math.max(1, math.floor(#steps / LSP_STEPS))
			for index = stride, #steps, stride do
				if #sampled < LSP_STEPS then sampled[#sampled + 1] = index end
			end
			if #sampled == 0 then sampled[1] = 1 end
			if VERBOSE then print("lsp sampled: " .. entry.name .. " steps " .. table.concat(sampled, ",")) end
			lspCase(entry, steps, sampled, cache)
		end
	end
end

local PRELUDE = analyzer.prelude(require("lye-defs"))
local entries = corpus()
local sequences = {}
local checks, resumedParser, resumedAnalyzer = 0, 0, 0
local analyzerSkipped = nil
if not INCREMENTAL then analyzerSkipped = "LYE_INCREMENTAL=0" end

os.execute("rm -rf " .. string.format("%q", FAILURES))
os.execute("mkdir -p " .. string.format("%q", FAILURES))

local startedAt = os.clock()
for fileIndex, entry in ipairs(entries) do
	local text = entry.text
	local steps, history = {}, {}
	-- The result the text held before the next edit, which is what A3.3 reads as `previous`.
	local previousAnalysis

	for step = 1, STEPS do
		local action = (step - 1) % 3 + 1
		-- The tree of the text as it stands, which is where an edit inside a string, a function or
		-- a statement is found.
		local before = parser.new(text):parse()
		local edit
		for offset = 0, #categories - 1 do
			local category = categories[(fileIndex + step + offset - 1) % #categories + 1]
			edit = choose(category, before, text, action)
			if edit and edit.start >= 1 and edit.start <= #text + 1
				and edit.delete <= #text - edit.start + 1 then
				break
			end
			edit = nil
		end
		if not edit then break end

		local edited = apply(text, edit)
		edit.from = edit.start
		edit.source = edited
		history[#history + 1] = edit
		edit.history = history
		used[edit.category] = (used[edit.category] or 0) + 1
		checks += 1

		-- A resume is single-use: `Parser.new` writes the kept nodes and the new ones into the
		-- tables it was handed, so the analyzer's warm run and the parser's get one each.
		local resume = parser.resumeAt and parser.resumeAt(before, edit.from) or nil
		edit.resume = resume and ("from=" .. resume.from) or "nil"
		local cold = parser.new(edited):parse()

		-- The analyzer, when its incremental path is on: the same diagnostics and the same module
		-- export bytes, from a warm run and a cold one. The options are the frozen shape of §2.2:
		-- `incremental = false` names the cold path explicitly, and the warm run is handed the
		-- predecessor result and the byte the edit starts at, so item reuse is compared too once
		-- it exists. A run of code that does not read them yet ignores them.
		if INCREMENTAL then
			local beforeAnalysis = previousAnalysis or analyzer.analyze(text, PRELUDE)
			local coldAnalysis = analyzer.analyze(edited, PRELUDE, nil, nil, nil, nil, nil, nil, nil, nil,
				{ uri = entry.uri, incremental = false })
			previousAnalysis = coldAnalysis
			if resume then
				resumedAnalyzer += 1
				local warmAnalysis = analyzer.analyze(edited, PRELUDE, nil, nil, resume, nil, nil, nil,
					nil, nil, { uri = entry.uri, previous = beforeAnalysis, from = edit.from })
				local coldDiagnostics = dumpDiagnostics(coldAnalysis.diagnostics)
				local warmDiagnostics = dumpDiagnostics(warmAnalysis.diagnostics)
				if coldDiagnostics ~= warmDiagnostics then
					fail("diagnostics", entry, step, edit, coldDiagnostics, warmDiagnostics)
				end
				local coldType = dumpType(coldAnalysis.module)
				local warmType = dumpType(warmAnalysis.module)
				if coldType ~= warmType then
					fail("module", entry, step, edit, coldType, warmType)
				end
				local coldTree = dumpParse(coldAnalysis.parser)
				local warmTree = dumpParse(warmAnalysis.parser)
				if coldTree ~= warmTree then fail("analyzer-parser", entry, step, edit, coldTree, warmTree) end
			end
		end

		-- The parser: keep what is before the edit and compare with a fresh parse of the result.
		if resume then
			local pristine = parser.new(text):parse()
			local held = parser.resumeAt(pristine, edit.from)
			if held then
				resumedParser += 1
				local warm = parser.new(edited, held):parse()
				local left, right = dumpParse(cold), dumpParse(warm)
				if left ~= right then fail("parser", entry, step, edit, left, right) end
			end
		end

		steps[#steps + 1] = { text = edited, edit = edit }
		text = edited
		if VERBOSE then
			print(string.format("%-56s step %d %-10s %s", entry.name, step, edit.category, edit.resume))
		end
	end
	sequences[entry.name] = steps
end

lsp(entries, sequences)

local elapsed = os.clock() - startedAt
print(string.format(
	"incremental: %d files, %d steps, %d parser resumes, %d analyzer resumes, %d LSP checks, %.2fs",
	#entries, checks, resumedParser, resumedAnalyzer, lspChecks, elapsed))
print("categories: " .. table.concat((function()
	local held = {}
	for _, name in ipairs(categories) do held[#held + 1] = name .. "=" .. tostring(used[name] or 0) end
	return held
end)(), " "))
if analyzerSkipped then print("analyzer warm: skipped (" .. analyzerSkipped .. ")") end
if lspSkipped then print("lsp warm: skipped (" .. lspSkipped .. ")") end
print(string.format("mismatches: %d", failures))
if failures > 0 then
	print("failures saved under " .. FAILURES:sub(#ROOT + 2))
	os.exit(1)
end
os.exit(0)
