--[[
	What a plugin is, and how one is found, loaded and asked.

	A plugin is a Lua module that returns a table of hooks. lye calls them where a document is about
	to be read, and where an editor has asked something about one:

	* `lower(context)` answers the edits that turn the document into Lua lye can read. A plugin for
	  another language compiles what it can and says where each piece came from; lye works on the
	  result and reports in the original, which is what an editor holding that other language needs.
	* `tokens(context)` answers extra semantic tokens, in the offsets of the text lye read — the
	  lowered one, when a plugin lowered it.

	Only what a plugin has to be handed is handed: the document, the text lye reads, what the
	analysis worked out, and the map it is working under. Nothing about the server is visible, so a
	plugin cannot depend on how the server happens to be written today.

	A hook that raises is reported once and then left alone: a plugin is not allowed to take the
	server down with it, and an editor that repeats the same fault on every keystroke is unusable.
]]

local source = require("lye-plugin.source")

local plugin = {}

--- The plugins lye ships, by the name a workspace writes them with. Required rather than found by
--- name at runtime: a bundler follows a `require` it can see, and a module loaded from a string
--- built here is a file the compiled binary would not carry.
local SHIPPED = {
	patterns = require("lye-plugin.plugins.patterns"),
	formats = require("lye-plugin.plugins.formats"),
	cdef = require("lye-plugin.plugins.cdef"),
}

--- The order they are asked in when a workspace names none of them: a plugin's kind is looked up
--- after the ones before it had their say, so the order is written down rather than left to the
--- table's.
local SHIPPED_ORDER = { "patterns", "formats", "cdef" }

--- A context a hook is handed: the document, and the text lye reads.
---@class lye.plugin.Context
---@field uri string
---@field source string the document as the editor holds it
---@field text string the text lye reads — the lowered text, once a plugin has lowered it
---@field root string? the directory `lye.json` was read from, for a plugin with files of its own

--- Extra tokens, over the text lye reads.
---@class lye.plugin.TokenContext : lye.plugin.Context
---@field parsed lye.parser.Result
---@field analysis lye.analyzer.Result
---@field map lye.plugin.Map the map from the text lye reads back to the document
---@field typeOf fun(nodeIdx: integer): lye.doc.Type? what the analyzer worked out for a node
---@field ownerOf fun(held: lye.doc.Type?): string? the table a value's fields come from, as its name

--- One token a plugin wants an editor to colour, in the offsets of `context.source` — the document
--- as the editor holds it, which is the text the colour lands on. A plugin that reads
--- `context.parsed` is reading the *lowered* text, and maps what it found back with `context.map`,
--- leaving out what has no place in the document.
---@class lye.plugin.Span
---@field from integer byte offset into `context.source`, 1-based
---@field to integer byte offset one past the last byte
---@field type string a token type from the legend: `regexp`, `property`, `number`, `keyword`, …

--- A loaded plugin: the hooks it answered with, and what a fault in one costs.
---@class lye.plugin.Spec
---@field name string the name it was loaded under
---@field path string? the file it came from, for a plugin of the workspace's own
---@field extensions string[]? the file extensions its language is written in, without the dot:
--- `{ "moon" }` says a `.moon` file is one lye should read through this plugin
---@field lower fun(context: lye.plugin.Context): lye.plugin.Edit[]?
---@field tokens fun(context: lye.plugin.TokenContext): lye.plugin.Span[]?

--- A file of the workspace's own, loaded the way a plugin file is: a Lua chunk that returns the
--- hooks. `require` is reachable from it under the name the server's runtime gives it, which is
--- how a plugin uses anything lye ships.
---@param path string
---@param name string
---@param report fun(message: string)
---@return table? hooks
local function loadFile(path, name, report)
	local chunk, err = loadfile(path)
	if not chunk then
		report(string.format("plugin `%s`: %s", name, err or ("cannot read " .. path)))
		return nil
	end
	local ok, hooks = pcall(chunk)
	if not ok then
		report(string.format("plugin `%s`: %s", name, hooks))
		return nil
	end
	if type(hooks) ~= "table" then
		report(string.format("plugin `%s` answered with %s rather than a table of hooks",
			name, type(hooks)))
		return nil
	end
	return hooks
end

--- One plugin's hooks, with a hook that raises turned into a report and then nothing: the second
--- fault of the same kind is the same fault, and a keystroke repeats it.
---@param hooks table
---@param name string
---@param path string?
---@param report fun(message: string)
---@return lye.plugin.Spec
local function protect(hooks, name, path, report)
	local spec = { name = name, path = path }
	-- The file extensions the plugin's language is written in, if it named any: a check walking a
	-- directory has no way to know that `.moon` is Lua to this workspace without being told.
	if type(hooks.extensions) == "table" then
		local list = {}
		for _, extension in ipairs(hooks.extensions) do
			if type(extension) == "string" and extension ~= "" then
				list[#list + 1] = (extension:gsub("^%.", ""):lower())
			end
		end
		if #list > 0 then spec.extensions = list end
	end
	for _, hook in ipairs({ "lower", "tokens" }) do
		local asked = hooks[hook]
		if type(asked) == "function" then
			local broken = false
			spec[hook] = function(...)
				if broken then return nil end
				local ok, answer = pcall(asked, ...)
				if ok then return answer end
				broken = true
				report(string.format("plugin `%s`: %s is broken: %s", name, hook, answer))
				return nil
			end
		end
	end
	return spec
end

--- Whether an entry names a file rather than a plugin: a path is written as one — `./tools/x.lua`,
--- `/opt/x.lua` — and anything else is a name, resolved the way a `require` is.
---@param entry string
---@return boolean
local function isPath(entry)
	return entry:sub(1, 1) == "." or entry:sub(1, 1) == "/" or entry:sub(-4) == ".lua"
end

--- The plugins a workspace asked for, in the order it listed them:
---
---     "plugins": [
---         "./tools/moonscript.lua",  a file of the workspace's own, from the file that named it
---         "moonscript",              a module the package installed, resolved like a `require`
---         "!cdef"                    one lye ships, turned off
---     ]
---
--- The plugins lye ships are on unless a `!` turns one off, so a workspace that says nothing gets
--- them and an empty list is not a way to lose them. One entry is loaded once: naming a plugin
--- twice is naming it once, and the order is the order it was written in, because a plugin that
--- lowers a language is asked before one that colours it.
---
--- Entries that do not load are reported rather than fatal: an editor with a mistyped plugin name
--- still reads Lua.
---@param entries string[]? what the configuration listed
---@param root string? the directory the configuration was read from, which a relative path is relative to
---@param resolve fun(name: string): string? where a plugin named rather than pathed comes from
---@param report fun(message: string)
---@return lye.plugin.Spec[]
function plugin.load(entries, root, resolve, report)
	local specs, seen = {}, {}
	---@param name string
	---@param path string?
	local function add(name, path)
		if seen[name] then return end
		seen[name] = true
		local hooks = SHIPPED[name]
		if path then
			hooks = loadFile(path, name, report)
			if not hooks then return end
		end
		if not hooks then return end
		specs[#specs + 1] = protect(hooks, name, path, report)
	end

	---@param entry string
	local function listed(entry)
		if entry:sub(1, 1) == "!" then
			-- A plugin lye ships, turned off: it is in `SHIPPED` or it is a name this workspace
			-- made up, and which of the two it is worth saying.
			local name = entry:sub(2)
			if SHIPPED[name] then
				seen[name] = true
			else
				report(string.format("plugin `%s` is not one lye ships, so `!%s` turns off nothing",
					name, name))
			end
			return
		end
		if isPath(entry) then
			local path = entry
			if path:sub(1, 1) ~= "/" then path = (root or ".") .. "/" .. path:gsub("^%./", "") end
			add(entry:match("([^/]+)%.lua$") or path, path)
			return
		end
		local found = resolve and resolve(entry)
		if not found then
			report(string.format("plugin `%s` is not installed in this package and is not one lye "
				.. "ships", entry))
			return
		end
		add(entry, found)
	end

	for _, entry in ipairs(entries or {}) do
		if type(entry) == "string" and entry ~= "" then listed(entry) end
	end
	-- What lye ships is on unless a `!` turned it off — and nothing a workspace named itself is.
	for _, name in ipairs(SHIPPED_ORDER) do
		if not seen[name] then add(name, nil) end
	end
	return specs
end

--- Lower a document through every plugin that has something to say, each answering about the text
--- the one before it produced. Answers with the map: the text to read, and the way back.
---@param specs lye.plugin.Spec[]
---@param context lye.plugin.Context
---@param report fun(message: string)
---@return lye.plugin.Map
function plugin.lower(specs, context, report)
	local maps = {}
	local text = context.source
	context.text = text
	for _, spec in ipairs(specs) do
		if spec.lower then
			local edits = spec.lower(context)
			if edits then
				-- What a plugin answers is not to be trusted: an edit list that overlaps or runs
				-- past the text is that plugin's fault, and one that is reported is one the
				-- document survives. `source.lower` is what raises it, since making a text of the
				-- list is where the list has to make sense.
				local ok, map = pcall(source.lower, text, edits)
				if ok then
					maps[#maps + 1] = map
					text = map.text
					context.text = text
				else
					report(string.format("plugin `%s`: %s", spec.name, map))
				end
			end
		end
	end
	-- Nothing lowered the document — no plugin answered, or every edit list was refused — and the
	-- map is the one that moves nothing.
	if #maps == 0 then return source.lower(context.source, {}) end
	return source.chain(maps)
end

--- Every token every plugin asked for, over the text lye read.
---@param specs lye.plugin.Spec[]
---@param context lye.plugin.TokenContext
---@return lye.plugin.Span[]
function plugin.tokens(specs, context)
	local spans = {}
	for _, spec in ipairs(specs) do
		if spec.tokens then
			local asked = spec.tokens(context) or {}
			for _, span in ipairs(asked) do
				spans[#spans + 1] = span
			end
		end
	end
	return spans
end

return plugin
