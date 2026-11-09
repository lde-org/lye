local test = require("lde-test")
local ffi = require("ffi")
local Uri = require("lye-framework.uri")

test.it("decodes a POSIX document URI to its path", function()
	test.equal(Uri.toPath("file:///home/puffy/lye/a%20b.lua"), "/home/puffy/lye/a b.lua")
	test.equal(Uri.toPath("file:///home/puffy/lye/a.lua"), "/home/puffy/lye/a.lua")
end)

test.it("drops the authority slash and decodes the drive colon of a Windows URI", function()
	test.equal(Uri.toPath("file:///c%3A/Users/puffy/a.lua"), "c:/Users/puffy/a.lua")
	test.equal(Uri.toPath("file:///c%3A/Users/puffy/a%20b.lua"), "c:/Users/puffy/a b.lua")
end)

test.it("reads a literal drive colon and the two-slash spelling alike", function()
	-- Clients that build a URI by joining `file://` and a path write the drive as the authority.
	test.equal(Uri.toPath("file:///c:/Users/puffy/a.lua"), "c:/Users/puffy/a.lua")
	test.equal(Uri.toPath("file://c:/Users/puffy/a.lua"), "c:/Users/puffy/a.lua")
	test.equal(Uri.toPath("file:///C%3A/Users/puffy/a.lua"), "c:/Users/puffy/a.lua",
		"the drive is lower case, as VS Code writes it")
end)

test.it("writes a Windows path as the URI VS Code sends", function()
	-- VS Code escapes the drive colon and lower-cases the drive. A URI with a literal colon is a
	-- different string, and the client keys its documents by the string it sent.
	test.equal(Uri.fromPath("c:/Users/puffy/a.lua"), "file:///c%3A/Users/puffy/a.lua")
	test.equal(Uri.fromPath("C:/Users/puffy/a b.lua"), "file:///c%3A/Users/puffy/a%20b.lua")
	test.equal(Uri.fromPath("c:\\Users\\puffy\\a.lua"), "file:///c%3A/Users/puffy/a.lua")
end)

test.it("writes a POSIX path as a three-slash URI", function()
	test.equal(Uri.fromPath("/home/puffy/a.lua"), "file:///home/puffy/a.lua")
	test.equal(Uri.fromPath("/home/puffy/a b.lua"), "file:///home/puffy/a%20b.lua")
end)

test.it("escapes a percent sign and a question mark in a name", function()
	test.equal(Uri.fromPath("/home/puffy/100%.lua"), "file:///home/puffy/100%25.lua")
	test.equal(Uri.fromPath("/home/puffy/what?.lua"), "file:///home/puffy/what%3F.lua")
	test.equal(Uri.toPath("file:///home/puffy/what%3F.lua"), "/home/puffy/what?.lua")
end)

test.it("round-trips a URI through a path and back", function()
	local windows = "file:///c%3A/Users/puffy/a%20b%25.lua"
	test.equal(Uri.fromPath(Uri.toPath(windows)), windows)
	local posix = "file:///home/puffy/a%20b%25.lua"
	test.equal(Uri.fromPath(Uri.toPath(posix)), posix)
end)

test.it("names a workspace folder without a trailing separator, but keeps a drive root", function()
	test.equal(Uri.rootPath("file:///home/puffy/project/"), "/home/puffy/project")
	test.equal(Uri.rootPath("file:///c%3A/Users/puffy/project"), "c:/Users/puffy/project")
	test.equal(Uri.rootPath("file:///c%3A/"), "c:/", "`c:` names a drive's current directory")
end)

test.it("tells an absolute path from a drive-relative one", function()
	test.truthy(Uri.isAbsolute("/home/puffy/a.lua"))
	test.truthy(Uri.isAbsolute("c:/Users/puffy/a.lua"))
	test.truthy(Uri.isAbsolute("C:\\Users\\puffy\\a.lua"))
	test.truthy(Uri.isAbsolute("\\rooted"))
	test.falsy(Uri.isAbsolute("src/a.lua"))
	test.falsy(Uri.isAbsolute("c:a.lua"), "a drive-relative path is not absolute")
end)

test.it("keys one document by one path whatever the separator or case", function()
	-- Windows compares paths without regard to case, and a path may arrive with either separator:
	-- the document store must answer with the buffer for all of them.
	if ffi.os ~= "Windows" then return end
	test.equal(Uri.pathKey("file:///c%3A/Users/puffy/a.lua"), Uri.pathKey("C:\\Users\\puffy\\a.lua"))
end)
