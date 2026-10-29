--[[
	The caches that make a keystroke cheaper without changing its answer.

	The paths here are the ones a repeated analysis takes: a namespace read once per annotation
	digest, and an annotation type text parsed once per resolver in an analysis. Each test compares
	the warm answer with the cold one — the first analysis in the process is the cold one for its
	text — and checks the boundary the caches must never cross: a parsed type, an evolved class or a
	contributed namespace belongs to one analysis, never to the next. Two analyses of one text must
	also write the same bytes, because `serial.write` writes a type graph by identity.
]]

local test = require("lde-test")
local lye = require("lye-analyzer")
local doc = require("lye-doc")
local types = require("lye-doc.type")
local memo = require("lye-analyzer.memo")
local serial = require("lye-doc.serial")

local URI = "file:///tmp/memo.lua"

---@param source string
---@param options table?
local function analyze(source, options)
	options = options or {}
	return lye.analyze(source, options.prepared, options.elsewhere, options.modules,
		nil, options.annotations, nil, nil, options.plugins, nil, {
			uri = URI, incremental = true, counters = options.counters,
		})
end

--- The answers a reader can see, as text: every diagnostic, every signature and the module.
---@param result lye.analyzer.Result
local function answer(result)
	local parts = {}
	for _, entry in ipairs(result.diagnostics or {}) do
		parts[#parts + 1] = string.format("d %d %d %d %s", entry.start, entry.stop or entry.start,
			entry.severity or 1, entry.message)
	end
	local names = {}
	for name in pairs(result.signatures or {}) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local signature = result.signatures[name]
		local params = {}
		for index, param in ipairs(signature.params or {}) do
			params[index] = param.name .. ":" .. (param.type or "")
		end
		parts[#parts + 1] = string.format("s %s (%s) -> %s", name, table.concat(params, ","),
			signature.returns and signature.returns.type or "")
	end
	parts[#parts + 1] = "m " .. (result.module and types.display(result.module) or "nil")
	return table.concat(parts, "\n")
end

--- The type a name has at the end of the source, as text.
---@param result lye.analyzer.Result
---@param source string
---@param name string
---@return string?
local function typeOf(result, source, name)
	for _, variable in ipairs(result.variables or {}) do
		if variable.name == name then
			return types.display(lye.typeAt(result, variable, #source))
		end
	end
end

-- The kinds of annotation a cache has to keep straight: a class with fields, an alias whose body
-- is a union, a generic signature, a table shape and a const parameter.
local CORPUS = {
	class = table.concat({
		"---@class Point\n",
		"---@field x number\n",
		"---@field y number\n",
		"local Point = {}\n",
		"---@return Point\n",
		"function Point.new()\n",
		"\treturn setmetatable({ x = 0, y = 0 }, Point)\n",
		"end\n",
		"local held = Point.new()\n",
	}, ""),
	alias = table.concat({
		"---@alias Mode number|string\n",
		"---@param mode Mode\n",
		"---@return Mode\n",
		"local function pick(mode) return mode end\n",
		"local held = pick(1)\n",
	}, ""),
	generics = table.concat({
		"---@generic T\n",
		"---@param item T\n",
		"---@return T, T?\n",
		"local function id(item) return item, nil end\n",
		"local n, missing = id(5)\n",
		'local s = id("a")\n',
	}, ""),
	tableShape = table.concat({
		"---@param options {name: string, count?: integer}\n",
		"---@return table<string, number>\n",
		"local function read(options) return {} end\n",
		"local held = read({ name = \"a\" })\n",
	}, ""),
	const = table.concat({
		"---@class Box<T: number, const N: integer>\n",
		"---@field value T\n",
		"---@type Box<number, 5>\n",
		"local held = { value = 1 }\n",
	}, ""),
	module = table.concat({
		"---@class App\n",
		"---@field run fun(self: App): number\n",
		"local M = {}\n",
		"function M.run() return 1 end\n",
		"return M\n",
	}, ""),
}

test.it("keeps the answer of a warm analysis identical to the cold one", function()
	for name, source in pairs(CORPUS) do
		---@cast name string
		---@cast source string
		local cold = answer(analyze(source))
		for round = 1, 3 do
			local warm = analyze(source)
			test.equal(answer(warm), cold, name .. " answers the same when its caches are warm (" .. round .. ")")
		end
	end
end)

test.it("reuses the annotations it already read and the texts it already parsed", function()
	local source = CORPUS.alias
	analyze(source)
	local counters = {}
	analyze(source, { counters = counters })
	test.equal(counters.namespaceReused, 1, "the namespace of the same annotations is the one already read")
	test.truthy(counters.typeHits > 0, "a text read twice in one analysis is parsed once")
	test.truthy(counters.typeMisses > 0, "and a text read once is read once")
end)

test.it("reads a namespace once per annotation digest", function()
	local source = CORPUS.class
	local annotations = doc.parse(source)
	---@cast annotations lye.doc.File
	local prepared = lye.prelude({ ["defs.lua"] = "---@meta\n---@class Point\nlocal Point = {}\n" })
	local first = memo.namespace(annotations, "digest-a", prepared)
	local second, reused = memo.namespace(annotations, "digest-a", prepared)
	test.truthy(reused, "the second read is a hit")
	test.equal(second.classes, first.classes, "the classes table is the same one")
	test.equal(second.aliases, first.aliases, "the aliases table is the same one")
	test.truthy(second.built ~= first.built, "the built-types table is new, so a class type is not shared")
	test.truthy(second.evolved ~= first.evolved, "the evolved table is new, so a method is not shared")

	local _, otherDigest = memo.namespace(annotations, "digest-b", prepared)
	test.falsy(otherDigest, "a different annotation digest is read again")

	local otherPrepared = lye.prelude({ ["defs.lua"] = "---@meta\n---@class Other\nlocal Other = {}\n" })
	local other, otherPreparedReused = memo.namespace(annotations, "digest-a", otherPrepared)
	test.falsy(otherPreparedReused, "the same text read against other definitions is read again")
	test.truthy(other.classes ~= first.classes, "and does not share the definitions it resolves through")
end)

test.it("keeps one analysis's evolved class out of the next", function()
	local annotations = doc.parse("---@class Widget\nlocal Widget = {}\n---@class Gadget\nlocal Gadget = {}\n")
	---@cast annotations lye.doc.File
	local first = memo.namespace(annotations, "evolve-digest", nil)
	local method = types.fn({}, types.NUMBER, false)
	doc.classes.evolve(first, "Widget", "size", method)
	local firstType = doc.classes.resolver(first)("Widget")
	local sizeField = types.fieldOf(firstType, "size")
	---@cast sizeField lye.doc.Type
	test.equal(types.display(sizeField), "fn() -> number", "the method is on this analysis's class")

	local second = memo.namespace(annotations, "evolve-digest", nil)
	local secondType = doc.classes.resolver(second)("Widget")
	test.equal(types.fieldOf(secondType, "size"), nil, "the next analysis's class never grew the method")
	test.equal(types.display(assert(secondType)), "Widget", "it is still the declared Widget")
end)

test.it("rebuilds when the annotations, definitions or plugins change", function()
	local source = CORPUS.alias
	local prepared = lye.prelude({ ["defs.lua"] = "---@meta\n" })
	analyze(source, { prepared = prepared })
	local counters = {}
	analyze(source, { prepared = prepared, counters = counters })
	test.equal(counters.namespaceReused, 1, "the same declarations and definitions are a hit")

	local changed = {}
	analyze(source .. "\n---@alias Mode boolean\n", { prepared = prepared, counters = changed })
	test.equal(changed.namespaceReused, 0, "an annotation that changed is read again")

	local otherPrepared = lye.prelude({ ["defs.lua"] = "---@meta\n---@class Mode\nlocal Mode = {}\n" })
	local other = {}
	analyze(source, { prepared = otherPrepared, counters = other })
	test.equal(other.namespaceReused, 0, "other definitions are read again")

	local noPlugins = {}
	analyze(source, { prepared = prepared, plugins = {}, counters = noPlugins })
	test.equal(noPlugins.namespaceReused, 1, "the annotations are still the same read whatever the plugins")
end)

test.it("reuses a namespace a plugin did not write, and copies one it did", function()
	-- The ffi plugin contributes classes only when it finds a `cdef` block. The first document has
	-- none, so the shared read is left untouched; the second does, and its contribution must not
	-- land in the table the first document's analysis shares.
	local without = "---@class Bare\nlocal Bare = {}\nlocal held = Bare\n"
	local firstCounters = {}
	analyze(without, { counters = firstCounters })
	local secondCounters = {}
	analyze(without, { counters = secondCounters })
	test.equal(secondCounters.namespaceReused, 1, "a document with nothing contributed shares its read")

	local withCdef = table.concat({
		"local ffi = require(\"ffi\")\n",
		"ffi.cdef[[\ntypedef struct { double x; } Contributed;\n]]\n",
		"---@type Contributed\nlocal held = ffi.new(\"Contributed\")\n",
	}, "")
	local result = analyze(withCdef)
	test.equal(typeOf(result, withCdef, "held"), "Contributed", "the contributed class is readable")
	for _, entry in ipairs(result.diagnostics) do
		test.falsy(entry.message:match("Contributed"), "the contributed class is not reported: " .. entry.message)
	end
	-- And the shared namespace the first document read has no Contributed class to give another
	-- analysis: the contribution wrote into a copy.
	local annotations = doc.parse(without)
	---@cast annotations lye.doc.File
	local namespace, reused = memo.namespace(annotations, "plugin-copy-digest", nil)
	test.falsy(reused, "the first read of this digest is a read")
	local ownFile = doc.parse(without)
	---@cast ownFile lye.doc.File
	test.equal(doc.classes.read(ownFile).classes.Contributed, nil, "nothing contributed is in the document's own classes")
	test.equal(namespace.classes.Contributed, nil, "and the shared read has no Contributed")
end)

test.it("writes the same bytes for two analyses of one text", function()
	-- `serial.write` writes a type graph by identity, so a table kept from an earlier analysis would
	-- change which tables a later answer shares. Two cold analyses of one text must be the same
	-- bytes, and so must one run after an analysis of a nearby text.
	local source = table.concat({
		CORPUS.generics,
		CORPUS.tableShape,
		"---@alias Mode number|string\n",
		"---@param mode Mode\n",
		"local function echo(mode) return mode, nil end\n",
		"return { id = echo, read = read }\n",
	}, "")
	---@param text string
	local function cold(text)
		local written = serial.write(lye.analyze(text, nil, nil, nil, nil, nil, nil, nil, nil, nil,
			{ uri = URI, incremental = false }).module)
		return assert(written)
	end
	local first = cold(source)
	local second = cold(source)
	test.equal(second, first, "the second cold analysis has the same bytes")
	local nearby = source:gsub("local function echo", "local  function echo")
	local before = cold(nearby)
	test.equal(cold(source), first, "and an analysis of a nearby text does not change them")
	test.truthy(before ~= "", "the nearby text is analysed too")
end)

test.it("does not hand a reused answer to a resolver that answers differently", function()
	-- `id(5)` and `id("a")` read the generic `T` through the same signature, but a different
	-- binding. A text cache keyed by name alone would give the second call the first one's answer.
	local source = table.concat({
		"---@generic T\n",
		"---@param item T\n",
		"---@return T\n",
		"local function id(item) return item end\n",
		"local n = id(5)\n",
		'local s = id("a")\n',
	}, "")
	local result = analyze(source)
	test.equal(typeOf(result, source, "n"), "5", "the first binding")
	test.equal(typeOf(result, source, "s"), "string", "the second binding is its own")
	for _, entry in ipairs(result.diagnostics) do
		test.falsy(entry.message:match("type") and entry.message:match("T"),
			"a generic name is not reported: " .. entry.message)
	end
end)
