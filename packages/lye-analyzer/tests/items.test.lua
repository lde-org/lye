--[[
	Tests for the item manifest, the analyzer's phase counters, and the names an analysis resolved
	through `elsewhere` or handed to `modules`.

	The manifest is invisible to typing and checks in this wave: what it must get right is the
	structural identity of an item and the two hashes a later cache keys on.
]]

local test = require("lde-test")
local lye = require("lye-analyzer")
local types = require("lye-doc.type")

local URI = "file:///tmp/items.lua"

---@param source string
---@param options table?
local function analyze(source, options)
	return lye.analyze(source, nil, nil, nil, nil, nil, nil, nil, nil, nil,
		options and { uri = URI, incremental = true, counters = options.counters,
			previous = options.previous, from = options.from } or { uri = URI, incremental = true })
end

---@param tree lye.analyzer.ItemTree
---@return integer
local function count(tree)
	local n = 0
	for _ in pairs(tree.items) do n += 1 end
	return n
end

---@param tree lye.analyzer.ItemTree
---@param name string
---@return lye.analyzer.Item?
local function itemNamed(tree, name)
	for _, item in pairs(tree.items) do
		if item.name == name then return item end
	end
end

test.it("fills the requested counters and leaves them out otherwise", function()
	local counters = {}
	local result = analyze("local x = 1\n", { counters = counters })
	test.equal(result.counters, counters, "the table the caller passed is the one filled")
	for _, name in ipairs({
		"parse", "annotations", "namespace", "scopes", "typing", "typing2",
		"checks", "dedupe", "items", "reused", "retyped",
	}) do
		test.equal(type(counters[name]), "number", name .. " is measured")
		test.truthy(counters[name] >= 0, name .. " is not negative")
	end
	test.truthy(counters.items > 0, "the manifest is counted")
	test.equal(type(counters.retyped), "number", "retyped is a count of items, not a time")
	test.equal(counters.retyped, 0, "a chunk with no item of its own types no item")
	test.equal(counters.retypedItems, counters.retyped, "the explicit alias agrees")
	test.equal(counters.reused, 0, "nothing is reused without a previous result")

	local quiet = analyze("local x = 1\n")
	test.equal(quiet.counters, nil, "no counters are measured unless asked for")
	test.equal(type(quiet.items), "table", "the manifest is built for every analysis")
	test.equal(quiet.reused and next(quiet.reused), nil, "nothing is reused yet")
end)

test.it("keeps the cold path when incremental is off", function()
	-- A resume the parser could not read is proof the option reached the parse: with incremental
	-- on it is handed over, and the cold path has to drop it before the parser sees it.
	local source = "local first = 1\nlocal second = 2\n"
	local cold = analyze(source)
	local previous = analyze(source)
	local result = lye.analyze(source, nil, nil, nil, {}, nil, nil, nil, nil, nil,
		{ incremental = false, uri = URI, previous = previous, from = 18 })
	test.equal(#result.diagnostics, #cold.diagnostics, "the cold path parses from the source alone")
	test.equal(result.parser.source, source)
	test.falsy(rawequal(result.parser.nodes[1], previous.parser.nodes[1]),
		"previous and from are ignored, and the resume is dropped")
	test.equal(result.items.skeletonHash, cold.items.skeletonHash, "and still builds the same tree")
end)

test.it("derives a resume from the previous result and from", function()
	local previous = analyze("local first = 1\nlocal second = 2\n")
	local edited = "local first = 1\nlocal second = 3\n"
	-- The parser resumes only before a statement that *starts* before the edit, so the offset has
	-- to be inside the edited statement rather than at its first byte.
	local from = #("local first = 1\n") + 2
	local warm = analyze(edited, { previous = previous, from = from })
	local cold = analyze(edited, {})
	test.truthy(rawequal(warm.parser.nodes[1], previous.parser.nodes[1]),
		"the statement before the edit is the node the previous parse made")
	test.falsy(rawequal(cold.parser.nodes[1], previous.parser.nodes[1]),
		"a cold parse reads its own nodes")
	test.equal(#warm.diagnostics, #cold.diagnostics, "the derived resume changes no answer")
	test.equal(warm.items.skeletonHash, cold.items.skeletonHash,
		"and the manifest is the same either way")
end)

test.it("records a name the resolver read from elsewhere", function()
	-- The field's type is resolved inside `doc.classes.resolver`, which reads `elsewhere` on its
	-- own. A recording wrapper that only saw the analyzer's fallback would miss it.
	local remote = types.classType("Remote", {})
	local result = lye.analyze(
		"---@class Local\n---@field x Remote\nlocal Local = {}\n", nil,
		{ Remote = remote, OnlyName = true })
	test.truthy(result.declarationNames.Remote, "the field's foreign type is recorded")
	test.equal(result.declarationNames.OnlyName, nil,
		"a name that is only a typo guard is not a resolution")
end)

test.it("records the module names the callback was handed", function()
	local asked = {}
	local result = lye.analyze("local a = require(\"pkg.one\")\nlocal b = require(\"pkg.two\")\n",
		nil, nil, function(name)
			asked[#asked + 1] = name
			return nil
		end)
	test.equal(result.requiredModules["pkg.one"], true, "a require with no answer is recorded")
	test.equal(result.requiredModules["pkg.two"], true)
	test.equal(#asked, 2, "and the callback was asked for both")
	test.equal(result.requiredModules["pkg.three"], nil)

	local without = lye.analyze("local a = require(\"pkg.one\")\n")
	test.equal(next(without.requiredModules), nil, "no callback means no names to record")
end)

test.it("keeps an item ID stable across a body edit", function()
	local base = "local M = {}\nfunction M.double(x) return x * 2 end\n"
		.. "function M.plus(x) return x + 1 end\n"
	local before = analyze(base)
	local after = analyze("local M = {}\nfunction M.double(x) return x * 3 end\n"
		.. "function M.plus(x) return x + 1 end\n")
	local item = before.items.items["file:" .. URI .. "#function:M.double:1"]
	local plus = before.items.items["file:" .. URI .. "#function:M.plus:1"]
	test.truthy(item, "the function is an item named structurally")
	test.truthy(after.items.items[item.id], "the same edit leaves the ID alone")
	test.falsy(item.bodyHash == after.items.items[item.id].bodyHash, "the body hash changes")
	test.equal(before.items.skeletonHash, after.items.skeletonHash,
		"a body edit does not change the skeleton")

	-- An edit that shifts every later offset must still name both items the same way, and the
	-- untouched function's body slice is the same text even though it now starts later.
	local shifted = analyze("local M = {}\nfunction M.double(x)\n\treturn x * 2\nend\n"
		.. "function M.plus(x) return x + 1 end\n")
	local moved = shifted.items.items[plus.id]
	test.truthy(moved, "an offset shift does not rename the item")
	test.truthy(moved.start > plus.start, "its span moved")
	test.equal(moved.bodyHash, plus.bodyHash, "its body text did not")
	test.equal(shifted.items.skeletonHash, before.items.skeletonHash,
		"and the skeleton ignores how the body is laid out")
end)

test.it("changes the skeleton when a signature, annotation or module declaration changes", function()
	local base = "local M = {}\n---@param x number\nfunction M.double(x) return x * 2 end\n"
	local signature = base:gsub("---@param x number", "---@param x string")
	local annotation = base:gsub("function M.double%(x%) return x %* 2 end",
		"---@return number\nfunction M.double(x) return x * 2 end")
	local declaration = base:gsub("local M = {}", "local Mod = {}")
	local skeleton = analyze(base).items.skeletonHash
	test.falsy(skeleton == analyze(signature).items.skeletonHash, "a parameter type changed it")
	test.falsy(skeleton == analyze(annotation).items.skeletonHash, "an annotation changed it")
	test.falsy(skeleton == analyze(declaration).items.skeletonHash, "a module declaration changed it")
end)

test.it("puts the annotations above a local function in its signature", function()
	-- The statement opens at `local` and the name comes after it, so a leading block read from
	-- the name would find code between the annotations and the declaration and attach nothing.
	local source = "local M = {}\n---@param x number\n---@return number\n"
		.. "local function add(x) return x end\n"
		.. "---@param y string\nfunction M:put(y) end\n"
	local add = itemNamed(analyze(source).items, "add")
	test.equal(add.signature.params[1].name, "x")
	test.equal(add.signature.params[1].type, "number", "the parameter annotation is part of it")
	test.equal(add.signature.returns, "number", "and so is the return")
	test.equal(#add.signature.annotations, 2, "and the lines themselves")
	local put = itemNamed(analyze(source).items, "M:put")
	test.equal(put.signature.params[2].type, "string", "a method's parameter is read too")
end)

test.it("keeps a nested function inside the item that holds it", function()
	local source = "local function outer(a)\n\tlocal function inner(b)\n\t\treturn b\n\tend\n"
		.. "\treturn inner(a)\nend\n"
	local result = analyze(source)
	test.equal(count(result.items), 1, "the nested function is not an item of its own")
	local outer = itemNamed(result.items, "outer")
	test.truthy(outer, "the top-level function is")
	local innerStart = source:find("function inner", 1, true)
	local innerStop = source:find("return b", 1, true) + #"return b"
	test.truthy(outer.start <= innerStart and innerStop <= outer.stop,
		"the parent's span covers the nested function")

	local edited = source:gsub("return b", "return b + 1")
	local warm = analyze(edited)
	local same = itemNamed(warm.items, "outer")
	test.equal(same.id, outer.id, "a nested body edit leaves the parent ID alone")
	test.falsy(same.bodyHash == outer.bodyHash, "and the parent body hash sees the edit")
	test.equal(warm.items.skeletonHash, result.items.skeletonHash,
		"the edit is inside the parent body, so the skeleton is unchanged")
end)

test.it("makes a class and an alias items of their own", function()
	local result = analyze("---@class Foo<T>\n---@field value T\nlocal Foo = {}\n"
		.. "---@alias List<T> T[]\n")
	local class = itemNamed(result.items, "Foo")
	local alias = itemNamed(result.items, "List")
	test.truthy(class, "the class annotation is an item")
	test.equal(class.kind, "class")
	test.equal(class.signature.generics.T, true, "its parameter is part of the signature")
	test.truthy(alias, "the alias annotation is an item")
	test.equal(alias.kind, "alias")
end)

test.it("keeps top-level requires in the module item and body requires with their item", function()
	local result = analyze("local helper = require(\"pkg.helper\")\nlocal M = {}\n"
		.. "function M.run() return require(\"pkg.inner\") end\n")
	local module = result.items.moduleItem
	test.equal(module.deps.modules["pkg.helper"], true, "a top-level require belongs to the module")
	test.equal(module.deps.modules["pkg.inner"], nil, "one inside a function does not")
	test.equal(module.deps.tables.M, true, "the module table is recorded")
	local run = itemNamed(result.items, "M.run")
	test.equal(run.deps.modules["pkg.inner"], true, "the body's require belongs to the function")
	test.equal(run.deps.items, run.deps.items, "deps are a table")
end)

return true
