--[[
	Statement grammar, including error recovery.
]]

local Parser = require("lye-parser")

local KIND = Parser.KIND

local statements = {}

function statements.parseIf(self)
	local start = self:peek().start
	self:expect("if")
	local conditionIdx = self:parseExpression()
	self:expect("then")
	self:pushScope(self:peek().start, conditionIdx)
	self:parseBlock()
	self:popScope(self:peek().start - 1, "then")

	while self:check("elseif") do
		self:advance()
		local clauseIdx = self:parseExpression()
		self:expect("then")
		self:pushScope(self:peek().start, clauseIdx)
		self:parseBlock()
		self:popScope(self:peek().start - 1, "elseif")
	end

	if self:check("else") then
		self:advance()
		self:pushScope(self:peek().start)
		self:parseBlock()
		self:popScope(self:peek().start - 1, "else")
	end
	self:expect("end")
	self:emit("if", start, self.arena[self.index - 1].stop)
end

function statements.parseDoBlock(self, start, conditionIdx)
	start = start or self:peek().start
	self:expect("do")
	self:pushScope(start, conditionIdx)
	self:parseBlock()
	self:popScope(self:peek().start - 1)
	self:expect("end")
end

function statements.parseWhile(self)
	local start = self:peek().start
	self:expect("while")
	local conditionIdx = self:parseExpression()
	self:parseDoBlock(nil, conditionIdx)
	self:emit("while", start, self.arena[self.index - 1].stop)
end

function statements.parseRepeat(self)
	local start = self:peek().start
	self:expect("repeat")
	self:pushScope(self:peek().start)
	self:parseBlock()
	self:popScope(self:peek().start - 1)
	-- The condition is parsed after the body, so the scope it guards takes it afterwards.
	local scope = self.scopes_[#self.scopes_]
	self:expect("until")
	scope.conditionIdx = self:parseExpression()
	self:emit("repeat", start, self.arena[self.index - 1].stop)
end

function statements.parseFor(self)
	local start = self:peek().start
	self:expect("for")
	self:pushScope(self:peek().start)

	local name, token = self:parseName()
	if name then self:declare(name, "local", token) end

	if self:accept("=") then
		self:parseExpression()
		self:expect(",")
		self:parseExpression()
		if self:accept(",") then self:parseExpression() end
	else
		while self:accept(",") do
			local extra, extraToken = self:parseName()
			if extra then self:declare(extra, "local", extraToken) end
		end
		self:expect("in")
		repeat
			self:parseExpression()
		until not self:accept(",")
	end

	-- Pass the scope's own start: `parseDoBlock` would otherwise default to the current
	-- token, which by then is `do` at best and `end` if the body was empty.
	local doStart = self:peek().start
	self:parseDoBlock(doStart)
	self:popScope(self.arena[self.index - 1].stop)
	self:emit("for", start, self.arena[self.index - 1].stop)
end

---@return string? name
---@return lye.lexer.Token? token
---@return boolean isMethod
function statements.parseFunctionName(self)
	local name, token = self:parseName()
	if not name then return nil, token, false end

	local full = name
	while self:accept(".") do
		local field, fieldToken = self:parseName()
		if not field then break end
		full = full .. "." .. field
		token = fieldToken
	end

	local isMethod = false
	if self:accept(":") then
		local method, methodToken = self:parseName()
		if method then
			full = full .. ":" .. method
			token = methodToken
		end
		isMethod = true
	end
	return full, token, isMethod
end

function statements.parseFunctionStatement(self)
	local start, startIdx = self:peek().start, self.index
	self:expect("function")

	local name, token, isMethod = self:parseFunctionName()
	if name and token then
		self:declare(name, name:find("[%.:]") and "field" or "global", token, true)
	end
	if self.lastDeclaration then self.declarations[self.lastDeclaration].anchorIdx = startIdx end
	self:parseFunctionBody(start, isMethod)
end

function statements.parseLocal(self, start)
	local startIdx = self.index
	self:expect("local")
	if self:accept("function") then
		local name, token = self:parseName()
		if name then self:declare(name, "local", token, true) end
		if self.lastDeclaration then self.declarations[self.lastDeclaration].anchorIdx = startIdx end
		self:parseFunctionBody(start, false)
		return
	end

	local first, count = nil, 0
	local lastToken
	repeat
		local name, token = self:parseName()
		lastToken = token
		if name then
			self:declare(name, "local", token)
			first = first or self.lastDeclaration
			count += 1
		else
			-- The name failed, but the initializer still has to be consumed or the next
			-- statement reports a second, misleading error for the same mistake.
			count = math.max(count, 1)
			first = first or self.lastDeclaration
		end
	until not self:accept(",")

	-- The initializer expressions become this statement's children, listed explicitly.
	local valueIdxs = {}
	if self:accept("=") then
		-- Fewer values than names is legal (`local a, b = 1`), so stop at the last one.
		-- With no declaration at all, `first` is nil and there is nothing to backfill.
		for offset = 0, count - 1 do
			self.lastKind = nil
			local valueIdx = self:parseExpression()
			valueIdxs[#valueIdxs + 1] = valueIdx
			if first then self:setInitializer(first + offset, self.lastKind, valueIdx) end
			if not self:accept(",") then break end
		end
	end
	-- The statement's first token is the anchor: an annotation describes a declaration when it
	-- is the comment right before it, which is a question about tokens, not offsets.
	if first then
		for index = first, first + count - 1 do
			if self.declarations[index] then self.declarations[index].anchorIdx = startIdx end
		end
	end
	local localIdx = self:emit("local", start, self.arena[self.index - 1].stop, nil)
	self:adopt(localIdx, valueIdxs)
end

function statements.parseConst(self, start)
	local startIdx = self.index
	self:expect("const")
	repeat
		local name, token = self:parseName()
		if name then
			self:declare(name, "local", token)
			self.declarations[self.lastDeclaration].anchorIdx = startIdx
		end
	until not self:accept(",")

	if self:accept("=") then
		repeat
			self.lastKind = nil
			self:parseExpression()
		until not self:accept(",")
	end
	self:emit("const", start, self.arena[self.index - 1].stop)
end

function statements.parseReturn(self)
	local start = self:peek().start
	self:expect("return")
	if not self:isBlockEnd() and not self:check(";") then
		repeat
			self:parseExpression()
		until not self:accept(",")
	end
	self:accept(";")
	self:emit("return", start, self.arena[self.index - 1].stop)
end

--- An assignment or a call statement. The engine parses the prefix once and then decides
--- from the next token, which is why this reads the same way.
function statements.parseExpressionStatement(self)
	-- `parsePrefix` reports a node index, so the statement's span comes from that node.
	local target = self:parsePrefix(true)
	local start = self.nodes[target].start
	local token = self:peek()
	local text = self:text(token)

	if text == "=" or text == "," then
		while self:accept(",") do
			target = self:parsePrefix(true)
		end
		self:expect("=")
		local valueIdx
		repeat
			-- The last value is the one the tree links; several targets with several values
			-- is not modelled yet.
			valueIdx = self:parseExpression()
		until not self:accept(",")
		self:emit("assignment", start, self.arena[self.index - 1].stop,
			{ target = target, value = valueIdx }, target, valueIdx)
		return
	end

	if Parser.COMPOUND[text] then
		self:advance()
		local valueIdx = self:parseExpression()
		self:emit("assignment", start, self.arena[self.index - 1].stop,
			{ target = target, value = valueIdx }, target, valueIdx)
	end
end

---@return boolean whether the token started a statement
function statements.parseStatement(self)
	local token = self:peek()
	local text = self:text(token)

	-- A semicolon is a statement separator and may also stand alone.
	if text == ";" then
		self:advance()
		return true
	end
	if text == "if" then self:parseIf() return true end
	if text == "while" then self:parseWhile() return true end
	if text == "repeat" then self:parseRepeat() return true end
	if text == "for" then self:parseFor() return true end
	if text == "do" then self:parseDoBlock() return true end
	if text == "function" then self:parseFunctionStatement() return true end
	if text == "local" then self:parseLocal(token.start) return true end
	if text == "return" then self:parseReturn() return true end
	if text == "const" then self:parseConst(token.start) return true end

	if text == "break" or text == "continue" then
		self:advance()
		self:emit("break", token.start, token.stop)
		return true
	end

	if token.kind == KIND.label then
		self:advance()
			local name = text:match("^::%s*([_%a][_%w]*)")
		if name then
			local offset = text:find(name, 1, true)
			self:declare(name, "label", { start = token.start + offset - 1, stop = token.start + offset + #name - 2 })
		end
		self:emit("label", token.start, token.stop)
		return true
	end

	-- A soft keyword starts a goto statement only when a name follows it.
	if text == "goto" and self:peekAt(2).kind == KIND.name then
		self:advance()
		self:advance()
		self:emit("goto", token.start, self.arena[self.index - 1].stop)
		return true
	end

	if token.kind == KIND.name or text == "(" then
		self:parseExpressionStatement()
		return true
	end
	return false
end

function statements.parseBlock(self)
	while true do
		-- Comments carry no syntax, but they do carry annotations, so they stay in the
		-- stream for other readers. Skipping them first is also what makes a comment before
		-- `end` not look like trailing code.
		while self:peek().kind == KIND.comment do self:advance() end
		if self:isBlockEnd() then return end

		local before = self.index
		if not self:parseStatement() then
			local token = self:peek()
			if token.kind == KIND.eof then return end
			self:report(token, string.format("unexpected '%s'", self:text(token)))
			self:advance()
		end
		-- No progress means the recovery would loop forever.
		if self.index == before then self:advance() end
	end
end

Parser.parseIf = statements.parseIf
Parser.parseDoBlock = statements.parseDoBlock
Parser.parseWhile = statements.parseWhile
Parser.parseRepeat = statements.parseRepeat
Parser.parseFor = statements.parseFor
Parser.parseFunctionName = statements.parseFunctionName
Parser.parseFunctionStatement = statements.parseFunctionStatement
Parser.parseLocal = statements.parseLocal
Parser.parseConst = statements.parseConst
Parser.parseReturn = statements.parseReturn
Parser.parseExpressionStatement = statements.parseExpressionStatement
Parser.parseStatement = statements.parseStatement
Parser.parseBlock = statements.parseBlock

return true
