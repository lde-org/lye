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

--- The suffixes a guard covers rather than a field name. `.` is not among them: the guard owns its
--- own dot, so `a?..b` writes a second one, which the engine rejects.
local GUARDED = { ["["] = true, [":"] = true, ["("] = true, ["{"] = true }

--- Prefix expressions, with the suffix chain attached: calls, indexing, fields, method
--- calls and safe navigation all belong to one loop, which is how the engine parses them.
---@param allowTernaryColon boolean
---@return integer
local function parsePrefix(self, allowTernaryColon)
	local token = self:peek()
	local startOffset = token.start

	local callee, groupIdx
	if self:isName(token) then
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
	-- The wrapper is the expression's identity while a suffix has something to wrap. A group that
	-- nothing wrapped is the expression it holds: Lua's parentheses cut a call down to one value,
	-- and one value is what a call gives here anyway, so `(part:gsub(...))` is the call itself.
	local wrapper = expressionIdx

	while true do
		self:skipComments()
		local nextToken = self:peek()
		local text = self:text(nextToken)
		local link

		-- `?.` guards whatever suffix is written after it: `a?.b`, `a?.[k]`, `a?.:m()`, `a?.(x)`.
		-- Only the field form was read, so every other spelling stopped there.
		local isSafe = text == "?."
		if isSafe then
			self:advance()
			nextToken = self:peek()
			text = self:text(nextToken)
		end

		-- A guard is read as the suffix after it. A name is the field it reads, and so is nothing at
		-- all: `a?.` is an access being written, and the value's fields are what is about to be
		-- offered. The rest — `[`, `:`, `(` and a literal — are suffixes of their own, read below.
		local isField = isSafe and not (GUARDED[text] or nextToken.kind == KIND.string)

		if isField or (text == "." and not isSafe) then
			-- The guard consumed its own dot, so only a plain `.` has one left to step past.
			if not isField then self:advance() end
			link = { field = self:parseName(), isField = true }
		elseif text == "[" then
			self:advance()
			-- The key is kept: `t[k]` is an index like any other, and what it reads with is what
			-- says whether the value has anything there.
			local key = self:parseExpression()
			self:expect("]")
			link = { isDynamic = true, key = key }
		elseif text == ":" and allowTernaryColon then
			self:advance()
			local method = self:parseName()
			-- The arguments are kept and the node is a call: a method call has a result, and one
			-- represented as a plain index node silently has none.
			local _, args = self:parseArguments()
			link = { field = method, isMethod = true, args = args, isCall = true }
		elseif text == "(" or text == "{" or nextToken.kind == KIND.string then
			local before = self.index
			local _, parsedArgs = self:parseArguments()
			-- A call names the name it is written on only when nothing has been wrapped yet:
			-- `load("x").lazy(f)` calls `lazy`, and carrying `load` onto that node had every
			-- argument of the second call checked against the first call's parameters.
			local called = expressionIdx == wrapper and callee or nil
			if self.index > before then link = { callee = called, args = parsedArgs, isCall = true } end
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

	if expressionIdx == wrapper and groupIdx then return groupIdx end
	return expressionIdx
end

---@return integer
---@return integer[] arguments arena indices, like every other child in the tree
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
	-- The argument is the index of the node, like every other one: a reader takes an argument out
	-- of the arena by that index, and a node table put here instead reads as no argument at all.
	if self:text(token) == "{" then
		local argStart = self:parseTable()
		return argStart, { self.nodes[#self.nodes].index }
	end

	-- A string literal used directly as an argument: `print[[hello]]`.
	local start = token.start
	self:advance()
	self:emit("string", start, token.stop, { value = stringValue(self:text(token)) })
	return start, { self.nodes[#self.nodes].index }
end

---@return integer
local function parseTable(self)
	local start = self:peek().start
	local fieldKinds, fieldValues, elementIdxs = {}, {}, {}
	local keyIdxs = {}
	self:expect("{")
	while not self:check("}") and not self:isEof(self:peek()) do
		self:skipComments()
		if self:check("}") then break end
		if self:check("[") then
			self:advance()
			local keyIdx = self:parseExpression()
			keyIdxs[#keyIdxs + 1] = keyIdx
			self:expect("]")
			self:expect("=")
			local valueIdx = self:parseExpression()
			-- A key written as a string literal is a field like any other: `["end"] = v` holds what
			-- `{ end = v }` holds, and leaving it out made a shape miss a member an annotation asked
			-- for — `{ end = 2 }` read as an object with no `end` at all.
			local keyNode = self.nodes[keyIdx]
			if keyNode and keyNode.kind == "string" and type(keyNode.value) == "string" then
				fieldValues[keyNode.value] = valueIdx
				fieldKinds[keyNode.value] = self.lastKind or "unknown"
			end
		elseif self:isName(self:peek()) and self:text(self:peekAt(2)) == "=" then
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
	-- The members belong to the literal, the way an operator's operands belong to it: without this
	-- they stayed unparented and were taken for statements of the chunk, which is what a guard's
	-- `fallsThrough` reads when it asks whether the clause ends in a `return` — `if not x then
	-- return { y = "z" } end` looked like it fell through, so nothing after it was narrowed.
	local members = {}
	for _, valueIdx in pairs(fieldValues) do members[#members + 1] = valueIdx end
	for _, elementIdx in ipairs(elementIdxs) do members[#members + 1] = elementIdx end
	for _, keyIdx in ipairs(keyIdxs) do members[#members + 1] = keyIdx end
	if next(members) then self:adopt(index, members) end
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

	-- A comment may sit between any two of these: `f(a --[[string]], b)` is written that way. The
	-- lexer emits comments as tokens, so each step past one is a step past a token.
	local isVariadic = false
	while true do
		self:skipComments()
		if self:check(")") or self:isEof(self:peek()) then break end
		if self:accept("...") then
			isVariadic = true
			break
		end
		local name, token = self:parseName()
		if name then params[#params + 1] = self:declare(name, "param", token) end
		self:skipComments()
		if not self:accept(",") then break end
	end
	self:skipComments()
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

local function parsePrimary(self, allowTernaryColon)
	local token = self:peek()
	local text = self:text(token)

	if text == "function" then
		local start = token.start
		self:advance()
		return parseFunctionBody(self, start, false)
	end

	-- A complete parameter list here is `|a, b| -> expr`, or `|| -> expr` for one that takes
	-- nothing — the two bars are one token when there is nothing between them. `x -> e` is
	-- recognised once the left operand has been parsed.
	if text == "|" or text == "||" then
		local start = token.start
		local takesNothing = text == "||"
		self:advance()
		self:pushScope(start)
		local params = {}
		if not takesNothing then
			while true do
				self:skipComments()
				if self:check("|") or self:isEof(self:peek()) then break end
				local name, nameToken = self:parseName()
				if name then params[#params + 1] = self:declare(name, "param", nameToken) end
				self:skipComments()
				if not self:accept(",") then break end
			end
			self:skipComments()
			self:expect("|")
		end
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
		-- `x -> e` names its one parameter on the left of the arrow. That name was read as an
		-- expression, so it has to be declared as the parameter here: without it every use inside
		-- the body is an undefined global, and the argument a caller passes is never bound.
		local params = {}
		local node = self.nodes[idx]
		local written
		if node.kind == "prefix" then written = node.callee
		elseif node.kind == "name" then written = node.name end
		if written then
			self:pushScope(startOffset)
			params[1] = self:declare(written, "param", { start = node.start, stop = node.stop })
		end
		local bodyIdx = self:parseBinary(1, allowTernaryColon)
		if written then self:popScope(self.nodes[bodyIdx].stop) end
		idx = self:emit("function", startOffset, self.nodes[bodyIdx].stop,
			{ isFunction = true, body = bodyIdx, params = params }, { bodyIdx })
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

---@param allowTernaryColon boolean? absent is the form that allows one
function Parser:parseExpression(allowTernaryColon)
	return parseBinary(self, 1, allowTernaryColon ~= false)
end

return true
