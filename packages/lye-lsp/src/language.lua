--[[
	The lye language server: wires the protocol layer to the Lua tooling.
]]

-- First, so the mark it writes for `initialize` covers everything this server loaded.
local timing = require("lye-lsp.timing")
local rpc = require("lye-rpc")
local doc = require("lye-doc")
local classes = require("lye-doc.class")
local framework = require("lye-framework")
local position = require("lye-framework.position")
local json = require("lye-json")
local definitionsIndex = require("lye-lsp.definitions")
local Parser = require("lye-parser")
local analyzer = require("lye-analyzer")
local analyzerNames = require("lye-analyzer.names")
local editorconfig = require("lye-lsp.editorconfig")
local KIND = require("lye-lexer").KIND
local types = require("lye-doc.type")
local cache = require("lye-lsp.cache")
local plugin = require("lye-plugin")
-- A package of its own, but linked into this server: the static `require` is what a bundler can
-- see, and the hooks are handed to the plugin system below.
local requireCompletion = require("lye-plugin-require")
local Declarations = require("lye-lsp.declarations")
local Modules = require("lye-lsp.modules")
local AnalysisCache = require("lye-lsp.analysis_cache")

local SYMBOL_KIND = { ["function"] = 12, variable = 13 }

--- The LuaJIT definitions, prepared once: they are the same for every document, and parsing
--- them per keystroke would be absurd.
local PRELUDE = analyzer.prelude(require("lye-defs"))
-- The prelude is a namespace by content; its own class spells `aliases` too loosely for the
-- resolver's parameter.
---@type lye.doc.Namespace
local PRELUDE_NS = PRELUDE --[[@as lye.doc.Namespace]]
local PRELUDE_RESOLVE = doc.classes.resolver(PRELUDE_NS)

--- The plugin map answers a span as two values, which the checker cannot split across files; the
--- annotations here are what a caller reads, so the pair stays a pair.
---@param map lye.plugin.Map
---@param from integer
---@param to integer
---@return integer from
---@return integer to
local function originalRange(map, from, to)
	return map:toOriginalRange(from, to)
end

---@param map lye.plugin.Map
---@param offset integer
---@return integer
local function originalAt(map, offset)
	return (map:toOriginal(offset))
end

local TOKEN_LEGEND = {
	tokenTypes = {
		"keyword", "string", "number", "comment", "operator", "variable", "function", "parameter",
		"type", "namespace", "class", "property", "method", "regexp",
	},
	tokenModifiers = { "documentation" },
}

-- The name a receiver's type is declared under, which says whether a field is one of the standard
-- library's. It lives with the types, because a plugin is handed it as well.
local ownerOf = types.ownerOf

local TOKEN_TYPE = {}
for index, name in ipairs(TOKEN_LEGEND.tokenTypes) do
	TOKEN_TYPE[name] = index - 1
end

--- Modifiers are a bitmask, one bit per legend entry, in legend order.
local TOKEN_MODIFIER = {}
for index, name in ipairs(TOKEN_LEGEND.tokenModifiers) do
	TOKEN_MODIFIER[name] = 2 ^ (index - 1)
end

--- The words that are grammar inside a type rather than the name of one.
local TYPE_KEYWORD = {
	const = true, fun = true, fn = true, async = true,
	-- The values a type can name are constants rather than names of one.
	["true"] = true, ["false"] = true, ["nil"] = true,
}

-- An idle checkpoint after a pass has answered everything. A step is cheap and leaves the heap
-- smaller than the pause alone would; a full collection is only worth its pause when the heap has
-- really grown, or when a document that made it grow has closed.
local GC_STEP_BYTES = 2 * 1024 * 1024
local GC_FULL_BYTES = 8 * 1024 * 1024

-- The features a plugin extension has to join when its language is not Lua. The selector is
-- registered for each file extension a plugin claims, so an editor that supports dynamic document
-- registration sends the `.moon`/`.toy` document through the same handlers as a `.lua` one.
---@type { id: string, method: string, provider: string, capability: string[] }[]
local EXTENSION_FEATURES = {
	{ id = "hover", method = "textDocument/hover", provider = "hoverProvider",
		capability = { "textDocument", "hover" } },
	{ id = "definition", method = "textDocument/definition", provider = "definitionProvider",
		capability = { "textDocument", "definition" } },
	{ id = "type-definition", method = "textDocument/typeDefinition", provider = "typeDefinitionProvider",
		capability = { "textDocument", "typeDefinition" } },
	{ id = "implementation", method = "textDocument/implementation", provider = "implementationProvider",
		capability = { "textDocument", "implementation" } },
	{ id = "references", method = "textDocument/references", provider = "referencesProvider",
		capability = { "textDocument", "references" } },
	{ id = "document-highlight", method = "textDocument/documentHighlight",
		provider = "documentHighlightProvider", capability = { "textDocument", "documentHighlight" } },
	{ id = "document-symbol", method = "textDocument/documentSymbol", provider = "documentSymbolProvider",
		capability = { "textDocument", "documentSymbol" } },
	{ id = "rename", method = "textDocument/rename", provider = "renameProvider",
		capability = { "textDocument", "rename" } },
	{ id = "folding-range", method = "textDocument/foldingRange", provider = "foldingRangeProvider",
		capability = { "textDocument", "foldingRange" } },
	{ id = "selection-range", method = "textDocument/selectionRange", provider = "selectionRangeProvider",
		capability = { "textDocument", "selectionRange" } },
	{ id = "inlay-hint", method = "textDocument/inlayHint", provider = "inlayHintProvider",
		capability = { "textDocument", "inlayHint" } },
	{ id = "call-hierarchy", method = "textDocument/prepareCallHierarchy", provider = "callHierarchyProvider",
		capability = { "textDocument", "callHierarchy" } },
	{ id = "code-action", method = "textDocument/codeAction", provider = "codeActionProvider",
		capability = { "textDocument", "codeAction" } },
	{ id = "code-lens", method = "textDocument/codeLens", provider = "codeLensProvider",
		capability = { "textDocument", "codeLens" } },
	{ id = "color", method = "textDocument/documentColor", provider = "colorProvider",
		capability = { "textDocument", "colorProvider" } },
	{ id = "formatting", method = "textDocument/formatting", provider = "documentFormattingProvider",
		capability = { "textDocument", "formatting" } },
	{ id = "range-formatting", method = "textDocument/rangeFormatting",
		provider = "documentRangeFormattingProvider", capability = { "textDocument", "rangeFormatting" } },
	{ id = "type-formatting", method = "textDocument/onTypeFormatting",
		provider = "documentOnTypeFormattingProvider", capability = { "textDocument", "onTypeFormatting" } },
	{ id = "completion", method = "textDocument/completion", provider = "completionProvider",
		capability = { "textDocument", "completion" } },
	{ id = "signature-help", method = "textDocument/signatureHelp", provider = "signatureHelpProvider",
		capability = { "textDocument", "signatureHelp" } },
	{ id = "semantic-tokens", method = "textDocument/semanticTokens",
		provider = "semanticTokensProvider", capability = { "textDocument", "semanticTokens" } },
	-- Diagnostics are pushed for every document the sync registration opens. Pulling them too
	-- makes an editor show the same finding from both paths; the extensions get the sync stream.
}

--- Walk the words of a type and hand each to `visit` with the kind it reads as. A type holds
--- names, string literals, numbers and the `|` between union members; the punctuation around them
--- is grammar and is left to whatever writes the token.
---
--- A type is written in two places — inside an annotation and in a definition file's own
--- signature — and both colour the same way, so both walk it here.
---@param text string
---@param from integer
---@param stop integer
---@param visit fun(start: integer, stop: integer, target: string)
local function typeWords(text, from, stop, visit)
	local written = text:sub(from, stop)
	local cursor = 1
	while cursor <= #written do
		local quoteAt = written:find("['\"]", cursor)
		local nameAt = written:find("[%a_]", cursor)
		local numberAt = written:find("%d", cursor)
		local barAt = written:find("|", cursor, true)
		if quoteAt and (not nameAt or quoteAt < nameAt) then
			local quote = written:sub(quoteAt, quoteAt)
			local closeAt = written:find(quote, quoteAt + 1, true) or #written
			visit(from + quoteAt - 1, from + closeAt - 1, "string")
			cursor = closeAt + 1
		elseif nameAt and (not numberAt or nameAt < numberAt) and (not barAt or nameAt < barAt) then
			local _, nameStop = written:find("^[%a_][%w_%.]*", nameAt)
			local word = written:sub(nameAt, nameStop)
			-- `const` and the signature keywords are grammar rather than names of a type:
			-- `---@alias Font<const Size: number>` marks a parameter.
			visit(from + nameAt - 1, from + nameStop - 1, TYPE_KEYWORD[word] and "keyword" or "type")
			cursor = nameStop + 1
		elseif numberAt and (not barAt or numberAt < barAt) then
			-- `---@type 2149 | 231` lists numbers, and a number is a number.
			local _, numberStop = written:find("^%d[%w%.]*", numberAt)
			visit(from + numberAt - 1, from + numberStop - 1, "number")
			cursor = numberStop + 1
		elseif barAt then
			-- The `|` between members is punctuation rather than text, so it reads in the editor's
			-- own colour instead of the colour of what holds it.
			visit(from + barAt - 1, from + barAt - 1, "operator")
			cursor = barAt + 1
		else
			break
		end
	end
end


--- A `---@tag` inside a comment, with the tag's own span. Whitespace is matched without
--- newlines, so a tag never counts as spanning two lines.
local DOC_TAG = "%-%-%-[ \t]*@"
local DOC_TAG_NAME = "[%a_][%w_]*"

---@class lye.lsp.Position
---@field line integer
---@field character integer

---@class lye.lsp.Range
---@field start lye.lsp.Position
---@field ["end"] lye.lsp.Position

---@class lye.lsp.TextDocument
---@field uri string

---@class lye.lsp.ItemData
---@field uri string?
---@field name string?
---@field offset integer?

---@class lye.lsp.Item
---@field data lye.lsp.ItemData?
---@field uri string?
---@field name string?
---@field kind integer?
---@field label string?
---@field detail string?
---@field documentation string|table?
---@field textEdit table?

---@class lye.lsp.Context
---@field includeDeclaration boolean?
---@field diagnostics lye.analyzer.Diagnostic[]?

---@class lye.lsp.DocumentSymbol
---@field name string
---@field kind integer
---@field range table
---@field selectionRange table
---@field children lye.lsp.DocumentSymbol[]?

---@class lye.lsp.Params
---@field textDocument lye.lsp.TextDocument?
---@field position lye.lsp.Position?
---@field range lye.lsp.Range?
---@field positions lye.lsp.Position[]?
---@field context lye.lsp.Context?
---@field item lye.lsp.Item?
---@field newName string?
---@field query string?

--- What a document change carries. The protocol sends the document, and the field is stated as
--- present here: a table whose every field is optional makes a later argument mis-bind.
---@class lye.lsp.ChangeParams
---@field textDocument lye.lsp.TextDocument

---@class lye.Server
---@field server lye.framework.Server
---@field analysis table<string, lye.parser.Result>
---@field names table<string, lye.analyzer.Result>
---@field packageRoots table<string, string|boolean>? which package each path belongs to, by `find`
---@field packageNames table<string, table<string, boolean|lye.doc.Type>>? what each package's `target/` declares
---@field packageDigests table<string, string>? the digest of each package's links, keyed by root
---@field typeLocations table<string, { location: lye.DefinitionLocation, lines: string }>? where each class or alias is written
---@field annotationsDigest string? the digest of every annotation the workspace scan read
---@field declarations lye.Declarations the workspace/package declarations and their view
---@field modules lye.Modules what each required file gives, and the digest of the open documents
---@field prelude table the definitions, prepared once for every analysis
---@field declaredBy table<string, table<string, boolean|lye.doc.Type>> what each document declares, kept after its analysis is dropped
---@field known table<string, boolean|lye.doc.Type>? what every file in the workspace declares, resolved
---@field order string[] the documents whose analyses are held, least recently used first
---@field cache lye.AnalysisCache the analyses, parses, predecessors and annotations this session holds
---@field epoch integer how many changes this session has seen, which a held result is recorded against
---@field definitions lye.Definitions? the definitions, indexed by name, built once
---@field plugins_ table<string, lye.plugin.Spec[]>? the plugins each package asked for, loaded once
---@field views table<string, lye.View>? what lye reads of each open document, and the way back
---@field dirty table<string, boolean> documents whose analysis is stale
---@field lastHeap number? the heap size at the last collection checkpoint
---@field dirtyAt table<string, number>? when each dirty document last changed, so the newest is analysed first
---@field dirtyEpoch table<string, integer>? which change count last marked each dirty document, breaking a tie on the clock
---@field tokens_ table<string, { text: string, answer: table }>? the token answer for a document
--- that has not changed since it was worked out
---@field viewByIndex table<lye.framework.LineIndex, lye.View>? the same, found by a line index a
--- range was written with
---@field workspace table[]? the symbols of the workspace, listed once
---@field settings table<string, table<string, string>>? the `.editorconfig` per directory
local Lye = {}
Lye.__index = Lye

---@param server lye.framework.Server
function Lye.new(server)
	local lye = setmetatable({
		server = server, declaredBy = {}, dirty = {}, epoch = 0, prelude = PRELUDE,
		lastHeap = timing.heap(),
	}, Lye)
	-- The cache owns `analysis`, `names` and `order`; it publishes the same tables on `lye`,
	-- because the declaration and module facades read them and must see what it clears.
	lye.cache = AnalysisCache.new(lye)
	lye.declarations = Declarations.new(lye)
	lye.modules = Modules.new(lye)
	return lye
end

--- What a checkpoint should do, from how many bytes the heap grew since the last one. Kept apart
--- from `checkpoint` so the policy is testable without a server or a collector.
---@param grown number bytes the heap grew
---@param force boolean? a document closed, which makes the answer worth the pause
---@return boolean collect
---@return boolean full
function Lye.gcDecision(grown, force)
	if force or grown >= GC_FULL_BYTES then return true, true end
	if grown >= GC_STEP_BYTES then return true, false end
	return false, false
end

--- A bounded collection between requests. It runs after an idle pass has published every answer,
--- or after a close, so no analysis and no reply is paying for it. Growth is measured from the
--- last checkpoint, so a heap that is not growing is left to the pause alone. Under `LYE_TIMING=1`
--- the resident set, the heap and whether it collected are written as one stable mark.
---@param force boolean? collect fully whatever the growth
---@return boolean collected
---@return boolean full
---@param self lye.Server
function Lye:checkpoint(force)
	local started = timing.now()
	local grown = (timing.heap() - self.lastHeap) * 1024
	local collect, full = Lye.gcDecision(grown, force)
	if collect then
		if full then collectgarbage("collect") else collectgarbage("step") end
		self.lastHeap = timing.heap()
	end
	timing.memory(started, collect)
	return collect, full
end

--- The modules a `require("...")` could name, in the layout the workspace uses.
---@param self lye.Server
---@param prefix string what has been typed inside the quotes so far
---@return { name: string, path: string?, detail: string? }[] a workspace file has a path, a module of the engine a detail
function Lye:moduleNames(prefix)
	return self.declarations:moduleNames(prefix)
end

--- The modules a `require("...")` could name, in the layout the workspace uses.
---@param self lye.Server
---@param name string
---@param from string? the document the require is written in
---@return string?
function Lye:moduleFile(name, from)
	return self.declarations:moduleFile(name, from)
end

--- The directory of the lde package a document belongs to: the nearest one above it that declares
--- itself with an `lde.json`. That file is what makes the layout knowable — the package is the unit
--- lde resolves within, and everything it can `require` is linked into that package's `target/`.
---@param self lye.Server
---@param uri string?
function Lye:packageRoot(uri)
	local root = self.server.rootPath
	if not uri or not root then return nil end
	local path = uri:gsub("^file://", "")
	local at = path:match("^(.*)/[^/]+$")
	while at and #at >= #root do
		if self.packageRoots then
			local held = self.packageRoots[at]
			if type(held) == "string" then return held end
			if held then return at end
		end
		local handle = io.open(at .. "/lde.json", "rb")
		if handle then
			handle:close()
			self.packageRoots = self.packageRoots or {}
			self.packageRoots[at] = at
			return at
		end
		self.packageRoots = self.packageRoots or {}
		self.packageRoots[at] = false
		at = at:match("^(.*)/[^/]+$")
	end
end

--- The search paths a document's project declares, each with `?` where the module name goes. Two
--- files are read, the package's and the workspace's, because a monorepo may have its own idea of
--- where a shared library lives and a package may have another.
---@param self lye.Server
---@param uri string?
---@return string[]
function Lye:requirePaths(uri)
	local out = {}
	local seen = {}
	---@param dir string?
	local function read(dir)
		if not dir or seen[dir] then return end
		seen[dir] = true
		local handle = io.open(dir .. "/lye.json", "rb")
		if not handle then return end
		local written = handle:read("*a")
		handle:close()
		local ok, config = pcall(require("lye-json").decode, written)
		if not ok or type(config) ~= "table" then return end
		for _, pattern in ipairs(config.requirePaths or {}) do
			if type(pattern) == "string" and pattern ~= "" then
				-- A pattern is written the way `package.path` writes one; an absolute one is left
				-- alone and a relative one is read from the file that declared it.
				out[#out + 1] = pattern:sub(1, 1) == "/" and pattern or (dir .. "/" .. pattern)
			end
		end
	end
	read(self:packageRoot(uri))
	read(self.server.rootPath)
	return out
end

--- Whether a document is a definition file: one named `.d.lua` describes a library the way a
--- `---@meta` file does, and the analyzer holds it to its annotations rather than to a body.
---@param self lye.Server
---@param uri string
function Lye:isDefinition(uri)
	return uri:match("%.d%.lua$") ~= nil
end

--- The `plugins` a document's package and its workspace listed, in that order: the package's
--- entries first, since a package that says something about a plugin means it, and each entry read
--- from the file that wrote it — the rule `requirePaths` follows.
---@param self lye.Server
---@param uri string?
---@return string[]
function Lye:pluginConfig(uri)
	local out, seen = {}, {}
	---@param dir string?
	local function read(dir)
		if not dir or seen[dir] then return end
		seen[dir] = true
		local handle = io.open(dir .. "/lye.json", "rb")
		if not handle then return end
		local written = handle:read("*a")
		handle:close()
		local ok, config = pcall(json.decode, written)
		if not ok or type(config) ~= "table" or type(config.plugins) ~= "table" then return end
		for _, entry in ipairs(config.plugins) do
			if type(entry) == "string" and entry ~= "" then
				-- A relative path is read from the file that wrote it, and a name is left as it is
				-- for the package's own resolution.
				local named = entry:sub(1, 1) ~= "!" and entry:sub(1, 1) ~= "/"
					and (entry:sub(1, 1) == "." or entry:sub(-4) == ".lua")
				out[#out + 1] = named and (dir .. "/" .. entry:gsub("^%./", "")) or entry
			end
		end
	end
	read(self:packageRoot(uri))
	read(self.server.rootPath)
	return out
end

--- The plugins a package asked for, loaded once per package: a plugin is code, and code that is
--- loaded again on every keystroke is code that is loaded for nothing.
---@param self lye.Server
---@param uri string?
function Lye:plugins(uri)
	local root = self:packageRoot(uri) or self.server.rootPath
	self.plugins_ = self.plugins_ or {}
	local held = self.plugins_[root or ""]
	if held then return held end
	-- The require-completion plugin is a package of its own. It is on unless the workspace wrote
	-- `!lye-plugin-require`; its hooks are already linked in, so it is not loaded from a path.
	local entries = {}
	local wantsRequire, explicit = true, false
	for _, entry in ipairs(self:pluginConfig(uri)) do
		if entry == "!lye-plugin-require" then
			wantsRequire = false
		elseif entry == "lye-plugin-require" then
			explicit = true
		else
			entries[#entries + 1] = entry
		end
	end
	---@param message string
	local function report(message)
		-- A fault in a plugin is the plugin author's to fix, and the user's to see once.
		self.server:log(message, framework.LOG.warning)
	end
	---@param name string
	local function pluginAt(name)
		-- A plugin named rather than pathed is a module, and a module of this package is one lde
		-- linked into its `target/`: the same place `require` finds, so `lde add` is how one is
		-- installed and `lye.json` is where it is turned on.
		return self:moduleFile(name, uri)
	end
	local specs = plugin.load(entries, root, pluginAt, report)
	if wantsRequire or explicit then
		table.insert(specs, 1, plugin.spec(requireCompletion, "lye-plugin-require", report))
	end
	self.plugins_[root or ""] = specs
	return specs
end

--- The file extensions the workspace's plugins claim, as selectors an LSP client can use. Only
--- extensions other than `lua` are returned: a `.lua` document is already in the client's default
--- selector, and registering it twice would make every provider run twice.
---@param self lye.Server
---@return table[]?
function Lye:extensionSelectors()
	local root = self.server.rootPath
	if not root then return nil end
	-- Loaded here rather than at module load: a workspace with no plugin never pays for the walk.
	local check = require("lye-lsp.check")
	local selectors = {}
	for _, extension in ipairs(check.extensions(root)) do
		local clean = extension:gsub("^%.", "")
		if clean ~= "" and clean ~= "lua" then
			selectors[#selectors + 1] = { scheme = "file", pattern = "**/*." .. clean }
		end
	end
	if #selectors == 0 then return nil end
	return selectors
end

--- What lye reads of a document, and the way back to what the editor holds. A plugin for another
--- language lowers the document — `lye.json` names it — and then the analysis reads the lowered
--- text while every position and range an editor sees is the one it wrote. With nothing lowered
--- the text is the document itself and the map moves nothing.
---@class lye.View
---@field source string the document as the editor holds it
---@field sourceIndex lye.framework.LineIndex the line index of that text
---@field text string what the analysis reads
---@field index lye.framework.LineIndex the line index of that text
---@field map lye.plugin.Map
---@field specs lye.plugin.Spec[]

---@param self lye.Server
---@param uri string
---@return lye.View?
function Lye:view(uri)
	---@type lye.framework.Document?
	local document = self.server.documents:get(uri)
	if not document then return nil end
	self.views = self.views or {}
	self.viewByIndex = self.viewByIndex or {}
	local held = self.views[uri]
	if held and held.source == document.text then return held end

	local specs = self:plugins(uri)
	local context = {
		uri = uri, source = document.text, text = document.text, root = self:packageRoot(uri),
	}
	local map = plugin.lower(specs, context, function(message)
		self.server:log(message, framework.LOG.warning)
	end)
	local view = {
		source = document.text, sourceIndex = document.lineIndex,
		text = map.text, index = document.lineIndex, map = map, specs = specs,
	}
	if not map:isEmpty() then
		-- The lowered text is its own text: a line index of its own is what turns an offset of it
		-- into a position, and nothing else reads the one it replaced.
		view.index = position.buildLineIndex(view.text)
	end
	if held then
		-- The view this one replaces was found by the line index of the text it was built from, and
		-- a keystroke builds a new one: leaving the old pair behind keeps a document's worth of
		-- lowered text and its map alive for every keystroke of a session.
		if self.viewByIndex[held.sourceIndex] == held then self.viewByIndex[held.sourceIndex] = nil end
		if held.index ~= held.sourceIndex and self.viewByIndex[held.index] == held then
			self.viewByIndex[held.index] = nil
		end
	end
	self.views[uri] = view
	self.viewByIndex[document.lineIndex] = view
	self.viewByIndex[view.index] = view
	return view
end

--- Where the map of a document is, from a line index that belongs to it: a range is written with
--- the text it was read from, and that pair is the document's own.
---@param self lye.Server
---@param index lye.framework.LineIndex?
function Lye:viewOf(index)
	return index and self.viewByIndex and self.viewByIndex[index] or nil
end

--- What `require("name")` is: the type the module file returns, analysed once and kept until its
--- text changes.
---@param self lye.Server
---@param name string
---@param from string? the document the require is written in, which is what says which package it
--- resolves within
---@return lye.doc.Type?
function Lye:moduleType(name, from)
	return self.modules:type(name, from)
end

--- A digest of the documents an editor has open, which a kept module answer is read against.
---@param self lye.Server
---@return string
function Lye:documentsDigest()
	return self.modules:documentsDigest()
end

--- Where this session keeps what it works out: the workspace the editor opened, so a second
--- editor on the same project reads what the first one worked out. A run that named a directory —
--- `LYE_CACHE_DIR`, or the command line — has said where it wants everything, and this leaves it
--- there.
---@param self lye.Server
function Lye:useWorkspaceCache()
	local root = self.server.rootPath
	if root and root ~= "" and not cache.named() then cache.setRoot(root .. "/.lye") end
end


--- What one document declares, which `declaredBy` keeps after its analysis is dropped.
---@param file lye.doc.File
local function declarationsOf(file)
	return classes.declare({ file })
end

--- The classes and aliases every file in the workspace declares, each resolved to the type it
--- stands for.
---@param self lye.Server
---@return table<string, boolean|lye.doc.Type>
function Lye:workspaceDeclarations()
	self:useWorkspaceCache()
	return self.declarations:workspace()
end

--- The classes and aliases the modules linked into a package's `target/` declare, resolved.
---@param self lye.Server
---@param root string the package root
---@return table<string, boolean|lye.doc.Type>
function Lye:packageDeclarations(root)
	return self.declarations:package(root)
end

--- What a document is analysed against: the workspace, its package, and what each open document
--- declared.
---@param self lye.Server
---@param uri string? the document the names are for, which decides which package's modules count
---@return table<string, boolean|lye.doc.Type>
function Lye:declaredTypes(uri)
	return self.declarations:view(uri)
end

--- How many analyses are held. One is about eight megabytes for two thousand lines, and what an
--- editor has open is unbounded, so the least recently used is dropped and analysed again on the
--- next request for it — which costs one analysis, not correctness. Measured with four such
--- documents open: two held is 43 MiB where four is 61. The count is the cache's for now; the byte
--- budget is what replaces it.
---@param uri string
---@param from integer? the byte the change starts at, in the text the held parse was for
---@param self lye.Server
function Lye:analyze(uri, from)
	---@type lye.framework.Document?
	local document = self.server.documents:get(uri)
	if not document then return nil end
	local view = self:view(uri)
	if not view then return nil end
	local started = timing.now()
	local incremental = os.getenv("LYE_INCREMENTAL") ~= "0"
	---@type integer?
	local fromOffset = incremental and from or nil

	-- Resume from the tree the held parse left. A lowered document is analysed as it stands:
	-- resuming at an offset of the text the editor holds would be resuming from a text this
	-- analysis never read.
	local resume
	if incremental and fromOffset and view.map:isEmpty() then
		local held = self.cache.parsed[uri]
		if held then resume = Parser.resumeAt(held.parsed, fromOffset) end
	end

	-- The counters are the analyzer's plain table: it measures its phases with `os.clock`, and
	-- nothing here is asked for unless a timing run wants to read it.
	local counters = timing.detailed() and {} or nil
	local options
	if incremental then
		options = {
			uri = uri, previous = self.cache.previous[uri], from = fromOffset,
			incremental = true, counters = counters,
		}
	else
		-- The cold path: the previous result and the offset are not offered at all.
		options = { uri = uri, incremental = false, counters = counters }
	end

	---@param name string
	local function moduleAt(name) return self:moduleType(name, uri) end
	---@param message string
	local function reportPlugin(message) self.server:log(message, framework.LOG.warning) end
	local names = analyzer.analyze(view.text, PRELUDE, self:declaredTypes(uri), moduleAt,
		resume, self.cache:annotationsFor(uri, view.text), nil, self:isDefinition(uri),
		view.specs, reportPlugin, options)
	local parsed = names.parser

	-- Type errors from annotations belong in the same list as syntax errors, but the parse tree is
	-- the parser's own: it is what the next text resumes from, and a diagnostic the analyzer
	-- appended here would be carried into that parse and appended again. So the combined list is
	-- a result-table copy, and the tree the cache keeps stays parser-only.
	---@type lye.parser.Result
	local result = {}
	for key, value in pairs(parsed) do result[key] = value end
	---@type lye.parser.Problem[]
	local diagnostics = {}
	for index = 1, #parsed.diagnostics do diagnostics[index] = parsed.diagnostics[index] end
	for _, entry in ipairs(names.diagnostics) do
		diagnostics[#diagnostics + 1] = entry --[[@as lye.parser.Problem]]
	end
	-- A `require` naming a module neither the workspace, its packages, nor the definitions
	-- provide is not typed; the reader is told rather than every use becoming unknown.
	for _, node in ipairs(parsed.nodes) do
		if node.kind == "call" and node.callee == "require" and node.args and node.args[1] then
			local argument = parsed.nodes[node.args[1]]
			if argument and argument.kind == "string" and type(argument.value) == "string"
				and not self:moduleFile(argument.value, uri) then
				diagnostics[#diagnostics + 1] = {
					message = string.format("module `%s` is not found", argument.value),
					severity = 1, start = argument.start, stop = argument.stop,
				} --[[@as lye.parser.Problem]]
			end
		end
	end
	-- The parser's own class now admits the severity the analysis adds, and the list is one list.
	result.diagnostics = diagnostics
	if names.doc then
		self.declaredBy[uri] = declarationsOf(names.doc)
		-- The declarations of the new text are the open-document layer every view reads.
		self.declarations:declared(uri, self.declaredBy[uri])
	end
	self.cache:store(uri, names, view, self.epoch)
	self.dirty[uri] = nil

	local items, reused = 0, 0
	if counters then items, reused = counters.items or 0, counters.reused or 0 end
	timing.detail("analyze", started, "bytes=%d resumed=%s items=%s reused=%s",
		#view.text, resume and "1" or "0", tostring(items), tostring(reused))
	return result
end

--- Enforce the analysis budget after an answer has been published, and say what it holds when
--- `LYE_TIMING=1` asks. It is never called between an analysis and its diagnostics: an evicted
--- document is a full-parse miss on the next request, not a missing answer on this one.
---@param self lye.Server
function Lye:evictCache()
	local started = timing.now()
	local stats = self.cache:evict()
	timing.detail("cache", started, "entries=%d bytes=%d analyses=%d analysisBytes=%d parsedBytes=%d",
		stats.entries, stats.bytes, stats.analyses, stats.analysisBytes, stats.parsedBytes)
end

---@param self lye.Server
---@param uri string
---@return string?
---@return lye.framework.LineIndex?
function Lye:textOf(uri)
	local view = self:view(uri)
	if not view then return nil end
	return view.text, view.index
end

---@param self lye.Server
---@param text string the text the offsets were read from
---@param index lye.framework.LineIndex
---@param start integer
---@param stop integer
---@return table
function Lye:toRange(text, index, start, stop)
	-- A document a plugin lowered is read and answered about in two texts: the offsets are the
	-- lowered text's and the editor's positions are its own, so the range travels back before it is
	-- written down. With nothing lowered there is no view to find and nothing moves.
	---@type lye.View?
	local view = self:viewOf(index)
	if view and not view.map:isEmpty() then
		local movedStart, movedStop = originalRange(view.map, start, stop)
		start, stop = movedStart, movedStop
		text = view.source or text
		index = view.sourceIndex or index
	end
	local encoding = self.server.encoding
	local startLine, startCharacter = position.toPosition(text, index, start, encoding)
	local stopLine, stopCharacter = position.toPosition(text, index, stop + 1, encoding)

	return {
		start = { line = startLine, character = startCharacter },
		["end"] = { line = stopLine, character = stopCharacter },
	}
end

--- The byte an editor's position names, in the text the analysis reads. It is the one place a
--- position from a client enters the server, so it is where a lowered document carries it across.
---@param self lye.Server
---@param uri string
---@param line integer
---@param character integer
---@return integer?
function Lye:offsetAt(uri, line, character)
	---@type lye.framework.Document?
	local document = self.server.documents:get(uri)
	if not document then return nil end
	local offset = position.toOffset(
		document.text, document.lineIndex, line, character, self.server.encoding
	)
	local view = self:view(uri)
	if view and not view.map:isEmpty() then offset = view.map:toLowered(offset) end
	return offset
end

---@param self lye.Server
---@param uri string
---@param result lye.parser.Result
function Lye:diagnosticItems(uri, result)
	---@type lye.framework.Document?
	local document = self.server.documents:get(uri)
	if not document then return nil end
	local text, index = document.text, document.lineIndex
	local diagnostics = json.array()
	for _, entry in ipairs(result.diagnostics) do
		diagnostics[#diagnostics + 1] = {
			range = self:toRange(text, index, entry.start, entry.stop),
			-- The severity the analysis gave it: a syntax error has none and is the loudest, and
			-- an unused local is a warning. Publishing everything as an error is how a warning
			-- becomes a red squiggle.
			severity = entry.severity or 1,
			source = "lye",
			message = entry.message,
		}
	end
	return diagnostics, document
end

---@param self lye.Server
---@param uri string
---@param result lye.parser.Result
function Lye:publishDiagnostics(uri, result)
	local diagnostics, document = self:diagnosticItems(uri, result)
	if not diagnostics or not document then return end
	-- An empty set must still be published, or the client keeps showing stale markers.
	self.server:notify(framework.METHOD.publishDiagnostics, {
		uri = uri,
		diagnostics = diagnostics,
		version = document.version,
	})
end

--- Pull diagnostics for an open document. Clients that support `textDocument/diagnostic` use
--- this instead of, or beside, the push diagnostics above.
---@param self lye.Server
---@param params lye.lsp.Params
---@return table
function Lye:onTextDocumentDiagnostic(params)
	local uri = params.textDocument?.uri
	if not uri then return { kind = "full", items = json.array() } end
	local result = self:analyze(uri)
	if not result then return { kind = "full", items = json.array() } end
	---@cast result lye.parser.Result
	local diagnostics, document = self:diagnosticItems(uri, result)
	if not diagnostics or not document then return { kind = "full", items = json.array() } end
	return {
		kind = "full",
		resultId = uri .. ":" .. tostring(document.version or 0),
		items = diagnostics,
	}
end

--- Workspace pull diagnostics: check every Lua file under the workspace root and return the
--- findings grouped by URI. This is the editor-visible equivalent of `lye check`.
---@param self lye.Server
---@param params lye.lsp.Params
---@return table
function Lye:onWorkspaceDiagnostic(params)
	local root = self.server.rootPath
	if not root then return { items = json.array() } end
	local check = require("lye-lsp.check")
	local report = require("lye-lsp.report")
	local collector = report.collect()
	local paths = check.expand({ root })
	check.files(paths, collector)
	local byUri = {}
	for _, entry in ipairs(collector.collect or {}) do
		if entry.line and entry.column and not entry.err then
			local path = entry.path
			---@cast path string
			local absolute = path:sub(1, 1) == "/" or path:sub(1, 1) == "\\"
				or path:match("^%a:[/\\]") ~= nil
			if not absolute then path = root .. "/" .. path:gsub("^%./", "") end
			local uri = "file://" .. path
			local item = {
				range = {
					start = { line = entry.line - 1, character = entry.column - 1 },
					["end"] = { line = entry.line - 1, character = entry.column },
				},
				severity = entry.severity or 1,
				source = "lye",
				message = entry.message,
			}
			local list = byUri[uri]
			if not list then list = json.array(); byUri[uri] = list end
			list[#list + 1] = item
		end
	end
	local items = json.array()
	for uri, diagnostics in pairs(byUri) do
		items[#items + 1] = {
			uri = uri, version = nil, kind = "full", resultId = uri, items = diagnostics,
		}
	end
	return { items = items }
end

---@param result lye.parser.Result
---@param offset integer
---@return lye.lexer.ffi.token?
local function tokenAt(result, offset)
	local tokens = result.tokens.arena
	local low, high = 1, result.tokens.count
	while low <= high do
		local mid = math.floor((low + high) / 2)
		local token = tokens[mid]
		if offset < token.start then
			high = mid - 1
		elseif offset > token.stop then
			low = mid + 1
		else
			return token
		end
	end
end

--- Whether a token is something a hover can be about: a name or a literal. A `}` or a `,` is not,
--- and answering about the expression around one is how a hover ends up describing a call nobody
--- pointed at.
---@param token lye.lexer.ffi.token
local function isValueToken(token)
	local kind = token.kind
	return kind == KIND.name or kind == KIND.number or kind == KIND.string or kind == KIND.keyword
end

---@param result lye.parser.Result
---@param offset integer
---@return string? name
---@return lye.lexer.ffi.token?
local function nameAt(result, offset)
	local token = tokenAt(result, offset)
	if token and token.kind == KIND.name then return result.tokens.texts[token.index], token end
end

--- Whether the token at this offset names the field of an index or a call rather than a lexical
--- variable. `handle:read()` is the method `read`, not the local function `read`; resolving the
--- spelling through the scope chain found the local and showed its signature for the method.
---@param parsed lye.parser.Result
---@param token lye.lexer.ffi.token
---@param name string
---@return boolean
local function fieldUseAt(parsed, token, name)
	local source = parsed.source or ""
	local at = token.start - 1
	while at >= 1 and source:sub(at, at):match("%s") do at = at - 1 end
	local separator = at >= 1 and source:sub(at, at) or ""
	if separator ~= "." and separator ~= ":" then return false end
	for _, node in ipairs(parsed.nodes) do
		if node.field == name and (node.kind == "index" or node.kind == "call")
			and node.start <= token.start and node.stop >= token.stop then
			return true
		end
	end
	return false
end

--- The declaration a name at an offset refers to. The analyzer already resolves names
--- through the scope chain, so this asks it instead of repeating the search with looser rules:
--- two resolvers can disagree about which declaration shadows which.
---@param names lye.analyzer.Result
---@param offset integer
local function declarationFor(names, offset)
	local name, token = nameAt(names.parser, offset)
	if not name or not token then return nil end
	-- A field is not a lexical name, even when a variable of the same spelling is in scope.
	---@type lye.analyzer.Variable?
	local variable
	if not fieldUseAt(names.parser, token, name) then
		variable = analyzer.lookupAt(names, name, offset)
	end
	if variable then return variable.declaration end
	-- A `function t.m()` is declared under its dotted name, which no plain lookup reaches.
	local declarations = names.parser.declarations
	for index = #declarations, 1, -1 do
		local candidate = declarations[index]
		if candidate.start <= offset and candidate.name:match("([^%.:]+)$") == name then
			if candidate.qualifier == "field" or candidate.qualifier == "global" then
				return candidate
			end
		end
	end
end

---@param self lye.Server
---@param params lye.lsp.Params
function Lye:onDocumentSymbol(params)
	local uri = params.textDocument?.uri
	if not uri then return nil end

	---@type lye.framework.Document?
	local document = self.server.documents:get(uri)
	if not document then return nil end
	---@type lye.parser.Result?
	local result = self.analysis[uri] or self:analyze(uri)
	if not result then return nil end

	---@param declaration lye.parser.Declaration
	---@return lye.lsp.DocumentSymbol
	local function symbolOf(declaration)
		local range = self:toRange(document.text, document.lineIndex, declaration.start, declaration.stop)
		return {
			name = declaration.name,
			kind = declaration.isFunction and SYMBOL_KIND["function"] or SYMBOL_KIND.variable,
			range = range,
			selectionRange = range,
		}
	end

	-- Declarations arrive in source order with their scope depth. `enclosing[depth]` holds
	-- the last symbol seen at that depth, so a declaration one level deeper becomes its
	-- child and one at the same level becomes its sibling.
	---@type lye.lsp.DocumentSymbol[]
	local roots = json.array()
	---@type table<integer, lye.lsp.DocumentSymbol>
	local enclosing = {}
	for _, declaration in ipairs(result.declarations) do
		if declaration.qualifier ~= "label" then
			local depth = declaration.depth
			local symbol = symbolOf(declaration)
			local parent = enclosing[depth]

			if parent then
				parent.children = parent.children or json.array()
				parent.children[#parent.children + 1] = symbol
			else
				roots[#roots + 1] = symbol
			end

			enclosing[depth + 1] = symbol
			for deeper = depth + 2, #enclosing do enclosing[deeper] = nil end
		end
	end
	return roots
end

--- The document, its line index, the parse result and the byte offset under a cursor.
--- Every position-based feature needs exactly this, so it is resolved once.
---@param self lye.Server
---@param params lye.lsp.Params
---@return string? uri
---@return string? text
---@return lye.framework.LineIndex? index
---@return lye.analyzer.Result? result
---@return integer? offset
function Lye:resolvePosition(params)
	local uri = params.textDocument?.uri
	local where = params.position
	if not uri or not where then return nil end

	---@type lye.framework.Document?
	local document = self.server.documents:get(uri)
	if not document then return nil end
	local view = self:view(uri)
	local result = self.analysis[uri] or self:analyze(uri)
	local names = self.names[uri]
	if not result or not names or not view then return nil end

	local offset = position.toOffset(
		document.text, document.lineIndex, where.line, where.character,
		self.server.encoding
	)
	-- The editor holds one text and lye reads another: the position is carried across before
	-- anything is asked about it. What is handed back is the text the offsets belong to, so every
	-- read a caller makes of it — the word under the cursor, a token, a field — is of that text.
	if not view.map:isEmpty() then offset = view.map:toLowered(offset) end
	return uri, view.text, view.index, names, offset
end

--- The type a value expression has, walking the suffix chain the arena recorded: a name reads its
--- variable where the cursor is, and each `.field` reads that field of what came before.
---@param result lye.analyzer.Result
---@param idx integer?
---@param offset integer
---@return lye.doc.Type?
local function typeOfExpression(result, idx, offset)
	local node = idx and result.parser.nodes[idx]
	if not node then return nil end
	-- A group is the expression it holds: `(s:gsub("%s+", "")):gsub(...)` calls `gsub` on the string
	-- the inner call returned, and `("a b"):gsub(...)` on a string literal.
	if node.kind == "prefix" and node.group then return typeOfExpression(result, node.group, offset) end
	if node.kind == "string" then return types.base("string") end
	if node.kind == "prefix" then
		local variable = node.callee and analyzer.lookupAt(result, node.callee, offset)
		return variable and analyzer.typeAt(result, variable, offset) or nil
	end
	if node.kind == "index" and node.target then
		local base = typeOfExpression(result, node.target, offset)
		if base and node.field then
			-- Through the analyzer rather than the type alone, so what the environment arranges is
			-- applied as well: a string reads the `string` table's fields, which is what makes
			-- `s.upper` the function it is rather than the string a bare index of one gives.
			local target = result.parser.nodes[node.target]
			local baseName = target and target.kind == "prefix" and target.callee or nil
			return analyzer.fieldTypeAt(result, base, baseName, node.field, offset)
		end
	end
	if node.kind == "binary" then
		-- A value written as an expression is still a value: `(s or ""):lower()` calls a method on
		-- what the `or` gave. Only `prefix`, `index`, `call` and a literal were read here, so a
		-- grouped `or` — the shape a writer reaches for exactly when a value may be absent —
		-- resolved to nothing at all.
		local left, right = typeOfExpression(result, node.left, offset), typeOfExpression(result, node.right, offset)
		if left and right then return types.binaryResult(node.op or "", left, right) end
		return nil
	end
	if node.kind == "call" then
		-- A generic result belongs to the call rather than to the function, so the analyzer's
		-- binding is read first and the callee's own return type is the fallback.
		local bound = result.callTypes and result.callTypes[idx]
		if bound then return bound end
		if node.field and node.target then
			local base = typeOfExpression(result, node.target, offset)
			-- The analyzer's answer, so a string receiver gives the function the `string` table
			-- holds: `s:sub(2):upper()` is a string either way, and reading the field off the type
			-- alone gives back the string for both halves of the chain.
			local target = result.parser.nodes[node.target]
			local baseName = target and target.kind == "prefix" and target.callee or nil
			if base then
				local called = analyzer.fieldTypeAt(result, base, baseName, node.field, offset)
				if called then
					---@cast called lye.doc.Type
					if types.isFn(called) then return called.returns end
				end
			end
		else
			-- A dotted call keeps its field on the node it targets, so what is being called is that
			-- field rather than the name the call itself carries: `string.gsub(s, " ", "-")` is
			-- read off the `string` table, and `string.gsub(s, " ", "-"):upper()` of its result.
			local target = node.target and result.parser.nodes[node.target]
			if target and target.kind == "index" and target.field then
				local base = typeOfExpression(result, target.target, offset)
				local owner = target.target and result.parser.nodes[target.target]
				local baseName = owner and owner.kind == "prefix" and owner.callee or nil
				if base then
					local called = analyzer.fieldTypeAt(result, base, baseName, target.field, offset)
					if called then
						---@cast called lye.doc.Type
						if types.isFn(called) then return called.returns end
					end
				end
			else
				---@type lye.analyzer.Variable?
				local variable = node.callee and analyzer.lookupAt(result, node.callee, offset)
				if variable then
					local called = analyzer.typeAt(result, variable, offset)
					if types.isFn(called) then return called.returns end
				end
			end
		end
	end
end

--- A signature as its annotations wrote it: `print(...: any)`, `math.floor(x: number) -> number`.
--- The name is optional, since a completion item is already labelled with it, and so is the
--- signature: a caller that has none shows the type instead.
---@param signature lye.analyzer.Signature?
---@param name string?
---@param result lye.doc.Type? what this call actually gives, when an overload decided it
---@return string
local function signatureText(signature, name, result)
	if not signature then return "" end
	local parts = {}
	for _, annotation in ipairs(signature.params) do
		local held = annotation.type or "any"
		local param = annotation.name
		parts[#parts + 1] = (param and param ~= "") and (param .. ": " .. held) or held
	end
	-- Every value it gives back: `fn(...) -> lye.doc.Class?, string[]` is what a caller writing
	-- `local class, args = resolve(ns, text)` reads, and naming only the first was the complaint.
	-- A call whose overload selected its return shows that answer rather than the primary `any`.
	local returned
	if result and not types.isMutable(result) and result.variant ~= "unknown" then
		returned = types.display(result)
	else
		returned = signature.values and table.concat(signature.values, ", ")
			or (signature.returns and signature.returns.type)
		---@type lye.doc.Type[]?
		local inferred = signature.inferredValues
		if not returned and inferred and #inferred > 0 then
			local values = {}
			for _, value in ipairs(inferred) do values[#values + 1] = types.display(value) end
			returned = table.concat(values, ", ")
		end
	end
	return (name or "") .. "(" .. table.concat(parts, ", ") .. ")"
		.. (returned and (" -> " .. returned) or "")
end

--- The signature behind whatever sits at an offset: a name the definitions declare, a field read off
--- a standard library table, or a method of a class this document declares. It is how a hover finds
--- the documentation a call carries.
---@param names lye.analyzer.Result
---@param node lye.parser.Node
---@param offset integer
local function signatureFor(names, node, offset)
	local signatures = names.signatures or {}
	if node.callee and signatures[node.callee] then return signatures[node.callee] end
	-- `math.floor(...)` is a call whose callee is `math`: the field is on the node it targets, and
	-- that node carries the signature.
	if node.kind == "call" and node.target and not node.field then
		local target = names.parser.nodes[node.target]
		if target then return signatureFor(names, target, offset) end
	end
	if not node.field then return nil end

	-- A field: the type it holds is the identity the definitions recorded it under. Only an index
	-- node has a key expression; a call node's `index` is its own arena position, and asking that
	-- read the call's result instead of the field it calls.
	local held
	if node.kind == "index" then held = typeOfExpression(names, node.key or node.index, offset) end
	if not held then
		local base = typeOfExpression(names, node.target, offset)
		if base then held = types.indexResult(base, node.field) end
	end
	if held and PRELUDE.fields[held] then return PRELUDE.fields[held] end

	-- A method of a class this document declares is keyed by the name it was declared under, and a
	-- method of a *string* is keyed under `string`: a string reads that table's fields, which is
	-- what Lua arranges with the string metatable, so `s:sub(2)` is `string.sub(s, 2)`.
	local owner = ownerOf(typeOfExpression(names, node.target, offset))
	if owner then
		return signatures[owner .. "." .. node.field] or signatures[owner .. ":" .. node.field]
	end
end

--- The documentation a completion item carries: the prose above the declaration it offers, from
--- the definitions or from this document.
---@param signature lye.analyzer.Signature?
---@return table?
local function documentationItem(signature)
	local doc = signature and signature.doc
	if not doc then return nil end
	return { kind = "markdown", value = doc }
end

--- What a name reads as, from the type behind it rather than from the syntax it was written
--- with: a global holding a table is a namespace, a name holding a function is a function. It is
--- what colours a reference and what picks a completion icon, so the two never disagree.
---@param names lye.analyzer.Result
---@param name string
---@param offset integer
---@return string?
local function readAsName(names, name, offset)
	local variable = analyzer.lookupAt(names, name, offset)
	if variable then
		local held = analyzer.typeAt(names, variable, offset)
		if types.isFn(held) then return "function" end
		if variable.qualifier == "global" then
			-- `math` and `string` are globals the definitions describe as classes: a reader sees
			-- a namespace, not a class they could construct.
			return held.variant == "class" and "namespace" or "variable"
		end
		if held.variant == "class" then return "class" end
		return variable.qualifier == "param" and "parameter" or "variable"
	end
	-- A function declared in the definitions has no variable in the document: `print` and
	-- `setmetatable` are known by their signature.
	if names.signatures and names.signatures[name] then return "function" end
end

--- The last byte of a value expression. A `prefix` node spans the first byte of its name, so the
--- name's own length says where it ends. Everything else spans what it reads.
--- A grouped expression is the exception: the node spans its opening `(` alone, so its inner
--- expression's end is one byte short of where the value ends — and every reader of the text after
--- it, like the `:` of a method call, was one byte out because of that.
--- The tree is read from either: an analysis carries the parser's result and both hold the nodes.
---@param result table
---@param node lye.parser.Node
local function valueStop(result, node)
	-- An analysis carries the parser's result rather than the nodes themselves, so the arena is
	-- reached through whichever of the two was handed over. Reading `result.nodes` alone raised on
	-- every grouped expression, and because the walk is one loop the raise took the whole answer
	-- with it — which is why a method written on `(a or b)` resolved to nothing at all.
	local nodes = (result.nodes or (result.parser and result.parser.nodes)) --[[@as lye.parser.Node[]?]]
	if not nodes then return node.stop end
	if node.group then
		local inner = nodes[node.group]
		if inner then return valueStop(result, inner) + 1 end
	end
	if node.kind == "prefix" and node.callee then return node.start + #node.callee - 1 end
	return node.stop
end

--- How the value at a node is written, for a hover heading: `print`, `math.floor`, `p:add`. A call
--- node spans its arguments, so what it is called is read from the chain the arena recorded rather
--- than from the text under the cursor.
---@param result lye.analyzer.Result
---@param node lye.parser.Node
---@param source string
local function writtenName(result, node, source)
	if node.field then
		local target = node.target and result.parser.nodes[node.target]
		local base = target and writtenName(result, target, source) or node.callee or ""
		return base .. (node.isMethod and ":" or ".") .. node.field
	end
	if node.kind == "call" and node.target then
		return writtenName(result, result.parser.nodes[node.target], source)
	end
	if node.callee then return node.callee end
	return (source:sub(node.start, valueStop(result, node)))
end

--- Where the name of an access starts: past the guard and the separator that introduce it. The
--- guard `?.` is two bytes and the `.`, `:` or `[` of the access itself is one more, so `a?.b`
--- names its field one byte later than `a.b`, and `a?.:m()` and `t?.[k]` two bytes later than
--- `a:m()` and `t[k]`. Reading the run as the single one it is without a guard named every guarded
--- field early — the name was there, and what was coloured was the byte before it.
---@param text string
---@param targetStop integer
---@return integer
local function fieldStartAt(text, targetStop)
	local at = targetStop + 1
	if text:sub(at, at + 1) == "?." then at = at + 2 end
	local delimiter = text:sub(at, at)
	return (delimiter == "." or delimiter == ":" or delimiter == "[") and at + 1 or at
end

--- The expression node holding an offset, innermost first. Spans are enough: the arena already
--- says what each node is, so nothing is re-read from the text.
---
--- A hover also needs the literal nodes: a string inside `f("x")` is a string, while the call
--- around it is the function that takes one. Resolution elsewhere — `require` completion, a
--- definition lookup — asks for the expression node and leaves the literals out.
---@param result lye.analyzer.Result
---@param offset integer
---@param withLiterals boolean? include strings, numbers, booleans and table constructors
---@return lye.parser.Node?
local function nodeAt(result, offset, withLiterals)
	local found
	for _, node in ipairs(result.parser.nodes) do
		local isValue = node.kind == "prefix" or node.kind == "index" or node.kind == "call"
			or node.kind == "name"
		if withLiterals and (node.kind == "string" or node.kind == "literal"
			or node.kind == "number" or node.kind == "table") then
			isValue = true
		end
		if isValue and node.start <= offset and offset <= node.stop + 1 then
			-- The innermost: the latest start, and among those the shortest span.
			if not found or node.start > found.start
				or (node.start == found.start and node.stop < found.stop) then
				found = node
			end
		end
	end
	return found
end

--- The name written at an offset, read from the source: an identifier, dotted if it is one.
---@param source string
---@param offset integer
local function writtenAt(source, offset)
	local at = offset
	if not source:sub(at, at):match("[%w_%.]") and source:sub(at - 1, at - 1):match("[%w_%.]") then
		at = at - 1
	end
	if not source:sub(at, at):match("[%w_%.]") then return nil end
	local from, to = at, at
	while from > 1 and source:sub(from - 1, from - 1):match("[%w_%.]") do from = from - 1 end
	while to < #source and source:sub(to + 1, to + 1):match("[%w_%.]") do to = to + 1 end
	return source:sub(from, to)
end

--- The name an offset sits under, when it sits inside a doc annotation rather than in code.
---@param names lye.analyzer.Result
---@param source string
---@param offset integer
---@return string? name
---@return lye.doc.Annotation? annotation
local function nameInAnnotation(names, source, offset)
	for _, annotation in ipairs(names.doc and names.doc.annotations or {}) do
		if annotation.nameStart and offset >= annotation.nameStart and offset <= annotation.nameStop then
			-- The name the annotation declares is a declaration in its own right: `---@field call`
			-- is where the field is, and `---@class App` where the class is.
			return writtenAt(source, offset), annotation
		end
		local from, to = annotation.typeStart, annotation.typeStop
		if not from or offset < from or offset > to then
			from, to = annotation.start, annotation.stop
			if offset < from or offset > to then from = nil end
		end
		if from then return writtenAt(source, offset), nil end
	end
end

--- The string inside a `require(...)` that an offset sits in, and what has been typed in it.
---@param self lye.Server
---@param uri string
---@param source string
---@param offset integer
function Lye:requireStringAt(uri, source, offset)
	---@type lye.analyzer.Result?
	local names = self.names[uri]
	if not names then
		self:analyze(uri)
		names = self.names[uri]
	end
	if not names then return nil end
	---@cast names lye.analyzer.Result
	local node = nodeAt(names, offset)
	if not node or node.kind ~= "call" or node.callee ~= "require" then return nil end
	local argument = node.args and node.args[1] and names.parser.nodes[node.args[1]]
	if not argument or argument.kind ~= "string" then return nil end
	if offset < argument.start or offset > argument.stop + 1 then return nil end
	-- The quotes are not part of the name, and the cursor may sit just past the last character.
	local contentFrom = argument.start + 1
	local contentTo = argument.stop - 1
	local typed = source:sub(contentFrom, math.min(offset, contentTo))
	return { from = contentFrom, to = contentTo, typed = typed }
end

--- The span of the word an offset sits on, which is what a hover is about.
---@param source string
---@param offset integer
---@return integer? start
---@return integer? stop
local function wordSpan(source, offset)
	local at = offset
	if not source:sub(at, at):match("[%w_%.]") and source:sub(at - 1, at - 1):match("[%w_%.]") then
		at = at - 1
	end
	if not source:sub(at, at):match("[%w_%.]") then return nil end
	local from, to = at, at
	while from > 1 and source:sub(from - 1, from - 1):match("[%w_%.]") do from = from - 1 end
	while to < #source and source:sub(to + 1, to + 1):match("[%w_%.]") do to = to + 1 end
	return from, to
end

---@param self lye.Server
---@param params lye.lsp.Params
function Lye:onHover(params)
	local uri, text, index, result, offset = self:resolvePosition(params)
	if not uri or not text or not index or not result or not offset then return nil end

	local declaration = declarationFor(result, offset)
	if declaration then
		local qualifier = declaration.qualifier == "param" and "parameter" or declaration.qualifier
		local variable = result.byStart[declaration.start]
		local shown = variable and types.display(analyzer.typeAt(result, variable, offset)) or "unknown"
		local origin = variable and variable.declared and "declared" or "inferred"
		local blocks = {
			string.format("```lua\n%s: %s\n-- %s, %s\n```", declaration.name, shown, qualifier, origin),
		}
		local signature = self.names[uri].signatures and self.names[uri].signatures[declaration.name]
		if signature and signature.doc then blocks[#blocks + 1] = signature.doc end

		return {
			contents = { kind = "markdown", value = table.concat(blocks, "\n\n") },
			-- The word being hovered, not the declaration it resolves to: a client highlights what
			-- the answer points at, and pointing at the declaration highlights another line. A
			-- dotted name is several tokens, and the one the cursor is on is the answer.
			range = (function()
				local token = tokenAt(result.parser, offset)
				if token and isValueToken(token) then
					return self:toRange(text, index, token.start, token.stop)
				end
				local from, to = wordSpan(text, offset)
				return self:toRange(text, index, from or declaration.start, to or declaration.stop)
			end)(),
		}
	end

	-- A type named in an annotation is not a name the parser sees: the whole annotation is one
	-- comment token. What it stands for is the class or alias it names, and the answer is where
	-- that is written.
	local written = nameInAnnotation(result, text, offset)
	local declared = written and self:typeDeclaration(written, uri)
	if declared then
		local from, to = wordSpan(text, offset)
		return {
			contents = { kind = "markdown", value = "```lua\n" .. declared.lines .. "\n```" },
			range = self:toRange(text, index, from or offset, to or offset),
		}
	end

	-- Nothing is declared here, so the answer is what the expression holds: `math.floor` is a function of
	-- the standard library. A function is shown by the signature it was declared with.
	local node = nodeAt(result, offset, true)
	if not node then return nil end
	-- The word the cursor is written on decides both answers. A reader moving from `t` to `t.field`
	-- is asking about two different things, and a range over the whole access tells a client they
	-- are the same one, so the answer points at the word itself.
	local token = tokenAt(result.parser, offset)
	if not token or not isValueToken(token) then return nil end
	---@type lye.analyzer.Signature?
	local signature = signatureFor(self.names[uri], node, offset)
	local held = typeOfExpression(result, node.index, offset)
	if not signature and not held then return nil end

	local label
	if signature then
		---@cast signature lye.analyzer.Signature
		label = signatureText(signature, writtenName(result, node, text),
			node.kind == "call" and held or nil)
	end
	local described = label
	if described == nil then
		---@cast held lye.doc.Type
		described = types.display(held)
	end
	local blocks = {
		string.format("```lua\n%s\n```", described),
	}
	if signature then
		---@cast signature lye.analyzer.Signature
		---@type string?
		local doc = signature.doc
		if doc then blocks[#blocks + 1] = doc end
	end
	return {
		contents = { kind = "markdown", value = table.concat(blocks, "\n\n") },
		range = self:toRange(text, index, token.start, token.stop),
	}
end

--- The names the definitions declare, indexed once and written where a client can open them.
---@param self lye.Server
function Lye:definitionIndex()
	self:useWorkspaceCache()
	---@type lye.Definitions?
	local built = self.definitions
	if not built then
		built = definitionsIndex.prepare(require("lye-defs"))
	end
	---@cast built lye.Definitions
	self.definitions = built
	return built
end

--- A range in another file, resolved against that file's own text. A definition the server wrote
--- out is not an open document, so its line index is built when it is first needed.
---@param self lye.Server
---@param target lye.DefinitionLocation
---@return table
function Lye:rangeIn(target)
	---@type lye.framework.Document?
	local document = self.server.documents:get(target.uri)
	---@type string?
	local text = document and document.text
	---@type lye.framework.LineIndex?
	local lineIndex = document and document.lineIndex
	if not text then text, lineIndex = definitionsIndex.sourceOf(self:definitionIndex(), target.uri) end
	if not text or not lineIndex then
		return { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }
	end
	---@cast text string
	---@cast lineIndex lye.framework.LineIndex
	local line, character = position.toPosition(text, lineIndex, target.start, self.server.encoding)
	local stopLine, stopCharacter = position.toPosition(text, lineIndex, target.stop + 1, self.server.encoding)
	return {
		start = { line = line, character = character },
		["end"] = { line = stopLine, character = stopCharacter },
	}
end

--- The class or alias a name stands for, with the lines that declare it.
---@param self lye.Server
---@param name string
---@param uri string? the document the question came from, which is read first
---@return { location: lye.DefinitionLocation, lines: string }?
function Lye:typeDeclaration(name, uri)
	return self.declarations:typeLocation(name, uri)
end

--- The class or alias a name declares: in this document, in another the server has analysed, or in
--- the definitions — which is where the builtin types live.
---@param self lye.Server
---@param name string
---@param uri string
---@return lye.DefinitionLocation?
function Lye:targetOfType(name, uri)
	return self.declarations:targetOfType(name, uri)
end

--- Where a name resolves: the declaration the parser recorded, or the definitions the server wrote
--- out, which is the only place a builtin can be found.
---@param self lye.Server
---@param uri string
---@param text string
---@param names lye.analyzer.Result
---@param offset integer
---@return lye.DefinitionLocation?
function Lye:targetAt(uri, text, names, offset)
	local written, declared = nameInAnnotation(names, text, offset)
	if written and declared then
		return {
			uri = uri,
			start = declared.nameStart or declared.start,
			stop = declared.nameStop or declared.stop,
		}
	end
	if written then
		local found = self:targetOfType(written, uri)
		if found then return found end
	end

	-- `require("a.b")` names a file: the string is a path, and the jump goes to the module.
	local required = nodeAt(names, offset)
	if required and required.kind == "call" and required.callee == "require"
		and required.args and required.args[1] then
		local argument = names.parser.nodes[required.args[1]]
		if argument and argument.kind == "string" and offset >= argument.start and offset <= argument.stop then
			local path = type(argument.value) == "string" and self:moduleFile(argument.value)
			if path then return { uri = "file://" .. path, start = 1, stop = 1 } end
		end
	end

	local declaration = declarationFor(names, offset)
	if declaration then
		return { uri = uri, start = declaration.start, stop = declaration.stop }
	end

	-- `math.floor` is declared by name in the definitions and `Point.x` by the class it belongs to. Both
	-- readers below go through the analysis result, whose `parser` field is the tree.
	local node = nodeAt(names, offset)
	if node then
		local dotted = writtenName(names, node, text)
		local found = definitionsIndex.find(self:definitionIndex(), dotted)
		if found then return found end
		if node.field and (node.kind == "index" or node.kind == "call") then
			-- Who declares the field: the class the receiver's type names, or `string` for a
			-- string, because a string reads that table's fields — which is what Lua's own string
			-- metatable arranges, and what makes `s:sub(2)` jump to `string.sub`. A class written
			-- with a marker (`file*`) and its method declared without one (`function file:read`)
			-- are the same class, so both spellings and both separators are tried.
			local owner = ownerOf(typeOfExpression(names, node.target, offset))
			if owner then
				local bare = (owner:gsub("%*$", ""))
				local candidates = {
					owner .. "." .. node.field, owner .. ":" .. node.field,
					bare .. "." .. node.field, bare .. ":" .. node.field,
				}
				-- A method this document declares is found where it is written before the
				-- definitions are asked: a definition only answers the builtin libraries.
				for _, candidate in ipairs(candidates) do
					for _, declaration in ipairs(names.parser.declarations) do
						if declaration.name == candidate
							and (declaration.qualifier == "field" or declaration.qualifier == "global") then
							return { uri = uri, start = declaration.start, stop = declaration.stop }
						end
					end
				end
				for _, candidate in ipairs(candidates) do
					local method = definitionsIndex.find(self:definitionIndex(), candidate)
					if method then return method end
				end
			end
		end
		-- A name that is not declared here may still be a value of a type that is: `math` is the
		-- table `mathlib` describes, and the class is where a reader wants to land.
		local held = node.kind == "prefix" and node.callee
			and typeOfExpression(names, node.index, offset)
		if held and held.variant == "class" then
			local found = self:targetOfType(held.name, uri)
			if found and found.uri ~= uri then return found end
		end
	end
	return nil
end

---@param self lye.Server
---@param params lye.lsp.Params
---@return table?
function Lye:onDefinition(params)
	local uri, text, index, names, offset = self:resolvePosition(params)
	-- A document the server has not read has no text and no analysis, and there is nothing to
	-- define in it.
	if not uri or not text or not index or not names or not offset then return nil end

	local target = self:targetAt(uri, text, names, offset)
	if not target then return nil end
	if target.uri == uri then
		return { uri = uri, range = self:toRange(text, index, target.start, target.stop) }
	end
	return { uri = target.uri, range = self:rangeIn(target) }
end

---@param self lye.Server
---@param params lye.lsp.Params
---@return table
function Lye:onSemanticTokens(params)
	local started = timing.now()
	local uri = params.textDocument?.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	---@type lye.parser.Result?
	local result = uri and (self.analysis[uri] or self:analyze(uri))
	---@type lye.View?
	local view = uri and self:view(uri)
	if not uri or not document or not result or not view then return { data = json.array() } end

	-- Colouring a document is a walk of all of it, and an editor asks for it again as the cursor
	-- moves and the view scrolls: the answer for a document that has not changed is the answer.
	self.tokens_ = self.tokens_ or {}
	local held = self.tokens_[uri]
	if held and held.text == document.text then
		timing.detail("tokens", started, "cached=1")
		return held.answer
	end

	-- What lye reads is the lowered text, and what the editor colours is its own: every span is
	-- carried back through the map before a token is written down.
	local text = view.text
	local encoding = self.server.encoding

	---@type table<integer, string>
	local kinds = {}
	for _, declaration in ipairs(result.declarations) do
		if declaration.qualifier ~= "label" then
			local target = declaration.isFunction and "function"
				or (declaration.qualifier == "param" and "parameter" or "variable")
			for at = declaration.start, declaration.stop do
				kinds[at] = target
			end
		end
	end

	-- A definition file writes its types where a reader sees them — `function f(n: number): string`
	-- — and they are types like any other: the word inside one reads as a type rather than as the
	-- variable it would be outside one. The span is what the parser kept beside the text.
	---@param at integer
	---@param stop integer
	---@param target string
	local function asType(at, stop, target)
		kinds[at] = target
	end
	for _, declaration in ipairs(result.declarations) do
		-- The parser records the span of an inline signature type beside the declaration; the
		-- shared class leaves it out, so it is named here where it is read.
		---@cast declaration lye.parser.Declaration & { inlineTypeStart: integer?, inlineTypeStop: integer? }
		if declaration.inlineTypeStart and declaration.inlineTypeStop then
			typeWords(text, declaration.inlineTypeStart, declaration.inlineTypeStop, asType)
		end
	end
	for _, node in ipairs(result.nodes) do
		if node.inlineVariadicStart and node.inlineVariadicStop then
			typeWords(text, node.inlineVariadicStart, node.inlineVariadicStop, asType)
		end
		if node.inlineReturnsStart and node.inlineReturnsStop then
			typeWords(text, node.inlineReturnsStart, node.inlineReturnsStop, asType)
		end
	end

	-- Read before the emitters below: a closure that reads a local declared after it sees a
	-- global instead, which is nil and silent until it is indexed.
	---@type lye.analyzer.Result?
	local names = self.names[uri]
	---@type lye.doc.Annotation[]
	local annotations = (names and names.doc and names.doc.annotations) or {}

	-- A name that is not a declaration is a reference, and what it reads as comes from the type behind
	-- it. Colouring every reference as a variable is what left the whole standard library white.
	if names then
		for _, node in ipairs(result.nodes) do
			if node.kind == "prefix" and node.callee and not kinds[node.start] then
				local read = readAsName(names, node.callee, node.start)
				if read then kinds[node.start] = read end
			elseif node.kind == "index" and node.field and node.isDynamic ~= true then
				local fieldStart = node.stop - #node.field + 1
				if not kinds[fieldStart] then
					-- What the analyzer worked out for the read itself: a string's field is the
					-- function that table holds, not the string a bare index of one gives.
					local held = typeOfExpression(names, node.index, node.start)
					kinds[fieldStart] = held and types.isFn(held) and "function" or "property"
				end
			elseif node.kind == "call" and node.isMethod == true and node.field then
				-- `s:sub(2)` calls the field its receiver holds, so the name is a method rather
				-- than a variable nothing declares, which is what left it uncoloured. Where the
				-- name starts comes from `valueStop`, not from the node's own span: a receiver
				-- written as an expression records only its opening `(`, so `(a or b):lower()`
				-- coloured a byte two past the bracket and left the name plain.
				---@type lye.parser.Node?
				local target = node.target and result.nodes[node.target]
				if target then
					local fieldStart = fieldStartAt(text, valueStop(result, target))
					if not kinds[fieldStart] then kinds[fieldStart] = "method" end
				end
			end
		end
	end

	-- Every span the walk below decides is collected rather than written out: a plugin answers with
	-- spans of its own over the same text, and the two sets have to become one before any of it is
	-- carried back through the map and written down.
	---@type { from: integer, to: integer, kind: string, modifiers: integer? }[]
	local spans = {}
	local spanCount = 0

	---@param spanStart integer
	---@param spanStop integer
	---@param target string
	---@param modifiers integer?
	local function emitSpan(spanStart, spanStop, target, modifiers)
		if spanStop < spanStart then return end
		spanCount += 1
		spans[spanCount] = { from = spanStart, to = spanStop, kind = target, modifiers = modifiers }
	end

	-- What the parser calls a token, in the vocabulary this server advertises.

	--- A doc comment is emitted as the comment it is, with the tags, parameter names and types
	--- inside it marked out. The spans are cut at newlines because a token may not cross one.
	---@param token lye.lexer.ffi.token
	---@param written string
	local function emitComment(token, written)
		---@type { start: integer, stop: integer, target: string }[]
		local carved = {}
		local count_ = 0
		---@param from integer
		---@param to integer
		---@param target string
		local function carve(from, to, target)
			if to < from or from < token.start or to > token.stop then return end
			count_ += 1
			carved[count_] = { start = from, stop = to, target = target }
		end

		-- Only the tag the comment *starts* with is an annotation; one mid-sentence is prose about one.
		local at, stop = written:find(DOC_TAG .. DOC_TAG_NAME)
		-- Whether this comment is an annotation at all: one that begins with a tag.
		local isAnnotation = at and stop and written:sub(1, at - 1):match("^[ \t]*$") ~= nil
		while isAnnotation and at and stop do
			carve(token.start + at - 1, token.start + stop - 1, "keyword")
			at, stop = written:find(DOC_TAG .. DOC_TAG_NAME, stop + 1)
		end

		-- A member of a multi-line alias: `---@alias T` followed by `--- | "a"` lines. The body is
		-- joined by the reader, so the bar that joins it and the values it names are the pieces an
		-- editor colours separately.
		local member = written:match("^%-%-%-?%s*(|.*)$")
		local bar = member and written:find("|", 1, true)
		if member and bar then
			-- Offsets are inside the comment, so the member's own are found from where it starts.
			carve(token.start + bar - 1, token.start + bar - 1, "operator")
			local quote = member:find("[\"']")
			while quote do
				local opened = member:sub(quote, quote)
				local close = member:find(opened, quote + 1, true)
				if not close then break end
				local from = token.start + bar + quote - 2
				carve(from, from + close - quote, "string")
				quote = member:find("[\"']", close + 1)
			end
		end

		-- The name of a parameter reads as a parameter, and the identifiers in a type read as a
		-- type. A string literal inside a type stays a string; the punctuation around them is
		-- grammar and stays part of the comment.
		for _, annotation in ipairs(annotations) do
			if annotation.start >= token.start and annotation.stop <= token.stop then
				---@type integer?
				local nameStart = annotation.nameStart
				---@type integer?
				local nameStop = annotation.nameStop
				if nameStart and nameStop then
					-- What the name in an annotation *is*: a parameter is a parameter, a class or
					-- an alias names a type, and the name of a field is a field.
					local target = "variable"
					if annotation.tag == "param" then
						target = "parameter"
					elseif annotation.tag == "class" or annotation.tag == "alias" then
						target = "type"
					elseif annotation.tag == "field" and annotation.name then
						-- `---@field [integer] T` names a key type rather than a field, and a key
						-- type reads as a type.
						target = annotation.name:sub(1, 1) == "[" and "type" or "property"
					end
					carve(nameStart, nameStop, target)
				end
				---@type integer?
				local typeStart = annotation.typeStart
				---@type integer?
				local typeStop = annotation.typeStop
				if typeStart and typeStop then
					typeWords(text, typeStart, typeStop, carve)
				end
			end
		end

		if count_ == 0 then
			emitSpan(token.start, token.stop, "comment")
			return
		end
		table.sort(carved, function(left, right) return left.start < right.start end)

		---@param from integer
		---@param to integer
		---@param target string
		---@param modifiers integer?
		local function emitLines(from, to, target, modifiers)
			-- Split at newlines: a span that crosses one cannot be encoded.
			local cursor = from
			while cursor <= to do
				local newline = text:find("\n", cursor, true)
				local lineStop = (newline and newline - 1 < to) and newline - 1 or to
				emitSpan(cursor, lineStop, target, modifiers)
				cursor = lineStop + 2
			end
		end

		local cursor, seen = token.start, token.start - 1
		for _, span in ipairs(carved) do
			if span.start > seen then
				if span.start > cursor then
					emitLines(cursor, span.start - 1, "comment", TOKEN_MODIFIER.documentation)
				end
				emitLines(span.start, span.stop, span.target)
				cursor = span.stop + 1
				seen = span.stop
			end
		end
		if cursor <= token.stop then
			emitLines(cursor, token.stop, "comment", TOKEN_MODIFIER.documentation)
		end
	end

	local tokens = result.tokens
	for at = 1, tokens.count do
		local token = tokens.arena[at]
		local written = tokens.texts[at]
		if token.kind == KIND.comment then
			emitComment(token, written)
		else
			---@type string?
			local target
			if token.kind == KIND.keyword then
				target = "keyword"
			elseif token.kind == KIND.string then
				-- The literal is a string. What is read rather than spelled — a pattern's escapes,
				-- a format's conversions — is a plugin's to colour, and it answers over this text.
				target = "string"
			elseif token.kind == KIND.number then
				target = "number"
			elseif token.kind == KIND.symbol and written ~= "::" and written ~= "label" then
				target = "operator"
			elseif token.kind == KIND.name then
				target = kinds[token.start] or "variable"
			end
			if target then
				emitSpan(token.start, token.stop, target)
			end
		end
	end

	-- What the plugins asked to colour, by the byte of *the reader's* text: a plugin colours the
	-- language it reads, so its spans are already in the offsets the editor holds and need no map.
	-- A kind the legend does not have is left out rather than advertised to an editor that cannot
	-- know it.
	---@type table<integer, string>
	local askedKind = {}
	---@type table<integer, integer>
	local askedMods = {}
	local pluginStarted = timing.now()
	---@param nodeIdx integer?
	---@return lye.doc.Type?
	local function typeOfNode(nodeIdx)
		---@type lye.parser.Node?
		local node = nodeIdx and result.nodes[nodeIdx]
		return node and typeOfExpression(self.names[uri], nodeIdx, node.start) or nil
	end
	---@param node lye.parser.Node
	local function callNameOf(node) return analyzerNames.callName(result, node) end
	---@type lye.analyzer.Result
	local analysis = names or {}
	local asked = plugin.tokens(view.specs, {
		uri = uri, source = view.source, text = view.text, root = self:packageRoot(uri),
		map = view.map, parsed = result, analysis = analysis,
		typeOf = typeOfNode,
		ownerOf = types.ownerOf,
		callName = callNameOf,
	})
	timing.detail("plugin-tokens", pluginStarted, "plugins=%d spans=%d", #view.specs, #asked)
	for _, span in ipairs(asked) do
		local from, to, kind = span.from, span.to, span.type
		if type(from) == "number" and type(to) == "number" and TOKEN_TYPE[kind] and to >= from then
			for at = math.max(from, 1), math.min(to, #view.source) do
				askedKind[at] = kind
				askedMods[at] = span.modifiers or 0
			end
		end
	end

	-- Every span in the editor's own offsets, in order, with what a plugin coloured cut out of what
	-- the walk found: a `%d` inside a string is a conversion, and the string is written around it.
	---@type { from: integer, to: integer, kind: string, modifiers: integer? }[]
	local pieces = {}
	---@param from integer
	---@param to integer
	---@param kind string
	---@param modifiers integer?
	local function collect(from, to, kind, modifiers)
		if from > to then return end
		pieces[#pieces + 1] = { from = from, to = to, kind = kind, modifiers = modifiers }
	end
	for _, span in ipairs(spans) do
		-- What lye read out of the text a plugin wrote has nowhere to be pointed at: `---@type
		-- number` exists in the lowered text, not in the line the reader wrote.
		if not view.map:rangeIsWritten(span.from, span.to) then
			local from, to = originalRange(view.map, span.from, span.to)
			---@cast from integer
			---@cast to integer
			local at = from
			while at <= to do
				local kind = askedKind[at] or span.kind
				local modifiers = askedKind[at] and askedMods[at] or span.modifiers
				local stop = at
				while stop < to
					and (askedKind[stop + 1] or span.kind) == kind
					and ((askedKind[stop + 1] and askedMods[stop + 1] or span.modifiers) == modifiers) do
					stop += 1
				end
				-- A span a plugin covers is the plugin's: the walk writes up to it and carries on
				-- after it, and the plugin's own span is written from its own list below.
				if not askedKind[at] then collect(at, stop, kind, modifiers) end
				at = stop + 1
			end
		end
	end
	for _, span in ipairs(asked) do
		if TOKEN_TYPE[span.type] and type(span.from) == "number" and type(span.to) == "number" then
			collect(math.max(span.from, 1), math.min(span.to, #view.source), span.type, span.modifiers)
		end
	end
	table.sort(pieces, function(left, right)
		if left.from ~= right.from then return left.from < right.from end
		return left.to > right.to
	end)

	local data, count = json.array(), 0
	local lastLine, lastStart, lastStop = 0, 0, 0
	local isFirst = true

	--- Tokens are relative to the one before, and a token never spans a line, so a span that does
	--- is written as one token per line it covers.
	---@param from integer
	---@param to integer
	---@param kind string
	---@param modifiers integer?
	local function write(from, to, kind, modifiers)
		-- Two spans of the lowered text can stand for one span of the editor's — everything a
		-- plugin wrote inside a statement answers with that statement — so a span that begins where
		-- the one before it already reached is not one to send.
		if from <= lastStop then from = lastStop + 1 end
		if from > to then return end
		local at = from
		while at <= to do
			local newline = view.source:find("\n", at, true)
			---@type integer
			local lineStop = to
			if newline then lineStop = math.min(newline - 1, to) end
			if lineStop >= at then
				local line, start = position.toPosition(view.source, view.sourceIndex, at, encoding)
				local _, stopCharacter = position.toPosition(view.source, view.sourceIndex, lineStop, encoding)
				local deltaLine = isFirst and line or (line - lastLine)
				local deltaStart = isFirst and start or (deltaLine == 0 and (start - lastStart) or start)
				count += 1
				data[count] = deltaLine
				count += 1
				data[count] = deltaStart
				count += 1
				data[count] = math.max(stopCharacter - start + 1, 1)
				count += 1
				data[count] = TOKEN_TYPE[kind]
				count += 1
				data[count] = modifiers or 0
				lastLine, lastStart, isFirst, lastStop = line, start, false, lineStop
			end
			if not newline or newline > to then break end
			at = newline + 1
		end
	end

	for _, piece in ipairs(pieces) do write(piece.from, piece.to, piece.kind, piece.modifiers) end

	local answer = { data = data }
	self.tokens_[uri] = { text = document.text, answer = answer }
	timing.detail("tokens", started, "cached=0 tokens=%d spans=%d", count / 5, #pieces)
	return answer
end

--- Completion kinds, by number, as the protocol defines them.
local COMPLETION_KIND = {
	["function"] = 3, method = 2, field = 5, variable = 6, class = 7, module = 9, namespace = 9,
	parameter = 6, property = 10, keyword = 14, constant = 21,
}

--- Collect everything a value carries into one table: its own fields, its parents', and both
--- sides of a union. A field the class keeps to itself is left out, since reading one is reported.
---@param type lye.doc.Type
---@param out table<string, lye.doc.Type>
---@param result lye.analyzer.Result?
---@param offset integer?
local function collectFields(type, out, result, offset)
	if type.variant == "class" or type.variant == "object" then
		-- A class carries who may read each field; the shared type alias leaves the table out.
		---@cast type lye.doc.Type & { visibility: table<string, string>? }
		for name, field in pairs(type.fields or {}) do
			local visibility = type.visibility and type.visibility[name]
			if not out[name] and visibility ~= "private" then out[name] = field end
		end
		for _, parent in ipairs(type.parents or {}) do collectFields(parent, out, result, offset) end
	elseif type.variant == "union" then
		for _, member in ipairs(type.types) do collectFields(member, out, result, offset) end
	elseif result and offset then
		-- A value of a base type reads the library of the same name: `s:lower()` is `string.lower`.
		-- That library is a global the definitions declare, so it is read the way any other name is
		-- — the class the prelude holds is the annotations as written, not a type with fields.
		-- Without this a method on a string, the commonest receiver there is, completed to nothing
		-- while `math.floor` resolved, because `math` is a class of its own.
		---@type lye.analyzer.Variable?
		local variable = analyzer.lookupAt(result, type.variant, offset)
		---@type lye.doc.Type?
		local library = variable and analyzer.typeAt(result, variable, offset)
		if library and library ~= type then collectFields(library, out, result, offset) end
	end
end

--- Everything a value carries, by name.
---@param type lye.doc.Type
---@param result lye.analyzer.Result
---@param offset integer
local function fieldsOf(type, result, offset)
	local out = {}
	collectFields(type, out, result, offset)
	return out
end

--- The value a `.` or `:` was written after, and the name typed after it so far. The arena
--- already knows: `math.` is an index whose field failed to parse, and `table.inse` one whose
--- field is half written, so nothing is recovered by looking at the text.
---@param result lye.analyzer.Result
---@param source string
---@param offset integer where the cursor is
---@return integer? target arena index of the value
---@return string prefix what has been typed of the field name
---@return boolean isMethod
---@return integer? keyFrom where the key text starts, when it has to be rewritten
---@return string? quote the quote a rewritten key is written with
local function accessAt(result, source, offset)
	local found
	for _, node in ipairs(result.parser.nodes) do
		-- `t["` names no field in the tree, and an `index` or a method call is what has one. The node spans
		-- its arguments — an unterminated call spans the file — so the field decides, not the node.
		local isAccess = node.kind == "index" and node.isDynamic ~= true
			or (node.kind == "call" and node.isMethod == true)
		if node.target and isAccess then
			---@type lye.parser.Node?
			local target = result.parser.nodes[node.target]
			if target then
				-- The field starts after the `.` or `:` that follows the value it is read on.
				local targetStop = valueStop(result, target)
				local fieldStart = fieldStartAt(source, targetStop)
				local upToCursor = source:sub(targetStop, offset - 1)
				if fieldStart <= offset and not upToCursor:find("\n", 1, true) then
					local fieldStop = node.field and (fieldStart + #node.field) or fieldStart
					if offset <= fieldStop + 1 and (not found or fieldStart > found.start) then
						local typed = node.field and node.field:sub(1, math.max(offset - fieldStart, 0)) or ""
						found = {
							target = node.target, prefix = typed,
							isMethod = node.isMethod == true, start = fieldStart,
						}
					end
				end
			end
		elseif node.target and node.kind == "index" and node.isDynamic == true then
			-- `t["…` being typed: the parser has no field name for it, so what has been written
			-- of the key is the text between the bracket and the cursor. Only a quoted key is a
			-- field name — `t[i]` reads one the writer named elsewhere.
			---@type lye.parser.Node?
			local target = result.parser.nodes[node.target]
			if target then
				local keyStart = fieldStartAt(source, valueStop(result, target))
				if keyStart <= offset and (not found or keyStart > found.start) then
					local typed = source:sub(keyStart, offset - 1)
					local opening = typed:sub(1, 1)
					local quote, name
					if opening == '"' or opening == "'" then
						local rest = typed:sub(2)
						if rest:sub(-1) == opening and not rest:sub(1, -2):find(opening, 1, true) then
							-- The key is written and closed: the list is what the table holds, and
							-- choosing from it replaces the key rather than being inserted into it.
							quote, name = opening, ""
						elseif not rest:find(opening, 1, true) then
							quote, name = opening, rest
						end
					elseif typed == "" then
						-- Just the bracket: the field is about to be named, and a name only fits here
						-- as a string.
						quote, name = '"', ""
					end
					if name and not name:find("\n") then
						found = {
							target = node.target, prefix = name, isMethod = false, start = keyStart,
							keyFrom = opening == "" and offset or keyStart, quote = quote,
						}
					end
				end
			end
		end
	end
	if found then return found.target, found.prefix, found.isMethod, found.keyFrom, found.quote end
end

--- The primitives an annotation may name, which no file declares.
local PRIMITIVE_TYPES = {
	"any", "boolean", "function", "integer", "never", "nil", "number", "string", "table", "unknown",
}

---@param self lye.Server
---@param uri string
---@return table
function Lye:completeTypes(uri)
	local items, seen = json.array(), {}
	local namespace = doc.classes.read(self.names[uri].doc)
	---@param name string
	---@param detail string
	---@param kind integer
	local function offer(name, detail, kind)
		if seen[name] then return end
		seen[name] = true
		items[#items + 1] = { label = name, kind = kind, detail = detail }
	end

	---@param classes table<string, lye.doc.Class>
	---@param aliases table<string, lye.doc.Alias>
	local function offerNamespace(classes, aliases)
		for name, class in pairs(classes) do
			---@cast name string
			offer(name, class.parent and ("class: " .. class.parent) or "class", COMPLETION_KIND.class)
		end
		for name, alias in pairs(aliases) do
			---@cast name string
			offer(name, "alias of " .. alias.body, COMPLETION_KIND.class)
		end
	end

	for _, name in ipairs(PRIMITIVE_TYPES) do offer(name, "built-in type", COMPLETION_KIND.class) end
	-- This document's own come first, since they win over the definitions where they disagree.
	offerNamespace(namespace.classes, namespace.aliases)
	offerNamespace(PRELUDE.classes,
		PRELUDE.aliases --[[@as table<string, lye.doc.Alias>]])
	return { isIncomplete = false, items = items }
end

---@param self lye.Server
---@param params lye.lsp.Params
---@return table
function Lye:onCompletion(params)
	local uri = params.textDocument?.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	if not uri or not document then return { isIncomplete = false, items = json.array() } end
	-- Analysed on demand, the way hover does it: a document that was just opened has not been
	-- through the analyzer yet, and answering nothing for it is how completion stops working in a
	-- file nobody has typed in.
	---@type lye.analyzer.Result?
	local names = self.names[uri]
	if not names then
		self:analyze(uri)
		names = self.names[uri]
	end
	if not names then return { isIncomplete = false, items = json.array() } end
	---@cast names lye.analyzer.Result

	local where = params.position
	if not where then return { isIncomplete = false, items = json.array() } end
	local source = self:textOf(uri)
	local offset = self:offsetAt(uri, where.line, where.character)
	if not source or not offset then return { isIncomplete = false, items = json.array() } end

	-- Inside `require("...")` what is wanted is a module name, and the files of the workspace are
	-- the list of them. The item replaces the text inside the quotes.
	local inside = self:requireStringAt(uri, source, offset)
	if inside then
		local items = json.array()
		local seen = {}
		-- A plugin may add modules the workspace index does not cover: the engine's own names, a
		-- `requirePaths` directory, or what lde linked into the package's target. The workspace's
		-- own list is added after it, so a file of this project is never hidden by a plugin.
		local asked = plugin.complete(self:plugins(uri), {
			uri = uri, source = source, text = source, offset = offset,
			prefix = inside.typed, workspace = self.server.rootPath, packageRoot = self:packageRoot(uri),
		})
		for _, found in ipairs(asked) do
			if not seen[found.name] and found.name:sub(1, #inside.typed) == inside.typed then
				seen[found.name] = true
				items[#items + 1] = {
					label = found.name,
					kind = 9,
					detail = found.detail or found.path,
					textEdit = {
						range = self:toRange(source, document.lineIndex, inside.from, inside.to),
						newText = found.name,
					},
				}
			end
		end
		for _, found in ipairs(self:moduleNames(inside.typed, uri)) do
			if not seen[found.name] then
				seen[found.name] = true
				-- A builtin module has no path in this workspace to show, and its own name is what
				-- it is called: the definitions are where it comes from.
				local detail = found.detail
				if not detail and found.path then
					local root = self.server.rootPath or ""
					detail = root ~= "" and found.path:sub(#root + 2) or found.path
				end
				items[#items + 1] = {
					label = found.name,
					kind = 9,
					detail = detail,
					textEdit = {
						range = self:toRange(source, document.lineIndex, inside.from, inside.to),
						newText = found.name,
					},
				}
			end
		end
		return { isIncomplete = false, items = items }
	end

	-- Inside a `---@` comment the writer is naming a type rather than a value.
	local lineStart = source:sub(1, offset - 1):match(".*()\n") or 1
	local before = source:sub(lineStart, offset - 1)
	-- The pattern the doc reader uses, so `--- @param` offers types exactly where `---@param` does.
	if before:match("^%s*" .. doc.TAG_PATTERN) then return self:completeTypes(uri) end

	local target, prefix, isMethod, keyFrom, quote = accessAt(names, source, offset)
	if target then
		local items = json.array()
		local base = typeOfExpression(names, target, offset)
		if base then
			local signatures = names.signatures or {}
			for name, field in pairs(fieldsOf(base, names, offset)) do
				---@cast name string
				if prefix == "" or name:sub(1, #prefix) == prefix then
					local kind = COMPLETION_KIND.field
					local item = { label = name, kind = kind, detail = types.display(field) }
					if types.isFn(field) then
						-- After a `:` the writer is calling a method; after a `.` it is reading a
						-- field, and a function stored in one is a function.
						kind = isMethod and COMPLETION_KIND.method or COMPLETION_KIND["function"]
						item.kind = kind
						-- The definitions keep the annotations a field was built from, and the
						-- document keeps its own declarations: either may carry documentation.
						---@type string?
						local owner = types.ownerOf(base)
						local signature = PRELUDE.fields[field]
						if not signature and owner and base.variant == "class" then
							signature = signatures[owner .. "." .. name]
								or signatures[owner .. ":" .. name]
						end
						if signature then
							item.detail = signatureText(signature)
							item.documentation = documentationItem(signature)
						end
					end
					---@type string?
					local keyQuote = quote
					if keyQuote and keyFrom then
						-- Inside a bracket the field is a *string* key, so the item replaces the
						-- text written of it — a bare label would leave `t[alpha]`.
						item.textEdit = {
							range = self:toRange(source, document.lineIndex, keyFrom, offset - 1),
							newText = keyQuote .. name .. keyQuote,
						}
					end
					items[#items + 1] = item
				end
			end
		end
		return { isIncomplete = false, items = items }
	end

	-- A name means nothing inside a string, and offering one there is how a completion writes
	-- `string.format` into the middle of a message. The module names above are the one thing a
	-- string may hold, and they were offered before this.
	local token = tokenAt(names.parser, offset)
	if token and token.kind == KIND.string then
		return { isIncomplete = false, items = json.array() }
	end

	local items, seen = json.array(), {}
	for _, variable in ipairs(analyzer.visibleAt(names, offset)) do
		if not seen[variable.name] then
			seen[variable.name] = true
			local shown = types.display(analyzer.typeAt(names, variable, offset))
			-- The icon follows the type: `math` is the namespace it holds, `join` the function it
			-- is, and a plain value is a variable.
			local as = readAsName(names, variable.name, offset)
			items[#items + 1] = {
				label = variable.name,
				kind = COMPLETION_KIND[as or "variable"],
				detail = shown,
				documentation = documentationItem(names.signatures and names.signatures[variable.name]),
			}
		end
	end

	-- The definitions declare functions rather than variables, so the standard library is offered from
	-- their signatures; a name the document declares was offered above, and a dotted name is reached
	-- through its table. `pairs` does not see through an `__index` metatable, so the names are walked.
	---@type table<string, lye.analyzer.Signature>
	local declaredSignatures = names.signatures or {}
	---@param name string
	local function offerGlobal(name)
		if seen[name] or name:find("[%.:]") then return end
		local signature = declaredSignatures[name]
		seen[name] = true
		items[#items + 1] = {
			label = name,
			-- A name the definitions declare without a signature is a value, not a function:
			-- `arg` and `_VERSION` are written as plain assignments.
			kind = signature and COMPLETION_KIND["function"] or COMPLETION_KIND.variable,
			detail = signatureText(signature),
			documentation = documentationItem(signature),
		}
	end
	for name in pairs(declaredSignatures) do
		---@cast name string
		offerGlobal(name)
	end
	for name in pairs(PRELUDE.globalNames or {}) do
		---@cast name string
		offerGlobal(name)
	end

	for _, keyword in ipairs(Parser.KEYWORD_LIST) do
		if not seen[keyword] then
			seen[keyword] = true
			items[#items + 1] = { label = keyword, kind = COMPLETION_KIND.keyword }
		end
	end

	return { isIncomplete = false, items = items }
end

---@param self lye.Server
---@param params lye.lsp.ChangeParams
---@param atOnce boolean? analyse now rather than with the rest of the burst. Opening a document
--- is the first look at it and nothing is following, so it is answered at once; a keystroke is
--- one of many and only the last of them is worth analysing.
function Lye:onDocumentChanged(params, atOnce)
	local uri = params.textDocument?.uri
	if not uri then return end
	local started = timing.now()
	self.epoch = self.epoch + 1

	-- Where this text first differs from the text the held parse read. The change ranges the
	-- editor sent are not used: a burst may have applied several of them since the last analysis,
	-- and one span covering all of them is still the right text to re-read, where the first one
	-- alone would be an offset into text this session never read. A plugin-lowered document has a
	-- different text at different offsets, so it never resumes.
	local view = self:view(uri)
	if view then
		self.cache.spans[uri] = self.cache:span(uri, view.text, not view.map:isEmpty())
	end

	-- The text has moved on, so what was worked out for the old text is not an answer about this
	-- one. It is dropped rather than analysed over: a burst of keystrokes arrives faster than a
	-- file can be analysed, and the ones in between are answers nobody reads. The parse stays.
	self:forget(uri)

	if atOnce then
		local span = self.cache.spans[uri]
		---@type lye.parser.Result?
		local result = self:analyze(uri, span and span.from)
		if result then
			---@cast result lye.parser.Result
			self:publishDiagnostics(uri, result)
		end
		timing.detail("open", started, "bytes=%d", #self.server.documents:get(uri).text)
		if self.cache.analysis[uri] then self.cache.current = uri end
		self:evictCache()
		return
	end
	self.dirty[uri] = true
	-- When this change arrived. The newest dirty document is the one the writer is looking at, so
	-- it is analysed first and the others wait for the next tick.
	self.dirtyAt = self.dirtyAt or {}
	self.dirtyAt[uri] = started
	self.dirtyEpoch = self.dirtyEpoch or {}
	self.dirtyEpoch[uri] = self.epoch
end

--- Every document whose text has changed since it was last analysed, read once the editor has
--- stopped sending. This is what makes typing cost one analysis rather than one per keystroke. The
--- one most recently changed goes first — that is the document the writer is looking at — and the
--- rest follow in the same pass: nothing promises another idle tick if no further message arrives,
--- and an editor is owed diagnostics for every document it changed.
---@param self lye.Server
function Lye:onIdle()
	local dirty = {}
	for uri in pairs(self.dirty) do
		dirty[#dirty + 1] = {
			uri = uri,
			at = self.dirtyAt and self.dirtyAt[uri] or 0,
			seq = self.dirtyEpoch and self.dirtyEpoch[uri] or 0,
		}
	end
	if #dirty == 0 then
		-- A request may have analysed a document on demand since the last pass, and that analysis
		-- stored without a pass of its own. Trim here so a read-only session between changes is
		-- held to the same budget as a typing one.
		self:evictCache()
		self:checkpoint()
		return
	end
	table.sort(dirty, function(a, b)
		if a.at ~= b.at then return a.at > b.at end
		if a.seq ~= b.seq then return a.seq > b.seq end
		return a.uri < b.uri
	end)

	for _, entry in ipairs(dirty) do
		local uri = entry.uri
		self.dirty[uri] = nil
		if self.dirtyAt then self.dirtyAt[uri] = nil end
		if self.dirtyEpoch then self.dirtyEpoch[uri] = nil end
		local started = entry.at > 0 and entry.at or timing.now()
		local analyzeStarted = timing.now()
		local span = self.cache.spans[uri]
		---@type lye.parser.Result?
		local result = self:analyze(uri, span and span.from)
		if result then
			---@cast result lye.parser.Result
			self:publishDiagnostics(uri, result)
		end
		timing.detail("keystroke", started, "analyze=%.1fms", timing.now() - analyzeStarted)
	end
	-- The newest changed document is the one the writer is looking at, so it is the one the cache
	-- keeps whatever the older ones needed.
	if self.cache.analysis[dirty[1].uri] then self.cache.current = dirty[1].uri end
	self:evictCache()
	self:checkpoint()
end

--- Everything the old text meant, dropped: the analysis, the names it declared, what it
--- contributed to the declaration and module layers, and its parsed annotations. The parse tree
--- stays, because the next text is read against it.
---@param self lye.Server
---@param uri string
function Lye:forget(uri)
	self.cache:forget(uri)
	self.declarations:documentChanged(uri)
	self.modules:documentChanged(uri, self.declaredBy[uri])
	self.declaredBy[uri] = nil
end

---@param self lye.Server
---@param params lye.lsp.Params
function Lye:onDocumentClosed(params)
	local uri = params.textDocument?.uri
	if not uri then return end

	self.epoch = self.epoch + 1
	-- The declarations and module answers it contributed, and then the parse, annotations and
	-- predecessor that only an open document is worth holding.
	self:forget(uri)
	self.cache:close(uri)
	self.declarations:documentClosed(uri)
	self.dirty[uri] = nil
	if self.dirtyAt then self.dirtyAt[uri] = nil end
	if self.dirtyEpoch then self.dirtyEpoch[uri] = nil end
	if self.views then
		local view = self.views[uri]
		if view then
			-- A view is found by the line index of the text it was read from, and by that of the
			-- lowered text it made, so both keys go with it.
			if self.viewByIndex[view.sourceIndex] == view then self.viewByIndex[view.sourceIndex] = nil end
			if self.viewByIndex[view.index] == view then self.viewByIndex[view.index] = nil end
			self.views[uri] = nil
		end
	end
	if self.tokens_ then self.tokens_[uri] = nil end
	self.server:notify(framework.METHOD.publishDiagnostics, { uri = uri, diagnostics = json.array() })
	-- The document's trees and facts are unreachable now, and the editor is not waiting for the
	-- close notification's answer. This is the one place a full collection is worth its pause.
	self:checkpoint(true)
end

--- Every place a name is written: its declaration and each reference. The analyzer records the
--- references while it resolves them, so this is a lookup rather than a search.
---@param self lye.Server
---@param params lye.lsp.Params
---@return lye.analyzer.Variable?
---@return lye.analyzer.Result?
---@return lye.parser.Result?
local function targetAt(self, params)
	local _, _, _, names, offset = self:resolvePosition(params)
	if not names or not offset then return nil, nil, nil end
	local name = nameAt(names.parser, offset)
	---@type lye.analyzer.Variable?
	local variable = name and analyzer.lookupAt(names, name, offset)
	return variable, names
end

---@param self lye.Server
---@param text string
---@param index lye.framework.LineIndex
---@param variable lye.analyzer.Variable
---@return table[] ranges
local function placesOf(self, text, index, variable)
	local ranges = json.array()
	local declaration = variable.declaration
	ranges[#ranges + 1] = self:toRange(text, index, declaration.start, declaration.stop)
	for _, at in ipairs(variable.references) do
		ranges[#ranges + 1] = self:toRange(text, index, at, at + #variable.name - 1)
	end
	return ranges
end

---@param self lye.Server
---@param params lye.lsp.Params
---@return table?
function Lye:onReferences(params)
	local variable = targetAt(self, params)
	local uri = params.textDocument?.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	if not variable or not document then return json.array() end

	local include = params.context == nil or params.context.includeDeclaration ~= false
	local places = placesOf(self, document.text, document.lineIndex, variable)
	local out = json.array()
	for index, range in ipairs(places) do
		if include or index > 1 then out[#out + 1] = { uri = uri, range = range } end
	end
	return out
end

--- Where a name written in an annotation is written again: the annotation that declares it and
--- every type text that names it. The name is dotted — `jit.funcinfo.c` — so a match counts only
--- where neither side of it runs on into another name.
---@param self lye.Server
---@param text string
---@param lineIndex lye.framework.LineIndex
---@param names lye.analyzer.Result
---@param written string
---@return table[] ranges
function Lye:placesOfType(text, lineIndex, names, written)
	local out = {}
	---@param from integer
	---@param to integer
	local function add(from, to)
		out[#out + 1] = self:toRange(text, lineIndex, from, to)
	end
	for _, annotation in ipairs((names.doc and names.doc.annotations) or {}) do
		---@type integer?
		local nameStart = annotation.nameStart
		---@type integer?
		local nameStop = annotation.nameStop
		if annotation.name == written and nameStart and nameStop then
			add(nameStart, nameStop)
		end
		---@type integer?
		local typeStart = annotation.typeStart
		if annotation.typeText and typeStart then
			local at = 1
			while true do
				local from, to = annotation.typeText:find(written, at, true)
				if not from or not to then break end
				if not annotation.typeText:sub(from - 1, from - 1):match("[%w_%.]")
					and not annotation.typeText:sub(to + 1, to + 1):match("[%w_%.]") then
					add(typeStart + from - 1, typeStart + to - 1)
				end
				at = to + 1
			end
		end
	end
	return out
end

---@param self lye.Server
---@param params lye.lsp.Params
function Lye:onDocumentHighlight(params)
	local uri, text, index, names, offset = self:resolvePosition(params)
	-- A type named in an annotation is not a name the parser sees: the annotation is one comment
	-- token. What is highlighted is the name written there, wherever it is written again — a
	-- client that is given nothing falls back to its own idea of a word, and its idea splits on
	-- the dots a type name is made of.
	local written = names and text and offset and nameInAnnotation(names, text, offset)
	if written then
		---@cast text string
		---@cast index lye.framework.LineIndex
		---@cast names lye.analyzer.Result
		local out = json.array()
		for _, range in ipairs(self:placesOfType(text, index, names, written)) do
			out[#out + 1] = { range = range, kind = 2 }
		end
		if #out > 0 then return out end
	end

	local variable = targetAt(self, params)
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	if not variable or not document then return json.array() end

	local out = json.array()
	local writes = {}
	for _, assignment in ipairs(variable.assignments) do writes[assignment.at] = true end
	for _, range in ipairs(placesOf(self, document.text, document.lineIndex, variable)) do
		-- A reference that a name is assigned to is a write; everything else is a read.
		local kind = writes[range.start.line + 1] and 3 or 2
		out[#out + 1] = { range = range, kind = kind }
	end
	return out
end

---@param self lye.Server
---@param params lye.lsp.Params
---@return table?
function Lye:onPrepareRename(params)
	local variable = targetAt(self, params)
	local uri = params.textDocument?.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	if not variable or not document then return nil end
	local declaration = variable.declaration
	return {
		range = self:toRange(document.text, document.lineIndex, declaration.start, declaration.stop),
		placeholder = variable.name,
	}
end

---@param self lye.Server
---@param params lye.lsp.Params
---@return table?
function Lye:onRename(params)
	local variable = targetAt(self, params)
	local uri = params.textDocument?.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	local newName = params.newName
	if not variable or not document or not newName then return nil end

	local edits = json.array()
	for _, range in ipairs(placesOf(self, document.text, document.lineIndex, variable)) do
		edits[#edits + 1] = { range = range, newText = newName }
	end
	return { changes = { [uri] = edits } }
end

--- The declaration a type came from: `---@class Point` over `local Point = {}` is a declaration
--- like any other, so go-to-type is a lookup by the class's name.
---@param self lye.Server
---@param params lye.lsp.Params
---@return table?
function Lye:onTypeDefinition(params)
	local uri, text, index, names, offset = self:resolvePosition(params)
	local result = names and names.parser
	-- The text is there whenever an analysis is: the one is read from the other. Saying so keeps
	-- the position resolvers below from taking a nil source.
	if not uri or not names or not result or not text or not index or not offset then return nil end

	-- A type named in an annotation is already a type; what it needs is where it is declared, in
	-- this document or another. Asking only about the other one left a jump into a class written
	-- in the same file with no answer at all.
	local target = self:targetAt(uri, text, names, offset)
	if target then
		if target.uri == uri then
			return { uri = uri, range = self:toRange(text, index, target.start, target.stop) }
		end
		return { uri = target.uri, range = self:rangeIn(target) }
	end

	local variable = analyzer.lookupAt(names, nameAt(result, offset) or "", offset)
	local held = variable and analyzer.typeAt(names, variable, offset)
	if not held then return nil end
	local wanted = held.variant == "class" and held.name or nil
	if not wanted then return nil end

	for _, declaration in ipairs(result.declarations) do
		if declaration.name == wanted then
			return {
				uri = uri,
				range = self:toRange(text, index, declaration.start, declaration.stop),
			}
		end
	end
end

--- Folding: the blocks the parser recorded, and the comment blocks above them.
---@param self lye.Server
---@param params lye.lsp.Params
function Lye:onFoldingRange(params)
	local uri = params.textDocument?.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	local result = uri and self.analysis[uri]
	if not uri or not document or not result then return json.array() end

	local view = self:view(uri)
	local text, index = self:textOf(uri)
	if not view or not text or not index then return json.array() end
	local out, seen = json.array(), {}
	---@param from integer
	---@param to integer
	---@param kind string
	local function add(from, to, kind)
		local source, sourceIndex = text, index
		if not view.map:isEmpty() then
			-- A folding range is a pair of lines in the editor's text, so the span an analysis
			-- reports travels back before it is read as lines.
			from, to = originalRange(view.map, from, to)
			source, sourceIndex = view.source, view.sourceIndex
		end
		local startLine = select(1, position.toPosition(source, sourceIndex, from, self.server.encoding))
		local endLine = select(1, position.toPosition(source, sourceIndex, to, self.server.encoding))
		if endLine > startLine then
			local key = startLine .. ":" .. endLine
			if not seen[key] then
				seen[key] = true
				out[#out + 1] = { startLine = startLine, endLine = endLine, kind = kind }
			end
		end
	end

	for _, scope in ipairs(result.scopes) do add(scope.start, scope.stop, "region") end

	-- A run of comment lines is one folding range, which is what a doc block is.
	local runStart
	for at = 1, result.tokens.count do
		local token = result.tokens.arena[at]
		if token.kind == KIND.comment then
			if not runStart then runStart = token.start end
			local next_ = result.tokens.arena[at + 1]
			if not next_ or next_.kind ~= KIND.comment then
				add(runStart, token.stop, "comment")
				runStart = nil
			end
		else
			runStart = nil
		end
	end
	return out
end

--- Selection ranges: the chain of expressions and blocks containing a position, innermost first.
---@param self lye.Server
---@param params lye.lsp.Params
function Lye:onSelectionRange(params)
	local uri = params.textDocument?.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	local result = uri and self.analysis[uri]
	if not uri or not document or not result then return json.array() end

	local text, index = self:textOf(uri)
	local out = json.array()
	for _, where in ipairs(params.positions or {}) do
		local offset = self:offsetAt(uri, where.line, where.character)
		if not offset or not text or not index then return out end
		local held = {}
		for _, node in ipairs(result.nodes) do
			if node.start <= offset and offset <= node.stop then held[#held + 1] = node end
		end
		-- Outermost first, so each range can be written as the parent of the one inside it.
		table.sort(held, function(left, right)
			if left.start ~= right.start then return left.start < right.start end
			return left.stop > right.stop
		end)

		local range
		for _, node in ipairs(held) do
			local mine = self:toRange(text, index, node.start, node.stop)
			range = { range = mine, parent = range }
		end
		out[#out + 1] = range or { range = self:toRange(text, index, offset, offset) }
	end
	return out
end

--- Inlay hints: the type of a name that was inferred rather than written, which is what a reader
--- cannot see for themselves.
---@param self lye.Server
---@return table
--- How long an inlay hint may be. A table of twenty fields and a string of two hundred characters
--- are both correct answers to "what is this", and neither is readable beside a name.
local HINT_LIMIT = 32

--- The type an inlay hint shows, cut to fit. The hover still has all of it, so a hint only has to
--- say enough to be worth reading: what is kept is the beginning, cut back to a separator where
--- there is one rather than through the middle of a word.
---
--- A table shape that does not fit is not shown at all: half of `{ collect: fn() -> ... }` reads as
--- a table with one field, which is a worse answer than none. A name, a union or an array still
--- says what it is when it is cut, and the hover has the rest.
---@param type lye.doc.Type
local function hintText(type)
	local shown = types.display(type)
	if #shown <= HINT_LIMIT then return shown end
	if shown:sub(1, 1) == "{" then return nil end
	local cut = shown:sub(1, HINT_LIMIT)
	-- A string value keeps its shape: `"a very long messa…"` still reads as a string.
	if shown:sub(1, 1) == '"' then return cut .. '…"' end
	local edge = cut:match("^.*[,;{}]")
	if edge and #edge >= HINT_LIMIT / 2 then return edge .. " …" end
	local word = cut:match("^.*%s")
	return (word or cut) .. "…"
end

---@param self lye.Server
---@param params lye.lsp.Params
function Lye:onInlayHint(params)
	local uri = params.textDocument?.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	local names = uri and self.names[uri]
	if not uri or not document or not names then return json.array() end

	local view = self:view(uri)
	local text = self:textOf(uri)
	if not view or not text then return json.array() end
	local encoding = self.server.encoding
	---@type integer
	local from = 1
	---@type integer
	local to = #text
	local asked = params.range
	if asked then
		from = self:offsetAt(uri, asked.start.line, asked.start.character) or 1
		to = self:offsetAt(uri, asked["end"].line, asked["end"].character) or #text
	end

	local out = json.array()
	for _, variable in ipairs(names.variables) do
		local declaration = variable.declaration
		local value = declaration.valueIdx and names.parser.nodes[declaration.valueIdx]
		-- A function's own declaration is not a name whose type a reader has to guess, and the
		-- hint would land on the `(` of its parameter list.
		local isFunction = value ~= nil and value.kind == "function"
		if not variable.declared and not isFunction and declaration.start >= from and declaration.stop <= to then
			local held = analyzer.typeAt(names, variable, declaration.stop)
			local shown = hintText(held)
			-- `local ffi = require("ffi")` with a type that reads `ffi` says nothing: the hint
			-- would be the name written twice.
			if shown == variable.name then shown = nil end
			if shown and shown ~= "unknown" and shown ~= "any" then
				local at = declaration.stop + 1
				if view and not view.map:isEmpty() then at = originalAt(view.map, at) end
				local line, character = position.toPosition(view.source, view.sourceIndex, at, encoding)
				out[#out + 1] = {
					position = { line = line, character = character },
					label = ": " .. shown,
					kind = 1,
					paddingLeft = false,
				}
			end
		end
	end
	return out
end

--- The call a position is inside, for signature help.
---@param result lye.parser.Result
---@param offset integer
---@return lye.parser.Node?
local function callAt(result, offset)
	local found
	for _, node in ipairs(result.nodes) do
		if node.kind == "call" and node.start <= offset and offset <= node.stop + 1 then
			if not found or node.start > found.start then found = node end
		end
	end
	return found
end

--- Whether a call argument satisfies an overload parameter. A parameter written as a literal names
--- one value, and the text typed at the call is what says whether that overload is still possible.
---@param wanted lye.doc.Type
---@param actual lye.doc.Type
local function overloadMismatch(wanted, actual)
	if wanted.variant == "union" then
		for _, member in ipairs(wanted.types) do
			if not overloadMismatch(member, actual) then return false end
		end
		return true
	end
	local exact = (wanted.variant == "number" and wanted.value ~= nil)
		or (wanted.variant == "boolean" and wanted.value ~= nil)
		or (wanted.variant == "extern" and wanted.name
			and wanted.name:match("^[\"']") and wanted.name:match("[\"']$"))
	if exact then return types.display(wanted) ~= types.display(actual) end
	return types.mismatch(wanted, actual, "argument") ~= nil
end

--- The type of one argument as the call wrote it. A string literal is the one string it spells,
--- which is what an overload's `"*a"` names; a name keeps the type the analysis gave it.
---@param names lye.analyzer.Result
---@param node lye.parser.Node
---@param offset integer
---@return lye.doc.Type
local function argumentTypeAt(names, node, offset)
	if node.kind == "string" then
		return types.stringValue(type(node.value) == "string" and node.value or "")
	end
	return typeOfExpression(names, node.index, offset) or types.UNKNOWN_TYPE
end

--- The overloads still possible after the arguments already written, with the index of the first
--- parameter that is not the receiver. Returns nil when the callee has no usable overloads.
---@param names lye.analyzer.Result
---@param node lye.parser.Node
---@param offset integer
---@param signature lye.analyzer.Signature
---@param completed integer how many arguments are wholly before the cursor
---@return { shape: lye.doc.Type, first: integer }[]?
local function remainingOverloads(names, node, offset, signature, completed)
	---@type string[]
	local overloads = signature.overloads
	if #overloads == 0 then return nil end
	---@type lye.doc.Type?
	local receiver = node.isMethod and typeOfExpression(names, node.target, offset) or nil
	if receiver ~= nil then receiver = types.narrowTruthiness(receiver, true) or receiver end
	---@cast receiver lye.doc.Type?

	local kept = {}
	local args = node.args or {}
	for _, written in ipairs(overloads) do
		local shape = types.parse(written, PRELUDE_RESOLVE)
		if shape and shape.variant == "fn" then
			local first, fits = 1, true
			if receiver ~= nil then
				local wanted = shape.params[1]
				if wanted then
					if overloadMismatch(wanted, receiver) then
						fits = false
					else
						first = 2
					end
				end
			end
			if fits then
				for index = 1, completed do
					local argIdx = args[index]
					local wanted = shape.params[index + first - 1]
					if not wanted and shape.variadic and index + first - 1 > #shape.params then
						wanted = shape.variadic
					end
					if argIdx and wanted
						and overloadMismatch(wanted, argumentTypeAt(names, names.parser.nodes[argIdx], offset)) then
						fits = false
						break
					end
				end
			end
			if fits and not shape.variadic then
				local available = #shape.params - first + 1
				if #(node.args or {}) > available then fits = false end
			end
			if fits then kept[#kept + 1] = { shape = shape, first = first } end
		end
	end
	if #kept == 0 then return nil end
	return kept
end

--- One signature whose parameter types are the union still possible at each position. As the
--- writer types an argument, the overloads it rules out disappear and the next parameter narrows;
--- when one shape is left it is that shape's exact signature.
---@param names lye.analyzer.Result
---@param node lye.parser.Node
---@param text string
---@param kept { shape: lye.doc.Type, first: integer }[]
---@return table signature
local function narrowedSignature(names, node, text, kept)
	local count = 0
	for _, entry in ipairs(kept) do
		count = math.max(count, #entry.shape.params - entry.first + 1)
	end
	local parts, parameters = {}, json.array()
	for index = 1, count do
		---@type lye.doc.Type[]
		local members = {}
		for _, entry in ipairs(kept) do
			local wanted = entry.shape.params[entry.first + index - 1]
			if wanted then
				---@cast wanted lye.doc.Type
				members[#members + 1] = wanted
			end
		end
		local shown = members[1] and types.display(types.union(members)) or "any"
		parts[#parts + 1] = shown
		parameters[#parameters + 1] = { label = shown }
	end
	---@type lye.doc.Type[]
	local returns = {}
	for _, entry in ipairs(kept) do
		local one = entry.shape.returns
		if one then
			---@cast one lye.doc.Type
			returns[#returns + 1] = one
		end
	end
	local returned = returns[1] and types.display(types.union(returns)) or nil
	return {
		label = writtenName(names, node, text) .. "(" .. table.concat(parts, ", ") .. ")"
			.. (returned and (" -> " .. returned) or ""),
		parameters = parameters,
		count = count,
	}
end

---@param self lye.Server
---@param params lye.lsp.Params
---@return table?
function Lye:onSignatureHelp(params)
	local _, text, _, names, offset = self:resolvePosition(params)
	local result = names and names.parser
	if not names or not result or not text or not offset then return nil end

	local node = callAt(result, offset)
	if not node then return nil end
	---@type lye.analyzer.Signature?
	local signature = signatureFor(names, node, offset)
	if not signature then return nil end
	---@cast signature lye.analyzer.Signature

	local parts, params_ = {}, json.array()
	for _, annotation in ipairs(signature.params) do
		local held = annotation.type or "any"
		---@type string?
		local name = annotation.name
		local one = (name and name ~= "") and (name .. ": " .. held) or held
		parts[#parts + 1] = one
		params_[#params_ + 1] = { label = one }
	end
	local returned = signature.returns and signature.returns.type
	local label = writtenName(names, node, text) .. "(" .. table.concat(parts, ", ") .. ")"
		.. (returned and (" -> " .. returned) or "")

	-- How many arguments are wholly written before the cursor. The one being typed is left out:
	-- its overload is not decided until the literal is complete.
	local completed = 0
	for index_, argIdx in ipairs(node.args or {}) do
		local argument = result.nodes[argIdx]
		if argument and argument.stop < offset then completed = index_ else break end
	end

	-- An overload this call can still take decides the parameter type shown. The arguments already
	-- written have eliminated the shapes they do not fit; the rest contribute a union, and one
	-- shape left is its own exact signature.
	local kept = remainingOverloads(names, node, offset, signature, completed)
	local active = completed

	if kept then
		local narrowed = narrowedSignature(names, node, text, kept)
		label = narrowed.label
		params_ = narrowed.parameters
		active = math.min(completed, math.max(narrowed.count - 1, 0))
	elseif #signature.params > 0 then
		active = math.min(completed, #signature.params - 1)
	end

	return {
		signatures = json.array({ {
			label = label,
			parameters = params_,
			documentation = signature.doc and { kind = "markdown", value = signature.doc } or nil,
		} }),
		activeSignature = 0,
		activeParameter = active,
	}
end

--- The function a position names, for the call hierarchy: what a caller and a callee are both
--- about.
---@param self lye.Server
---@param params lye.lsp.Params
function Lye:onCallHierarchyPrepare(params)
	local uri, text, index, names, offset = self:resolvePosition(params)
	local result = names and names.parser
	if not uri or not text or not index or not names or not result or not offset then return nil end

	local name = nameAt(result, offset)
	local variable = name and analyzer.lookupAt(names, name, offset)
	if not variable then return nil end
	local declaration = variable.declaration
	return json.array({ {
		name = variable.name,
		kind = variable.declaration.isFunction and 12 or 13,
		uri = uri,
		range = self:toRange(text, index, declaration.start, declaration.stop),
		selectionRange = self:toRange(text, index, declaration.start, declaration.stop),
		data = { uri = uri, name = variable.name, offset = declaration.start },
	} })
end

--- The function a position is inside, which is what a caller is: the innermost declaration whose
--- body holds the offset.
---@param parsed lye.parser.Result
---@param offset integer
---@return lye.parser.Declaration?
local function enclosingFunction(parsed, offset)
	local owner
	for _, declaration in ipairs(parsed.declarations) do
		local body = declaration.valueIdx and parsed.nodes[declaration.valueIdx]
		if body and body.kind == "function" and body.start <= offset and offset <= body.stop then
			local owned = owner and owner.valueIdx and parsed.nodes[owner.valueIdx]
			if not owned or body.start > owned.start then owner = declaration end
		end
	end
	return owner
end

--- A hierarchy item for a declaration.
---@param self lye.Server
---@param uri string
---@param text string
---@param index lye.framework.LineIndex
---@param declaration lye.parser.Declaration
---@return table
local function hierarchyItem(self, uri, text, index, declaration)
	local range = self:toRange(text, index, declaration.start, declaration.stop)
	return {
		name = declaration.name,
		kind = declaration.isFunction and 12 or 13,
		uri = uri,
		range = range,
		selectionRange = range,
		data = { uri = uri, name = declaration.name, offset = declaration.start },
	}
end

---@param self lye.Server
---@param params lye.lsp.Params
---@return table[]
function Lye:onCallHierarchyIncoming(params)
	local item = params.item or {}
	local data = item.data
	local uri = (data and data.uri) or item.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	local names = uri and self.names[uri]
	local result = uri and self.analysis[uri]
	if not uri or not document or not names or not result then return json.array() end

	---@type lye.analyzer.Variable?
	local variable
	if data and data.name then variable = analyzer.lookupAt(names, data.name, data.offset or 1) end
	if not variable then return json.array() end

	local text, index = document.text, document.lineIndex
	local calls, byCaller = json.array(), {}
	for _, at in ipairs(variable.references) do
		local caller = enclosingFunction(result, at)
		if caller then
			local key = caller.start
			local entry = byCaller[key]
			if not entry then
				entry = {
					from = hierarchyItem(self, uri, text, index, caller),
					fromRanges = json.array(),
				}
				byCaller[key] = entry
				calls[#calls + 1] = entry
			end
			entry.fromRanges[#entry.fromRanges + 1] = self:toRange(text, index, at, at + #variable.name - 1)
		end
	end
	return calls
end

---@param self lye.Server
---@param params lye.lsp.Params
---@return table[]
function Lye:onCallHierarchyOutgoing(params)
	local item = params.item or {}
	local data = item.data
	local uri = (data and data.uri) or item.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	local names = uri and self.names[uri]
	local result = uri and self.analysis[uri]
	if not uri or not document or not names or not result then return json.array() end

	local owner
	for _, declaration in ipairs(result.declarations) do
		if declaration.start == item.data?.offset or declaration.name == item.name then owner = declaration end
	end
	if not owner or not owner.valueIdx then return json.array() end

	local text, index = document.text, document.lineIndex
	local body = result.nodes[owner.valueIdx]
	local out, byCallee = json.array(), {}
	for _, node in ipairs(result.nodes) do
		local inside = node.kind == "call" and node.start >= body.start and node.stop <= body.stop + 1
		local name = inside and (node.field or node.callee)
		if name then
			local callee = analyzer.lookupAt(names, name, node.start)
			if callee then
				local key = callee.declaration.start
				local entry = byCallee[key]
				if not entry then
					entry = {
						to = hierarchyItem(self, uri, text, index, callee.declaration),
						fromRanges = json.array(),
					}
					byCallee[key] = entry
					out[#out + 1] = entry
				end
				entry.fromRanges[#entry.fromRanges + 1] = self:toRange(text, index, node.start, node.stop)
			end
		end
	end
	return out
end

--- How deep a line is written: the number of blocks the parser recorded around it. The tree knows
--- which blocks are bodies, so nothing is guessed from the text.
---@param parsed lye.parser.Result
---@param offset integer
---@return integer
local function indentAt(parsed, offset)
	local depth, seen = 0, {}
	for _, scope in ipairs(parsed.scopes) do
		-- Keyed by the scope itself: an `if` clause and the block it opens begin at the same
		-- offset when the clause is the block's first statement, and keying by the offset counted
		-- one of them and threw the other away — which is a body at the depth of its own header.
		if scope.start <= offset and offset <= scope.stop and not seen[scope] then
			seen[scope] = true
			depth = depth + 1
		end
	end
	-- A line at the top of the file is inside no block at all: the chunk is not among the scopes the
	-- parser records, so what is counted here is exactly the nesting a reader sees.
	return depth
end

--- Whether a line starts inside a string that runs over more than one line, which no formatter can
--- reindent without changing what the string says.
---@param parsed lye.parser.Result
---@param source string
---@param from integer
---@param to integer
---@return boolean
local function insideLongString(parsed, source, from, to)
	local tokens = parsed.tokens
	for index = 1, tokens.count do
		local token = tokens.arena[index]
		if token.kind == KIND.string and token.start <= from and from <= token.stop then
			return true
		end
	end
	_ = source
	_ = to
	return false
end

--- The edits a formatter would make to the lines in a range: the indentation a line is written at,
--- and nothing else. Spacing inside a line is left alone deliberately — a formatter that rewrites
--- what a writer wrote is one they turn off — and so is a line inside a long string.
---@param self lye.Server
---@param uri string
---@param firstLine integer 0-based
---@param lastLine integer 0-based
---@return table[]
function Lye:formatRange(uri, firstLine, lastLine)
	---@type lye.framework.Document?
	local document = self.server.documents:get(uri)
	local parsed = self.analysis[uri]
	if not document or not parsed then return json.array() end

	local text, index, encoding = document.text, document.lineIndex, self.server.encoding
	local edits = json.array()
	-- What the project asks for, and lye's own style where it asks nothing: tabs, one blank line
	-- between things, a trailing newline, nothing left hanging at the end of a line.
	local settings = self:editorSettings(uri)
	local unit = settings.indent_style == "space" and (" "):rep(tonumber(settings.indent_size) or 2) or "\t"
	local line, at = 0, 1
	while at <= #text do
		local newline = text:find("\n", at, true)
		local stop = (newline and newline - 1) or #text
		local written = text:sub(at, stop)
		if line >= firstLine and line <= lastLine then
			local trimmed = written:gsub("%s+$", "")
			if not insideLongString(parsed, text, at, stop) then
				-- The offset of the line's own text, not of the line: a block opens *after* the
				-- newline, so the leading whitespace sits outside it and every body came out at the
				-- depth of the thing it was written inside.
				local body = written:find("[^ \t]")
				local first = body and (at + body - 1) or at
				-- A blank line holds nothing, so it stays empty rather than indented to whatever
				-- depth it happens to sit at.
				local wanted = trimmed == "" and ""
					or unit:rep(indentAt(parsed, math.min(first, #text))) .. (trimmed:gsub("^[ \t]+", ""))
				if wanted ~= written then
					edits[#edits + 1] = {
						range = {
							start = { line = line, character = 0 },
							["end"] = { line = line, character = #written },
						},
						newText = wanted,
					}
				end
			elseif trimmed ~= written then
				edits[#edits + 1] = {
					range = {
						start = { line = line, character = #trimmed },
						["end"] = { line = line, character = #written },
					},
					newText = "",
				}
			end
		end
		line = line + 1
		at = stop + 2
		if not newline then break end
	end
	_ = index
	_ = encoding
	return edits
end

---@param self lye.Server
---@param params lye.lsp.Params
---@return table[]
function Lye:onFormatting(params)
	local uri = params.textDocument?.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	if not uri or not document then return json.array() end
	-- A document a plugin lowered has lines lye did not write and must not lay out: a plugin that
	-- knows the language it lowered from is the one that knows its style.
	local view = self:view(uri)
	if view and not view.map:isEmpty() then return json.array() end
	local text = document.text
	local lines = 0
	for _ in text:gmatch("\n") do lines += 1 end
	local edits = self:formatRange(uri, 0, lines)

	-- The rest of the style is about the document rather than one line, so it is applied only when the
	-- whole file is asked for: one blank line between things, and a single newline at the end.
	local settings = self:editorSettings(uri)
	local blankRun, at = 0, 1
	local line = 0
	while at <= #text do
		local newline = text:find("\n", at, true)
		local stop = (newline and newline - 1) or #text
		local written = text:sub(at, stop)
		if written:match("^%s*$") then
			blankRun += 1
			if blankRun > 1 then
				edits[#edits + 1] = {
					range = {
						start = { line = line, character = 0 },
						["end"] = { line = line + 1, character = 0 },
					},
					newText = "",
				}
			end
		else
			blankRun = 0
		end
		line += 1
		at = stop + 2
		if not newline then
			-- The last line, when the file does not end where it should. The indentation may have
			-- rewritten this very line, so the newline joins that edit rather than racing it.
			if settings.insert_final_newline ~= "false" and written ~= "" then
				local existing = edits[#edits]
				if existing and existing.range.start.line == line - 1 then
					existing.newText = existing.newText .. "\n"
				else
					edits[#edits + 1] = {
						range = {
							start = { line = line - 1, character = #written },
							["end"] = { line = line - 1, character = #written },
						},
						newText = "\n",
					}
				end
			end
			break
		end
	end
	return edits
end

---@param self lye.Server
---@param params lye.lsp.Params
---@return table[]
function Lye:onFormattingRange(params)
	local uri = params.textDocument?.uri
	local range = params.range
	if not uri or not range then return json.array() end
	return self:formatRange(uri, range.start.line, range["end"].line)
end

--- The `.editorconfig` that covers a document, read once per directory: the file is opened on
--- every keystroke otherwise, and it changes about as often as never.
---@param self lye.Server
---@param uri string
function Lye:editorSettings(uri)
	local path = uri:gsub("^file://", "")
	local directory = path:match("^(.*)/[^/]*$")
	self.settings = self.settings or {}
	local cached = self.settings[directory]
	if not cached then
		cached = editorconfig.forFile(directory, path)
		self.settings[directory] = cached
	end
	return cached
end

--- `textDocument/onTypeFormatting`: after a newline, the line being written gets its indentation.
--- A new line inside an alias gets the `--- | ` that continues it instead, and that is the only
--- edit then, because the indentation it needs is the alias's own.
---@param self lye.Server
---@param params lye.lsp.Params
---@return table[]
function Lye:onTypeFormatting(params)
	local uri = params.textDocument?.uri
	local where = params.position
	if not uri or not where then return json.array() end
	-- A document a plugin lowered is the plugin's text to lay out: lye's own style is about the
	-- lines it read, and those are not the lines the editor is showing.
	local view = self:view(uri)
	if view and not view.map:isEmpty() then return json.array() end
	local continuation = self:aliasContinuation(uri, where.line)
	if continuation then
		local out = json.array()
		out[1] = continuation
		return out
	end
	return self:formatRange(uri, where.line, where.line)
end

--- The `--- | ` a new line inside an alias wants, or nil when the line above it is not one, or when
--- the line being written already holds something: enter in the middle of a line is a split rather
--- than the start of another member.
---@param self lye.Server
---@param uri string
---@param line integer
---@return table?
function Lye:aliasContinuation(uri, line)
	---@type lye.framework.Document?
	local document = self.server.documents:get(uri)
	if not document or line < 1 then return nil end
	local lines = {}
	for piece in (document.text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = piece end
	local writing, above = lines[line + 1], lines[line]
	if writing == nil or above == nil or not writing:match("^%s*$") then return nil end
	local body = above:match("^%s*%-%-%-?%s*(.*)$")
	if not body or not (body:match("^@alias%s") or body:match("^|")) then return nil end
	return {
		range = { start = { line = line, character = 0 }, ["end"] = { line = line, character = 0 } },
		newText = (above:match("^(%s*)") or "") .. "--- | ",
	}
end

--- The classes that extend the one under the cursor, which is what "go to implementations" asks
--- for in a language without interfaces: a class's child is its implementation.
---@param self lye.Server
---@param params lye.lsp.Params
---@return table[]
function Lye:onImplementation(params)
	local uri, text, index, names, offset = self:resolvePosition(params)
	if not uri or not text or not index or not names or not offset then return json.array() end

	local variable = analyzer.lookupAt(names, nameAt(names.parser, offset) or "", offset)
	local held = variable and analyzer.typeAt(names, variable, offset)
	if not held or held.variant ~= "class" then return json.array() end
	---@cast held lye.doc.Type & { name: string }

	local out = json.array()
	local namespace = doc.classes.read(names.doc)
	local node = nodeAt(names, offset)
	local field = node and node.field
	for className, class in pairs(namespace.classes) do
		---@cast className string
		---@cast class lye.doc.Class
		local parent = class.parent and class.parent:match("^([%w_%.]+)") or nil
		-- A child class implements its parent, and a child's method implements the one it overrides.
		local matches = parent == held.name
		if not matches and field then
			for _, one in ipairs(class.fields) do
				---@cast one lye.doc.Field
				if one.name == field and class.parent then matches = true end
			end
		end
		if matches then
			---@type string?
			local fieldName = field
			for _, declaration in ipairs(names.parser.declarations) do
				local wanted = fieldName and (className .. ":" .. fieldName) or className
				if declaration.name == className or declaration.name == wanted
					or declaration.name == (className .. "." .. (fieldName or "")) then
					out[#out + 1] = {
						uri = uri,
						range = self:toRange(text, index, declaration.start, declaration.stop),
					}
				end
			end
		end
	end
	return out
end

--- What an editor offers to do about a diagnostic: an unused local is renamed to `_name`, which is
--- how a writer says the name is deliberate.
---@param self lye.Server
---@param params lye.lsp.Params
---@return table[]
function Lye:onCodeAction(params)
	local uri = params.textDocument?.uri
	local actions = json.array()
	for _, diagnostic in ipairs(params.context?.diagnostics or {}) do
		local name = (diagnostic.message or ""):match("^unused local `([%w_]+)`$")
		if name then
			actions[#actions + 1] = {
				title = string.format("Mark `%s` as deliberately unused", name),
				kind = "quickfix",
				diagnostics = json.array({ diagnostic }),
				edit = {
					changes = {
						[uri] = json.array({ { range = diagnostic.range, newText = "_" .. name } }),
					},
				},
				isPreferred = false,
			}
		end
	end
	return actions
end

--- How many places read each function, above its declaration: the count a reader would otherwise
--- have to ask for.
---@param self lye.Server
---@param params lye.lsp.Params
---@return table[]
function Lye:onCodeLens(params)
	local uri = params.textDocument?.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	local names = uri and self.names[uri]
	if not document or not names then return json.array() end

	local out = json.array()
	for _, variable in ipairs(names.variables) do
		local declaration = variable.declaration
		local isFunction = declaration.isFunction or (declaration.valueIdx
			and names.parser.nodes[declaration.valueIdx]
			and names.parser.nodes[declaration.valueIdx].kind == "function")
		local places = #variable.references
		if isFunction and places > 0 then
			out[#out + 1] = {
				range = self:toRange(document.text, document.lineIndex, declaration.start, declaration.stop),
				command = {
					title = places == 1 and "1 reference" or (places .. " references"),
					command = "",
				},
			}
		end
	end
	return out
end

--- The colours a number spells: `0xRRGGBB` and `0xAARRGGBB` are how LuaJIT code writes them, and
--- an editor shows a swatch for them.
---@param self lye.Server
---@param params lye.lsp.Params
---@return table[]
function Lye:onDocumentColor(params)
	local uri = params.textDocument?.uri
	---@type lye.framework.Document?
	local document = uri and self.server.documents:get(uri)
	local parsed = uri and self.analysis[uri]
	if not uri or not document or not parsed then return json.array() end

	local view = self:view(uri)
	local text, index = self:textOf(uri)
	if not view or not text or not index then return json.array() end
	local encoding = self.server.encoding
	local out = json.array()
	for at = 1, parsed.tokens.count do
		local token = parsed.tokens.arena[at]
		if token.kind == KIND.number then
			local written = parsed.tokens.texts[at]
			local digits = written:match("^0[xX](%x+)$")
			if digits and (#digits == 6 or #digits == 8) then
				---@param from integer
				---@param to integer
				---@return number
				local function channel(from, to)
					return tonumber(digits:sub(from, to), 16) / 255
				end
				local alpha = #digits == 8 and channel(1, 2) or 1
				local shift = #digits == 8 and 2 or 0
				local from, to = token.start, token.stop
				local source, sourceIndex = text, index
				if not view.map:isEmpty() then
					from, to = originalRange(view.map, from, to)
					source, sourceIndex = view.source, view.sourceIndex
				end
				local startLine, startCharacter = position.toPosition(source, sourceIndex, from, encoding)
				local stopLine, stopCharacter = position.toPosition(source, sourceIndex, to + 1, encoding)
				out[#out + 1] = {
					range = {
						start = { line = startLine, character = startCharacter },
						["end"] = { line = stopLine, character = stopCharacter },
					},
					color = {
						red = channel(1 + shift, 2 + shift),
						green = channel(3 + shift, 4 + shift),
						blue = channel(5 + shift, 6 + shift),
						alpha = alpha,
					},
				}
			end
		end
	end
	return out
end

--- A symbol in the workspace: every `*.lua` file under the folder the client opened, read once and
--- kept until a file in it changes. LuaLS indexes the workspace the same way; the difference is that
--- this reads the files when the first symbol is asked for rather than while the editor starts.
---@param self lye.Server
function Lye:workspaceSymbols()
	if self.workspace then return self.workspace end
	local started = timing.now()

	local out = json.array()
	local root = self.server.rootPath
	if not root then
		self.workspace = out
		return out
	end
	local pipe = io.popen(string.format("find %q -type f -name '*.lua' -not -path '*/target/*' -not -path '*/.*/*' | head -2000", root))
	if not pipe then
		self.workspace = out
		return out
	end
	local files = 0
	for file in pipe:lines() do
		---@cast file string
		local handle = io.open(file, "rb")
		-- A directory named like a file opens and then reads as nil, which is not a document.
		local source = handle and handle:read("*a")
		if handle then handle:close() end
		if type(source) == "string" then
			---@cast source string
			files += 1
			-- A symbol is a name the file declares, so the tree is all that is needed: analysing
			-- every file of a project to list them typed and checked a workspace nobody asked
			-- about, and one request over 126 files took the process from 17 MiB to 44.
			local result = Parser.new(source):parse()
			local index = nameIndex(source)
			local uri = "file://" .. file
			---@type lye.parser.Declaration[]
			local declarations = result.declarations
			for _, declaration in ipairs(declarations) do
				if declaration.qualifier ~= "param" and declaration.qualifier ~= "label"
					and not declaration.name:find("[%.:]") then
					local range = self:toRange(source, index, declaration.start, declaration.stop)
					out[#out + 1] = {
						name = declaration.name,
						kind = declaration.isFunction and 12 or 13,
						location = { uri = uri, range = range },
					}
				end
			end
		end
	end
	pipe:close()
	self.workspace = out
	timing.mark("workspace-symbols", started, string.format("files=%d symbols=%d", files, #out))
	return out
end

--- The line index of a source, kept per call rather than rebuilt: a workspace symbol request is
--- rare enough that caching it would be more bookkeeping than it saves.
---@param source string
function nameIndex(source)
	return position.buildLineIndex(source)
end

---@param self lye.Server
---@param params lye.lsp.Params
---@return table[]
function Lye:onWorkspaceSymbol(params)
	local query = (params.query or ""):lower()
	local out = json.array()
	for _, symbol in ipairs(self:workspaceSymbols()) do
		---@cast symbol { name: string }
		if query == "" or symbol.name:lower():find(query, 1, true) then out[#out + 1] = symbol end
	end
	return out
end

--- Register the plugin extensions with a client that supports dynamic registration. A static
--- `documentSelector` is chosen before the server starts and cannot know which plugins a workspace
--- will load; this is the protocol-level way to add the files those plugins claim.
---@param self lye.Server
function Lye:registerExtensionCapabilities()
	local capabilities = self.server.capabilities
	local client = self.server.clientCapabilities

	---@param path string[]
	---@return boolean
	local function supports(path)
		local held = client
		for _, key in ipairs(path) do
			if type(held) ~= "table" then return false end
			held = held[key]
		end
		return held == true or (type(held) == "table" and held.dynamicRegistration == true)
	end

	-- Work out whether the client can use any of this before walking the workspace and loading
	-- plugin code: a client with no dynamic registration gets the static selector only.
	local wanted = supports({ "textDocument", "synchronization", "dynamicRegistration" })
	for _, feature in ipairs(EXTENSION_FEATURES) do
		if not wanted and supports(feature.capability) then wanted = true end
	end
	if not wanted then return end

	local selectors = self:extensionSelectors()
	if not selectors then return end

	--- The static capability's options, with the extension selector swapped in. A boolean capability
	--- has no options of its own and becomes the selector alone.
	---@param provider string
	---@return table?
	local function providerOptions(provider)
		local held = capabilities[provider]
		if held == nil or held == false then return nil end
		local options = {}
		if type(held) == "table" then
			for key, value in pairs(held) do options[key] = value end
		end
		options.documentSelector = selectors
		return options
	end

	local registrations = {}
	---@param id string
	---@param method string
	---@param options table
	local function addRegistration(id, method, options)
		registrations[#registrations + 1] = {
			id = "lye-extension-" .. id, method = method, registerOptions = options,
		}
	end

	if supports({ "textDocument", "synchronization", "dynamicRegistration" }) then
		local sync = capabilities.textDocumentSync
		local change = type(sync) == "table" and sync.change or 2
		addRegistration("open", "textDocument/didOpen", { documentSelector = selectors })
		addRegistration("change", "textDocument/didChange", { documentSelector = selectors, syncKind = change })
		addRegistration("close", "textDocument/didClose", { documentSelector = selectors })
	end
	for _, feature in ipairs(EXTENSION_FEATURES) do
		if supports(feature.capability) then
			local options = providerOptions(feature.provider)
			if options then addRegistration(feature.id, feature.method, options) end
		end
	end

	if #registrations == 0 then return end
	self.server:request(framework.METHOD.registerCapability, { registrations = registrations })
end

---@param self lye.Server
function Lye:register()
	local server = self.server
	local method = framework.METHOD

	server:capability("hoverProvider", true)
	server:capability("definitionProvider", true)
	server:capability("typeDefinitionProvider", true)
	server:capability("documentSymbolProvider", true)
	server:capability("documentHighlightProvider", true)
	server:capability("referencesProvider", true)
	server:capability("renameProvider", { prepareProvider = true })
	server:capability("foldingRangeProvider", true)
	server:capability("selectionRangeProvider", true)
	server:capability("inlayHintProvider", true)
	server:capability("callHierarchyProvider", true)
	server:capability("workspaceSymbolProvider", true)
	server:capability("implementationProvider", true)
	server:capability("codeActionProvider", { codeActionKinds = { "", "quickfix" } })
	server:capability("codeLensProvider", { resolveProvider = false })
	server:capability("colorProvider", true)
	server:capability("documentFormattingProvider", true)
	server:capability("documentRangeFormattingProvider", true)
	server:capability("documentOnTypeFormattingProvider", { firstTriggerCharacter = "\n" })
	server:capability("diagnosticProvider", {
		identifier = "lye", interFileDependencies = true, workspaceDiagnostics = true,
	})
	server:capability("semanticTokensProvider", {
		legend = TOKEN_LEGEND, full = true, range = true,
	})
	-- `.` and `:` are what a field or method call starts with; a name is completed as it is typed.
	-- `[` is a trigger too: `t[` is where a field with a name that is not an identifier is reached.
	-- A client that supports dynamic registration is asked for file watching when the handshake
	-- ends, which is the first moment it accepts a request. One that does not gets no registration
	-- and no request, which is what it had before the watcher was advertised.
	server:on(framework.METHOD.initialized, function()
		self:registerExtensionCapabilities()
		local watched = server.clientCapabilities?.workspace?.didChangeWatchedFiles
		if not (watched and watched.dynamicRegistration) then return end
		server:request(framework.METHOD.registerCapability, {
			registrations = {
				{
					id = "lye-watched-files",
					method = method.workspaceDidChangeWatchedFiles,
					registerOptions = { watchers = { { globPattern = "**/*.lua" } } },
				},
			},
		})
	end)
	server.connection:setIdleHandler(function() self:onIdle() end)
	-- A change may be followed by more of the same burst, which is worth waiting for; anything else
	-- is reading what the burst described and has to find it done.
	server.connection:setBeforeHandler(function(message)
		---@cast message { method: string }
		local method = message.method
		-- The first request an editor sends, after the runtime and the definitions are already
		-- loaded: from here on the session is answering rather than starting.
		if method == framework.METHOD.initialize then timing.fromStart("initialize") end
		if method ~= framework.METHOD.didChange and method ~= framework.METHOD.didOpen then
			self:onIdle()
		end
	end)
	server:capability("completionProvider", { triggerCharacters = { ".", ":", "[", '"', "'" } })
	server:capability("signatureHelpProvider", { triggerCharacters = { "(", "," } })

	---@param _ any
	---@param params table?
	local function onDidOpen(_, params)
		self.server:onDidOpen(params or {})
		local held = params or {}
		---@cast held lye.lsp.ChangeParams
		self:onDocumentChanged(held, true)
	end
	server:on(method.didOpen, onDidOpen)

	---@param _ any
	---@param params table?
	local function onDidChange(_, params)
		self.server:onDidChange(params or {})
		local held = params or {}
		---@cast held lye.lsp.ChangeParams
		self:onDocumentChanged(held)
	end
	server:on(method.didChange, onDidChange)

	server:on(method.didClose, function(_, params)
		self.server:onDidClose(params or {})
		self:onDocumentClosed(params or {})
	end)

	server:on(method.documentSymbol, function(_, params) return self:onDocumentSymbol(params or {}) end)
	server:on(method.diagnostic, function(_, params) return self:onTextDocumentDiagnostic(params or {}) end)
	server:on(method.workspaceDiagnostic, function(_, params) return self:onWorkspaceDiagnostic(params or {}) end)
	server:on(method.hover, function(_, params) return self:onHover(params or {}) end)
	server:on(method.definition, function(_, params) return self:onDefinition(params or {}) end)
	server:on(method.semanticTokens, function(_, params) return self:onSemanticTokens(params or {}) end)
	server:on(method.completion, function(_, params) return self:onCompletion(params or {}) end)
	server:on(method.semanticTokensRange, function(_, params)
		return self:onSemanticTokens(params or {})
	end)
	server:on(method.signatureHelp, function(_, params) return self:onSignatureHelp(params or {}) end)
	server:on(method.references, function(_, params) return self:onReferences(params or {}) end)
	server:on(method.documentHighlight, function(_, params)
		return self:onDocumentHighlight(params or {})
	end)
	server:on(method.prepareRename, function(_, params) return self:onPrepareRename(params or {}) end)
	server:on(method.rename, function(_, params) return self:onRename(params or {}) end)
	server:on(method.typeDefinition, function(_, params) return self:onTypeDefinition(params or {}) end)
	server:on(method.foldingRange, function(_, params) return self:onFoldingRange(params or {}) end)
	server:on(method.selectionRange, function(_, params) return self:onSelectionRange(params or {}) end)
	server:on(method.inlayHint, function(_, params) return self:onInlayHint(params or {}) end)
	server:on(method.callHierarchyPrepare, function(_, params)
		return self:onCallHierarchyPrepare(params or {})
	end)
	server:on(method.callHierarchyIncoming, function(_, params)
		return self:onCallHierarchyIncoming(params or {})
	end)
	server:on(method.callHierarchyOutgoing, function(_, params)
		return self:onCallHierarchyOutgoing(params or {})
	end)
	server:on(method.workspaceSymbol, function(_, params) return self:onWorkspaceSymbol(params or {}) end)
	server:on(method.implementation, function(_, params) return self:onImplementation(params or {}) end)
	server:on(method.codeAction, function(_, params) return self:onCodeAction(params or {}) end)
	server:on(method.codeLens, function(_, params) return self:onCodeLens(params or {}) end)
	server:on(method.documentColor, function(_, params) return self:onDocumentColor(params or {}) end)
	server:on(method.formatting, function(_, params) return self:onFormatting(params or {}) end)
	server:on(method.formattingRange, function(_, params) return self:onFormattingRange(params or {}) end)
	server:on(method.typeFormatting, function(_, params) return self:onTypeFormatting(params or {}) end)
	server:on(method.workspaceDidChangeWatchedFiles, function(_, params)
		-- A symbol list is of files as they were, and the event has already moved one of them.
		self.workspace = nil
		if self.declarations:watchedFiles(params or {}) then return end
		self.epoch = self.epoch + 1
		self.known = nil
		self.packageNames = nil
		self.declarations:invalidate()
		self.modules:clear()
	end)
end

---@return lye.Server
function Lye.start()
	-- A server runs for hours, and every analysis leaves a tree, its scopes and its facts for the
	-- collector to find later. LuaJIT waits until the heap has *doubled*, which puts the resident set
	-- above the size of any file the editor asked about.
	collectgarbage("setpause", 150)
	local connection = rpc.Connection.new()
	local server = framework.Server.new(connection, { name = "lye", version = "0.1.0" })
	local lye = Lye.new(server)
	lye:register()
	server:run()
	return lye
end

return Lye
