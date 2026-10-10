--[[
	Where a builtin is declared.

	The definitions are embedded in the binary, so they have no file of their own to open. They are
	written into a cache directory instead and every jump into them points at that copy: it is the
	same text the analyzer reads, so offsets line up, and a client that lets one be edited changes a
	file nothing ever reads back.
]]

local Parser = require("lye-parser")
local doc = require("lye-doc")

local definitions = {}

---@class lye.DefinitionLocation
---@field uri string
---@field start integer
---@field stop integer

---@return string
local function cacheDir()
	local root = os.getenv("XDG_CACHE_HOME")
	if not root or root == "" then root = (os.getenv("HOME") or ".") .. "/.cache" end
	local path = root .. "/lye/defs"
	os.execute("mkdir -p '" .. path .. "'")
	return path
end

--- Write the sources where a client can open them, and index what each file declares: a class or
--- an alias by name, a function by the name it is declared under (`math.floor`), and a field by
--- the class it belongs to (`Point.x`).
---@param sources table<string, string> definition text by name
---@return table index
function definitions.prepare(sources)
	local dir = cacheDir()
	local index = { types = {}, names = {}, fields = {}, text = {}, lines = {}, modules = {} }

	for name, text in pairs(sources) do
		local path = dir .. "/" .. name .. ".lua"
		local handle = io.open(path, "wb")
		if handle then
			handle:write(text)
			handle:close()
		end
		local uri = "file://" .. path
		index.text[uri] = text

		-- A class, an alias and the fields of each, in the order they are written.
		local current
		for _, annotation in ipairs(doc.parse(text).annotations) do
			if annotation.tag == "class" or annotation.tag == "alias" then
				current = annotation.name
				if annotation.name then
					index.types[annotation.name] = {
						uri = uri,
						start = annotation.nameStart or annotation.start,
						stop = annotation.nameStop or annotation.stop,
					}
				end
			elseif annotation.tag == "field" and current and annotation.name then
				index.fields[current .. "." .. annotation.name] = {
					uri = uri,
					start = annotation.nameStart or annotation.start,
					stop = annotation.nameStop or annotation.stop,
				}
			end
		end

		-- The declarations themselves, `function math.floor()` among them.
		local parsed = Parser.new(text):parse()
		-- A definition file that returns a value is a module `require` may name. Over the whole
		-- corpus that is the same question as "does the engine ship this module": the sixteen that
		-- return one are the sixteen names `require` accepts — `ffi`, `jit`, `jit.util`,
		-- `string.buffer`, `table.new` and the rest — and `basic` and `builtin`, which only
		-- declare globals, are the two it refuses.
		for _, child in ipairs(parsed.nodes[parsed.root].children or {}) do
			if parsed.nodes[child].kind == "return" then
				index.modules[name] = { uri = uri, path = path }
				break
			end
		end
		for _, declaration in ipairs(parsed.declarations) do
			if not index.names[declaration.name] then
				index.names[declaration.name] = {
					uri = uri, start = declaration.start, stop = declaration.stop,
				}
			end
		end
	end

	return index
end

---@param index table
---@param name string?
---@return lye.DefinitionLocation?
local function locationOf(index, name)
	if not name then return nil end
	local found = index.types[name] or index.names[name] or index.fields[name]
	if not found then return nil end
	return { uri = found.uri, start = found.start, stop = found.stop, name = name }
end

--- The text of a definition file, and its line index, built when a jump first needs one.
---@param index table
---@param uri string
---@return string? text
---@return table? lineIndex
function definitions.sourceOf(index, uri)
	local text = index.text[uri]
	if not text then return nil end
	if not index.lines[uri] then
		index.lines[uri] = require("lye-framework.position").buildLineIndex(text)
	end
	return text, index.lines[uri]
end

--- The builtin a name refers to, when it is one.
---@param index table
---@param name string?
---@return lye.DefinitionLocation?
function definitions.find(index, name)
	return locationOf(index, name)
end

return definitions
