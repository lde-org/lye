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
---@field onIdle fun()? work to run when the stream has nothing more waiting
---@field onBefore fun(message: lye.rpc.Message)? work a handler will read, finished first
---@field isShutdown boolean
---@field isInitialized boolean
---@field nextId integer
local Connection = {}
Connection.__index = Connection

function Connection.new()
	return setmetatable({ chunk = stdio.Chunk.new(), nextId = 0, isShutdown = false, isInitialized = false }, Connection)
end

---@param self lye.rpc.Connection
---@param handler fun(connection: lye.rpc.Connection, message: lye.rpc.Message)
function Connection:setHandler(handler)
	self.handler = handler
end

---@param self lye.rpc.Connection
---@param handler fun(err: string)
function Connection:setParseErrorHandler(handler)
	self.onParseError = handler
end

--- Work that only has to happen once per burst of input, run when the stream has nothing more
--- waiting: the moment an editor has stopped sending is the moment its latest text is the one to
--- work on. Without this, every keystroke in a fast burst is analysed and all but the last are
--- thrown away.
---@param self lye.rpc.Connection
---@param handler fun()
function Connection:setIdleHandler(handler)
	self.onIdle = handler
end

--- Work that has to be finished before a message is handled, because the handler will read it.
--- Deferring is only safe while nothing is asking: a request that arrives mid-burst must find the
--- state the burst has already described.
---@param self lye.rpc.Connection
---@param handler fun(message: table)
function Connection:setBeforeHandler(handler)
	self.onBefore = handler
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
function Connection:readMessage()
	local headers, headerBytes = self:readHeaders()
	if not headers then return nil end

	-- Without a length the frame boundary is unknown, so nothing after this point can
	-- be trusted. This is the one unrecoverable framing failure.
	local length = tonumber(headers["content-length"])
	local bodyEnd = length and headerBytes + length
	assert(bodyEnd, "lye-rpc: message header has no Content-Length")
	---@cast headerBytes integer
	---@cast bodyEnd integer

	while self.chunk.n < bodyEnd do
		assert(stdio.read(self.chunk) ~= stdio.EOF, "lye-rpc: stream ended inside a message body")
	end

	local body = stdio.slice(self.chunk, headerBytes + 1, bodyEnd)
	stdio.consume(self.chunk, bodyEnd)

	local isOk, message = pcall(decode, body)
	if isOk then return message --[[@as lye.rpc.Message ]] end
	if self.onParseError then self.onParseError(tostring(message)) end
end

---@param message table
local function write(message)
	local body = encode(message)
	stdio.write("Content-Length: " .. #body .. "\r\n\r\n" .. body)
end

---@param self lye.rpc.Connection
---@param id integer|string|lye.json.null|nil
---@param result any
function Connection:respond(id, result)
	write({ jsonrpc = "2.0", id = id, result = result == nil ? json.null : result })
end

---@param id integer|string|lye.json.null|nil
---@param code integer
---@param message string
---@param data any
---@param self lye.rpc.Connection
function Connection:respondError(id, code, message, data)
	write({ jsonrpc = "2.0", id = id, error = { code = code, message = message, data = data } })
end

---@param self lye.rpc.Connection
---@param method string
---@param params any
function Connection:notify(method, params)
	write({ jsonrpc = "2.0", method = method, params = params })
end

---@param self lye.rpc.Connection
---@param method string
---@param params any
---@return integer
function Connection:request(method, params)
	self.nextId += 1
	write({ jsonrpc = "2.0", id = self.nextId, method = method, params = params })
	return self.nextId
end

---@param self lye.rpc.Connection
---@param message table
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
		self:respondError(json.null --[[@as lye.json.null ]], rpc.ERROR.parseError, err)
	end)

	while true do
		didParseError = false
		local isOk, message = pcall(self.readMessage, self)
		---@cast message lye.rpc.Message?
		assert(isOk, message)
		if message == nil and not didParseError then return end

		if message ~= nil then
			if self.onBefore then self.onBefore(message) end
			local isHandled, err = pcall(self.dispatch, self, message)
			if not isHandled and message.id ~= nil then
				self:respondError(message.id, rpc.ERROR.internalError, tostring(err))
			end
		end

		-- Bytes still in hand mean more is already on its way, so this is not the pause between
		-- bursts and the work can wait for the one that is.
		if self.onIdle and self.chunk.n == 0 then
			local isHandled, err = pcall(self.onIdle)
			assert(isHandled, err)
		end
	end
end

---@param code integer
function rpc.exit(code)
	stdio.exit(code)
end

rpc.Connection = Connection

return rpc
