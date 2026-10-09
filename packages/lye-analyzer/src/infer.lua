--[[
	Recursive typing over the arena.

	A node's type comes from its operands, so this is a fold over `left`/`right`/`target`/`args`
	starting at the expression and descending. Every node kind the parser emits is handled;
	a kind that is not understood yields a **mutable** unknown rather than a guess, so an
	unfinished corner produces no false error and can still be refined later.

	Results are memoised per arena index, so a node inside two expressions is typed once.
]]

local types = require("lye-doc.type")

local infer = {}

---@class lye.infer.Context
---@field parser lye.parser.Result
---@field typeOfName fun(name: string, offset: integer): lye.doc.Type
---@field returns table<string, lye.doc.Type>
---@field cache table<integer, lye.doc.Type>

local KNOWN = {
	number = true, string = true, literal = true, table = true, ["function"] = true,
	call = true, binary = true, unary = true, ternary = true, index = true, name = true, prefix = true,
}

---@param ctx lye.infer.Context
---@param idx integer?
---@return lye.doc.Type
local function of(ctx, idx)
	if not idx then return types.mutable() end
	local cached = ctx.cache[idx]
	if cached then return cached end

	local node = ctx.parser.nodes[idx]
	if not node then return types.mutable() end

	local result
	local kind = node.kind

	if kind == "number" then
		result = types.NUMBER
	elseif kind == "string" then
		result = types.STRING
	elseif kind == "literal" then
		result = node.text == "nil" and types.NIL_TYPE or types.BOOLEAN
	elseif kind == "table" then
		local kinds = ctx.parser.tableFields[node.index]
		if not kinds then
			result = types.TABLE
		else
			local fields = {}
			for name, fieldKind in pairs(kinds) do
				fields[name] = types.parse(fieldKind) or types.mutable()
			end
			result = types.object(fields)
		end
	elseif kind == "function" then
		result = types.FUNCTION
	elseif kind == "name" then
		result = node.name and ctx.typeOfName(node.name, node.start) or types.mutable()
	elseif kind == "prefix" then
		-- A prefix is either a grouped expression, which keeps the inner type, or a bare
		-- name that never received a suffix.
		if node.group then
			result = of(ctx, node.group)
		elseif node.callee then
			result = ctx.typeOfName(node.callee, node.start)
		else
			result = types.mutable()
		end
	elseif kind == "binary" then
		result = types.binaryResult(node.op or "", of(ctx, node.left), of(ctx, node.right))
	elseif kind == "unary" then
		result = types.unaryResult(node.op or "not", of(ctx, node.operand))
	elseif kind == "ternary" then
		result = types.combine(of(ctx, node.right), of(ctx, node.alternative))
	elseif kind == "index" then
		result = types.indexResult(of(ctx, node.target), node.field)
	elseif kind == "call" then
		result = ctx.returns[node.callee or ""] or types.mutable()
	else
		result = types.mutable()
	end

	ctx.cache[idx] = result
	return result
end

---@param parser lye.parser.Result
---@param typeOfName fun(name: string, offset: integer): lye.doc.Type
---@param returns table<string, lye.doc.Type>?
---@return lye.infer.Context
function infer.context(parser, typeOfName, returns)
	return { parser = parser, typeOfName = typeOfName, returns = returns or {}, cache = {} }
end

--- The type of the expression at an arena index.
---@param ctx lye.infer.Context
---@param idx integer?
---@return lye.doc.Type
function infer.at(ctx, idx)
	return of(ctx, idx)
end

--- Whether typing reached a verdict for this node, which is what refinement waits on.
---@param ctx lye.infer.Context
---@param idx integer
---@return boolean
function infer.isResolved(ctx, idx)
	local cached = ctx.cache[idx]
	return cached ~= nil and cached.variant ~= "unknown"
end

--- Promote anything still unknown that a known type now contradicts. A mutable unknown is a
--- promise that a later pass may learn more, so this is where that promise is kept.
---@param ctx lye.infer.Context
---@param returns table<string, lye.doc.Type>
function infer.refine(ctx, returns)
	for _, node in ipairs(ctx.parser.nodes) do
		if node.kind == "call" and node.callee and returns[node.callee] then
			local cached = ctx.cache[node.index]
			if cached and types.isMutable(cached) then
				types.promote(cached, returns[node.callee])
			end
		end
	end
end

infer.KNOWN = KNOWN

return infer
