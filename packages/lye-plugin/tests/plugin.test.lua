--[[
	Tests for the plugin system: the edits a plugin answers with, the map that carries an answer
	back to the text an editor holds, and what a plugin that misbehaves costs.
]]

local test = require("lde-test")
local source = require("lye-plugin.source")
local plugin = require("lye-plugin")
local types = require("lye-doc.type")

local TESTS_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$")
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local WORK = PACKAGE_DIR .. "/target/plugin-fixture"

---@param path string
---@param content string
local function write(path, content)
	local dir = path:match("^(.*)/[^/]+$")
	os.execute("mkdir -p " .. string.format("%q", dir))
	local handle = assert(io.open(path, "wb"))
	handle:write(content)
	handle:close()
end

---@return string[]
---@return fun(message: string)
local function collecting()
	local said = {}
	return said, function(message) said[#said + 1] = message end
end

--- Where a plugin named rather than pathed comes from, as a package's own resolution answers: the
--- `target/` an lde dependency is linked into.
---@param name string
local function resolve(name)
	local path = WORK .. "/" .. name .. ".lua"
	local handle = io.open(path, "rb")
	if not handle then return nil end
	handle:close()
	return path
end

---@param specs lye.plugin.Spec[]
local function namesOf(specs)
	local out = {}
	for _, spec in ipairs(specs) do out[#out + 1] = spec.name end
	return table.concat(out, " ")
end

---@param said string[]
---@param piece string
---@return string?
local function about(said, piece)
	for _, message in ipairs(said) do
		if message:find(piece, 1, true) then return message end
	end
end

test.it("hands back the document itself when a plugin has nothing to say", function()
	local map = source.lower("local x = 1\n", {})
	test.equal(map.text, "local x = 1\n")
	test.equal(map:isEmpty(), true, "nothing moved")
	test.equal(map:toLowered(5), 5, "and a position is where it was")
	local from, to = map:toOriginal(5)
	test.equal(from, 5)
	test.equal(to, 5)
end)

test.it("reads the text a plugin lowered, and carries an answer back", function()
	-- A statement of another language, compiled: what lye reads is Lua, and what the editor holds
	-- is the line the reader wrote.
	local original = "x = 1\nprint(y)\n"
	local map = source.lower(original, {
		{ from = 1, to = 6, text = "local x = 1" },
	})
	test.equal(map.text, "local x = 1\nprint(y)\n", "the lowered text is what lye reads")
	test.equal(map:toLowered(1), 1, "the start of the statement is the start of it")
	test.equal(map:toLowered(15), 21, "text after it keeps its own place, moved by what was added")
	test.equal(map:toLowered(4), 1, "a position inside what was replaced is where the new text is")

	local from, to = map:toOriginal(13)
	test.equal(from, 7, "an offset in material no edit covers is itself, moved back")
	test.equal(to, 7)
	from, to = map:toOriginal(8)
	test.equal(from, 1, "and text the plugin wrote answers with the line it replaced")
	test.equal(to, 5)

	-- What the analysis reports inside the lowered text is pointed at the line the reader wrote.
	from, to = map:toOriginalRange(7, 9)
	test.equal(from, 1)
	test.equal(to, 5)
	from, to = map:toOriginalRange(13, 18)
	test.equal(from, 7, "text no replacement covers maps to itself")
	test.equal(to, 12)
end)

test.it("maps one to one through text a plugin says stands where the original stood", function()
	-- `same` is the promise a plugin makes when it re-emits a span unchanged: a move, or a
	-- statement it wrapped in something else.
	local original = "local a = 1\nlocal b = 2\n"
	local map = source.lower(original, {
		{ from = 1, to = 12, text = original:sub(1, 11), same = true },
	})
	test.equal(map.text, original)
	local from, to = map:toOriginal(7)
	test.equal(from, 7, "an offset inside it stays where it was")
	test.equal(to, 7)
	test.equal(map:toLowered(7), 7)
	from, to = map:toOriginalRange(1, 12)
	test.equal(from, 1)
	test.equal(to, 12)
end)

test.it("sorts the edits a plugin wrote in any order, and refuses ones that cannot be applied", function()
	local map = source.lower("abcdef", {
		{ from = 5, to = 6, text = "E" },
		{ from = 1, to = 2, text = "A" },
	})
	test.equal(map.text, "AbcdEf")

	map = source.lower("abcdef", { { from = 3, to = 3, text = "!" } })
	test.equal(map.text, "ab!cdef", "an edit that covers nothing is an insertion")

	---@param label string
	---@param edits lye.plugin.Edit[]
	local function refused(label, edits)
		local ok, err = pcall(source.lower, "abcdef", edits)
		test.falsy(ok, label .. " must be refused")
		test.includes(tostring(err), "edit", label .. ": " .. tostring(err))
	end
	refused("edits that overlap", {
		{ from = 1, to = 4, text = "x" },
		{ from = 3, to = 5, text = "y" },
	})
	refused("an edit past the text", { { from = 2, to = 99, text = "x" } })
	-- Deliberately malformed: an edit with no `text` is what the check has to refuse.
	local nameless = { { from = 3 } }
	---@cast nameless lye.plugin.Edit[]
	refused("an edit that names no text", nameless)
	refused("`same` over text of another length", { { from = 1, to = 3, text = "abcd", same = true } })
end)

test.it("keeps a position through two lowerings, and brings an answer back through both", function()
	-- A plugin for a second language sits on top of the first: its edits are written against the
	-- text the one before it produced, so a position travels down through them in order.
	local first = source.lower("x = 1\n", { { from = 1, to = 6, text = "local x = 1" } })
	local second = source.lower(first.text, { { from = 1, to = 12, text = "    local x = 1" } })
	local chain = source.chain({ first, second })
	test.equal(first.text, "local x = 1\n")
	test.equal(chain.text, "    local x = 1\n")
	test.equal(chain:toLowered(6), 16, "the statement's own line end is the last text's line end")
	test.equal(chain:toLowered(4), 1, "and a position inside the statement is where it starts")

	local from, to = chain:toOriginalRange(1, 5)
	test.equal(from, 1, "an answer covers what the first plugin replaced")
	test.equal(to, 5, "both replacements narrowing to the code the reader wrote")
end)

test.it("loads a plugin of the workspace's own, and turns a shipped one off by name", function()
	local said, report = collecting()
	write(WORK .. "/mine.lua", table.concat({
		"-- A plugin in the shape a workspace writes one.\n",
		"return {\n",
		"\tlower = function(context)\n",
		"\t\treturn { { from = 1, to = #context.source + 1, text = \"local lowered = 1\" } }\n",
		"\tend,\n",
		"}\n",
	}, ""))

	local specs = plugin.load({ "./mine.lua" }, WORK, resolve, report)
	test.equal(#specs, 4, "the plugin the workspace named, and the shipped ones it did not turn off")
	test.equal(namesOf(specs), "mine patterns formats ffi",
		"in the order the workspace listed it, then lye's own")
	test.equal(#said, 0, "and nothing was reported")

	local context = { uri = "file:///f.lua", source = "let x be 1", root = WORK }
	---@cast context lye.plugin.Context
	local map = plugin.lower(specs, context, report)
	test.equal(map.text, "local lowered = 1", "the document is lowered through the plugin")
	test.equal(context.text, "local lowered = 1", "and what the hooks were handed says so")

	local shipped = plugin.load({}, WORK, resolve, report)
	test.equal(namesOf(shipped), "patterns formats ffi",
		"the shipped plugins are on unless a workspace says otherwise")
	for _, spec in ipairs(shipped) do
		test.truthy(spec.tokens, "each colours tokens: " .. spec.name)
	end
	test.equal(#plugin.load({ "!patterns", "!formats", "!ffi" }, WORK, resolve, report), 0,
		"and a `!` leaves one out")
end)

test.it("reports a name lye does not ship, and a file that does not load", function()
	local said, report = collecting()
	local specs = plugin.load({ "nonsense", "./nowhere.lua", "!nonsense" }, WORK, resolve, report)
	test.equal(#specs, 3, "the shipped plugins, which were not turned off")
	test.equal(#said, 3, "every fault is reported")
	test.truthy(about(said, "installed in this package"), "a name that resolves to nothing")
	test.truthy(about(said, "nowhere.lua"), "a file that is not there")
	test.truthy(about(said, "turns off nothing"), "and a `!` naming something lye does not ship")
end)

test.it("reports a broken hook once, and asks it nothing after that", function()
	local said, report = collecting()
	write(WORK .. "/broken.lua", table.concat({
		"asked = 0\n",
		"return {\n",
		"\tlower = function()\n",
		"\t\tasked = asked + 1\n",
		"\t\terror(\"this plugin is no good\")\n",
		"\tend,\n",
		"}\n",
	}, ""))
	-- The plugin counts its own calls in a global, which is the only thing a loaded chunk and the
	-- test running it can share: declared here so that the count is a name the checker knows.
	asked = 0
	local specs = plugin.load({ "./broken.lua", "!patterns", "!formats", "!ffi" }, WORK, resolve, report)
	local context = { uri = "file:///f.lua", source = "x" }
	---@cast context lye.plugin.Context
	plugin.lower(specs, context, report)
	plugin.lower(specs, context, report)
	test.equal(asked, 1, "the hook was asked once")
	test.equal(#said, 1, "and the fault was reported once")
	test.truthy(about(said, "broken") and about(said, "this plugin is no good"),
		"with the plugin's name and its own words in it")
	test.equal(context.text, "x", "the document is left as it was")
end)

test.it("reports a lowering that cannot be applied, and keeps the document", function()
	local said, report = collecting()
	write(WORK .. "/greedy.lua", table.concat({
		"return {\n",
		"\tlower = function()\n",
		"\t\treturn { { from = 2, to = 99, text = \"x\" } }\n",
		"\tend,\n",
		"}\n",
	}, ""))
	local specs = plugin.load({ "./greedy.lua", "!patterns", "!formats", "!ffi" }, WORK, resolve, report)
	local context = { uri = "file:///f.lua", source = "short" }
	---@cast context lye.plugin.Context
	local map = plugin.lower(specs, context, report)
	test.equal(context.text, "short", "the document is left as it was")
	test.equal(map:isEmpty(), true, "and the map moves nothing")
	test.equal(#said, 1, "the fault is reported")
	test.truthy(about(said, "greedy"), "with the plugin's name in it")
end)

test.it("hands every plugin the text lye reads, and collects what they colour", function()
	local specs = plugin.load({ "./mine.lua", "!patterns", "!formats", "!ffi" }, WORK, resolve,
		function() end)
	local texts = {}
	---@cast specs lye.plugin.Spec[]
	specs[1].tokens = function(context)
		---@cast context lye.plugin.TokenContext
		texts[#texts + 1] = context.text
		return { { from = 1, to = 3, type = "property" } }
	end
	local context = { uri = "file:///f.lua", source = "abc", text = "abc" }
	---@cast context lye.plugin.TokenContext
	local spans = plugin.tokens(specs, context)
	test.equal(#spans, 1)
	test.equal(assert(spans[1]).type, "property")
	test.equal(texts[1], "abc", "the hook is handed the text lye reads")
end)

test.it("finds a plugin the package installed, and keeps what the workspace listed first", function()
	-- A plugin named rather than pathed is a module the package installed, which is what an lde
	-- dependency is: the resolver answers with the file in `target/` a `require` would find, which
	-- is the whole reason a plugin needs no registry of its own.
	write(WORK .. "/moonscript.lua", "return { extensions = { \"moon\" } }\n")
	local said, report = collecting()
	local specs = plugin.load({ "moonscript", "./mine.lua" }, WORK, resolve, report)
	test.equal(namesOf(specs), "moonscript mine patterns formats ffi",
		"the two the workspace named, then lye's own")
	test.equal(assert(specs[1].extensions)[1], "moon", "and the extension it claims comes with it")
	test.equal(#said, 0, "nothing to report")
end)

test.it("asks a plugin for the modules it offers inside a require", function()
	local specs = {
		{ name = "one", complete = function() return { { name = "a.b", detail = "LuaJIT" }, { name = "c" } } end },
		{ name = "two", complete = function() return { { name = "d", path = "/tmp/d.lua" } } end },
	}
	local context = {}
	---@cast context lye.plugin.CompletionContext
	local got = plugin.complete(specs, context)
	test.equal(#got, 3)
	test.equal(got[1].name, "a.b")
	test.equal(got[3].path, "/tmp/d.lua")
end)

test.it("asks a plugin for the types it contributes, and calls its providers", function()
	write(WORK .. "/typed.lua", table.concat({
		"local typed = {}\n",
		"function typed.types(context)\n",
		"\treturn {\n",
		"\t\tannotations = { { annotations = {} } },\n",
		"\t\tattach = function(resolve)\n",
		"\t\t\treturn { call = function() return resolve(\"T\") end }\n",
		"\t\tend,\n",
		"\t}\n",
		"end\n",
		"return typed\n",
	}, ""))
	local specs = plugin.load({ "./typed.lua", "!patterns", "!formats", "!ffi" }, WORK, resolve,
		function() end)
	local contexts = {
		source = "", text = "", parsed = { byKind = {} }, annotations = { annotations = {} },
		callName = function() return nil end,
	}
	---@cast contexts lye.plugin.TypeContext
	local got = plugin.types(specs, contexts, function() end)
	test.equal(#got, 1, "one contribution")
	test.equal(got[1].name, "typed", "named for the plugin that answered")
	---@cast got { name: string, types: lye.plugin.Types }[]
	local providers = assert(got[1].types.attach(function(name) return name end))
	local node = {}
	---@cast node lye.parser.Node
	test.equal(providers.call(node), "T", "the provider is built with the document's resolver")
end)

test.it("colours a pattern's escapes and a format's conversion through the shipped plugins", function()
	-- What the server used to do itself, so it is the behaviour that must not move: an escape and a
	-- magic character in a pattern, and a conversion in a format string, are the parts that are
	-- read rather than spelled.
	local Parser = require("lye-parser")
	local patterns = require("lye-plugin.plugins.patterns")

	local written = table.concat({
		"local s = \"a b\"\n",
		"local a = s:gsub(\"%s+\", \"-\")\n",
		"local b = string.format(\"%d\", 1)\n",
		"local kept = s:sub(2)\n",
	}, "")
	local parsed = Parser.new(written):parse()
	-- The receiver of each call is a string, which is what makes the field the `string` library's.
	local context = {
		uri = "file:///f.lua", source = written, text = written, parsed = parsed,
		map = source.lower(written, {}),
		typeOf = function() return types.STRING end,
		ownerOf = types.ownerOf,
	}
	---@cast context lye.plugin.TokenContext
	local spans = patterns.tokens(context)
	for _, span in ipairs(require("lye-plugin.plugins.formats").tokens(context)) do
		spans[#spans + 1] = span
	end
	local marks = {}
	for _, span in ipairs(spans) do
		marks[#marks + 1] = written:sub(span.from, span.to)
		test.equal(span.type, "regexp", "each is a part read as a pattern")
	end
	test.equal(table.concat(marks, " "), "%s + %d",
		"the escape, the repetition, and the conversion — and not a call that interprets nothing")

	-- A replacement's escapes are read too.
	local escaped = "local s = \"a\"\nlocal r = s:gsub(\"%a\", \"%%\")\n"
	local escapedContext = {
		uri = "file:///f.lua", source = escaped, text = escaped, parsed = Parser.new(escaped):parse(),
		map = source.lower(escaped, {}),
		typeOf = function() return types.STRING end, ownerOf = types.ownerOf,
	}
	---@cast escapedContext lye.plugin.TokenContext
	local other = patterns.tokens(escapedContext)
	test.equal(#other, 2, "the pattern and the replacement")
	test.equal(escaped:sub(other[2].from, other[2].to), "%%", "the escape in the replacement")
end)

test.it("colours an ffi.cdef block from our own parse of it, through the shipped plugin", function()
	-- The text handed to `ffi.cdef` is C, and asking the editor to inject a C grammar needs that
	-- grammar installed and would not know LuaJIT's dialect: the parse lye already makes is what
	-- the colours come from. The brackets are lye's own string token, not the plugin's.
	local Parser = require("lye-parser")
	local cdefPlugin = require("lye-plugin.plugins.ffi")

	local written = table.concat({
		"local ffi = require(\"ffi\")\n",
		"ffi.cdef[[\n",
		"typedef struct { int x; } Vec;\n",
		"]]\n",
	}, "")
	local parsed = Parser.new(written):parse()
	local context = {
		uri = "file:///f.lua", source = written, text = written, parsed = parsed,
		map = source.lower(written, {}),
	}
	---@cast context lye.plugin.TokenContext
	local marks = {}
	for _, span in ipairs(cdefPlugin.tokens(context)) do
		marks[#marks + 1] = written:sub(span.from, span.to) .. ":" .. span.type
	end
	test.includes(table.concat(marks, " "), "typedef:keyword", "the keyword")
	test.includes(table.concat(marks, " "), "struct:keyword", "the struct keyword")
	test.includes(table.concat(marks, " "), "int:type", "a builtin type")
	test.includes(table.concat(marks, " "), "Vec:class", "and the name the block declared")
	for _, mark in ipairs(marks) do
		test.falsy(mark:find("^%[%[", 1), "the brackets are left to the string token: " .. mark)
	end
end)

test.it("leaves a cdef block a lowering plugin wrote out of it", function()
	-- The block is in text lye was handed by another plugin, so there is no place in the document
	-- for its colours: a plugin colours the language it reads, and this is not the reader's.
	local Parser = require("lye-parser")
	local cdefPlugin = require("lye-plugin.plugins.ffi")

	local written = "ffi.cdef[[int x;]]\n"
	local lowered = "local lowered = 1\n"
	local map = source.lower(written, { { from = 1, to = #written + 1, text = lowered } })
	local context = {
		uri = "file:///f.lua", source = written, text = map.text,
		parsed = Parser.new(map.text):parse(), map = map,
	}
	---@cast context lye.plugin.TokenContext
	test.equal(#cdefPlugin.tokens(context), 0, "nothing is coloured")
end)

return true
