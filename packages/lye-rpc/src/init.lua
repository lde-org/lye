--[[
	JSON-RPC 2.0 over the LSP base protocol, framed by `Content-Length` in bytes.
]]

local stdio = require("lye-rpc.stdio")
local json = require("lye-json")

local find, lower = string.find, string.lower
local decode, encode = json.decode, json.encode

local rpc = {}

rpc.ERROR = {
	parseError = -32700,
	invalidRequest = -32600,
	methodNotFound = -32601,
	invalidParams = -32602,
	internalError = -32603,
	serverNotInitialized = -32002,
	requestFailed = -32803,
	serverCancelled = -32802,
	contentModified = -32801,
	requestCancelled = -32800,
}

---@class lye.rpc.Message
---@field jsonrpc string?
---@field id integer|string?
---@field method string?
---@field params any
---@field result any
---@field error { code: integer, message: string, data: any }?

---@class lye.rpc.Connection
---@field chunk lye.rpc.Chunk
---@field handler fun(connection: lye.rpc.Connection, message: lye.rpc.Message)?
---@field onParseError fun(err: string)?
---@field isShutdown boolean
---@field isInitialized boolean
---@field nextId integer
local Connection = {}
Connection.__index = Connection

---@return lye.rpc.Connection
function Connection.new()
	return setmetatable({ chunk = stdio.Chunk.new(), nextId = 0, isShutdown = false, isInitialized = false }, Connection)
end

---@param self lye.rpc.Connection
function Connection:setHandler(handler)
	self.handler = handler
end

---@param self lye.rpc.Connection
function Connection:setParseErrorHandler(handler)
	self.onParseError = handler
end

---@param self lye.rpc.Connection
---@return table<string, string>? headers
---@return integer? headerBytes
function Connection:readHeaders()
	while true do
		local _, stop = find(stdio.slice(self.chunk, 1, self.chunk.n), "\r\n\r\n", 1, true)
		if stop then
			local headers = {}
			for line in stdio.slice(self.chunk, 1, stop - 4):gmatch("[^\r\n]+") do
				local name, value = line:match("^([^:]+):%s*(.*)$")
				if name then headers[lower(name)] = value end
			end
			return headers, stop
		end
		if stdio.read(self.chunk) == stdio.EOF then return nil, nil end
	end
end

---@param self lye.rpc.Connection
---@return lye.rpc.Message? message
function Connection:readMessage()
	local headers, headerBytes = self:readHeaders()
	if not headers then return nil end

	-- Without a length the frame boundary is unknown, so nothing after this point can
	-- be trusted. This is the one unrecoverable framing failure.
	local length = tonumber(headers["content-length"])
	local bodyEnd = length and headerBytes + length
	assert(bodyEnd, "lye-rpc: message header has no Content-Length")

	while self.chunk.n < bodyEnd do
		assert(stdio.read(self.chunk) ~= stdio.EOF, "lye-rpc: stream ended inside a message body")
	end

	local body = stdio.slice(self.chunk, headerBytes + 1, bodyEnd)
	stdio.consume(self.chunk, bodyEnd)

	local isOk, message = pcall(decode, body)
	if isOk then return message end
	if self.onParseError then self.onParseError(tostring(message)) end
end

local function write(message)
	local body = encode(message)
	stdio.write("Content-Length: " .. #body .. "\r\n\r\n" .. body)
end

---@param self lye.rpc.Connection
function Connection:respond(id, result)
	write({ jsonrpc = "2.0", id = id, result = result == nil ? json.null : result })
end

---@param id integer|string
---@param code integer
---@param message string
---@param data any
---@param self lye.rpc.Connection
function Connection:respondError(id, code, message, data)
	write({ jsonrpc = "2.0", id = id, error = { code = code, message = message, data = data } })
end

---@param self lye.rpc.Connection
function Connection:notify(method, params)
	write({ jsonrpc = "2.0", method = method, params = params })
end

---@param self lye.rpc.Connection
function Connection:request(method, params)
	self.nextId += 1
	write({ jsonrpc = "2.0", id = self.nextId, method = method, params = params })
	return self.nextId
end

---@param self lye.rpc.Connection
function Connection:dispatch(message)
	local handler = self.handler
	assert(handler, "lye-rpc: no message handler installed")
	handler(self, message)
end

---@param self lye.rpc.Connection
function Connection:listen()
	local didParseError = false
	self:setParseErrorHandler(function(err)
		didParseError = true
		self:respondError(json.null, rpc.ERROR.parseError, err)
	end)

	while true do
		didParseError = false
		local isOk, message = pcall(self.readMessage, self)
		assert(isOk, message)
		if message == nil and not didParseError then return end

		if message ~= nil then
			local isHandled, err = pcall(self.dispatch, self, message)
			if not isHandled and message.id ~= nil then
				self:respondError(message.id, rpc.ERROR.internalError, tostring(err))
			end
		end
	end
end

function rpc.exit(code)
	stdio.exit(code)
end

rpc.Connection = Connection

return rpc
