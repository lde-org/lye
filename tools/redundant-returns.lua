--[[
	Take out the `---@return` lines the analyzer reports as saying what the body already infers.

	The decision is not made here. The analyzer makes it, as a hint — "`---@return string` says what
	the body already infers" — and this reads those hints and removes the lines they point at, so the
	rule and the tool cannot disagree about which ones they are. A line only goes when nothing else
	shares it, since a line carrying two annotations is two annotations.

		LYE_ROOT=$PWD lde run -C packages/lye-lsp ../../tools/redundant-returns.lua
		LYE_ROOT=$PWD WRITE=1 lde run -C packages/lye-lsp ../../tools/redundant-returns.lua
]]

-- The packages through root `lye.json`, which the checker does not follow.
---@class lye.ReturnsDoc
---@field parse fun(source: string, tokens?: lye.lexer.Tokens): lye.doc.File

---@class lye.ReturnsClasses
---@field read fun(file: lye.doc.File): lye.doc.Namespace
---@field resolver fun(namespace: lye.doc.Namespace): fun(name: string): lye.doc.Type?

---@class lye.ReturnsAnalyzer
---@field prelude fun(sources: table<string, string>): lye.analyzer.Prelude
---@field analyze fun(source: string, prepared?: lye.analyzer.Prelude, elsewhere?: table<string, boolean|lye.doc.Type>?): lye.analyzer.Result

local analyzer = require("lye-analyzer") --[[@as lye.ReturnsAnalyzer]]
local doc = require("lye-doc") --[[@as lye.ReturnsDoc]]
local classes = require("lye-doc.class") --[[@as lye.ReturnsClasses]]

local ROOT = os.getenv("LYE_ROOT") or "/home/once/Projects/Personal/lye/"
if ROOT:sub(-1) ~= "/" then ROOT = ROOT .. "/" end
local WRITE = os.getenv("WRITE") == "1"

local roots = {
	ROOT .. "packages/lye-analyzer/src", ROOT .. "packages/lye-lsp/src", ROOT .. "packages/lye-doc/src",
	ROOT .. "packages/lye-parser/src", ROOT .. "packages/lye-framework/src", ROOT .. "packages/lye-cdef/src",
	ROOT .. "packages/lye-lexer/src", ROOT .. "packages/lye-json/src", ROOT .. "packages/lye-rpc/src",
}

local paths = {}
for _, root in ipairs(roots) do
	local pipe = io.popen(string.format(
		"find %q -name '*.lua' -not -path '*/target/*' -not -path '*/src/meta/*' 2>/dev/null", root))
	for line in pipe:lines() do
		---@cast line string
		paths[#paths + 1] = line
	end
	pipe:close()
end
table.sort(paths)

---@param path string
local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

-- The names the repository declares, so a file is analyzed the way the sweep analyzes it.
local foreign = {}
for _, path in ipairs(paths) do
	local file = doc.parse(read(path))
	local namespace = classes.read(file)
	local resolve = classes.resolver(namespace)
	for _, annotation in ipairs(file.annotations) do
		if (annotation.tag == "class" or annotation.tag == "alias") and annotation.name then
			foreign[annotation.name] = resolve(annotation.name) or true
		end
	end
end

local PRELUDE = analyzer.prelude(require("lye-defs") --[[@as table<string, string>]])
local total, filesTouched = 0, 0

for _, path in ipairs(paths) do
	local source = read(path)
	local names = analyzer.analyze(source, PRELUDE, foreign)
	--- The errors a source has: everything but the hints this file is about.
	---@param text string
	---@return integer
	local function errorsIn(text)
		local found = 0
		for _, entry in ipairs(analyzer.analyze(text, PRELUDE, foreign).diagnostics) do
			if (entry.severity or 1) < 3 then found += 1 end
		end
		return found
	end
	local baseline = errorsIn(source)

	local removable = {}
	for _, entry in ipairs(names.diagnostics) do
		if (entry.severity or 1) >= 3 and entry.message:match("says what the body already infers") then
			-- The line it is on: the offset of the newline before it decides the number, and the
			-- slice that says whether the annotation is all that is written there.
			local lineStart, line = entry.start, 1
			while lineStart > 1 and source:byte(lineStart - 1) ~= 10 do lineStart -= 1 end
			for at = 1, lineStart do
				if source:byte(at) == 10 then line += 1 end
			end
			local lineStop = (source:find("\n", entry.stop, true) or (#source + 1)) - 1
			local before, after = source:sub(lineStart, entry.start - 1), source:sub(entry.stop + 1, lineStop)
			-- Only when the line is that annotation and nothing else, and only when taking it out
			-- changes nothing: the types callers are checked against come from the annotation while
			-- it is there, so what the file says *without* it is the question that decides.
			if before:match("^%s*$") and after:match("^%s*$") then
				local without = source:sub(1, lineStart - 1) .. source:sub(lineStop + 2)
				if errorsIn(without) <= baseline then removable[#removable + 1] = line end
			end
		end
	end

	if #removable > 0 then
		filesTouched += 1
		total += #removable
		print(string.format("%-56s %d", path:gsub(".*/lye/", ""), #removable))
		if WRITE then
			local lines = {}
			for line in (source .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
			table.sort(removable)
			for index = #removable, 1, -1 do table.remove(lines, removable[index]) end
			local out = assert(io.open(path, "wb"))
			out:write(table.concat(lines, "\n"))
			out:close()
		end
	end
end

print(string.format("%s: %d return annotations across %d files",
	WRITE and "removed" or "removable", total, filesTouched))
