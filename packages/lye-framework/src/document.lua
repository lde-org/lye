

local Uri = require("lye-framework.uri")
local position = require("lye-framework.position")

---@class lye.framework.Position
---@field line integer zero-based, as the protocol counts lines
---@field character integer zero-based, in the encoding the client negotiated

---@class lye.framework.Range
---@field start lye.framework.Position
---@field ["end"] lye.framework.Position

---@class lye.framework.Document
---@field uri string
---@field text string
---@field version integer?
---@field lineIndex lye.framework.LineIndex
local Document = {}
Document.__index = Document

---@class lye.framework.Change
---@field range lye.framework.Range?
---@field text string

---@param uri string
---@param text string
---@param version integer?
function Document.new(uri, text, version)
	return setmetatable({ uri = uri, text = text, version = version, lineIndex = position.buildLineIndex(text) }, Document)
end

---@param self lye.framework.Document
---@param text string
---@param version integer?
function Document:setText(text, version)
	self.text = text
	self.version = version
	self.lineIndex = position.buildLineIndex(text)
end

---@param self lye.framework.Document
---@param change lye.framework.Change
---@param encoding string
function Document:applyChange(change, encoding)
	if not change then return end

	local range = change.range
	if not range then
		self:setText(change.text or "", self.version)
		return
	end

	-- The index is the one this text was built with: a range is written in the text as it stands,
	-- and `setText` rebuilds the index for the text that replaces it. Rebuilding here as well made
	-- a keystroke scan the document twice more than it had to.
	local from = position.toOffset(
		self.text, self.lineIndex, range.start.line, range.start.character, encoding
	)
	local to = position.toOffset(
		self.text, self.lineIndex, range["end"].line, range["end"].character, encoding
	)
	if to < from then from, to = to, from end

	self:setText(self.text:sub(1, from - 1) .. (change.text or "") .. self.text:sub(to), self.version)
end

---@class lye.framework.DocumentStore
---@field byUri table<string, lye.framework.Document>
---@field byPath table<string, lye.framework.Document> keyed by `Uri.pathKey`, not by the URI string
local DocumentStore = {}
DocumentStore.__index = DocumentStore

function DocumentStore.new()
	return setmetatable({ byUri = {}, byPath = {} }, DocumentStore)
end

---@param self lye.framework.DocumentStore
---@param uri string
---@param text string
---@param version integer?
function DocumentStore:open(uri, text, version)
	local document = Document.new(uri, text, version)
	self.byUri[uri] = document
	self.byPath[Uri.pathKey(uri)] = document
	return document
end

---@param self lye.framework.DocumentStore
---@param uri string
---@return lye.framework.Document?
function DocumentStore:get(uri)
	return self.byUri[uri]
end

--- The open document for a path. The URI a client keys a document by and the path a module
--- resolves to need not be spelled the same way: VS Code writes a drive colon as `%3A`, and a
--- path may come from the filesystem in another case. Matching on the path keeps an unsaved
--- buffer the text a `require` of it reads.
---@param self lye.framework.DocumentStore
---@param path string
---@return lye.framework.Document?
function DocumentStore:forPath(path)
	return self.byPath[Uri.pathKey(path)]
end

--- The URI to publish or point at for a path: the one the client opened it with, when it is open,
--- and otherwise the form `Uri.fromPath` builds.
---@param self lye.framework.DocumentStore
---@param path string a path or a URI
---@return string
function DocumentStore:uriFor(path)
	local document = self:forPath(path)
	if document then return document.uri end
	return Uri.fromPath(path)
end

---@param self lye.framework.DocumentStore
---@param uri string
function DocumentStore:close(uri)
	local document = self.byUri[uri]
	if document then self.byPath[Uri.pathKey(document.uri)] = nil end
	self.byUri[uri] = nil
end

---@param uri string
---@param version integer?
---@param changes lye.framework.Change[]
---@param encoding string
---@param self lye.framework.DocumentStore
function DocumentStore:change(uri, version, changes, encoding)
	local document = self.byUri[uri]
	if not document then return nil end

	document.version = version
	for _, change in ipairs(changes) do
		document:applyChange(change, encoding)
	end
	return document
end

return DocumentStore
