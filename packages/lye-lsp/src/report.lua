--[[
	What a check says and how it says it.

	A diagnostic is one line — `path:line:col: message` — so it can be read by eye, by `grep`, and
	by anything that already parses a compiler's output. On a terminal the severity and the path
	are coloured and the message is not, because the message is the part being read. In GitHub
	Actions the same line is emitted as a workflow command as well, which is what turns it into an
	annotation on the commit rather than a line of log nobody scrolls back to.
]]

local ffi = require("ffi")

-- `isatty` is the only way to know whether colour will be seen rather than printed as escape
-- codes into a file. Windows has no such symbol, so it is asked for and not insisted on.
pcall(ffi.cdef, "int isatty(int fd);")

local report = {}

--- Severity, by the number the analyzer gives a diagnostic: 1 is an error, 2 a warning, and 3 or
--- more a hint. A parser diagnostic carries no number, and a syntax error is the loudest thing
--- there is.
local SEVERITY = {
	[1] = "error",
	[2] = "warning",
	[3] = "hint",
}

local PAINT = {
	error   = "\27[31m",
	warning = "\27[33m",
	hint    = "\27[90m",
	path    = "\27[36m",
	good    = "\27[32m",
	bad     = "\27[31m",
	dim     = "\27[90m",
	reset   = "\27[0m",
}

--- Whether anything is watching: a terminal, rather than a pipe or a file.
---@return boolean
function report.terminal()
	local ok, isTerminal = pcall(function() return ffi.C.isatty(1) ~= 0 end)
	return ok and isTerminal or false
end

--- Whether that terminal will render escape codes rather than store them. `NO_COLOR` is the
--- environment's own word for no, and a dumb terminal means it has none.
local function wantsColor()
	if os.getenv("NO_COLOR") or os.getenv("TERM") == "dumb" then return false end
	return report.terminal()
end

---@param self lye.Report
---@param name string
---@param text string
local function paint(self, name, text)
	if not self.color then return text end
	return (PAINT[name] or "") .. text .. PAINT.reset
end

--- A workflow command escapes `%`, a newline and a carriage return; a property escapes the two
--- that separate properties and end them. GitHub's own rule, and the only way a path with a comma
--- or a message with a newline arrives intact.
---@param text string
---@param isProperty boolean?
local function escape(text, isProperty)
	local out = text:gsub("%%", "%%25"):gsub("\r", "%%0D"):gsub("\n", "%%0A")
	if isProperty then out = out:gsub(":", "%%3A"):gsub(",", "%%2C") end
	return out
end

--- What reports a diagnostic, given where the output goes.
---@class lye.Report
---@field color boolean
---@field github boolean
---@field counts table<string, integer>
---@field collect lye.Report.Finding[]? findings kept instead of printed, for a worker process

--- One diagnostic as a worker hands it over: the place it belongs to and what it says.
---@alias lye.Report.Entry { path: string, line: integer?, column: integer?, severity: integer?, message: string }

--- What a worker hands over: a diagnostic, or the file it is about when it could not be read —
--- a diagnostic is about a position, and a file that would not open has none. A check that runs
--- its files in several processes has each worker keep these, and the process that started them
--- prints them the way one process would have.
---@alias lye.Report.Finding lye.Report.Entry|{ path: string, err: string }

---@return lye.Report
function report.new()
	return {
		color = wantsColor(),
		github = os.getenv("GITHUB_ACTIONS") == "true",
		counts = { error = 0, warning = 0, hint = 0 },
	}
end

--- A report that keeps what it is told rather than printing it, and counts it all the same: the
--- findings are in `collect`, where whoever started the worker reads them.
---@class lye.Collector: lye.Report
---@field collect lye.Report.Finding[]

function report.collect()
	local collector = report.new() ---@type lye.Collector
	collector.collect = {}
	return collector
end

--- Turn colour off, for `--no-color`, and on, for a log that will render it.
---@param self lye.Report
---@param wanted boolean?
function report.plain(self, wanted) self.color = wanted == true end

--- One diagnostic, on its own line.
---@param self lye.Report
---@param path string
---@param line integer
---@param column integer
---@param severity integer?
---@param message string
function report.diagnostic(self, path, line, column, severity, message)
	local name = SEVERITY[severity or 1] or "error"
	self.counts[name] = (self.counts[name] or 0) + 1

	local collected = self.collect
	if collected then
		collected[#collected + 1] = { path = path, line = line, column = column, severity = severity, message = message }
		return
	end

	if self.github then
		-- `notice` rather than `warning` for a hint: an annotation that does not ask for anything
		-- should not be one more thing a reviewer has to dismiss.
		local command = name == "error" and "error" or name == "warning" and "warning" or "notice"
		-- A path the walk wrote with a `./` on the front is still the path from the repository
		-- root, and that is what an annotation is placed against.
		io.stdout:write(string.format("::%s file=%s,line=%d,col=%d,title=%s::%s\n", command,
			escape((path:gsub("^%./", "")), true), line, column, escape("lye", true), escape(message)))
	end

	io.stdout:write(string.format("%s:%d:%d: %s: %s\n",
		paint(self, "path", path), line, column, paint(self, name, name), message))
end

--- What was checked and what came of it, where a reader looks for it: last.
---@param self lye.Report
---@param files integer
function report.summary(self, files)
	local counts = self.counts
	local parts = {}
	for _, name in ipairs({ "error", "warning", "hint" }) do
		if counts[name] > 0 then
			parts[#parts + 1] = string.format("%d %s%s", counts[name], name, counts[name] == 1 and "" or "s")
		end
	end
	local isOk = counts.error == 0
	local found = #parts > 0 and table.concat(parts, ", ") or "nothing to report"
	-- The diagnostics went to stdout, which is buffered when it is a pipe, and this goes to stderr,
	-- which is not: without the flush the summary arrives first in any log that merges the two.
	io.stdout:flush()
	io.stderr:write(string.format("lye: %d file%s checked, %s\n", files, files == 1 and "" or "s",
		isOk and paint(self, "good", found) or paint(self, "bad", found)))
end

return report
