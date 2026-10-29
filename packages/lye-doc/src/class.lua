--[[
	Classes and aliases, as their annotations declare them.

	A field keeps the text it was written as; nothing here resolves a type.
]]

local classes = {}

---@alias lye.doc.Visibility
--- | "public"
--- | "private"
--- | "protected"

---@class lye.doc.Alias
---@field params string[] the names it takes, `ArrayOfNumberLike<T>` written `<T>`
---@field body string the type it stands for, read where it is used

---@class lye.doc.Field
---@field name string
---@field type string the declared type, as written, with the class's parameters substituted
---@field optional boolean? the field is one a value may leave out, written `name?`
---@field visibility lye.doc.Visibility

---@class lye.doc.Class
---@field consts table<string, boolean>? the parameters that take a value rather than a type
---@field constraints table<string, string>? what each parameter is limited to
---@field name string
---@field params string[] type parameters, empty when the class is not generic
---@field parent string? the parent as written, `Foo<number>` included
---@field fields lye.doc.Field[]

---@class lye.doc.Namespace
---@field classes table<string, lye.doc.Class>
---@field aliases table<string, lye.doc.Alias>
---@field built table<string, lye.doc.Type>? each spelling built once, so a class is one table
---@field evolved table<string, table<string, lye.doc.Type>>? fields a method added, by class

--- The index of the `>` closing the `<` at `from`, or nil when the angles do not balance.
---@param text string
---@param from integer
---@return integer?
local function closeAngle(text, from)
	local depth = 0
	for index = from, #text do
		local char = text:sub(index, index)
		if char == "<" then
			depth += 1
		elseif char == ">" then
			depth -= 1
			if depth == 0 then return index end
		end
	end
end

--- Split `Foo<A, B>` into its name and arguments. Angles nest, as `Map<K, List<V>>` shows.
---@param text string
---@return string name
---@return string? args
local function splitGeneric(text)
	local openAt = text:find("<", 1, true)
	if not openAt then return text, nil end
	local closeAt = closeAngle(text, openAt)
	if not closeAt then return text, nil end
	return text:sub(1, openAt - 1), text:sub(openAt + 1, closeAt - 1)
end

--- Read a parameter list, as `---@class Box<T: number, V>` and `---@alias X<T> T[]` both write
--- one. A parameter may be limited after a colon, and the name is what comes before it. `const`
--- in front of the name marks a parameter that takes a value — a literal — rather than a type.
---@param text string the text between the angle brackets
---@return string[] names
---@return table<string, string> constraints
---@return table<string, boolean> consts the names that must be given a value
function classes.readParams(text)
	local names, constraints, consts = {}, {}, {}
	for _, part in ipairs(classes.splitList(text)) do
		local name = (part:gsub("^%s+", ""):gsub("%s+$", ""))
		local marked = name:match("^const[%s]") ~= nil
		if marked then name = (name:sub(6):gsub("^%s+", "")) end
		local colon = name:find(":", 1, true)
		if colon then
			constraints[(name:sub(1, colon - 1):gsub("%s+$", ""))] = (name:sub(colon + 1):gsub("^%s+", ""))
			name = (name:sub(1, colon - 1):gsub("%s+$", ""))
		end
		if marked and name ~= "" then consts[name] = true end
		if name ~= "" then names[#names + 1] = name end
	end
	return names, constraints, consts
end

--- Split a comma-separated list, ignoring commas inside angles or braces.
---@param text string
---@return string[]
function classes.splitList(text)
	local types = require("lye-doc.type")
	local parts = {}
	for _, part in ipairs(types.splitAt(text, 44)) do
		local trimmed = (part:gsub("^%s+", ""):gsub("%s+$", ""))
		if trimmed ~= "" then parts[#parts + 1] = trimmed end
	end
	return parts
end

--- A `---@class` line: `Name<T, U>: Parent<X>`.
---@param text string
---@return string name
---@return string[] params
---@return string? parent
---@return table<string, boolean> consts
---@return table<string, string> constraints
local function readClass(text)
	-- The colon that names a parent is the one outside the parameters. `Box<T: number>` has one
	-- inside them, so splitting at the first colon would name the class `Box<T`.
	local depth, colonAt = 0, nil
	for index = 1, #text do
		local char = text:sub(index, index)
		if char == "<" then
			depth += 1
		elseif char == ">" then
			depth -= 1
		elseif char == ":" and depth == 0 then
			colonAt = index
			break
		end
	end
	local head, parent = text, nil
	if colonAt then head, parent = text:sub(1, colonAt - 1), text:sub(colonAt + 1) end
	local name, args = splitGeneric((head:gsub("%s+$", "")))
	local params, consts, constraints = {}, {}, {}
	if args then params, constraints, consts = classes.readParams(args) end
	return (name:gsub("%s+$", "")), params, parent and (parent:gsub("^%s+", "")) or nil, consts, constraints
end

--- The parameters and the body of an `---@alias`: `<T: number> T[]` is `T` and `T[]`.
---@param text string
---@return string[] params
---@return string body
---@return table<string, boolean> consts
---@return table<string, string> constraints
local function readAlias(text)
	local trimmed = text:gsub("^%s+", "")
	if trimmed:sub(1, 1) ~= "<" then return {}, trimmed, {}, {} end
	local closeAt = closeAngle(trimmed, 1)
	if not closeAt then return {}, trimmed, {}, {} end
	local params, constraints, consts = classes.readParams(trimmed:sub(2, closeAt - 1))
	return params, (trimmed:sub(closeAt + 1):gsub("^%s+", "")), consts, constraints
end

--- A `---@field` line: `---@field [visibility] name[?] type`.
---@param annotation lye.doc.Annotation
---@param fallback lye.doc.Visibility
---@return lye.doc.Field?
local function readField(annotation, fallback)
	local name = annotation.name
	if not name then return nil end

	local visibility = annotation.visibility or fallback
	local typeText = annotation.type or "any"
	-- The inline form: `---@field private name type`, where the tag's own name slot holds the
	-- visibility and the field's name moves into the type text. The doc reader splits the common
	-- spelling, and this keeps a hand-built annotation working the same way.
	local inline = name
	if inline == "private" or inline == "protected" or inline == "public" then
		visibility = inline
		local rest = typeText
		local realName, remaining = rest:match("^([%w_%.]+)(.*)$")
		if type(realName) ~= "string" or type(remaining) ~= "string" then return nil end
		name, typeText = realName, (remaining:gsub("^%s+", ""))
		---@cast name string
		---@cast typeText string
		-- `---@field private data table<K, V>` carries the rest in the tag's text, which is where
		-- the doc reader keeps a field's type when it stopped at the first word.
		if typeText == "" then
			local after = (annotation.text or ""):match("^private%s+[%w_%.]+%s+(.*)$")
			typeText = after and (after:gsub("%s+$", "")) or "any"
		end
	end

	-- `---@field x? number` marks the field optional, which is what `?` means on the type: it is
	-- nil as well as what it says. Recorded here rather than appended to the text, because a
	-- function type ends in its own return: `__add? fun(a: T, b: T): T` would otherwise read as a
	-- function returning `T?`, which is a different thing entirely.
	local optional = false
	if name:sub(-1) == "?" then
		name = name:sub(1, -2)
		optional = true
	elseif typeText:sub(1, 1) == "?" then
		typeText = (typeText:sub(2):gsub("^%s+", ""))
		optional = true
	end

	return { name = name, type = typeText, optional = optional, visibility = visibility }
end

--- Replace each parameter name in a type's text with the argument written for it, so a field read
--- through `Foo<number>` says number where `Foo<T>` said T. An argument that is an expression of
--- literals is folded first, so substituting it keeps the value it stands for.
---@param text string
---@param params string[]
---@param args string[]
---@return string
local function substitute(text, params, args)
	if #params == 0 then return text end
	local out = text
	local docTypes = require("lye-doc.type")
	for index, param in ipairs(params) do
		-- An argument written as arithmetic or as concatenation is folded before it goes in, so
		-- the value it stands for survives the substitution rather than its precedence.
		local replacement = args[index] and (docTypes.foldToText(args[index]) or args[index]) or "unknown"
		-- A frontier on either side, so `T` does not rewrite the T inside `Table`.
		out = out:gsub("%f[%w_](" .. param .. ")%f[^%w_]", replacement)
	end
	return out
end

--- A class or alias name without the marker an annotation may carry: `ffi.cdata*` is the class
--- `ffi.cdata`, and `file*` the class `file`. The marker says how a name is used rather than what it
--- is called, so a name written with it in one place and without it in another has to be one type —
--- which is how `ffi.gc` came to reject the very cdata it had been handed.
---@param name string
local function bareName(name)
	return (name:gsub("%s*%*$", ""))
end

--- The class a name refers to, with whatever arguments were written.
---@param namespace lye.doc.Namespace
---@param text string
function classes.resolve(namespace, text)
	local name, argsText = splitGeneric(text)

	local found = namespace.classes[bareName(name)]
	if not found then
		return nil
	end

	-- A name written without arguments — `Vec` rather than `Vec<number>` — has none to split:
	-- `splitGeneric` gives nil, and splitting that raised on every class read without parameters.
	return found, argsText and classes.splitList(argsText) or {}
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
				optional = field.optional,
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
---@param elsewhere table<string, lye.doc.Type|boolean>? what another file's names stand for, which the caller is the one that can say
function classes.resolver(namespace, elsewhere)
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
		-- A field's type is text until here too, so a name this file does not declare has to be
		-- answered the same way one written in the file would be: `---@field value lye.doc.Type`
		-- in a file that never declares it reads as that type rather than as a bare name, which
		-- is what lets the two compare equal.
		if not found then
			local foreign = elsewhere and elsewhere[text]
			if type(foreign) == "table" then return foreign end
		end
		if found then
			if built[text] then return built[text] end

			local argTypes = {}
			for index, argText in ipairs(args) do
				argTypes[index] = types.parse(argText, resolve) or types.UNKNOWN_TYPE
			end
			-- Built once per spelling, so a class type is the same table every time it is read
			-- and a method declared later can reach it. It goes into `built` before its fields
			-- are read: a class that reaches itself — a tree holding its children, a class
			-- extending itself through a parent — finds the type being built rather than an
			-- unresolved name, and the cycle ends because there is nothing left to build.
			local classType = types.classType(found.name, argTypes)
			classType.visibility = classType.visibility or {}
			built[text] = classType
			for name, field in pairs(classes.fieldsOf(namespace, text)) do
				---@cast name string
				---@cast field lye.doc.Field
				local held = types.parse(field.type, resolve) or types.UNKNOWN_TYPE
				-- A field a value may leave out is nil as well as what it says, which is what the
				-- `?` means: reading it gives the type or nil.
				if field.optional then held = types.union({ held, types.NIL_TYPE }) end
				local key = name:match("^%[([^%]]+)%]$")
				if key then
					-- An index signature, kept where a read with a computed key can find it.
					classType.indexed = { key = key, type = held }
				else
					classType.fields[name] = held
					classType.visibility[name] = field.visibility
				end
			end
			local methods = found.name
				and (evolved[found.name] or evolved[bareName(found.name)])
			-- A method declared on a generic class is written in the class's own parameters:
			-- `function Box:get() return self.value end` hands back `T`, and which `T` is what the
			-- arguments of the class say. Each method is one type shared by every instance, so the
			-- substitution makes a fresh callable rather than rewriting it.
			---@type table<string, lye.doc.Type>?
			local methodBindings
			if #found.params > 0 then
				methodBindings = {}
				for index, param in ipairs(found.params) do
					methodBindings[param] = argTypes[index] or types.UNKNOWN_TYPE
				end
			end
			for name, field in pairs(methods or {}) do
				local bindings = methodBindings
				-- A method that declares its own variables shadows the class's: `Box<T>` with
				-- `---@generic T` on `Box.new` has a constructor variable of its own, and binding
				-- it to the class's argument would make every call return the box the class table
				-- happens to be written under rather than the one the caller is building.
				if bindings and field.variant == "fn" then
					---@type table<string, boolean>?
					local generics = field.generics
					if generics then
						---@type table<string, boolean>?
						local shadowed
						for param in pairs(generics) do
							if bindings[param] then
								shadowed = shadowed or {}
								shadowed[param] = true
							end
						end
						if shadowed then
							---@type table<string, lye.doc.Type>
							local kept = {}
							for param, held in pairs(bindings) do
								if not shadowed[param] then kept[param] = held end
							end
							bindings = kept
						end
					end
				end
				classType.fields[name] = bindings
					and types.substitute(field, bindings) or field
			end
			if found.parent then
				local parentType = resolve(substitute(found.parent, found.params, args))
				if parentType then classType.parents[#classType.parents + 1] = parentType end
			end
			return classType
		end

		-- An alias is read where it is used, not where it is written: `ArrayOfNumberLike<Point>`
		-- substitutes its argument into the body, and the body may name anything the file
		-- declares, however far below the alias.
		local aliasName, argsText = splitGeneric(text)
		aliasName = (aliasName:gsub("%s+$", ""))
		local alias = namespace.aliases[bareName(aliasName)]
		if alias and not active[aliasName] then
			if built[text] then return built[text] end
			-- A body may name the alias being read: `---@alias Tree { children: Tree[] }` is how a
			-- recursive shape is written. A placeholder is what the body sees while it is being
			-- read; once the body has settled, the placeholder is promoted in place, so every
			-- reference the body made to the alias is the alias itself rather than `any`.
			local placeholder = types.mutable()
			built[text] = placeholder
			active[aliasName] = placeholder
			local body = alias.body
			if #alias.params > 0 then
				body = substitute(body, alias.params, argsText and classes.splitList(argsText) or {})
			end
			local resolved = types.parse(body, resolve)
			active[aliasName] = nil
			-- The body is built once per spelling, the way a class is: an alias named by a hundred
			-- signatures is one type, and reading it again is a tree per read. `Foo<number>` and
			-- `Foo<string>` are two spellings and two types, which is what the arguments say.
			if resolved and placeholder.variant == "unknown" and not types.isMutable(resolved) then
				types.promote(placeholder, resolved)
			end
			-- A name is what a reader of a type error should see. The body of `lye.doc.Type`
			-- is a union of a dozen object shapes; printing that union verbatim turned one
			-- parameter into a screenful of structure. The alias keeps its name and the display
			-- uses it, while the type system still works with the body.
			local named = built[text]
			-- Only a wide union needs the name in preference to its structure. Small aliases
			-- stay useful as the shape they write, which is what the doc tests and a reader
			-- comparing types expect.
			local wide = type(named) == "table" and named.variant == "union" and #named.types > 4
			if wide and named.variant ~= "class"
				and named ~= types.NUMBER and named ~= types.STRING and named ~= types.BOOLEAN
				and named ~= types.NIL_TYPE and named ~= types.TABLE and named ~= types.VOID
				and named ~= types.NEVER and named ~= types.UNKNOWN_TYPE and named ~= types.ANY_TYPE
				and not named.aliasName then
				named.aliasName = text
			end
			return built[text]
		end
		-- Reading the body of an alias that names itself: the placeholder the outer read is
		-- holding, so the alias can contain itself. A class may do the same because it is *named*
		-- — reading a field of it stops at the name — and an alias has no name to stop at.
		if active[aliasName] then return active[aliasName] end
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
	-- A class may be written with the marker that says how a name is used (`file*`) while the
	-- method is declared against the name without it (`function file:read`), or the other way
	-- round. The resolver builds the class type under the written name, so both spellings have to
	-- reach the same method table; storing only one left every `file:read` invisible.
	local bare = bareName(className)
	local fields = namespace.evolved[bare]
	if not fields then
		fields = {}
		namespace.evolved[bare] = fields
	end
	if className ~= bare then namespace.evolved[className] = fields end
	fields[field] = method
	for _, classType in pairs(namespace.built or {}) do
		if classType.variant == "class" and classType.name and bareName(classType.name) == bare then
			classType.fields[field] = method
		end
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
			local name, params, parent, consts, constraints = readClass(annotation.text or "")
			current = {
				name = name, params = params, parent = parent, fields = {}, consts = consts,
				constraints = constraints,
			}
			namespace.classes[bareName(name)] = current
			visibility = "public"
		elseif annotation.tag == "field" then
			if current then
				-- `---@field [integer] T` is an index signature rather than a field: what a value
				-- indexed with that kind of key gives. The name slot holds a bracket, which the
				-- field reader has no name for, so it is read from the body and kept under the
				-- bracketed name for the resolver to recognise.
				local key, held = (annotation.text or ""):match("^%s*%[([^%]]+)%]%s*(.+)$")
				if key then
					current.fields[#current.fields + 1] = {
						name = "[" .. (key:gsub("%s+$", "")) .. "]", type = held, visibility = visibility,
					}
				else
					local field = readField(annotation, visibility)
					if field then current.fields[#current.fields + 1] = field end
				end
			end
		elseif annotation.tag == "private" or annotation.tag == "protected" or annotation.tag == "public" then
			visibility = annotation.tag
		elseif annotation.tag == "alias" then
			-- `---@alias ArrayOfNumberLike<T: number> T[]`: the doc reader hands the parameters over
			-- in the type text, ahead of the body, and both are kept as written. The body is not
			-- resolved here: it may name a class the file declares further down, and a parameter
			-- only means something once an argument is given.
			if annotation.name then
				-- The marker after a name is not part of the body: `---@alias ffi.ct* ffi.ctype*|...`
				-- splits the name off at the star and leaves the star in front of the text that
				-- follows, which read as a first member of `*`.
				local written = (annotation.type or "any"):gsub("^%s*%*%s*", "")
				local params, body, consts, constraints = readAlias(written)
				namespace.aliases[bareName(annotation.name)] = {
					params = params, body = body, consts = consts, constraints = constraints,
				}
			end
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

--- The names a run of files declares, each resolved to the type it stands for: a class with its
--- fields, an alias as the body it writes. Every file's classes and aliases go into one namespace
--- before any name is resolved, because a field of one file's class may name an alias another
--- file writes — reading it against the file it was written in alone leaves that field a name
--- nothing stands for. `lye check` reads a batch of files this way and the LSP reads the whole
--- workspace this way, so both hand an analysis the same types.
---@param files lye.doc.File[]
---@return table<string, lye.doc.Type|boolean> the type where one can be built, `true` where not
function classes.declare(files)
	local merged = { classes = {}, aliases = {} }
	for _, file in ipairs(files) do
		local namespace = classes.read(file)
		for name, class in pairs(namespace.classes) do merged.classes[name] = merged.classes[name] or class end
		for name, alias in pairs(namespace.aliases) do merged.aliases[name] = merged.aliases[name] or alias end
	end
	local resolve = classes.resolver(merged)
	local found = {}
	for _, file in ipairs(files) do
		for _, annotation in ipairs(file.annotations) do
			if (annotation.tag == "class" or annotation.tag == "alias") and annotation.name
				and found[annotation.name] == nil then
				found[annotation.name] = resolve(annotation.name) or true
			end
		end
	end
	return found
end

return classes
