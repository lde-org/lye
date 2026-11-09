--[[
	The one conversion between a client's document URI and the path the rest of lye reads.

	An editor keys a document by the URI it sent, so that exact string is the one a response must
	name; a path is what `io.open` and `fs` take. The two differ most on Windows, where VS Code
	writes `file:///c%3A/Users/...`: the drive colon is escaped and the leading slash is part of the
	URI's empty authority rather than of the path. Stripping `file://` and using the rest as a path
	leaves `/c%3A/Users/...`, which no filesystem opens.
]]

local ffi = require("ffi")

local uri = {}

local IS_WINDOWS = ffi.os == "Windows"

-- The characters left as written. This is the URI `pchar` production plus `/`: letters, digits,
-- `-._~` and the sub-delims. `#`, `?`, `%`, space and every byte above 0x7F have to be escaped,
-- or they change what the URI means rather than how a path is spelled.
local UNSAFE = "[^%w%-%._~/!$&'()*+,;=:@]"

---@param text string
local function decode(text)
	return (text:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

---@param text string
local function encode(text)
	return (text:gsub(UNSAFE, function(char)
		return string.format("%%%02X", char:byte())
	end))
end

--- Whether a path carries a Windows drive. A drive-relative `c:file` is not absolute, so the
--- separator is what tells the two apart.
---@param path string
---@return boolean
function uri.isAbsolute(path)
	return path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" or path:match("^[A-Za-z]:[/\\]") ~= nil
end

--- The path a document URI names, with forward slashes.
---@param value string a `file:` URI, or a path, which is answered unchanged
---@return string
function uri.toPath(value)
	local rest = value:match("^[Ff][Ii][Ll][Ee]://(.*)$")
	if not rest then
		if IS_WINDOWS then
			value = value:gsub("\\", "/")
			local drive = value:match("^([A-Za-z]):")
			if drive then value = drive:lower() .. value:sub(2) end
		end
		return value
	end

	rest = decode(rest)
	if rest == "" then return "" end
	if rest:sub(1, 1) ~= "/" then
		-- `file://c:/x` puts the drive where a URI puts the authority. Clients that build a URI by
		-- joining `file://` and a Windows path write this, and it is a drive rather than a host.
		local drive, tail = rest:match("^([A-Za-z]):(.*)$")
		if drive then return drive:lower() .. ":" .. tail:gsub("\\", "/") end
		-- An authority: `file://server/share` names a UNC share, and `file://localhost/x` names
		-- this machine's `/x`, which is what VS Code writes for a drive-less POSIX path.
		local authority, tail = rest:match("^([^/]*)(/.*)$")
		if authority and (authority == "" or authority:lower() == "localhost") then
			rest = tail
		else
			return "//" .. rest
		end
	end

	if rest:match("^/[A-Za-z]:") then
		-- The URI's third slash is not the drive root: `/c:/x` is the path `c:/x`. VS Code writes
		-- the drive in lower case; do the same so a path read from a document and one resolved
		-- from a root compare as one string.
		rest = rest:sub(2)
		return rest:sub(1, 1):lower() .. rest:sub(2):gsub("\\", "/")
	end
	return rest
end

--- The directory a workspace folder URI names: a path with no trailing separator, except that a
--- drive's root keeps its slash — `c:` names a drive's current directory, not its root.
---@param value string a `file:` URI, or a path
---@return string
function uri.rootPath(value)
	local path = uri.toPath(value):gsub("[/\\]+$", "")
	if path:match("^%a:$") then return path .. "/" end
	return path
end

--- The URI a path is published under. A drive is written the way VS Code writes it,
--- `file:///c%3A/...`, because that is the spelling the client keys its own document by: a
--- diagnostics publication or a definition to `file:///c:/...` is a different URI to it.
---@param value string a path, or a URI, which is answered unchanged
---@return string
function uri.fromPath(value)
	if value:match("^[Ff][Ii][Ll][Ee]:") then return value end

	local path = value
	if IS_WINDOWS then path = path:gsub("\\", "/") end
	if path:sub(1, 2) == "//" then
		local host, rest = path:match("^//([^/]+)(/.*)$")
		if host then return "file://" .. host .. encode(rest) end
	end

	local drive, rest = path:match("^([A-Za-z]):(.*)$")
	if drive then
		return "file:///" .. drive:lower() .. "%3A" .. encode(rest)
	end
	if path:sub(1, 1) == "/" then return "file://" .. encode(path) end
	-- A relative path has no absolute spelling to give it; `lye` calls this with paths the
	-- filesystem already made absolute, and a stray one still becomes a URI rather than a host.
	return "file:///" .. encode(path)
end

--- A path as a table key. Windows compares a path without regard to case, as its filesystem does,
--- so two spellings of one document are one entry.
---@param value string a path or a URI
---@return string
function uri.pathKey(value)
	local path = uri.toPath(uri.fromPath(value))
	return IS_WINDOWS and path:lower() or path
end

return uri
