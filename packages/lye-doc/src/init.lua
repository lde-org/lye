--[[
	LuaLS annotation parsing.

	Annotations are comments, so they are read from the token stream rather than the parser, which
	discards them. Types are kept as written and interpreted only where a check is made.
]]

local lexer = require("lye-lexer")

local doc = {}

---@alias lye.doc.Tag
---| "type"|"param"|"return"|"class"|"field"|"alias"|"cast"|"as"|"generic"
---| "overload"|"deprecated"|"meta"|"diagnostic"|"async"|"nodiscard"|"operator"|"unknown"
---| "enum"|"package"|"private"|"protected"|"public"|"version"|"see"

---@class lye.doc.Annotation
---@field tag lye.doc.Tag
---@field text string the annotation body, after the tag
---@field name string? the identifier it names, for tags that take one
---@field type string? the declared type, where the tag takes one
---@field typeText string? the type text before it is parsed
---@field values string[]? every value a `@return` names
---@field extras table<string, string>? trailing `key value` pairs, as in `---@param x string # note`
---@field comment string?
---@field visibility string? what a member annotation says about who may read it
---@field start integer byte offset of the comment
---@field stop integer
---@field nameStart integer? byte offset of the name, so an editor can mark it as one
---@field nameStop integer?
---@field typeStart integer? byte offset of the type, for the same reason
---@field typeStop integer?

---@class lye.doc.File
---@field annotations lye.doc.Annotation[]
---@field isDefinition boolean? the file declares a library rather than an implementation

-- Tags this reader understands, and whether they name an identifier.
local TAGS = {
	["type"] = true, ["param"] = true, ["return"] = true, ["class"] = true,
	["field"] = true, ["alias"] = true, ["cast"] = true, ["as"] = true, ["generic"] = true,
	["overload"] = true, ["deprecated"] = true, ["meta"] = true, ["diagnostic"] = true,
	["async"] = true, ["nodiscard"] = true, ["operator"] = true,
	["enum"] = false, ["package"] = false, ["private"] = false, ["protected"] = false,
	["public"] = false, ["nodiscard"] = true, ["version"] = false, ["see"] = false,
}

---@param text string
local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split `name type # comment`, where the comment is optional and introduced by `#`.
--- The separator needs whitespace before it because a type can contain `#` in a table
--- shape, as in `{ # number }`.
---@param body string
---@return string
---@return string?
local function splitBody(body)
	local at = body:find("%s#%s")
	if at then return body:sub(1, at - 1), trim(body:sub(at + 2)) end
	return body, nil
end

--- The characters a word written after a space must open with for the space to bind the two words
--- into one type: `string | nil` is one type, and the space inside it is not prose. Brackets count
--- for depth, so `table<string, number>` needs none of this.
local CONTINUES = {
	["|"] = true, [","] = true, ["."] = true, ["["] = true, ["]"] = true, ["?"] = true,
	["*"] = true, ["("] = true, [")"] = true, ["<"] = true, [">"] = true, ["{"] = true,
	["}"] = true, [":"] = true, ["&"] = true, ["+"] = true, ["-"] = true,
}

--- The same, for the word *before* the space. Only a character that still wants the word after it —
--- an operator or an opener — keeps the type going; a closing bracket ends an expression, so a
--- space after `)` or `]` begins prose.
local BINDS = {
	["|"] = true, [","] = true, ["."] = true, ["?"] = true, ["*"] = true, [":"] = true,
	["("] = true, ["["] = true, ["{"] = true, ["<"] = true, ["&"] = true,
}

--- The type expression at the front of `text`, with any prose written after it dropped. Brackets
--- `()` `{}` `<>` `[]` nest, and a quoted string holds anything, so a space inside one of those is
--- part of the type. At the top level the first space that is neither bound to the word before it
--- nor followed by a continuation ends the type; everything past it is prose, as in
--- `---@param x string a sentence about it`.
---@param text string
---@return string
--- Split a leading `<...>` parameter list from what follows it. A class or an alias writes its
--- parameters first, and the body after them is read on its own. The two halves are the source's
--- own slices, so the offsets a reader finds in them still point at the text.
---@param text string
---@return string params
---@return string body
local function splitParams(text)
	if text:sub(1, 1) ~= "<" then return "", text end
	local depth = 0
	for at = 1, #text do
		local char = text:sub(at, at)
		if char == "<" then
			depth = depth + 1
		elseif char == ">" then
			depth = depth - 1
			if depth == 0 then return text:sub(1, at), text:sub(at + 1) end
		end
	end
	return "", text
end

---@param text string
local function cutType(text)
	text = trim(text)
	local conditional = text:find("%f[%w_]extends%f[^%w_]") ~= nil
	local keyof = text:sub(1, 5) == "keyof"
	local depth, quote, template, at, length = 0, nil, false, 1, #text
	while at <= length do
		local char = text:sub(at, at)
		if template then
			if char == "`" then template = false end
			at = at + 1
		elseif char == "`" then
			template = true
			at = at + 1
		elseif quote then
			if char == "\\" then at = at + 2
			else
				if char == quote then quote = nil end
				at = at + 1
			end
		elseif char == '"' or char == "'" then
			quote = char
			at = at + 1
		elseif char == "(" or char == "{" or char == "[" or char == "<" then
			depth = depth + 1
			at = at + 1
		elseif char == ")" or char == "}" or char == "]" or char == ">" then
			if depth > 0 then depth = depth - 1 end
			at = at + 1
		elseif (char == " " or char == "\t") and depth == 0 then
			local stop = at
			while stop <= length and (text:sub(stop, stop) == " " or text:sub(stop, stop) == "\t") do
				stop = stop + 1
			end
			if stop > length then break end
			local arrowHere = text:sub(at - 2, at - 1) == "->"
			local arrowNext = text:sub(stop, stop + 1) == "->"
			local afterKeyof = keyof and text:sub(1, at - 1):match("^keyof%s*$") ~= nil
			-- An operator on either side of the space belongs to a const expression: `A + B`
			-- and `A .. B` are one type, not a type followed by prose.
			local left = text:sub(1, at - 1)
			local right = text:sub(stop)
			local expression = left:match("%s%.%.$") ~= nil or left:match("%s[%+%-%*/%%%^]$") ~= nil
				or right:match("^%.%.%s") ~= nil or right:match("^[%+%-%*/%%%^]%s") ~= nil
			if conditional or afterKeyof or arrowHere or arrowNext or expression
				or BINDS[text:sub(at - 1, at - 1)] or CONTINUES[text:sub(stop, stop)] then
				at = stop
			else
				break
			end
		else
			at = at + 1
		end
	end
	return trim(text:sub(1, at - 1))
end

--- Where a tag begins on a line: `---@param`, and `--- @param` too. The space is what a writer
--- puts there when they think of the annotation as prose, and LuaLS reads it, so a reader that
--- insisted on the tight form would silently ignore half of someone's file.
doc.TAG_PATTERN = "%-%-%-[ \t]*@"

--- The span a piece of an annotation occupies in the line it was written on. The pieces are
--- located by their own text, read forwards from where the previous one ended.
---@param comment string
---@param text string
---@param from integer
---@param comment string
---@param text string
---@param from integer
---@return integer?
---@return integer?
local function spanOf(comment, text, from)
	local at = comment:find(text, from, true)
	if not at then return nil end
	return at, at + #text - 1
end

---@param comment string
---@param start integer
---@param stop integer
---@return lye.doc.Annotation?
local function parse(comment, start, stop)
	-- `---@param x T`, and the bracketed `--[[@as T]]` a cast is written with inside an
	-- expression. Both spellings are read here so the spans a caller computes stay the ones the
	-- text has: the closing brackets are the piece's own and are dropped with the opener.
	local body
	if comment:sub(1, 4) == "--[[" then
		body = comment:match("^%-%-%[%[%s*(.-)%s*%]%]%s*$")
	else
		body = comment:match("^%-%-%-?%s*(.*)$")
	end
	if not body or body == "" then return nil end

	local tag = body:match("^@([%w_]+)")
	-- `TAGS` records whether a tag takes a name, so `false` means "known, and it does not" —
	-- testing the value for truth rather than for presence made every such tag unknown.
	if not tag or TAGS[tag] == nil then
		return { tag = "unknown", text = "", start = start, stop = stop }
	end

	local rest, commentText = splitBody(trim(body:sub(#tag + 2)))
	-- A tag cannot be part of a type, so a second annotation sharing the line is where this one
	-- ends even if the line was not split before it got here.
	local nextTag = rest:find(doc.TAG_PATTERN)
	if nextTag then rest = trim(rest:sub(1, nextTag - 1)) end
	local annotation = {
		tag = tag,
		text = rest,
		comment = commentText,
		start = start,
		stop = stop,
		extras = {},
	}

	if tag == "param" then
		-- `---@param x string` and `---@param x? string`, where `?` marks it optional. `%?`
		-- is not a character class on this LuaJIT, so the marker is matched literally.
		local name, marker, remaining = rest:match("^([%w_%.]+)(%??)(.*)$")
		annotation.name = name
		annotation.type = cutType(remaining or "")
		annotation.typeText = annotation.type
		-- The marker belongs to the type, not the name: an optional parameter can be nil. A
		-- signature is bracketed first, because `fun(s: string): string?` is a function that returns
		-- something which may be absent, where `(fun(s: string): string)?` is the parameter itself —
		-- a function, or nothing. Appending it loose made every optional callback a callback that
		-- returns nil, which then disagreed with the field it was handed to.
		if marker == "?" then
			local written = annotation.type or ""
			local signature = written:match("^fun%s*%(") or written:match("^fn%s*%(")
			annotation.type = signature and ("(" .. written .. ")?") or (written .. "?")
		end
	elseif tag == "field" then
		-- `---@field private name type` writes the visibility first, which is the spelling the
		-- codebase uses. It belongs to the field rather than to its type: reading it as the name
		-- left the real field named `private` with the type `name`.
		for _, visibility in ipairs({ "private", "protected", "public" }) do
			local after = rest:match("^" .. visibility .. "%s+(.*)$")
			if type(after) == "string" then
				annotation.visibility = visibility
				rest = after
				break
			end
		end
		-- `---@field [integer] T` is an index signature rather than a field: what a value indexed
		-- with that kind of key gives. The bracket is the name slot — a key type, not an
		-- identifier — and the type after it is the value's.
		local name, remaining = rest:match("^([%w_%.]+)(.*)$")
		if not name then
			local bracket, body = rest:match("^(%[[^%]]*%])(.*)$")
			name, remaining = bracket, body
		end
		annotation.name = name
		local written = trim((remaining or ""):gsub("^=", ""))
		annotation.type = cutType(written)
		annotation.typeText = annotation.type
	elseif tag == "alias" or tag == "generic" or tag == "class" then
		local name, remaining = rest:match("^([%w_%.]+)(.*)$")
		annotation.name = name
		local written = trim((remaining or ""):gsub("^=", ""))
		if tag == "class" or tag == "alias" then
			-- A class or an alias writes its parameters first — `A<T: number> T[]`. An alias's
			-- body is the type it stands for; a class's body is a parent after `:`, and a sentence
			-- that follows the parameters is documentation rather than a type of its own.
			local params, body = splitParams(written)
			local colon = tag == "class" and body:find(":", 1, true) or nil
			if colon then
				local lead = body:match("^:%s*") or ":"
				annotation.type = params .. lead .. cutType(trim(body:sub(colon + 1)))
			elseif tag == "class" then
				annotation.type = params
			else
				local cut = cutType(trim(body))
				annotation.type = cut == "" and params or (params .. (body:match("^%s*") or "") .. cut)
			end
		else
			annotation.type = cutType(written)
		end
		annotation.typeText = annotation.type
	elseif tag == "return" then
		-- `---@return v is T` names a parameter and the type it proves rather than a type of its
		-- own: its words are the annotation, not prose, so it is kept whole.
		annotation.type = rest:match("^[%w_]+%s+is%s+") and rest or cutType(rest)
		annotation.typeText = annotation.type
	elseif tag == "type" or tag == "as" or tag == "overload" then
		annotation.type = cutType(rest)
		annotation.typeText = annotation.type
	elseif tag == "cast" then
		-- `---@cast name +type`: the name is part of what the analyzer reads, not prose, so the
		-- body is kept whole.
		annotation.type = rest
		annotation.typeText = rest
	elseif tag == "meta" or tag == "diagnostic" then
		-- `---@meta name value` names a global and its kind. A diagnostic directive is
		-- `---@diagnostic disable-next-line: unused-local`: the action is the name, and the codes
		-- after the optional colon are the type text.
		if tag == "diagnostic" then
			local action, value = rest:match("^([%w_%-]+)%s*:?%s*(.*)$")
			annotation.name = action
			annotation.type = trim(value or "")
		else
			local name, value = rest:match("^([%w_]+)%s+(.*)$")
			annotation.name = name
			annotation.type = trim(value or "")
		end
		annotation.typeText = annotation.type
	end

	if annotation.type == "" then annotation.type, annotation.typeText = nil, nil end

	-- Offsets for the parts an editor colours separately: the name of a parameter reads as a
	-- parameter, and the type as a type. Searching starts after the tag, since a name as short as
	-- `a` also appears inside `param`.
	local searchFrom = (select(2, comment:find("^%-%-%-?%s*")) or 0) + #tag + 2
	if annotation.name then
		local at, to = spanOf(comment, annotation.name, searchFrom)
		if at then
			annotation.nameStart, annotation.nameStop = start + at - 1, start + to - 1
			searchFrom = to + 1
		end
	end
	if annotation.typeText and annotation.typeText ~= "" then
		local at, to = spanOf(comment, annotation.typeText, searchFrom)
		if at then annotation.typeStart, annotation.typeStop = start + at - 1, start + to - 1 end
	end
	return annotation
end

--- Whether the byte at `at` in a line sits inside a backtick code span, in which case a tag
--- written there is a quotation rather than an annotation.
---@param line string
---@param at integer
local function quotedAt(line, at)
	local count, from = 0, 1
	while true do
		local found = line:find("`", from, true)
		if not found or found >= at then break end
		count += 1
		from = found + 1
	end
	return count % 2 == 1
end

--- Read a source's annotations: what each one says, and where the parts of it are written.
---@param source string
---@param tokens lye.lexer.Tokens? the tokens of this source, when the caller already has them
---@return lye.doc.File
function doc.parse(source, tokens)
	assert(type(source) == "string", "doc.parse expects a string")

	---@type lye.doc.Annotation[]
	local annotations = {}
	-- The body of an alias may be written a member per line — `---@alias X` and then `--- | "a"` —
	-- which is the spelling LuaLS uses and the one this package's own annotations use. A line
	-- holding nothing but a `|` continues the alias above it, and the members are joined with the
	-- bars they were written with, so the body that comes out is the one a single line would give.
	---@type lye.doc.Annotation?
	local continued = nil
	-- The parser lexes the same text on its way to a tree, and a caller that has done so already
	-- hands the tokens over rather than paying for a second pass over every byte.
	-- Only the comments are wanted, and asking the full lexer for them means scanning every name,
	-- number and operator on the way to the ones this reads.
	tokens = tokens or lexer.comments(source)
	for at = 1, tokens.count do
		local token = tokens.arena[at]
		if token.kind == lexer.KIND.comment then
			-- A block comment holds many lines; a short comment holds one. The offset
			-- advances by the real line length either way.
			local index = token.start
			local rest = tokens.texts[token.index]
			-- Whether this comment *is* a bracketed annotation, which is what the inline form is:
			-- `--[[@as Vec]]` written in the middle of an expression. The same text inside a `---`
			-- line is prose about the spelling, and is read as prose.
			local bracketedToken = rest:match("^%-%-%[%[%s*@") ~= nil
			while true do
				local newline = rest:find("\n", 1, true)
				local line = newline and rest:sub(1, newline - 1) or rest
				-- A line can hold more than one annotation: `---@param a Vec ---@param b Vec` is
				-- what a formatter leaves when it folds a block onto one line, and reading the line
				-- as one annotation puts the second tag inside the first one's type.
				-- A line of prose may quote an annotation — `-- write \`---@param a Vec\`` — and that
				-- is a sentence, not a tag. Only a tag the comment starts with, or one following
				-- another tag on the same line, is read as one.
				local at = line:find(doc.TAG_PATTERN)
				if at and not line:sub(1, at - 1):match("^%s*$") and not line:sub(1, at - 1):match("^%s*%-%-%-?%s*$") then
					at = nil
				end
				---@type lye.doc.Annotation?
				local last = nil
				while at do
					local nextAt = line:find(doc.TAG_PATTERN, at + 4)
					-- A description may quote a tag — ``the first `---@return` type`` — and what is
					-- inside a code span is prose about the spelling, not a tag of its own. Reading
					-- it as one put it in the line's run of annotations, and a class owns nothing
					-- past a `@return`: every field written below the sentence was dropped.
					while nextAt and quotedAt(line, nextAt) do
						nextAt = line:find(doc.TAG_PATTERN, nextAt + 4)
					end
					local piece = line:sub(at, nextAt and nextAt - 1 or #line)
					---@type lye.doc.Annotation?
					local found = parse(piece, index + at - 1, index + at - 1 + #piece - 1)
					if found then
						annotations[#annotations + 1] = found
						last = found
					end
					at = nextAt
				end
				-- A bracketed annotation is written *inside* an expression — `f --[[@as Vec]].x` — so it
				-- is read from the comment token it forms rather than from a tag that starts a line.
				-- Only from a token that *is* one: those same characters turn up quoted in prose that
				-- explains the spelling, and reading that as a cast attached the type to whatever
				-- expression happened to sit above the sentence.
				if bracketedToken then
					local bracketed = line:find("%-%-%[%[%s*@")
					while bracketed do
						local close = line:find("]]", bracketed, true)
						if not close then break end
						---@type lye.doc.Annotation?
						local found = parse(line:sub(bracketed, close + 1),
							index + bracketed - 1, index + close)
						if found then annotations[#annotations + 1] = found end
						bracketed = line:find("%-%-%[%[%s*@", close)
					end
				end
				if last then
					continued = last.tag == "alias" and last or nil
				elseif continued then
					local member = line:gsub("^%s*%-%-%-?", ""):match("^%s*|%s*(.-)%s*$")
					if member then
						local written = continued.type and (continued.type .. "|" .. member) or member
						continued.type, continued.typeText = written, written
					else
						continued = nil
					end
				end
				if not newline then break end
				index += newline
				rest = rest:sub(newline + 1)
			end
		end
	end

	-- Attaching an annotation to the declaration below it is a lookup by offset, so sort
	-- once and binary search later.
	table.sort(annotations, function(a, b) return a.start < b.start end)

	-- A definition file describes a library rather than running: `---@meta` says so, the way LuaLS
	-- spells it, and the analyzer holds such a file to its annotations instead of to bodies it does
	-- not have. The name a `---@meta` line may carry — the global the file describes — is kept.
	local isDefinition = false
	for _, annotation in ipairs(annotations) do
		if annotation.tag == "meta" then
			isDefinition = true
			break
		end
	end

	return { annotations = annotations, isDefinition = isDefinition }
end

--- The annotations that describe a declaration at `offset`: those whose comment ends above
--- it and which no other declaration has claimed.
---@param file lye.doc.File
---@param offset integer
---@return lye.doc.Annotation[]
function doc.attachedTo(file, offset)
	local out = {}
	for _, annotation in ipairs(file.annotations) do
		if annotation.stop < offset then
			out[#out + 1] = annotation
		else
			break
		end
	end
	return out
end

---@param file lye.doc.File
---@param tag lye.doc.Tag
---@return lye.doc.Annotation?
function doc.first(file, tag)
	for _, annotation in ipairs(file.annotations) do
		if annotation.tag == tag then return annotation end
	end
end

doc.classes = require("lye-doc.class")

return doc
