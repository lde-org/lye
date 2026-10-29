--[[
	Statement grammar, including error recovery.
]]

local Parser = require("lye-parser")

local KIND = Parser.KIND

local statements = {}

---@param self lye.parser.Parser
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

---@param self lye.parser.Parser
function statements.parseDoBlock(self, start, conditionIdx)
	start = start or self:peek().start
	self:expect("do")
	self:pushScope(start, conditionIdx)
	self:parseBlock()
	self:popScope(self:peek().start - 1)
	self:expect("end")
end

---@param self lye.parser.Parser
function statements.parseWhile(self)
	local start = self:peek().start
	self:expect("while")
	local conditionIdx = self:parseExpression()
	self:parseDoBlock(nil, conditionIdx)
	self:emit("while", start, self.arena[self.index - 1].stop)
end

---@param self lye.parser.Parser
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

---@param self lye.parser.Parser
function statements.parseFor(self)
	local start = self:peek().start
	self:expect("for")
	self:pushScope(self:peek().start)

	-- The control variables belong to the loop rather than to the body, so they carry their own
	-- kind: a numeric `for` counts, and a generic one takes what its expressions yield.
	local name, token = self:parseName()
	if name then self:declare(name, "loop", token) end

	local values, isNumeric = {}, false
	if self:accept("=") then
		isNumeric = true
		self:parseExpression()
		self:expect(",")
		self:parseExpression()
		if self:accept(",") then self:parseExpression() end
	else
		while self:accept(",") do
			local extra, extraToken = self:parseName()
			if extra then self:declare(extra, "loop", extraToken) end
		end
		self:expect("in")
		repeat
			values[#values + 1] = self:parseExpression()
		until not self:accept(",")
	end

	-- Pass the scope's own start: `parseDoBlock` would otherwise default to the current
	-- token, which by then is `do` at best and `end` if the body was empty.
	local doStart = self:peek().start
	self:parseDoBlock(doStart)
	self:popScope(self.arena[self.index - 1].stop)
	local forIdx = self:emit("for", start, self.arena[self.index - 1].stop,
		{ isNumeric = isNumeric })
	-- The expressions a generic `for` iterates over, so the loop's names can be typed from what
	-- the iterator yields.
	if #values > 0 then self:adopt(forIdx, values) end
end

---@return string? name
---@return lye.lexer.ffi.token? token
---@return boolean isMethod
---@param self lye.parser.Parser
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

---@param self lye.parser.Parser
function statements.parseFunctionStatement(self)
	local start, startIdx = self:peek().start, self.index
	self:expect("function")

	local name, token, isMethod = self:parseFunctionName()
	if name and token then
		self:declare(name, name:find("[%.:]") and "field" or "global", token, true)
	end
	local declarationIdx = self.lastDeclaration
	if declarationIdx then self.declarations[declarationIdx].anchorIdx = startIdx end
	-- `function f<T: number>(x: T)` names the types the signature works for.
	local generics = self.definition and self:skipGenerics() or nil
	local bodyIdx = self:parseFunctionBody(start, isMethod)
	if generics and bodyIdx then self.nodes[bodyIdx].inlineGenerics = generics end
	if declarationIdx then self:setInitializer(declarationIdx, "function", bodyIdx) end
end

---@param self lye.parser.Parser
function statements.parseLocal(self, start)
	local startIdx = self.index
	self:expect("local")
	if self:accept("function") then
		local name, token = self:parseName()
		if name then self:declare(name, "local", token, true) end
		local declarationIdx = self.lastDeclaration
		if declarationIdx then self.declarations[declarationIdx].anchorIdx = startIdx end
		-- The declaration has to be remembered before the body is parsed: parsing it declares the
		-- parameters, and `lastDeclaration` moves to the last of them.
		local generics = self.definition and self:skipGenerics() or nil
		local bodyIdx = self:parseFunctionBody(start, false)
		if generics and bodyIdx then self.nodes[bodyIdx].inlineGenerics = generics end
		if declarationIdx then self:setInitializer(declarationIdx, "function", bodyIdx) end
		return
	end

	local first, count = nil, 0
	local lastToken
	repeat
		local name, token = self:parseName()
		lastToken = token
		if name then
			local declaration = self:declare(name, "local", token, nil, count + 1)
			-- `local held: number = 1` writes the type where the name is.
			if self.definition then
				self:skipComments()
				if self:accept(":") then
					local text, from, to = self:skipInlineType()
					declaration.inlineType, declaration.inlineTypeStart, declaration.inlineTypeStop =
						text, from, to
				end
			end
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
	-- Only the last expression may give more than one value, and Lua fills the names the explicit
	-- list does not reach from it: `local a, b, c = 1, f()` is `1`, then `f`'s two. Each of those
	-- names is recorded as taking that expression, at the position it takes from it, so a reader
	-- can ask what the second value of the call is rather than only what the first is.
	local last = valueIdxs[#valueIdxs]
	if first and last then
		for offset = #valueIdxs, count - 1 do
			local declaration = self.declarations[first + offset]
			if declaration then
				declaration.valueIdx = last
				declaration.valuePosition = offset - #valueIdxs + 2
			end
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

---@param self lye.parser.Parser
function statements.parseConst(self, start)
	local startIdx = self.index
	self:expect("const")
	local first, count = nil, 0
	repeat
		local name, token = self:parseName()
		if name then
			self:declare(name, "local", token, nil, count + 1)
			-- The name is held, so nothing may write it again and its type is what it was given.
			self.declarations[self.lastDeclaration].isConst = true
			self.declarations[self.lastDeclaration].anchorIdx = startIdx
			first = first or self.lastDeclaration
			count += 1
		else
			count = math.max(count, 1)
			first = first or self.lastDeclaration
		end
	until not self:accept(",")

	-- The initializer is read the way `local` reads one, so `const n = 5` is a number rather than
	-- a name nothing knows.
	if self:accept("=") then
		for offset = 0, count - 1 do
			self.lastKind = nil
			local valueIdx = self:parseExpression()
			if first then self:setInitializer(first + offset, self.lastKind, valueIdx) end
			if not self:accept(",") then break end
		end
	end
	self:emit("const", start, self.arena[self.index - 1].stop)
end

---@param self lye.parser.Parser
function statements.parseReturn(self)
	local start = self:peek().start
	self:expect("return")
	-- The returned expressions are linked to the statement, so a reader can ask what a function
	-- returns without searching the arena for what follows it.
	local valueIdxs = {}
	if not self:isBlockEnd() and not self:check(";") then
		repeat
			valueIdxs[#valueIdxs + 1] = self:parseExpression()
		until not self:accept(",")
	end
	self:accept(";")
	local returnIdx = self:emit("return", start, self.arena[self.index - 1].stop)
	self:adopt(returnIdx, valueIdxs)
end

--- An assignment or a call statement. The engine parses the prefix once and then decides
--- from the next token, which is why this reads the same way.
---@param self lye.parser.Parser
function statements.parseExpressionStatement(self)
	local anchorIdx = self.index
	-- `parsePrefix` reports a node index, so the statement's span comes from that node.
	local target = self:parsePrefix(true)
	local start = self.nodes[target].start
	local token = self:peek()
	local text = self:text(token)

	if text == "=" or text == "," then
		local firstTarget = target
		local targets
		while self:accept(",") do
			if not targets then targets = { firstTarget } end
			target = self:parsePrefix(true)
			targets[#targets + 1] = target
		end
		self:expect("=")
		local firstValue = self:parseExpression()
		local valueIdxs
		while self:accept(",") do
			if not valueIdxs then valueIdxs = { firstValue } end
			valueIdxs[#valueIdxs + 1] = self:parseExpression()
		end
		-- The last value is the one the tree links. One name and one value is what almost every
		-- assignment is, and it carries nothing more than that: the lists below are for the rest.
		local lastTarget, lastValue = target, valueIdxs and valueIdxs[#valueIdxs] or firstValue
		if targets == nil and valueIdxs == nil then
			self:emit("assignment", start, self.arena[self.index - 1].stop,
				{ target = lastTarget, value = lastValue, anchorIdx = anchorIdx }, lastTarget, lastValue)
			return
		end
		-- A name past the last expression takes its value at that position in it, the way a name
		-- in a declaration does: `ok, err = pcall(f)` gives `err` the second value of the call.
		-- Every other name takes the expression written for it.
		local allTargets = targets or { firstTarget }
		local allValues = valueIdxs or { firstValue }
		local values, positions = {}, {}
		for index = 1, #allTargets do
			if index <= #allValues then
				values[index], positions[index] = allValues[index], 1
			else
				values[index] = allValues[#allValues]
				positions[index] = index - #allValues + 1
			end
		end
		self:emit("assignment", start, self.arena[self.index - 1].stop,
			{
				target = lastTarget, targets = allTargets, targetValues = values,
				targetPositions = positions, value = lastValue, anchorIdx = anchorIdx,
			},
			lastTarget, lastValue)
		return
	end

	if Parser.COMPOUND and Parser.COMPOUND[text] then
		self:advance()
		local valueIdx = self:parseExpression()
		self:emit("assignment", start, self.arena[self.index - 1].stop,
			{ target = target, value = valueIdx, anchorIdx = anchorIdx }, target, valueIdx)
	end
end

---@return boolean whether the token started a statement
---@param self lye.parser.Parser
function statements.parseStatement(self)
	-- The kind the last expression gave is read while a table is shaped, and a statement does not
	-- inherit it from the one before: `local t = { x = y }` asks what `y` is, not what the previous
	-- statement's last value was. Keeping it here is also what makes a parsed prefix and a resumed
	-- parse agree, since a resume starts with no such history.
	self.lastKind = nil
	-- The same for the declaration cursor: a `local` whose next token is not a name declares
	-- nothing, and reading the previous statement's cursor made it rewrite that statement's
	-- declaration — `local = 2` after `local a = 1` moved `a`'s initializer.
	self.lastDeclaration = nil
	local token = self:peek()
	local kind = token.kind
	-- Every problem reported from here until the statement is done belongs to it, even a problem
	-- an open argument list reports on the first token of the statement below. Only the outermost
	-- statement is recorded: a problem inside a block is still its top-level statement's, and that
	-- is the unit a resume keeps or re-reads.
	if self.depth == 0 then self.statementStart = token.start end
	-- The kind of the first token decides which words can matter, so a statement costs a handful
	-- of comparisons rather than every keyword the grammar knows.
	if kind == KIND.keyword then
		local text = self.texts[token.index]
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
		return false
	end

	if kind == KIND.name then
		local text = self.texts[token.index]
		-- A soft keyword starts a goto statement only when a name follows it.
		if text == "goto" and self:isName(self:peekAt(2)) then
			self:advance()
			self:advance()
			self:emit("goto", token.start, self.arena[self.index - 1].stop)
			return true
		end
		self:parseExpressionStatement()
		return true
	end

	if kind == KIND.symbol then
		local text = self.texts[token.index]
		-- A semicolon is a statement separator and may also stand alone.
		if text == ";" then
			self:advance()
			return true
		end
		if text == "(" then
			self:parseExpressionStatement()
			return true
		end
		return false
	end

	if kind == KIND.label then
		local text = self.texts[token.index]
		self:advance()
		local name = text:match("^::%s*([_%a][_%w]*)")
		if name then
			local offset = text:find(name, 1, true)
			self:declare(name, "label", { start = token.start + offset - 1, stop = token.start + offset + #name - 2 })
		end
		self:emit("label", token.start, token.stop)
		return true
	end
	return false
end

---@param self lye.parser.Parser
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
