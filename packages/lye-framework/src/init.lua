--[[
	Language-agnostic LSP server: lifecycle, dispatch and document ownership. Feature
	handlers are registered by method name, so a language package supplies behaviour
	and this module supplies the protocol.
]]

local rpc = require("lye-rpc")
local json = require("lye-json")
local DocumentStore = require("lye-framework.document")
local position = require("lye-framework.position")

local server = {}

server.METHOD = {
	initialize = "initialize",
	initialized = "initialized",
	shutdown = "shutdown",
	exit = "exit",
	setTrace = "$/setTrace",
	cancelRequest = "$/cancelRequest",
	didOpen = "textDocument/didOpen",
	didChange = "textDocument/didChange",
	didClose = "textDocument/didClose",
	didSave = "textDocument/didSave",
	publishDiagnostics = "textDocument/publishDiagnostics",
	logMessage = "window/logMessage",
	hover = "textDocument/hover",
	definition = "textDocument/definition",
	documentSymbol = "textDocument/documentSymbol",
	semanticTokens = "textDocument/semanticTokens/full",
	semanticTokensRange = "textDocument/semanticTokens/range",
	completion = "textDocument/completion",
	signatureHelp = "textDocument/signatureHelp",
	references = "textDocument/references",
	prepareRename = "textDocument/prepareRename",
	rename = "textDocument/rename",
	documentHighlight = "textDocument/documentHighlight",
	typeDefinition = "textDocument/typeDefinition",
	foldingRange = "textDocument/foldingRange",
	selectionRange = "textDocument/selectionRange",
	inlayHint = "textDocument/inlayHint",
	callHierarchyPrepare = "textDocument/prepareCallHierarchy",
	callHierarchyIncoming = "callHierarchy/incomingCalls",
	callHierarchyOutgoing = "callHierarchy/outgoingCalls",
	workspaceSymbol = "workspace/symbol",
	implementation = "textDocument/implementation",
	codeAction = "textDocument/codeAction",
	codeLens = "textDocument/codeLens",
	documentColor = "textDocument/documentColor",
	formatting = "textDocument/formatting",
	formattingRange = "textDocument/rangeFormatting",
	typeFormatting = "textDocument/onTypeFormatting",
	workspaceDidChangeWatchedFiles = "workspace/didChangeWatchedFiles",
	workspaceDidChangeConfiguration = "workspace/didChangeConfiguration",
}

server.ERROR = rpc.ERROR

server.LOG = {
	error = 1,
	warning = 2,
	info = 3,
	log = 4,
}

---@return string
local function negotiateEncoding(params)
	local offered = params.capabilities?.general?.positionEncodings
	if type(offered) ~= "table" or #offered == 0 then return position.UTF16 end

	-- Only take utf-8 when the client ranks it first. A client that offers it second
	-- may still reject an encoding it did not rank first.
	if offered[1] == position.UTF8 then return position.UTF8 end
	for _, kind in ipairs(offered) do
		if kind == position.UTF16 then return position.UTF16 end
	end
	return position.UTF16
end

---@class lye.framework.Server
---@field connection lye.rpc.Connection
---@field documents lye.framework.DocumentStore
---@field capabilities table
---@field encoding string
---@field isInitialized boolean
---@field isShutdown boolean
---@field rootPath string? the folder the client opened, as a path
---@field handlers table<string, fun(self: lye.framework.Server, params: table?, id: any)>
---@field answered table<any, boolean> the requests a handler answered itself
---@field options { name: string?, version: string? }
local Server = {}
Server.__index = Server

function Server.new(connection, options)
	local caps = { textDocumentSync = { openClose = true, change = 2 } }
	return setmetatable({ connection = connection, documents = DocumentStore.new(), capabilities = caps, encoding = position.UTF16, isInitialized = false, isShutdown = false, handlers = {}, answered = {}, options = options or {} }, Server)
end

---@param self lye.framework.Server
function Server:on(method, handler)
	self.handlers[method] = handler
end

---@param self lye.framework.Server
---@return fun(self: lye.framework.Server, params: table?, id: any)?
function Server:handlerFor(method)
	return self.handlers[method]
end

---@param self lye.framework.Server
function Server:capability(key, value)
	self.capabilities[key] = value
end

---@return boolean
local function isRequest(message)
	return message.id ~= nil
end

---@param self lye.framework.Server
function Server:respond(id, result)
	self.answered[id] = true
	self.connection:respond(id, result)
end

---@param self lye.framework.Server
function Server:respondError(id, code, message)
	self.connection:respondError(id, code, message)
end

---@param self lye.framework.Server
function Server:notify(method, params)
	self.connection:notify(method, params)
end

--- A failure on the notification path has no response to carry it, so `window/logMessage`
--- is the only channel that can report it.
---@param message string
---@param kind integer?
---@param self lye.framework.Server
function Server:log(message, kind)
	self:notify(server.METHOD.logMessage, { type = kind or server.LOG.error, message = message })
end

---@param self lye.framework.Server
--- The folder the client opened: `workspaceFolders` when it sends them, and `rootUri` otherwise.
--- Both are URIs, and a workspace symbol search needs a path to walk.
---@param self lye.framework.Server
---@param params table
local function rememberRoot(self, params)
	local uri = params.rootUri
	local folders = params.workspaceFolders
	if type(folders) == "table" and folders[1] then uri = folders[1].uri end
	if type(uri) == "string" then self.rootPath = (uri:gsub("^file://", "")) end
end

---@param self lye.framework.Server
---@param params table
function Server:onInitialize(params)
	self.encoding = negotiateEncoding(params)
	-- Omitting this silently selects the utf-16 default, making every position wrong.
	self.capabilities.positionEncoding = self.encoding
	rememberRoot(self, params)

	local result = { capabilities = self.capabilities }
	if self.options.name then
		result.serverInfo = { name = self.options.name, version = self.options.version }
	end
	return result
end

--- Must answer with an explicit null: returning nothing is indistinguishable from
--- "the handler will answer later", and the client waits forever.
---@param self lye.framework.Server
function Server:onShutdown()
	self.isShutdown = true
	return json.null
end

---@param self lye.framework.Server
function Server:onDidOpen(params)
	local item = params.textDocument
	if item then self.documents:open(item.uri, item.text, item.version) end
end

---@param self lye.framework.Server
function Server:onDidChange(params)
	local item = params.textDocument
	if not item then return end
	self.documents:change(item.uri, item.version, params.contentChanges or {}, self.encoding)
end

---@param self lye.framework.Server
function Server:onDidClose(params)
	local item = params.textDocument
	if item then self.documents:close(item.uri) end
end

---@param self lye.framework.Server
function Server:handle(message)
	local method = message.method
	if not method then return end

	if not self.isInitialized and method ~= server.METHOD.initialize and method ~= server.METHOD.exit then
		if isRequest(message) then
			self:respondError(message.id, rpc.ERROR.serverNotInitialized, method)
		end
		return
	end

	if method == server.METHOD.initialize then
		local result = self:onInitialize(message.params or {})
		self.isInitialized = true
		self:respond(message.id, result)
		return
	end

	if method == server.METHOD.exit then
		rpc.exit(self.isShutdown ? 0 : 1)
		return
	end

	local handler = self.handlers[method]
	if not handler then
		if isRequest(message) then
			self:respondError(message.id, rpc.ERROR.methodNotFound, method)
		end
		return
	end

	if isRequest(message) then
		-- A handler that answers for itself later returns nothing, and the id it answered with is
		-- recorded. Every other request is answered, `null` included: a client waits forever for
		-- a response that never comes, which is what a hover over something with no type did.
		local isOk, result = pcall(handler, self, message.params, message.id)
		if not isOk then
			-- A handler that raises is a bug in this server, not in the document. Say so in the
			-- output channel before answering, or the only trace is an error on the wire.
			self:log(string.format("%s: %s", method, tostring(result)))
			result = nil
		end
		if result ~= nil or not self.answered[message.id] then
			self:respond(message.id, result)
		end
		-- The record is only needed while this request is in flight: leaving it behind would grow
		-- a table entry for every hover and completion of a session.
		self.answered[message.id] = nil
	else
		-- A raised notification error is discarded by the transport, since there is no id
		-- to answer with. Log it, or a broken handler fails in complete silence.
		local isOk, err = pcall(handler, self, message.params, nil)
		if not isOk then self:log(tostring(err)) end
	end
end

--- Install a handler only when the language package has not registered one. A default is
--- a fallback: overwriting an explicit registration replaces the package's behaviour.
---@param method string
---@param handler fun(self: lye.framework.Server, params: table?, id: any)
---@param self lye.framework.Server
function Server:installDefault(method, handler)
	if self.handlers[method] == nil then self:on(method, handler) end
end

---@param self lye.framework.Server
function Server:installDefaults()
	local M = server.METHOD
	self:installDefault(M.initialized, function() end)
	self:installDefault(M.setTrace, function() end)
	self:installDefault(M.cancelRequest, function() end)
	self:installDefault(M.didOpen, function(_, params) self:onDidOpen(params or {}) end)
	self:installDefault(M.didChange, function(_, params) self:onDidChange(params or {}) end)
	self:installDefault(M.didClose, function(_, params) self:onDidClose(params or {}) end)
	self:installDefault(M.didSave, function() end)
	self:installDefault(M.shutdown, Server.onShutdown)
end

---@param self lye.framework.Server
function Server:run()
	self:installDefaults()
	self.connection:setHandler(function(_, message) self:handle(message) end)
	self.connection:listen()
end

server.Server = Server

return server
