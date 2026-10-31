--[[
	Tests for the annotation tags that say how a declaration is used rather than what it takes:
	`---@deprecated`, `---@nodiscard`, `---@async` and `---@operator`.
]]

local test = require("lde-test")
local lye = require("lye-analyzer")
local types = require("lye-doc.type")

--- The diagnostics a result reports under one code.
---@param result lye.analyzer.Result
---@param code string
---@return lye.analyzer.Diagnostic[]
local function withCode(result, code)
	local found = {}
	for _, entry in ipairs(result.diagnostics) do
		if entry.code == code then found[#found + 1] = entry end
	end
	return found
end

--- The type a name has at the end of the source, as text.
---@param source string
---@param name string
---@param prepared lye.analyzer.Prelude?
---@return string? shown
local function typeOf(source, name, prepared)
	local result = lye.analyze(source, prepared)
	for _, variable in ipairs(result.variables) do
		if variable.name == name then
			return types.display(lye.typeAt(result, variable, #source))
		end
	end
end

test.it("reports a call to a deprecated function", function()
	local source = table.concat({
		"---@deprecated",
		"local function old(x) return x end",
		"old(1)",
	}, "\n")
	local found = withCode(lye.analyze(source), "deprecated")
	test.equal(#found, 1, "the call is reported once")
	test.equal(found[1].severity, 3, "as a hint")
	test.truthy(found[1].message:match("old is deprecated"), found[1].message)
end)

test.it("reports a read of a deprecated class field", function()
	local source = table.concat({
		"---@class Config",
		"---@field name string",
		"---@deprecated",
		"---@field legacy number",
		"local Config = {}",
		"---@type Config",
		"local config = {}",
		"local read = config.legacy",
	}, "\n")
	local found = withCode(lye.analyze(source), "deprecated")
	test.equal(#found, 1, "the field read is reported")
	test.truthy(found[1].message:match("legacy"), found[1].message)
	test.equal(withCode(lye.analyze(source), "type")[1], nil,
		"and a declared field is not a type error")
end)

test.it("reports a call to a deprecated method", function()
	local source = table.concat({
		"---@class Service",
		"local Service = {}",
		"---@deprecated",
		"function Service:stop() end",
		"---@type Service",
		"local service = {}",
		"service:stop()",
	}, "\n")
	local found = withCode(lye.analyze(source), "deprecated")
	test.equal(#found, 1, "the method call is reported")
	test.truthy(found[1].message:match("stop"), found[1].message)
end)

test.it("reports a deprecated global from the definitions", function()
	local defs = table.concat({
		"---@meta",
		"---@class tablelib",
		"table = {}",
		"---@deprecated",
		"---@param t table",
		"function table.maxn(t) end",
	}, "\n")
	local prepared = lye.prelude({ table = defs })
	local found = withCode(lye.analyze("table.maxn({})", prepared), "deprecated")
	test.equal(#found, 1)
	test.truthy(found[1].message:match("table%.maxn"), found[1].message)
end)

test.it("reports a nodiscard call whose result is dropped", function()
	local source = table.concat({
		"---@nodiscard",
		"local function compute() return 1 end",
		"compute()",
		"local kept = compute()",
		"local function used() return compute() end",
	}, "\n")
	local found = withCode(lye.analyze(source), "discard")
	test.equal(#found, 1, "only the statement throws the result away")
	test.equal(found[1].severity, 2)
	test.truthy(found[1].message:match("compute"), found[1].message)
end)

test.it("does not report a discarded result of a call nobody marked", function()
	local source = table.concat({
		"local function compute() return 1 end",
		"compute()",
	}, "\n")
	test.equal(#withCode(lye.analyze(source), "discard"), 0)
end)

test.it("keeps the async marker in the callable's type", function()
	local source = table.concat({
		"---@async",
		"---@return number",
		"local function tick() return 1 end",
	}, "\n")
	local result = lye.analyze(source)
	test.equal(result.signatures.tick.async, true)
	test.equal(typeOf(source, "tick"), "async fn() -> number")
end)

test.it("types an operator a class declares and checks its operands", function()
	local source = table.concat({
		"---@class Vec",
		"---@operator add(number): number",
		"---@field x number",
		"local Vec = {}",
		"---@type Vec",
		"local vec = {}",
		"local total = vec + 1",
	}, "\n")
	local result = lye.analyze(source)
	test.equal(typeOf(source, "total"), "number", "the operator's return types the sum")
	test.equal(#withCode(result, "operator"), 0)

	local wrong = source .. "local broken = vec + \"s\"\n"
	local reported = withCode(lye.analyze(wrong), "operator")
	test.equal(#reported, 1, "the right operand is checked against the operator")
	test.truthy(reported[1].message:match("number"), reported[1].message)
end)

test.it("does not report a nodiscard call whose value is used", function()
	local source = table.concat({
		"---@nodiscard",
		"local function num() return 1 end",
		"---@nodiscard",
		"local function flag() return true end",
		"if flag() then end",
		"while flag() do break end",
		"for i = num(), 2 do break end",
		"local t = { [num()] = \"x\" }",
		"local a, b",
		"a, b = num(), 1",
		"return t, a, b",
	}, "\n")
	test.equal(#withCode(lye.analyze(source), "discard"), 0)
end)

test.it("reports a call to a deprecated field function", function()
	local source = table.concat({
		"---@class Api",
		"---@deprecated",
		"---@field old fun(x: number): number",
		"local Api = {}",
		"---@type Api",
		"local api = {}",
		"api.old(1)",
	}, "\n")
	local found = withCode(lye.analyze(source), "deprecated")
	test.equal(#found, 1)
	test.truthy(found[1].message:match("old"), found[1].message)
end)
