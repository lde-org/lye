--[[
	Classes and aliases, as their annotations declare them.

	A `---@class` names a type, its parameters, and what it extends; the `---@field` lines that
	follow belong to it until another class begins. Nothing here resolves a type: a field keeps
	the text it was written as, so the analyzer can parse it with the parameters of the class it
	was read from already substituted.
]]

local classes = {}

---@alias lye.doc.Visibility "public"|"private"|"protected"

---@class lye.doc.Field
---@field name string
---@field type string the declared type, as written, with the class's parameters substituted
---@field visibility lye.doc.Visibility

---@class lye.doc.Class
---@field name string
---@field params string[] type parameters, empty when the class is not generic
---@field parent string? the parent as written, `Foo<number>` included
---@field fields lye.doc.Field[]

---@class lye.doc.Namespace
---@field classes table<string, lye.doc.Class>
---@field aliases table<string, string>

--- Split `Foo<A, B>` into its name and arguments. Angles nest, as `Map<K, List<V>>` shows.
---@param text string
---@return string name
---@return string? args
local function splitGeneric(text)
	local openAt = text:find("<", 1, true)
	if not openAt then return text, nil end
	local depth, closeAt = 0, nil
	for index = openAt, #text do
		local char = text:sub(index, index)
		if char == "<" then
			depth += 1
		elseif char == ">" then
			depth -= 1
			if depth == 0 then
				closeAt = index
				break
			end
		end
	end
	if not closeAt then return text, nil end
	return text:sub(1, openAt - 1), text:sub(openAt + 1, closeAt - 1)
end

--- Split a comma-separated list, ignoring commas inside angles or braces.
---@param text string
---@return string[]
function classes.splitList(text)
	local parts, depth, from = {}, 0, 1
	for index = 1, #text do
		local char = text:sub(index, index)
		if char == "<" or char == "{" or char == "(" then
			depth += 1
		elseif char == ">" or char == "}" or char == ")" then
			depth -= 1
		elseif char == "," and depth == 0 then
			parts[#parts + 1] = (text:sub(from, index - 1):gsub("^%s+", ""):gsub("%s+$", ""))
			from = index + 1
		end
	end
	local last = (text:sub(from):gsub("^%s+", ""):gsub("%s+$", ""))
	if last ~= "" then parts[#parts + 1] = last end
	return parts
end

--- A `---@class` line: `Name<T, U>: Parent<X>`.
---@param text string
---@return string name
---@return string[] params
---@return string? parent
local function readClass(text)
	local head, parent = text:match("^([^:]+):(.*)$")
	if not head then
		head, parent = text, nil
	end
	local name, args = splitGeneric((head:gsub("%s+$", "")))
	local params = {}
	if args then
		for _, param in ipairs(classes.splitList(args)) do params[#params + 1] = param end
	end
	return (name:gsub("%s+$", "")), params, parent and (parent:gsub("^%s+", "")) or nil
end

--- A `---@field` line: `---@field [visibility] name[?] type`.
---@param annotation lye.doc.Annotation
---@param fallback lye.doc.Visibility
---@return lye.doc.Field?
local function readField(annotation, fallback)
	local name = annotation.name
	if not name then return nil end

	local visibility = fallback
	local typeText = annotation.type or "any"
	-- The inline form: `---@field private name type`, where the tag's own name slot holds the
	-- visibility and the field's name moves into the type text.
	local inline = name
	if inline == "private" or inline == "protected" or inline == "public" then
		visibility = inline
		local rest = typeText
		local realName, remaining = rest:match("^([%w_%.]+)(.*)$")
		if not realName then return nil end
		name, typeText = realName, (remaining:gsub("^%s+", ""))
		if typeText == "" then typeText = "any" end
	end

	-- `---@field x? number` marks the field optional, which is what `?` means on the type. The
	-- marker ends up at the front of the type text when the name pattern stops before it.
	if name:sub(-1) == "?" then
		name = name:sub(1, -2)
		typeText = typeText .. "?"
	elseif typeText:sub(1, 1) == "?" then
		typeText = (typeText:sub(2):gsub("^%s+", "")) .. "?"
	end
	return { name = name, type = typeText, visibility = visibility }
end

--- Replace each parameter name in a type's text with the argument written for it, so a field read
--- through `Foo<number>` says number where `Foo<T>` said T.
---@param text string
---@param params string[]
---@param args string[]
---@return string
local function substitute(text, params, args)
	if #params == 0 then return text end
	local out = text
	for index, param in ipairs(params) do
		local replacement = args[index] or "unknown"
		-- A frontier on either side, so `T` does not rewrite the T inside `Table`.
		out = out:gsub("%f[%w_](" .. param .. ")%f[^%w_]", replacement)
	end
	return out
end

--- The class a name refers to, with whatever arguments were written.
---@param namespace lye.doc.Namespace
---@param text string
---@return lye.doc.Class? class
---@return string[] args as written, empty when none were
function classes.resolve(namespace, text)
	local name, argsText = splitGeneric(text)
	local found = namespace.classes[name]
	if not found then return nil end
	local args = argsText and classes.splitList(argsText) or {}
	return found, args
end

--- The fields a class has, its parents' included. A parameter is substituted with the argument
--- its reader supplied, or with `unknown` when the reader supplied none: `Foo` means
--- `Foo<unknown>`, so a generic class is usable before anyone says what it holds.
---@param namespace lye.doc.Namespace
---@param text string the class as written, `Foo<number>` included
---@return table<string, lye.doc.Field> fields
function classes.fieldsOf(namespace, text)
	local found, args = classes.resolve(namespace, text)
	if not found then return {} end

	local fields = {}
	---@param class lye.doc.Class
	---@param args string[]
	local function collect(class, args)
		if class.parent then
			local parentClass, parentArgs = classes.resolve(namespace, substitute(class.parent, class.params, args))
			if parentClass then collect(parentClass, parentArgs) end
		end
		for _, field in ipairs(class.fields) do
			fields[field.name] = {
				name = field.name,
				type = substitute(field.type, class.params, args),
				visibility = field.visibility,
			}
		end
	end
	collect(found, args)
	return fields
end

--- A function that turns written type text into a type, resolving class names and aliases.
--- Class fields are resolved once, here, so the type system never has to know about annotations.
---@param namespace lye.doc.Namespace
---@return fun(text: string): lye.doc.Type?
function classes.resolver(namespace)
	local types = require("lye-doc.type")
	local active = {}
	-- A class grows as its methods are declared, so what a method adds is remembered on the
	-- namespace and merged into every variant of that class, including the ones already built.
	namespace.evolved = namespace.evolved or {}
	namespace.built = namespace.built or {}
	local evolved, built = namespace.evolved, namespace.built

	---@param text string
	---@return lye.doc.Type?
	local function resolve(text)
		local found, args = classes.resolve(namespace, text)
		if found then
			-- A class that reaches itself through a parent would resolve forever.
			if active[found.name] then return nil end
			active[found.name] = true

			local argTypes = {}
			for index, argText in ipairs(args) do
				argTypes[index] = types.parse(argText, resolve) or types.UNKNOWN_TYPE
			end
			if built[text] then
				active[found.name] = nil
				return built[text]
			end
			local fields, visibility = {}, {}
			for name, field in pairs(classes.fieldsOf(namespace, text)) do
				fields[name] = types.parse(field.type, resolve) or types.UNKNOWN_TYPE
				visibility[name] = field.visibility
			end
			for name, field in pairs(evolved[found.name] or {}) do fields[name] = field end
			local parents = {}
			if found.parent then
				local parentType = resolve(substitute(found.parent, found.params, args))
				if parentType then parents[#parents + 1] = parentType end
			end

			active[found.name] = nil
			-- Built once per spelling, so a class type is the same table every time it is read
			-- and a method declared later can reach it.
			built[text] = types.classType(found.name, argTypes, fields, parents, visibility)
			return built[text]
		end

		local alias = namespace.aliases[text]
		if alias and not active[text] then
			active[text] = true
			local resolved = types.parse(alias, resolve)
			active[text] = nil
			return resolved
		end
	end
	return resolve
end

--- Declare a method on a class, as `function Foo:bar()` does. Every variant of that class picks
--- it up, including the ones already built, so a `Foo` read before the method still has it. The
--- state lives on the namespace because a resolver is a function, and a function cannot be given
--- fields.
---@param namespace lye.doc.Namespace
---@param className string
---@param field string
---@param method lye.doc.Type
function classes.evolve(namespace, className, field, method)
	namespace.evolved = namespace.evolved or {}
	namespace.built = namespace.built or {}
	namespace.evolved[className] = namespace.evolved[className] or {}
	namespace.evolved[className][field] = method
	for _, classType in pairs(namespace.built) do
		if classType.name == className then classType.fields[field] = method end
	end
end

--- Read the classes and aliases a file declares.
---@param file lye.doc.File
---@return lye.doc.Namespace
function classes.read(file)
	local namespace = { classes = {}, aliases = {} }
	local current, visibility = nil, "public"

	for _, annotation in ipairs(file.annotations) do
		if annotation.tag == "class" then
			local name, params, parent = readClass(annotation.text or "")
			current = { name = name, params = params, parent = parent, fields = {} }
			namespace.classes[name] = current
			visibility = "public"
		elseif annotation.tag == "field" then
			if current then
				local field = readField(annotation, visibility)
				if field then current.fields[#current.fields + 1] = field end
			end
		elseif annotation.tag == "private" or annotation.tag == "protected" or annotation.tag == "public" then
			visibility = annotation.tag
		elseif annotation.tag == "alias" then
			if annotation.name then namespace.aliases[annotation.name] = annotation.type or "any" end
			current = nil
		elseif annotation.tag ~= "meta" and annotation.tag ~= "version" and annotation.tag ~= "see" then
			-- A class owns the fields written under it, and nothing past the next declaration.
			if annotation.tag == "param" or annotation.tag == "return" or annotation.tag == "type" then
				current = nil
			end
			visibility = "public"
		end
	end
	return namespace
end

return classes
