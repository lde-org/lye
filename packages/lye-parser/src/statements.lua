--[[
	Statement grammar, including error recovery.
]]

local Parser = require("lye-parser") --[[@as lye.parser.Parser]]

local KIND = Parser.KIND --[[@as table<string, integer>]]

local statements = {}

---@param self lye.parser.Parser
---@return integer
function statements.parseIf(self)
	local start = self:peek().start
	self:expect("if")
	local conditionIdx = self:parseExpression()
	self:expect("then")
	local thenScope = self:pushScope(self:peek().start, conditionIdx)
	local thenBody = self:parseBlock()
	self:popScope(self:peek().start - 1, "then")

	local elseIfs = {}
	while self:check("elseif") do
		local clauseStart = self:peek().start
		self:advance()
		local clauseIdx = self:parseExpression()
		self:expect("then")
		local clauseScope = self:pushScope(self:peek().start, clauseIdx)
		local body = self:parseBlock()
		self:popScope(self:peek().start - 1, "elseif")
		elseIfs[#elseIfs + 1] = {
			condition = clauseIdx, body = body, start = clauseStart,
			bodyStart = clauseScope.start, bodyStop = clauseScope.stop,
		}
	end

	local elseBody, elseStart, elseStop
	if self:check("else") then
		self:advance()
		local elseScope = self:pushScope(self:peek().start)
		elseBody = self:parseBlock()
		self:popScope(self:peek().start - 1, "else")
		elseStart, elseStop = elseScope.start, elseScope.stop
	end
	self:expect("end")
	local index = self:emit("if", start, self:lastStop(), {
		condition = conditionIdx, thenBody = thenBody,
		thenStart = thenScope.start, thenStop = thenScope.stop,
		elseIfs = elseIfs, elseBody = elseBody, elseStart = elseStart, elseStop = elseStop,
	})
	return index
end

---@param self lye.parser.Parser
---@param start integer?
---@param conditionIdx integer?
---@return integer[] body
---@return integer bodyStart
---@return integer bodyStop
function statements.parseDoBlock(self, start, conditionIdx)
	start = start or self:peek().start
	self:expect("do")
	local bodyStart = self:peek().start
	self:pushScope(start, conditionIdx)
	local body = self:parseBlock()
	self:popScope(self:peek().start - 1)
	local bodyStop = self:peek().start - 1
	self:expect("end")
	return body, bodyStart, bodyStop
end

---@param self lye.parser.Parser
---@return integer
function statements.parseWhile(self)
	local start = self:peek().start
	self:expect("while")
	local conditionIdx = self:parseExpression()
	local body, bodyStart, bodyStop = self:parseDoBlock(nil, conditionIdx)
	local index = self:emit("while", start, self:lastStop(), {
		condition = conditionIdx, bodyStatements = body, bodyStart = bodyStart, bodyStop = bodyStop,
	})
	return index
end

---@param self lye.parser.Parser
---@return integer
function statements.parseRepeat(self)
	local start = self:peek().start
	self:expect("repeat")
	local bodyStart = self:peek().start
	local scope = self:pushScope(self:peek().start)
	local body = self:parseBlock()
	self:popScope(self:peek().start - 1)
	local bodyStop = self:peek().start - 1
	-- The condition is parsed after the body, so the scope it guards takes it afterwards.
	self:expect("until")
	local conditionIdx = self:parseExpression()
	scope.conditionIdx = conditionIdx
	local index = self:emit("repeat", start, self:lastStop(), {
		condition = conditionIdx, bodyStatements = body, bodyStart = bodyStart, bodyStop = bodyStop,
	})
	return index
end

---@param self lye.parser.Parser
---@return integer
function statements.parseFor(self)
	local start = self:peek().start
	self:expect("for")
	-- The control names need a scope around the body, and the body opens one of its own. The
	-- marker tells a reader that this outer scope is not another indentation level.
	self:pushScope(self:peek().start, nil, true)

	-- The control variables belong to the loop rather than to the body, so they carry their own
	-- kind: a numeric `for` counts, and a generic one takes what its expressions yield.
	local names, declarations = {}, {}
	---@param declared string
	---@param written lye.lexer.ffi.token
	local function declareControl(declared, written)
		names[#names + 1] = declared
		declarations[#declarations + 1] = self:declare(declared, "loop", written)
	end
	local name, token = self:parseName()
	if name then
		---@cast name string
		---@cast token lye.lexer.ffi.token
		declareControl(name, token)
	end

	local values, isNumeric = {}, false
	local fromValue, toValue, stepValue
	if self:accept("=") then
		isNumeric = true
		fromValue = self:parseExpression()
		self:expect(",")
		toValue = self:parseExpression()
		if self:accept(",") then stepValue = self:parseExpression() end
	else
		while self:accept(",") do
			local extra, extraToken = self:parseName()
			if extra then
				---@cast extra string
				---@cast extraToken lye.lexer.ffi.token
				declareControl(extra, extraToken)
			end
		end
		self:expect("in")
		repeat
			values[#values + 1] = self:parseExpression()
		until not self:accept(",")
	end

	-- Pass the scope's own start: `parseDoBlock` would otherwise default to the current
	-- token, which by then is `do` at best and `end` if the body was empty.
	local doStart = self:peek().start
	local body, bodyStart, bodyStop = self:parseDoBlock(doStart)
	self:popScope(self:lastStop())
	local forIdx = self:emit("for", start, self:lastStop(), {
		isNumeric = isNumeric,
		controlNames = names, controlDeclarations = declarations,
		fromValue = fromValue, toValue = toValue, stepValue = stepValue,
		iteratorValues = #values > 0 and values or nil,
		bodyStatements = body, bodyStart = bodyStart, bodyStop = bodyStop,
	})
	-- The expressions a generic `for` iterates over, so the loop's names can be typed from what
	-- the iterator yields.
	if #values > 0 then self:adopt(forIdx, values) end
	return forIdx
end

---@return string? name
---@return lye.lexer.ffi.token? token
---@return boolean isMethod
---@param self lye.parser.Parser
---@return string? name
---@return lye.lexer.ffi.token? token
---@return boolean? isMethod
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
---@return integer?
function statements.parseFunctionStatement(self)
	local start, startIdx = self:peek().start, self.index
	self:expect("function")

	local name, token, isMethod = self:parseFunctionName()
	if name and token then
		---@cast name string
		---@cast token lye.lexer.ffi.token
		self:declare(name, name:find("[%.:]") and "field" or "global", token, true)
	end
	local declarationIdx = self.lastDeclaration
	if declarationIdx then self.declarations[declarationIdx].anchorIdx = startIdx end
	-- `function f<T: number>(x: T)` names the types the signature works for.
	local generics = self.definition and self:skipGenerics() or nil
	local bodyIdx = self:parseFunctionBody(start, isMethod)
	if generics and bodyIdx then self.nodes[bodyIdx].inlineGenerics = generics end
	if declarationIdx then self:setInitializer(declarationIdx, "function", bodyIdx) end
	if bodyIdx then
		local body = self.nodes[bodyIdx]
		body.name, body.isMethod, body.isLocal = name, isMethod, false
	end
	return bodyIdx
end

---@param self lye.parser.Parser
---@param start integer
---@return integer?
function statements.parseLocal(self, start)
	local startIdx = self.index
	self:expect("local")
	if self:accept("function") then
		local name, token = self:parseName()
		if name then
			---@cast name string
			---@cast token lye.lexer.ffi.token
			self:declare(name, "local", token, true)
		end
		local declarationIdx = self.lastDeclaration
		if declarationIdx then self.declarations[declarationIdx].anchorIdx = startIdx end
		-- The declaration has to be remembered before the body is parsed: parsing it declares the
		-- parameters, and `lastDeclaration` moves to the last of them.
		local generics = self.definition and self:skipGenerics() or nil
		local bodyIdx = self:parseFunctionBody(start, false)
		if generics and bodyIdx then self.nodes[bodyIdx].inlineGenerics = generics end
		if declarationIdx then self:setInitializer(declarationIdx, "function", bodyIdx) end
		if bodyIdx then
			local body = self.nodes[bodyIdx]
			body.name, body.isMethod, body.isLocal = name, false, true
		end
		return bodyIdx
	end

	local first, count = nil, 0
	local lastToken
	local declared = {}
	repeat
		local name, token = self:parseName()
		lastToken = token
		if name then
			---@cast name string
			---@cast token lye.lexer.ffi.token
			local declaration = self:declare(name, "local", token, nil, count + 1)
			declared[#declared + 1] = declaration
			-- `local held: number = 1` writes the type where the name is.
			if self.definition then
				self:skipComments()
				if self:accept(":") then
					local text, from, to = self:skipInlineType()
					declaration.inlineType, declaration.inlineTypeStart, declaration.inlineTypeStop = text, from, to
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
	---@cast valueIdxs integer[]
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
	local localIdx = self:emit("local", start, self:lastStop(),
		{ declarations = declared })
	self:adopt(localIdx, valueIdxs)
	return localIdx
end

---@param self lye.parser.Parser
---@param start integer
---@return integer
function statements.parseConst(self, start)
	local startIdx = self.index
	self:expect("const")
	local first, count = nil, 0
	local declared = {}
	repeat
		local name, token = self:parseName()
		if name then
			---@cast name string
			---@cast token lye.lexer.ffi.token
			local declaration = self:declare(name, "local", token, nil, count + 1)
			declared[#declared + 1] = declaration
			-- The name is held, so nothing may write it again and its type is what it was given.
			declaration.isConst = true
			declaration.anchorIdx = startIdx
			first = first or self.lastDeclaration
			count += 1
		else
			count = math.max(count, 1)
			first = first or self.lastDeclaration
		end
	until not self:accept(",")

	-- The initializer is read the way `local` reads one, so `const n = 5` is a number rather than
	-- a name nothing knows.
	local valueIdxs = {}
	---@cast valueIdxs integer[]
	if self:accept("=") then
		for offset = 0, count - 1 do
			self.lastKind = nil
			local valueIdx = self:parseExpression()
			valueIdxs[#valueIdxs + 1] = valueIdx
			if first then self:setInitializer(first + offset, self.lastKind, valueIdx) end
			if not self:accept(",") then break end
		end
	end
	local constIdx = self:emit("const", start, self:lastStop(),
		{ declarations = declared })
	self:adopt(constIdx, valueIdxs)
	return constIdx
end

---@param self lye.parser.Parser
---@return integer
function statements.parseReturn(self)
	local start = self:peek().start
	self:expect("return")
	-- The returned expressions are linked to the statement, so a reader can ask what a function
	-- returns without searching the arena for what follows it.
	local valueIdxs = {}
	---@cast valueIdxs integer[]
	if not self:isBlockEnd() and not self:check(";") then
		repeat
			valueIdxs[#valueIdxs + 1] = self:parseExpression()
		until not self:accept(",")
	end
	self:accept(";")
	local returnIdx = self:emit("return", start, self:lastStop())
	self:adopt(returnIdx, valueIdxs)
	return returnIdx
end

--- An assignment or a call statement. The engine parses the prefix once and then decides
--- from the next token, which is why this reads the same way.
---@param self lye.parser.Parser
---@return integer
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
		local allTargets = targets or { firstTarget }
		local allValues = valueIdxs or { firstValue }
		-- A name past the last expression takes its value at that position in it, the way a name
		-- in a declaration does: `ok, err = pcall(f)` gives `err` the second value of the call.
		-- Every other name takes the expression written for it. The list written in the source is
		-- kept separately, so a formatter never repeats the last expression to fill the names.
		local values, positions = {}, {}
		for index = 1, #allTargets do
			if index <= #allValues then
				values[index], positions[index] = allValues[index], 1
			else
				values[index] = allValues[#allValues]
				positions[index] = index - #allValues + 1
			end
		end
		local index = self:emit("assignment", start, self:lastStop(),
			{
				op = "=", target = lastTarget, targets = allTargets,
				assignedValues = allValues, targetValues = values,
				targetPositions = positions, valueIdx = lastValue, anchorIdx = anchorIdx,
			},
			lastTarget, lastValue)
		return index
	end

	if Parser.COMPOUND and Parser.COMPOUND[text] then
		self:advance()
		local valueIdx = self:parseExpression()
		local index = self:emit("assignment", start, self:lastStop(),
			{ op = text, target = target, valueIdx = valueIdx, anchorIdx = anchorIdx }, target, valueIdx)
		return index
	end
	return target
end

---@return boolean whether the token started a statement
---@return integer? index the statement's node, when it emitted one
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
		if text == "if" then return true, self:parseIf() end
		if text == "while" then return true, self:parseWhile() end
		if text == "repeat" then return true, self:parseRepeat() end
		if text == "for" then return true, self:parseFor() end
		if text == "do" then
			local start = token.start
			local body, bodyStart, bodyStop = self:parseDoBlock()
			local index = self:emit("do", start, self:lastStop(), {
				bodyStatements = body, bodyStart = bodyStart, bodyStop = bodyStop,
			})
			return true, index
		end
		if text == "function" then return true, self:parseFunctionStatement() end
		if text == "local" then return true, self:parseLocal(token.start) end
		if text == "return" then return true, self:parseReturn() end
		if text == "const" then return true, self:parseConst(token.start) end
		if text == "break" or text == "continue" then
			self:advance()
			local index = self:emit("break", token.start, token.stop, { keyword = text })
			return true, index
		end
		return false
	end

	if kind == KIND.name then
		local text = self.texts[token.index]
		-- A soft keyword starts a goto statement only when a name follows it.
		if text == "goto" and self:isName(self:peekAt(2)) then
			local name = self:text(self:peekAt(2))
			self:advance()
			self:advance()
			local index = self:emit("goto", token.start, self:lastStop(),
				{ name = name })
			return true, index
		end
		return true, self:parseExpressionStatement()
	end

	if kind == KIND.symbol then
		local text = self.texts[token.index]
		-- A semicolon is a statement separator and may also stand alone.
		if text == ";" then
			self:advance()
			return true
		end
		if text == "(" then
			return true, self:parseExpressionStatement()
		end
		return false
	end

	if kind == KIND.label then
		local text = self.texts[token.index]
		self:advance()
		local name = text:match("^::%s*([_%a][_%w]*)")
		if name then
			local offset = text:find(name, 1, true)
			local labelToken = {
				start = token.start + offset - 1,
				stop = token.start + offset + #name - 2,
			}
			---@cast labelToken lye.lexer.ffi.token
			self:declare(name, "label", labelToken)
		end
		local index = self:emit("label", token.start, token.stop, { name = name })
		return true, index
	end
	return false
end

---@param self lye.parser.Parser
---@return integer[] the statement nodes of the block, in source order
function statements.parseBlock(self)
	local body = {}
	while true do
		-- Comments carry no syntax, but they do carry annotations, so they stay in the
		-- stream for other readers. Skipping them first is also what makes a comment before
		-- `end` not look like trailing code.
		while self:peek().kind == KIND.comment do self:advance() end
		if self:isBlockEnd() then return body end

		local before = self.index
		local started, statementIdx = self:parseStatement()
		if not started then
			local token = self:peek()
			if token.kind == KIND.eof then return body end
			self:report(token, string.format("unexpected '%s'", self:text(token)))
			self:advance()
		elseif statementIdx then
			local statement = self.nodes[statementIdx]
			statement.isStatement = true
			body[#body + 1] = statementIdx
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
