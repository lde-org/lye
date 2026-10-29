--[[
	Fixture for the `lye-framework` lifecycle tests.

	Run as a subprocess by the test harness, so it must not require `lde-test`. It
	registers one extra request that reports the server's own view of a document, which
	is what makes incremental sync observable from the outside.
]]

local rpc = require("lye-rpc")
local framework = require("lye-framework")

local connection = rpc.Connection.new()
local server = framework.Server.new(connection, { name = "lye-test", version = "0.0.0" })

server:on("test/text", function(self, params)
	---@cast self lye.framework.Server
	---@cast params { uri: string }
	local document = self.documents:get(params.uri)
	return {
		text = document?.text,
		version = document?.version,
		encoding = self.encoding,
	}
end)

server:on("test/noResult", function() end)

-- Deliberate override of a default: a handler registered before `run` must survive
-- `installDefaults`, or a language package's behaviour is replaced by the no-op default.
server:on(framework.METHOD.didOpen, function(self, params)
	---@cast self lye.framework.Server
	---@cast params { textDocument: { uri: string } }
	self:onDidOpen(params or {})
	self:notify("test/didOpenOverride", { uri = params.textDocument?.uri })
end)

-- Deliberate raise: a notification error has no response, so it is only visible in the log.
server:on("test/raise", function() error("lye-framework test fixture raised") end)

server:run()
