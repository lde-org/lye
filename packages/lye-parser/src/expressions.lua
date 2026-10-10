--[[
	Expression grammar: precedence climbing, suffix chains and function bodies.
]]

local Parser = require("lye-parser")

local KIND = Parser.KIND

--- The text of a string literal without its quotes. Escapes stay as written: decoding them
--- needs an unescaper, and every reader so far compares plain names.
---@param text string the literal as written, quotes included
local function stringValue(text)
	local quote = text:sub(1, 1)
	if quote == '"' or quote == "'" then return text:sub(2, -2) end
	local level = text:match("^%[(=*)%[")
	if level then return text:sub(#level + 3, -(#level + 3)) end
	return text
end

--- Prefix expressions, with the suffix chain attached: calls, indexing, fields, method
--- calls and safe navigation all belong to one loop, which is how the engine parses them.
---@param allowTernaryColon boolean
---@return integer
local function parsePrefix(self, allowTernaryColon)
	local token = self:peek()
	local startOffset = token.start

	local callee, groupIdx
	if token.kind == KIND.name or self:text(token) == "goto" then
		callee = self:text(token)
		self:advance()
	elseif self:text(token) == "(" then
		self:advance()
		groupIdx = self:parseExpression()
		self:expect(")")
	else
		-- Still a node, so every caller sees a valid index and there is a span to report on.
		self:report(token, "expected an expression")
		self:advance()
		return self:emit("prefix", startOffset, token.stop, {})
	end

	-- The prefix is the expression's identity until a suffix wraps it. Nothing is
	-- auto-parented: the child lists are explicit, so there is one mechanism, not two.
	local expressionIdx = self:emit("prefix", startOffset, startOffset,
		{ callee = callee, group = groupIdx })

	while true do
		local nextToken = self:peek()
		local text = self:text(nextToken)
		local link

		if text == "." or text == "?." then
			self:advance()
			link = { field = self:parseName(), isField = true }
		elseif text == "[" then
			self:advance()
			self:parseExpression()
			self:expect("]")
			link = { isDynamic = true }
		elseif text == ":" and allowTernaryColon then
			self:advance()
			local method = self:parseName()
			-- The arguments are kept and the node is a call: a method call has a result, and one
			-- represented as a plain index node silently has none.
			local _, args = self:parseArguments()
			link = { field = method, isMethod = true, args = args, isCall = true }
		elseif text == "(" or text == "{" or nextToken.kind == KIND.string then
			local before = self.index
			local args
			_, args = self:parseArguments()
			if self.index > before then link = { callee = callee, args = args, isCall = true } end
		end

		if not link then break end
		link.kind = link.isCall and "call" or "index"
		link.target = expressionIdx
		expressionIdx = self:emit(link.kind, startOffset, self.arena[self.index - 1].stop, link,
			expressionIdx)
		-- Arguments are a list of any length, so they are adopted by loop rather than passed.
		if link.args then self:adopt(expressionIdx, link.args) end
		self.lastKind = link.kind
	end

	return expressionIdx
end

---@return integer
---@return lye.parser.Node[] arguments
local function parseArguments(self)
	local token = self:peek()
	if self:text(token) == "(" then
		local start = token.start
		self:advance()
		local args = {}
		if not self:check(")") then
			repeat
				local from = self.index
				self:parseExpression()
				local last = self.nodes[#self.nodes]
				if last and last.start >= start then args[#args + 1] = last.index end
				if self.index == from then self:advance() end
			until not self:accept(",")
		end
		self:expect(")")
		return start, args
	end
	if self:text(token) == "{" then
		local argStart = self:parseTable()
		return argStart, { self.nodes[#self.nodes] }
	end

	-- A string literal used directly as an argument.
	local start = token.start
	self:advance()
	self:emit("string", start, token.stop, { value = stringValue(self:text(token)) })
	return start, { self.nodes[#self.nodes] }
end

---@return integer
local function parseTable(self)
	local start = self:peek().start
	local fieldKinds, fieldValues, elementIdxs = {}, {}, {}
	self:expect("{")
	while not self:check("}") and not self:isEof(self:peek()) do
		self:skipComments()
		if self:check("}") then break end
		if self:check("[") then
			self:advance()
			self:parseExpression()
			self:expect("]")
			self:expect("=")
			self:parseExpression()
		elseif self:peek().kind == KIND.name and self:text(self:peekAt(2)) == "=" then
			local key = self:text(self:advance())
			self:advance()
			local from = self.index
			fieldValues[key] = self:parseExpression()
			fieldKinds[key] = self.lastKind or "unknown"
			if self.index == from then self:advance() end
		else
			-- A positional element. Its node is kept, so the literal's element type comes from
			-- what the elements actually are rather than from a kind name.
			elementIdxs[#elementIdxs + 1] = self:parseExpression()
		end
		if not self:accept(",") and not self:accept(";") then break end
	end
	self:expect("}")
	local index = self:emit("table", start, self.arena[self.index - 1].stop)
	-- Keyed by the node, which turns `local x = { foo = 1 }` into an object type without a
	-- reader having to find the literal again by position.
	if next(elementIdxs) then self.tableIndexes[index] = elementIdxs end
	if next(fieldKinds) then
		self.tableFields[index] = fieldKinds
		-- The node each value was read from, so a field of a literal is typed by what is written
		-- there rather than by the kind of thing it looked like: `{ __add = add }` holds a
		-- function, not a table.
		self.tableFieldValues[index] = fieldValues
		self.lastFields = fieldKinds
	else
		self.lastFields = nil
	end
	self.lastKind = "table"
	return index
end

---@return integer
local function parseFunctionBody(self, start, isMethod)
	-- The body's scope opens at the parameter list, not at the statement: a `local function f`
	-- declares its name outside the scope that holds its parameters and body, so the name stays
	-- visible after the declaration. Opening it at the statement put the name inside it.
	local paramsStart = self:peek().start
	self:expect("(")
	self:pushScope(paramsStart)
	local params = {}
	if isMethod then params[#params + 1] = self:declare("self", "param", self.arena[self.index]) end

	local isVariadic = false
	while not self:check(")") and not self:isEof(self:peek()) do
		if self:accept("...") then
			isVariadic = true
			break
		end
		local name, token = self:parseName()
		if name then params[#params + 1] = self:declare(name, "param", token) end
		if not self:accept(",") then break end
	end
	self:expect(")")

	self:parseBlock()
	self:popScope(self:peek().start - 1)
	self:expect("end")
	local index = self:emit("function", start, self.arena[self.index - 1].stop,
		{ isFunction = true, isVariadic = isVariadic, params = params })
	-- Set last, since parsing the body overwrites it.
	self.lastKind = "function"
	return index
end

---@return integer
local function parsePrimary(self, allowTernaryColon)
	local token = self:peek()
	local text = self:text(token)

	if text == "function" then
		local start = token.start
		self:advance()
		return parseFunctionBody(self, start, false)
	end

	-- Only `|a, b| -> expr` is a complete parameter list here; `x -> e` is recognised
	-- once the left operand has been parsed.
	if text == "|" then
		local start = token.start
		self:advance()
		self:pushScope(start)
		local params = {}
		while not self:check("|") and not self:isEof(self:peek()) do
			local name, nameToken = self:parseName()
			if name then params[#params + 1] = self:declare(name, "param", nameToken) end
			if not self:accept(",") then break end
		end
		self:expect("|")
		self:expect("->")
		-- The expression is the body, and what an arrow returns.
		local bodyIdx = self:parseExpression()
		self:popScope(self.arena[self.index - 1].stop)
		local index = self:emit("function", start, self.arena[self.index - 1].stop,
			{ isFunction = true, body = bodyIdx, params = params })
		self.lastKind = "function"
		return index
	end


	if text == "{" then return parseTable(self) end

	local variant = self:variant(token)
	if variant == "number" or variant == "string" then
		self:advance()
		local written = self:text(token)
		-- A literal is the value it spells, which is what lets `local n = 2149` be 2149 rather
		-- than the whole of `number`, and `5 + 6912` be worked out where it is written.
		local fields = variant == "string" and { value = stringValue(written) }
			or { value = tonumber(written), text = written }
		local index = self:emit(variant, token.start, token.stop, fields)
		self.lastKind = variant
		return index
	end

	if text == "nil" or text == "true" or text == "false" or text == "..." then
		self:advance()
		local index = self:emit("literal", token.start, token.stop, { text = text })
		-- The literal itself is the kind: nil and true are different types.
		self.lastKind = text
		return index
	end

	return parsePrefix(self, allowTernaryColon)
end

---@return integer
local function parseUnary(self, allowTernaryColon)
	local token = self:peek()
	for _, symbol in ipairs(Parser.UNARY) do
		if self:text(token) == symbol then
			local startOffset = token.start
			self:advance()
			local operandIdx = parseUnary(self, allowTernaryColon)
			return self:emit("unary", startOffset, self.nodes[operandIdx].stop,
				{ op = symbol, operand = operandIdx }, operandIdx)
		end
	end

	local idx = parsePrimary(self, allowTernaryColon)
	if self:check("->") then
		local startOffset = self.nodes[idx].start
		self:advance()
		local bodyIdx = self:parseBinary(1, allowTernaryColon)
		idx = self:emit("function", startOffset, self.nodes[bodyIdx].stop,
			{ isFunction = true, body = bodyIdx }, { bodyIdx })
		-- Set last, since parsing the body overwrites it.
		self.lastKind = "function"
	end
	return idx
end

--- `allowTernaryColon` is false inside a ternary's middle branch, where a `:` closes the
--- branch rather than starting a method call. The engine threads the same flag, and
--- without it `a ? b : c` reads the `:` as a method call.
--- Operands are node indices. A span comes from the node an index names, never from the
--- index itself, which is why every name here says which it holds.
---@param minPrecedence integer
---@param allowTernaryColon boolean
---@return integer idx of the node this expression produced
local function parseBinary(self, minPrecedence, allowTernaryColon)
	-- An expression never begins at a comment, which can appear before one.
	self:skipComments()
	local leftIdx = parseUnary(self, allowTernaryColon)
	local startOffset = self.nodes[leftIdx].start

	while true do
		local token = self:peek()
		local text = self:text(token)

		if text == "?" then
			if minPrecedence > 1 then break end
			self:advance()
			-- The middle branch is parsed with the colon disabled, so a `:` there closes the
			-- ternary instead of starting a method call.
			local thenIdx = self:parseBinary(1, false)
			self:expect(":")
			local elseIdx = self:parseBinary(1, allowTernaryColon)
			leftIdx = self:emit("ternary", startOffset, self.arena[self.index - 1].stop,
				{ left = leftIdx, right = thenIdx, alternative = elseIdx },
				leftIdx, thenIdx, elseIdx)
			self.lastKind = "ternary"
		else
			local level = Parser.BINARY_LEVEL[text]
			if not level or level < minPrecedence then break end

			self:advance()
			local isRight = text == "^" or text == "??"
			local rightIdx = self:parseBinary(isRight and level or (level + 1), allowTernaryColon)
			local stopOffset = self.nodes[rightIdx].stop
			leftIdx = self:emit("binary", startOffset, stopOffset,
				{ op = text, left = leftIdx, right = rightIdx }, leftIdx, rightIdx)
			self.lastKind = "binary"
		end
	end
	return leftIdx
end

Parser.parsePrefix = parsePrefix
Parser.parseArguments = parseArguments
Parser.parseTable = parseTable
Parser.parseFunctionBody = parseFunctionBody
Parser.parsePrimary = parsePrimary
Parser.parseUnary = parseUnary
Parser.parseBinary = parseBinary

---@param allowTernaryColon boolean?
---@return integer
function Parser:parseExpression(allowTernaryColon)
	if allowTernaryColon == nil then allowTernaryColon = true end
	return parseBinary(self, 1, allowTernaryColon)
end

return true
