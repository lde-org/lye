--[[
	The library entry point, as another package requires it.

	`main.lua` is the command line and the module a compiled binary starts; `init.lua` is what
	`require("lye-lsp")` reads. The difference is the contract tested here: requiring the library
	checks and reports, and starts nothing.
]]

local test = require("lde-test")
local lye = require("lye-lsp")
local check = require("lye-lsp.check")
local report = require("lye-lsp.report")

local sourcePath = assert(debug.getinfo(1, "S").source):sub(2)
local TESTS_DIR = assert(sourcePath:match("^(.*)/[^/]+$"))
local PACKAGE_DIR = assert(TESTS_DIR:match("^(.*)/tests$"))
local INPUT = PACKAGE_DIR .. "/target/library-input.lua"

---@param source string
local function writeInput(source)
	local handle = assert(io.open(INPUT, "wb"))
	handle:write(source)
	handle:close()
end

test.it("exposes the check and the report the command line uses", function()
	test.equal(lye.check, check)
	test.equal(lye.report, report)
	test.equal(type(lye.check.file), "function")
	test.equal(type(lye.check.files), "function")
	test.equal(type(lye.report.collect), "function")
end)

test.it("checks a file and keeps its findings instead of printing them", function()
	writeInput("local unused = 1\nreturn 1\n")

	local reporter = lye.report.collect()
	local isOk = lye.check.file(INPUT, nil, nil, reporter)
	test.equal(isOk, false, "a file with a finding does not pass")
	test.truthy(#reporter.collect > 0, "the reporter kept the finding")

	local finding = reporter.collect[1]
	test.equal(finding.path, INPUT)
	test.equal(finding.line, 1)
	test.truthy(finding.message)
end)

test.it("passes a file with nothing to report", function()
	writeInput("return 1\n")
	test.equal(lye.check.file(INPUT), true)
end)

return true
