--[[
	The name an expression is written as, and what a call is a call of.

	Leaf helpers: they read the node arena and nothing else, so every pass asks the same questions.
]]

--- The name a plain assignment writes. Only `x = v` names the variable it changes: `t.foo = v`
--- and `t[k] = v` write into a table, and reading them as an assignment to `t` would make every
--- table that is filled in a union with what was put in it.
---@param parsed lye.parser.Result
---@param targetIdx integer?
local function targetName(parsed, targetIdx)
	local node = targetIdx and parsed.nodes[targetIdx]
	if not node then return nil end
	if node.kind == "prefix" then return node.callee or node.name end
	if node.kind == "name" then return node.name end
end

--- The name an expression is written as, when it is one: `x`, `A.B.c`. A call or a computed
--- index is not a name, and says nothing about which table a function is written for.
---@param parsed lye.parser.Result
---@param idx integer?
local function writtenNameOf(parsed, idx)
	local node = idx and parsed.nodes[idx]
	if not node then return nil end
	if node.kind == "prefix" then return node.callee or node.name end
	if node.kind == "name" then return node.name end
	if node.kind == "index" and node.field then
		local base = writtenNameOf(parsed, node.target)
		if base then return base .. "." .. node.field end
	end
	return nil
end

--- The name a condition is about, and the field of it when the condition reads one. A
--- subject is an arena node: a name, a parenthesised expression, or a field of either.
---@param parsed lye.parser.Result
---@param idx integer? nil when the caller has no node to hand, which reads as nothing
local function readSubject(parsed, idx)
	local node = idx and parsed.nodes[idx]
	if not node then return nil end
	if node.kind == "prefix" then
		if node.group then return readSubject(parsed, node.group) end
		return node.callee
	end
	if node.kind == "index" and node.field and node.target and not node.isDynamic then
		local name = readSubject(parsed, node.target)
		if name then return name, node.field end
	end
end

--- The name a `type(x)` test is about, since the call is a node like any other.
---@param parsed lye.parser.Result
---@param idx integer? nil when the caller has no node to hand, which reads as nothing
---@return string? field
local function readTypeSubject(parsed, idx)
	local node = idx and parsed.nodes[idx]
	if not node or node.kind ~= "call" or node.callee ~= "type" then return nil end
	local argIdx = node.args and node.args[1]
	if not argIdx then return nil end
	return readSubject(parsed, argIdx)
end

--- The name a call is written with: `print`, `math.floor`, `ffi.cdef`. A call through a field
--- carries the field on the node it targets rather than on the call itself, so both halves are read
--- here rather than at every site that asks.
---@param parsed lye.parser.Result
---@param node lye.parser.Node
local function callName(parsed, node)
	if node.kind ~= "call" then return nil end
	local target = node.target and parsed.nodes[node.target]
	local field = node.field or (target and target.field)
	if not field then return nil end
	local owner = writtenNameOf(parsed, target and (target.target or node.target))
	return owner and (owner .. "." .. field) or field
end

local names = {}
names.targetName = targetName
names.writtenNameOf = writtenNameOf
names.readSubject = readSubject
names.readTypeSubject = readTypeSubject
names.callName = callName
return names
