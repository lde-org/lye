--[[
	Type-check every file in the repository and report what came back.

	A file is analyzed on its own — lye reads a document, not a workspace — so what another file
	declares is handed over: the class, or what an alias stands for. Without that a name like
	`lye.doc.Tag` resolves to nothing in the file that uses it, and every argument of every
	parameter typed with it disagrees with it.

		lde run -C packages/lye-lsp ../../tools/sweep.lua
		VERBOSE=1 lde run -C packages/lye-lsp ../../tools/sweep.lua   # every diagnostic, located
]]

local analyzer = require("lye-analyzer")
local doc = require("lye-doc")
local classes = require("lye-doc.class")

local ROOT = os.getenv("LYE_ROOT") or "/home/once/Projects/Personal/lye/"
if ROOT:sub(-1) ~= "/" then ROOT = ROOT .. "/" end
local VERBOSE = os.getenv("VERBOSE") == "1"

-- The packages of this repository, or whatever `LYE_ROOTS` names: a colon-separated list of
-- directories, so the same check can be pointed at another project entirely.
local roots = {}
for declared in (os.getenv("LYE_ROOTS") or ""):gmatch("[^:]+") do roots[#roots + 1] = declared end
if #roots == 0 then
	roots = {
		ROOT .. "packages/lye-analyzer/src", ROOT .. "packages/lye-lsp/src", ROOT .. "packages/lye-doc/src",
		ROOT .. "packages/lye-parser/src", ROOT .. "packages/lye-framework/src", ROOT .. "packages/lye-cdef/src",
		ROOT .. "packages/lye-lexer/src", ROOT .. "packages/lye-json/src", ROOT .. "packages/lye-rpc/src",
		-- The tools are Lua too, and they are the files most likely to drift: they read the packages
		-- through the same annotations a document does.
		ROOT .. "tools",
	}
end

local paths = {}
for _, root in ipairs(roots) do
	local pipe = io.popen(string.format(
		"find %q -name '*.lua' -not -path '*/target/*' -not -path '*/src/meta/*' 2>/dev/null", root))
	for line in pipe:lines() do paths[#paths + 1] = line end
	pipe:close()
end
table.sort(paths)

---@param path string
---@return string
local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

-- Every name the repository declares, and what it stands for.
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

local PRELUDE = analyzer.prelude(require("lye-defs"))
local counts = { error = 0, warning = 0, hint = 0 }
local catalog, hits, files = {}, 0, 0

for _, path in ipairs(paths) do
	files += 1
	if os.getenv("TRACE") == "1" then io.write("· " .. path:gsub(".*/", "") .. "\n") end
	local source = read(path)
	local names = analyzer.analyze(source, PRELUDE, foreign)
	local found = 0
	for _, entry in ipairs(names.diagnostics) do
		local severity = entry.severity or 1
		if severity >= 3 then counts.hint += 1
		elseif severity == 2 then counts.warning += 1
		else counts.error += 1 end
		found += 1
		if VERBOSE then
			local line = 1
			for at = 1, entry.start do
				if source:byte(at) == 10 then line += 1 end
			end
			print(string.format("%s:%d: [%d] %s", path:gsub(".*/lye/", ""), line, severity, entry.message))
		end
		local key = entry.message:gsub("`[^`]*`", "`x`"):gsub("%b{}", "{…}"):gsub("%d+", "N")
		catalog[key] = (catalog[key] or 0) + 1
	end
	if found > 0 then hits += 1 end
end

print(string.format("files=%d withDiagnostics=%d errors=%d warnings=%d hints=%d",
	files, hits, counts.error, counts.warning, counts.hint))

local ranked = {}
for message, count in pairs(catalog) do ranked[#ranked + 1] = { message = message, count = count } end
table.sort(ranked, function(a, b) return a.count > b.count end)
for index = 1, math.min(40, #ranked) do
	print(string.format("%6d  %s", ranked[index].count, ranked[index].message:sub(1, 150)))
end
