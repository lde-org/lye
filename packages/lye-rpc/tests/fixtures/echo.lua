--[[
	Echo fixture for the `lye-rpc` framing tests.

	Run by the test harness as a subprocess, not by `lde test`. It must not require
	`lde-test`, because the test framework is only injected into files that `lde test`
	runs itself.

	Responses to a request, notifications for a notification, so the harness can check
	that a notification never draws a reply.
]]

local rpc = require("lye-rpc")

local conn = rpc.Connection.new()
conn:setHandler(function(self, message)
	if message.id ~= nil then
		self:respond(message.id, { method = message.method })
	else
		self:notify("sawNotification", { method = message.method })
	end
end)
conn:listen()
