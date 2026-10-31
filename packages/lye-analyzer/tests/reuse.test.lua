--[[
	Per-top-level-item reuse (A3.3): what a keystroke carries over, what it has to look at
	again, and the proof that the warm answer is the cold one.
]]

local test = require("lde-test")
local lye = require("lye-analyzer")
local types = require("lye-doc.type")

local URI = "file:///tmp/reuse.lua"

---@param source string
---@param options table?
local function analyze(source, options)
	local opts = options or {}
	opts.incremental = opts.incremental
	if opts.incremental == nil then opts.incremental = true end
	opts.uri = URI
	return lye.analyze(source, nil, nil, nil, nil, nil, nil, nil, nil, nil, opts)
end

---@param result lye.analyzer.Result
local function signatures(result)
	local list = {}
	for name, signature in pairs(result.signatures) do
		local inferred = signature.inferred ? tostring(signature.inferred.variant) : "-"
		list[#list + 1] = name .. ":" .. inferred
	end
	table.sort(list)
	return table.concat(list, "\n")
end

---@param result lye.analyzer.Result
local function diagnostics(result)
	local list = {}
	for _, entry in ipairs(result.diagnostics) do
		list[#list + 1] = string.format("%d:%d:%d:%s", entry.start, entry.stop or entry.start, entry.severity or 1, entry.message)
	end
	table.sort(list)
	return table.concat(list, "\n")
end

---@param map table<string, unknown>
---@return integer
local function count(map)
	local n = 0
	for _ in pairs(map) do n += 1 end
	return n
end

local BASE = [[
local M = {}

---@param x number
---@return number
function M.alpha(x)
	return x + 1
end

---@param y number
---@return number
function M.beta(y)
	return M.alpha(y) * 2
end

---@param z number
---@return number
function M.gamma(z)
	return M.beta(z) + 3
end

function M.entry(z)
	return M.gamma(z)
end

return M
]]

test.it("reuses only the items before the edit by default", function()
	local base = analyze(BASE)
	local counters = {}
	local edited = BASE:gsub("return M.alpha%(y%) %* 2", "return M.alpha(y) * 4")
	local warm = analyze(edited, {
		previous = base, from = BASE:find("return M.alpha", 1, true) + 1, counters = counters, reuse = true,
	})
	test.equal(counters.reused, 1, "the function before the edit is reused")
	test.truthy(warm.reused["file:" .. URI .. "#function:M.alpha:1"])
	test.falsy(warm.reused["file:" .. URI .. "#function:M.beta:1"], "the edited item is not reused")
	test.equal(counters.retyped, count(warm.items.items) - 1, "everything from the edit onward is recomputed")
	test.truthy(counters.conservative >= 1, "the refused rebase is counted")
	test.equal(diagnostics(warm), diagnostics(analyze(edited, { incremental = false })),
		"the warm diagnostics are the cold ones")
end)

test.it("reuses later items when rebasing is explicitly requested", function()
	local base = analyze(BASE)
	local counters = {}
	local edited = BASE:gsub("return M.alpha%(y%) %* 2", "return M.alpha(y) * 4")
	local warm = analyze(edited, {
		previous = base, from = BASE:find("return M.alpha", 1, true) + 1,
		counters = counters, rebase = true, reuse = true,
	})
	test.equal(counters.retyped, 1, "only the edited item is typed")
	test.equal(counters.reused, count(warm.items.items) - 1, "the rest are reused after rebasing")
	test.truthy(counters.rebased >= 1, "the rebased items are counted")
	test.equal(diagnostics(warm), diagnostics(analyze(edited, { incremental = false })))
end)

--- What every call in the result was bound to, by span: the value a hover reads for a call.
---@param result lye.analyzer.Result
---@return string[]
local function callTypes(result)
	local list = {}
	for index, node in ipairs(result.parser.nodes) do
		if node.kind == "call" then
			local held = result.callTypes[index]
			list[#list + 1] = string.format("%d:%d:%s", node.start, node.stop,
				held and types.display(held) or "nil")
		end
	end
	table.sort(list)
	return list
end

test.it("restores every cached call type at an offset, not only the first node there", function()
	-- A call starts where the prefix it is written on starts, and every call chained onto it
	-- starts there too. The generic call's binding and both pattern calls share their offsets with
	-- that prefix and with each other, so restoring by start alone loses all of them.
	local source = "local M = {}\n"
		.. "---@generic T\n---@param x T\n---@return T\nlocal function id(x) return x end\n"
		.. "function M.value() return id(5) end\n"
		.. "function M.clean(s) return s:gsub(\"a\", \"b\"):gsub(\"c\", \"d\") end\n"
		.. "function M.touch() return 1 end\n"
		.. "return M\n"
	local base = analyze(source)
	local edited = source:gsub("return 1", "return 2")
	local at = source:find("return 1", 1, true) + 1
	local counters = {}
	local warm = analyze(edited, { previous = base, from = at, counters = counters, reuse = true })
	local cold = analyze(edited, { incremental = false })
	test.truthy(warm.reused["file:" .. URI .. "#function:M.value:1"],
		"the function holding the generic call is reused")
	test.truthy(warm.reused["file:" .. URI .. "#function:M.clean:1"],
		"the function holding the chained calls is reused")
	local expected = callTypes(cold)
	test.equal(#expected, 3, "the cold run bound three calls")
	test.equal(table.concat(callTypes(warm), "\n"), table.concat(expected, "\n"),
		"the warm run restored all three call bindings")
	-- The generic call is the one that names its result: `id(5)` is the literal 5, not the
	-- signature's type variable. It shares its start with the prefix `id`.
	local generic
	for index, node in ipairs(warm.parser.nodes) do
		if node.kind == "call" and node.callee == "id" then generic = warm.callTypes[index] end
	end
	test.truthy(generic, "the generic call was restored")
	test.equal(types.display(generic), "5", "with the type the cold run bound, not the signature's")
	-- Two calls at one offset are told apart by their order among calls starting there.
	local sharedStart
	for index, node in ipairs(warm.parser.nodes) do
		if node.kind == "call" and node.field == "gsub" then
			if sharedStart == nil then
				sharedStart = node.start
			else
				test.equal(node.start, sharedStart, "the chained calls share one start")
			end
			test.truthy(warm.callTypes[index], "every call at the offset was restored")
		end
	end
end)

test.it("falls back to cold when the edit changes later offsets", function()
	local base = analyze(BASE)
	-- A body edit that changes its length shifts every later span. Until rebasing is proven, the
	-- safe answer is cold: the bodies are identical text at a new offset, and the model does not
	-- yet prove that is enough for a dirty item's inference.
	local edited = BASE:gsub("return M.alpha%(y%) %* 2", "return M.alpha(y) * 200")
	local at = BASE:find("return M.alpha", 1, true) + 1
	local counters = {}
	local warm = analyze(edited, { previous = base, from = at, counters = counters, reuse = true })
	test.equal(counters.reused, 0, "nothing is carried over across an offset change")
	test.equal(counters.retyped, count(warm.items.items), "everything is recomputed")
	test.equal(diagnostics(warm), diagnostics(analyze(edited, { incremental = false })),
		"and the answer is the cold one")
end)
test.it("invalidates callers when a signature changes", function()
	local base = analyze(BASE)
	local edited = BASE:gsub("---@param y number", "---@param y string", 1)
	local counters = {}
	local warm = analyze(edited, { previous = base, from = BASE:find("---@param y", 1, true), counters = counters, reuse = true })
	test.truthy(counters.retyped > 1, "the signature's callers are looked at again")
	test.equal(diagnostics(warm), diagnostics(analyze(edited, { incremental = false })),
		"the callers report what a cold run reports")
end)

test.it("dirties a function that reads a changed module-level name", function()
	local base = "local factor = 2\nlocal function scale(x) return x * factor end\nreturn scale\n"
	local result = analyze(base)
	local edited = "local factor = 3\nlocal function scale(x) return x * factor end\nreturn scale\n"
	local counters = {}
	local warm = analyze(edited, { previous = result, from = 15, counters = counters, reuse = true })
	test.equal(warm.reused["file:" .. URI .. "#function:scale:1"], nil,
		"the reader of the module-level name is recomputed")
	test.equal(diagnostics(warm), diagnostics(analyze(edited, { incremental = false })))
end)

test.it("dirties a reader when a function writes the module-level name it reads", function()
	-- The declaration and its initializer do not move, so the name's declaration digest does not
	-- either. A same-length write inside another function's body rebases every later item cleanly;
	-- only the assignment text says the reader now sees a string.
	local source = "local shared = 1\n"
		.. "local function write() shared = 1.0 end\n"
		.. "local function read() return shared + 1 end\n"
		.. "return write, read\n"
	local edited = source:gsub("shared = 1%.0", 'shared = "x"')
	test.equal(#edited, #source, "the write is the same length, so every span rebases cleanly")
	local base = analyze(source)
	local at = source:find("shared = 1.0", 1, true) + #"shared = "
	local counters = {}
	local warm = analyze(edited, {
		previous = base, from = at, counters = counters, rebase = true, reuse = true,
	})
	local cold = analyze(edited, { incremental = false })
	test.equal(warm.reused["file:" .. URI .. "#function:read:1"], nil,
		"the reader of the name a function writes is recomputed")
	test.equal(diagnostics(warm), diagnostics(cold), "and its diagnostics are the cold ones")
	--- The callable a reader was given carries what it returns, which is what a later caller of
	--- it reads; the exact snippet's `read` is enough to observe it.
	---@param result lye.analyzer.Result
	---@return string?
	local function readType(result)
		for _, variable in ipairs(result.variables) do
			if variable.name == "read" then
				return variable.initializer and types.display(variable.initializer) or nil
			end
		end
	end
	test.equal(readType(cold), "fn() -> unknown", "cold does not keep the number-era answer the write replaced")
	test.equal(readType(warm), readType(cold), "the warm reader reads it too")
end)

test.it("is honest about a comment edit", function()
	local base = analyze(BASE)
	local edited = BASE:gsub("local M = {}\n", "local M = {}\n-- a note\n", 1)
	local warm = analyze(edited, { previous = base, from = 13, reuse = true })
	test.equal(diagnostics(warm), diagnostics(analyze(edited, { incremental = false })),
		"a comment never changes the answer")
end)

test.it("carries an item over a comment inserted inside its body", function()
	local source = "local function add(x)\n\tlocal unused = 1\n\treturn x + 1\nend\nreturn add\n"
	local base = analyze(source)
	local at = assert(source:find("local unused", 1, true))
	local edited = source:sub(1, at - 1) .. "\t-- a note\n" .. source:sub(at)
	local counters = {}
	local warm = analyze(edited, {
		previous = base, from = at, counters = counters, reuse = true, rebase = true,
	})
	local addReused = false
	for id in pairs(warm.reused) do
		if id:find("function:add", 1, true) then addReused = true end
	end
	test.truthy(addReused, "a comment between statements does not invalidate the body")
	test.equal(diagnostics(warm), diagnostics(analyze(edited, { incremental = false })),
		"the warm answer is the cold one")
end)

test.it("does not reuse a comment inserted between an annotation and its declaration", function()
	local source = "---@param x number\nfunction add(x)\n\treturn x + 1\nend\nreturn add\n"
	local base = analyze(source)
	local at = assert(source:find("function add", 1, true))
	local edited = source:sub(1, at - 1) .. "-- a note\n" .. source:sub(at)
	local warm = analyze(edited, { previous = base, from = at, reuse = true, rebase = true })
	local addReused = false
	for id in pairs(warm.reused) do
		if id:find("function:add", 1, true) then addReused = true end
	end
	test.equal(addReused, false, "the annotation no longer reaches the function, so the body is read again")
	test.equal(diagnostics(warm), diagnostics(analyze(edited, { incremental = false })),
		"and its diagnostics are the cold ones")
end)

test.it("keeps an earlier caller reused when a body edit leaves the result alone", function()
	-- The caller is written before the callee, which is the only shape the safe default reuses:
	-- items after the edit are recomputed, so early cutoff is observable for a caller above it.
	local source = "local M = {}\n"
		.. "function M.entry(z) return M.beta(z) end\n"
		.. "---@param y number\n---@return number\nfunction M.beta(y) return y * 2 end\n"
		.. "return M\n"
	local base = analyze(source)
	local edited = source:gsub("return y %* 2", "return y * 3")
	local counters = {}
	local warm = analyze(edited, { previous = base, from = source:find("return y", 1, true) + 1, counters = counters, reuse = true })
	test.equal(counters.retyped, 1, "only the edited body is typed")
	test.equal(counters.invalidated, 0, "early cutoff kept its caller")
	test.truthy(warm.reused["file:" .. URI .. "#function:M.entry:1"], "the caller before the edit is reused")
	test.equal(diagnostics(warm), diagnostics(analyze(edited, { incremental = false })),
		"and the diagnostics agree")
end)

test.it("LYE_INCREMENTAL=0 reproduces the cold path exactly", function()
	local base = analyze(BASE)
	local edited = BASE:gsub("return M.beta%(z%) %+ 3", "return M.beta(z) + 4")
	local counters = {}
	local warm = analyze(edited, { previous = base, from = BASE:find("return M.beta", 1, true), counters = counters })
	local off = analyze(edited, { previous = base, from = BASE:find("return M.beta", 1, true), incremental = false })
	test.equal(count(off.reused), 0, "no item is reused with the switch off")
	test.equal(diagnostics(off), diagnostics(analyze(edited, { incremental = false })),
		"the switch-off run is the cold run")
	test.equal(diagnostics(off), diagnostics(warm), "and the warm run is the cold run")
end)

test.it("matches the cold answer over a small corpus", function()
	local corpus = {
		BASE,
		"---@class Point\n---@field x number\n---@field y number\n\nlocal Point = {}\n\n"
			.. "---@param a Point\n---@param b Point\n---@return Point\n"
			.. "function Point.add(a, b) return { x = a.x + b.x, y = a.y + b.y } end\n\nreturn Point\n",
		"local t = {}\nfor index = 1, 10 do t[index] = index * 2 end\n"
			.. "local function total() local sum = 0 for _, value in ipairs(t) do sum = sum + value end return sum end\n"
			.. "return total\n",
		"-- malformed\nlocal x = \nfunction \n",
	}
	for _, source in ipairs(corpus) do
		local base = analyze(source)
		local at = math.max(1, math.floor(#source * 0.4))
		local edited = source:sub(1, at - 1) .. "\n-- edit\n" .. source:sub(at)
		local warm = analyze(edited, { previous = base, from = at })
		local cold = analyze(edited, { incremental = false })
		test.equal(diagnostics(warm), diagnostics(cold), "warm equals cold for a corpus entry")
	end
end)


test.it("gives the cold signature and diagnostics for same-named declarations", function()
	-- Two functions named `resolve` in different scopes: signatures are keyed by name, so an
	-- annotation or a return that belongs to one must not settle the other. The default path is
	-- cold, so this is the invariant; opting into reuse must agree for a body-only edit.
	local source = "local function outer()\n"
		.. "\tlocal function resolve(text) return text end\n"
		.. "\treturn resolve\n"
		.. "end\n"
		.. "---@param value number\n"
		.. "---@return string\n"
		.. "local function resolve(value) return tostring(value) end\n"
		.. "return outer, resolve\n"
	local base = analyze(source)
	local edited = source:gsub("return text end", "return (text) end", 1)
	local cold = analyze(edited, { incremental = false })
	local from = source:find("return text", 1, true) + 1
	local default = analyze(edited, { previous = base, from = from })
	test.equal(diagnostics(default), diagnostics(cold), "the default diagnostics are cold")
	test.equal(signatures(default), signatures(cold), "the default signatures are cold")
	local warm = analyze(edited, { previous = base, from = from, reuse = true })
	test.equal(diagnostics(warm), diagnostics(cold), "opt-in diagnostics are cold")
	test.equal(signatures(warm), signatures(cold), "opt-in signatures are cold")
end)

test.it("gives the cold answer when a deletion makes the file malformed", function()
	local source = "local t = {}\n"
		.. "local function add(a, b) return a + b end\n"
		.. "local function call(x) return add(x, 1) end\n"
		.. "t.add, t.call = add, call\n"
		.. "return t\n"
	local base = analyze(source)
	local at = assert(source:find("add(x, 1)", 1, true))
	local edited = source:sub(1, at - 2) .. source:sub(at) -- break the identifier
	local cold = analyze(edited, { incremental = false })
	local default = analyze(edited, { previous = base, from = at })
	test.equal(diagnostics(default), diagnostics(cold), "the default diagnostics are cold")
	test.equal(signatures(default), signatures(cold), "the default signatures are cold")
	local warm = analyze(edited, { previous = base, from = at, reuse = true })
	test.equal(diagnostics(warm), diagnostics(cold), "opt-in diagnostics are cold")
	test.equal(signatures(warm), signatures(cold), "opt-in signatures are cold")
end)


--- The type every variable has where it is declared, in source order. A reused item's names are
--- not typed again, so this is what a hover in that item reads; it has to be the cold answer.
---@param result lye.analyzer.Result
local function variableTypes(result)
	local list = {}
	for _, variable in ipairs(result.variables) do
		list[#list + 1] = string.format("%s@%d=%s", variable.name, variable.declaration.start,
			types.display(lye.typeAt(result, variable, variable.declaration.start)))
	end
	table.sort(list)
	return table.concat(list, "\n")
end

local CONTEXTUAL = [[
---@class Span
---@field start number
---@field stop number

local M = {}

---@param spans Span[]
---@param visit fun(span: Span) -> boolean
local function each(spans, visit) end

---@param entry Span
local function take(entry) end

---@return Span[]
function M.run()
	local spans = {}
	each(spans, function(left, right)
		return left.start < right.start
	end)
	local empty = {}
	take(empty)
	return spans
end

return M
]]

test.it("keeps the types a reused body was read with", function()
	local base = analyze(CONTEXTUAL)
	local edited = CONTEXTUAL .. "\n-- a keystroke outside every body\n"
	local warm = analyze(edited, {
		previous = base, from = #CONTEXTUAL + 1, rebase = true, reuse = true,
	})
	test.equal(variableTypes(warm), variableTypes(base),
		"a parameter a call typed and a table a call shaped keep their answers")
end)

return true
