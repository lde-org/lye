--[[
	LuaLS annotation parsing.

	Annotations are comments, so they are read from the token stream rather than from the
	parser, which discards them. Each one is attached to the next declaration at or after it,
	which is the convention LuaLS uses: the comment describes what follows.

	Types are kept as written and interpreted by `lye-doc.type` only where a check is
	actually made, so an annotation this reader does not understand is carried through
	rather than dropped.
]]

local lexer = require("lye-lexer")

local doc = {}

---@alias lye.doc.Tag
---| "type"|"param"|"return"|"class"|"field"|"alias"|"cast"|"generic"
---| "overload"|"deprecated"|"meta"|"diagnostic"|"async"|"nodiscard"|"operator"|"unknown"

---@class lye.doc.Annotation
---@field tag lye.doc.Tag
---@field text string the annotation body, after the tag
---@field name string? the identifier it names, for tags that take one
---@field type string? the declared type, where the tag takes one
---@field extras table<string, string>? trailing `key value` pairs, as in `---@param x string # note`
---@field comment string?
---@field start integer byte offset of the comment
---@field stop integer
---@field nameStart integer? byte offset of the name, so an editor can mark it as one
---@field nameStop integer?
---@field typeStart integer? byte offset of the type, for the same reason
---@field typeStop integer?

---@class lye.doc.File
---@field annotations lye.doc.Annotation[]
---@field byOffset table<integer, lye.doc.Annotation[]> annotations whose stop is below a key

-- Tags this reader understands, and whether they name an identifier.
local TAGS = {
	["type"] = true, ["param"] = true, ["return"] = true, ["class"] = true,
	["field"] = true, ["alias"] = true, ["cast"] = true, ["generic"] = true,
	["overload"] = true, ["deprecated"] = true, ["meta"] = true, ["diagnostic"] = true,
	["async"] = true, ["nodiscard"] = true, ["operator"] = true,
	["enum"] = false, ["package"] = false, ["private"] = false, ["protected"] = false,
	["public"] = false, ["nodiscard"] = true, ["version"] = false, ["see"] = false,
}

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split `name type # comment`, where the comment is optional and introduced by `#`.
--- The separator needs whitespace before it because a type can contain `#` in a table
--- shape, as in `{ # number }`.
local function splitBody(body)
	local at = body:find("%s#%s")
	if at then return body:sub(1, at - 1), trim(body:sub(at + 2)) end
	return body, nil
end

---@param comment string
---@param start integer
---@param stop integer
---@return lye.doc.Annotation?
--- The span a piece of an annotation occupies in the line it was written on. The pieces are
--- located by their own text, read forwards from where the previous one ended.
---@param comment string
---@param text string
---@param from integer
---@return integer? start
---@return integer? stop
local function spanOf(comment, text, from)
	local at = comment:find(text, from, true)
	if not at then return nil end
	return at, at + #text - 1
end

local function parse(comment, start, stop)
	local body = comment:match("^%-%-%-?%s*(.*)$")
	if not body or body == "" then return nil end

	local tag = body:match("^@([%w_]+)")
	if not tag or not TAGS[tag] then
		return { tag = "unknown", text = "", start = start, stop = stop }
	end

	local rest, commentText = splitBody(trim(body:sub(#tag + 2)))
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
		annotation.type = trim(remaining or "")
		annotation.typeText = annotation.type
		-- The marker belongs to the type, not the name: an optional parameter can be nil.
		if marker == "?" then annotation.type = (annotation.type or "") .. "?" end
	elseif tag == "field" or tag == "alias" or tag == "generic" or tag == "class" then
		local name, remaining = rest:match("^([%w_%.]+)(.*)$")
		annotation.name = name
		annotation.type = trim((remaining or ""):gsub("^=", ""))
		annotation.typeText = annotation.type
	elseif tag == "return" or tag == "type" or tag == "cast" or tag == "overload" then
		annotation.type = rest
		annotation.typeText = rest
	elseif tag == "meta" or tag == "diagnostic" then
		-- `---@meta name value`, used for identifiers and severity names.
		local name, value = rest:match("^([%w_]+)%s+(.*)$")
		annotation.name = name
		annotation.type = trim(value or "")
		annotation.typeText = annotation.type
	end

	if annotation.type == "" then annotation.type = nil end

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

---@param source string
---@return lye.doc.File
function doc.parse(source)
	assert(type(source) == "string", "doc.parse expects a string")

	local annotations = {}
	local tokens = lexer.tokenize(source)
	for at = 1, tokens.count do
		local token = tokens.arena[at]
		if token.kind == lexer.KIND.comment then
			-- A block comment holds many lines; a short comment holds one. The offset
			-- advances by the real line length either way.
			local index = token.start
			local rest = tokens.texts[token.index]
			while true do
				local newline = rest:find("\n", 1, true)
				local line = newline and rest:sub(1, newline - 1) or rest
				local found = parse(line, index, index + #line - 1)
				if found then annotations[#annotations + 1] = found end
				if not newline then break end
				index += newline
				rest = rest:sub(newline + 1)
			end
		end
	end

	-- Attaching an annotation to the declaration below it is a lookup by offset, so sort
	-- once and binary search later.
	table.sort(annotations, function(a, b) return a.start < b.start end)

	return { annotations = annotations }
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

return doc
