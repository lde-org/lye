--[[
	Running a batch of files in several processes.

	A check reads a project's worth of tables and exits when it is done, and one file's diagnostics
	do not depend on another's analysis once the names the whole batch is read against are known:
	they depend on what the batch declares and on what the modules the file requires come to. So the
	files are handed out in groups across as many processes as the machine has cores, and this
	module gives back what they found in the order one process would have found it.

	`fork` is the cheap way to get those processes: a child starts with the definitions, the parsed
	annotations and the JIT's traces already made, where starting another `lye` would read all of it
	again. Windows has none, so the batch runs in one process there.
]]

local report = require("lye-lsp.report")
local ffi = require("ffi")

local parallel = {}

pcall(ffi.cdef, [[
	int fork(void);
	int waitpid(int pid, int *status, int options);
	int getpid(void);
	void _exit(int status);
	long sysconf(int name);
]])

--- Whether this machine can run a batch in several processes. The symbol is looked up rather than
--- assumed, the way every other call to a symbol some systems do not have is.
local HAS_FORK = ffi.os ~= "Windows" and pcall(function() return ffi.C.fork end)

--- This process's pid, which names the files a batch's workers write their findings to.
local PID = 0
do
	local ok, value = pcall(function() return ffi.C.getpid() end)
	if ok then PID = tonumber(value) or 0 end
end

--- As many processors as the machine will admit to, and 4 when it will not say.
local function cpuCount()
	-- _SC_NPROCESSORS_ONLN: 84 on Linux and Android, 58 on the BSDs and macOS.
	for _, name in ipairs({ 84, 58 }) do
		local ok, value = pcall(function() return tonumber(ffi.C.sysconf(name)) end)
		---@cast value integer?
		if ok and value and value >= 1 then return value end
	end
	return 4
end

--- Whether this machine can fork at all. A caller that does something other than checking files —
--- building an index, say — asks before it plans for more than one process.
function parallel.canFork()
	return HAS_FORK
end

--- This process's pid, which names the files a forked worker writes.
function parallel.pid()
	return PID
end

--- As many processors as this machine will admit to.
function parallel.cores()
	return cpuCount()
end

--- The most processes a batch of this many files is worth splitting across, or 1 for one process.
--- Below a handful of files the processes cost more than they save; `LYE_WORKERS` says otherwise,
--- and `LYE_WORKERS=1` turns the split off.
---@param files integer
function parallel.workers(files)
	local wanted = tonumber(os.getenv("LYE_WORKERS") or "")
	if wanted and wanted >= 1 then return math.max(1, math.min(wanted, files)) end
	if files < 8 or not HAS_FORK then return 1 end
	return math.max(1, math.min(cpuCount(), 8, files))
end

--- Where a worker writes what it found, so the process that started it can read it back.
---@param index integer
local function outPath(index)
	local dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
	return string.format("%s/lye-check-%d-%d.out", dir, PID, index)
end

--- One record's field: a tab or a newline inside a message — or a path, which is only ever as odd
--- as a file name can be — would otherwise end the field or the line early.
---@param text string
local function escaped(text)
	return (text:gsub("[\\\t\r\n]", { ["\\"] = "\\\\", ["\t"] = "\\t", ["\r"] = "\\r", ["\n"] = "\\n" }))
end

---@param text string
local function unescaped(text)
	return (text:gsub("\\(.)", { t = "\t", r = "\r", n = "\n", ["\\"] = "\\" }))
end

--- The fields of one record line, split at the tabs that were not escaped.
---@param line string
local function fieldsOf(line)
	local fields = {} ---@type string[]
	for field in (line .. "\t"):gmatch("([^\t]*)\t") do
		---@cast field string
		fields[#fields + 1] = field
	end
	return fields
end

--- A number read back from a record line: the fields written down are whole ones — a line, a
--- column, a severity — and a reader of the report is given integers rather than whatever
--- `tonumber` says a string is.
---@param field string?
local function wholeOf(field)
	local value = field and tonumber(field)
	return value and math.floor(value) or nil
end

--- The findings of one batch, by path, in the order they were found.
---@alias lye.parallel.Found table<string, lye.Report.Finding[]>

--- A unit of work that one process holds together: the files of one package, which read the same
--- linked names and resolve one another in the order they are written.
---@class lye.parallel.Group
---@field files string[]
---@field sizes integer[] how many bytes each file is, parallel to `files`
---@field bytes integer

--- What one process was handed.
---@class lye.parallel.Slice
---@field files string[]
---@field bytes integer
---@field out string where its findings are written
---@field pid integer? the process that took it, when one was forked for it
---@field ranInParent boolean? whether this process ran the slice itself, after a child failed or because it kept it

---@param found lye.parallel.Found
---@param entry lye.Report.Finding
local function add(found, entry)
	local list = found[entry.path]
	if not list then
		list = {}
		found[entry.path] = list
	end
	list[#list + 1] = entry
end

---@param found lye.parallel.Found
---@param entries lye.Report.Finding[]
local function keep(found, entries)
	for _, entry in ipairs(entries) do add(found, entry) end
end

--- Run one slice of the batch in this process, writing what it found where the caller will read
--- it. A slice whose findings have no file to go in — a temp directory that will not take a write
--- — hands them back instead: a worker cannot print into a report it does not own, so it says so
--- and the process that started it checks that slice itself.
---@param slice lye.parallel.Slice
---@param check fun(files: string[], report: lye.Collector) what a worker does with its files
local function runSlice(slice, check)
	local collector = report.collect()
	check(slice.files, collector)
	local handle = io.open(slice.out, "wb")
	if handle then
		for _, entry in ipairs(collector.collect) do
			if entry.err then
				handle:write("x\t", escaped(entry.path), "\t", escaped(entry.err), "\n")
			else
				handle:write("d\t", escaped(entry.path), "\t", tostring(entry.line or 1), "\t",
					tostring(entry.column or 1), "\t", entry.severity and tostring(entry.severity) or "", "\t",
					escaped(entry.message), "\n")
			end
		end
		-- A write that fails halfway is not a result: closing says whether it all went out.
		if handle:close() == true then return nil end
	end
	return collector.collect
end

--- Wait for one child and say what it ended with: its exit code, or nothing when a signal ended it.
---@param pid integer
local function waitFor(pid)
	local status = ffi.new("int[1]")
	---@cast status ffi.ptr<ffi.int>
	while true do
		local waited = ffi.C.waitpid(pid, status, 0)
		if waited == pid then
			-- The low byte carries a signal in place of an exit code.
			if status[0] % 256 ~= 0 then return nil end
			return math.floor(status[0] / 256) % 256
		end
		-- EINTR: a signal arrived, and the child is still the one being waited for.
		if waited == -1 and ffi.errno() ~= 4 then return nil end
	end
end

--- Hand the groups out to as many slices as there are workers. A group is the unit a worker's
--- module cache works in — a package's files resolve one another and read the same linked names —
--- so it stays whole when it fits; a group larger than one worker's share of the batch is split
--- into pieces in the order its files were written, because one package holding most of the batch
--- is what leaves every other worker waiting for it. The largest piece goes onto the lightest
--- slice, so no worker is handed twice what another was.
---@param groups lye.parallel.Group[]
---@param workers integer
---@param outOf fun(index: integer): string? where each slice's answer is written; the check batch's
--- own files when a caller does not say
local function splitWork(groups, workers, outOf)
	local total = 0
	for _, group in ipairs(groups) do total += group.bytes end
	local share = math.max(math.floor(total / workers), 1)

	local pieces = {}
	for _, group in ipairs(groups) do
		local files, bytes = {}, 0
		for index, path in ipairs(group.files) do
			local size = group.sizes and group.sizes[index] or 0
			if #files > 0 and bytes + size > share then
				pieces[#pieces + 1] = { files = files, bytes = bytes }
				files, bytes = {}, 0
			end
			files[#files + 1] = path
			bytes += size
		end
		if #files > 0 then pieces[#pieces + 1] = { files = files, bytes = bytes } end
	end

	local slices = {} ---@type lye.parallel.Slice[]
	for index = 1, workers do
		slices[index] = { files = {}, bytes = 0, out = outOf and outOf(index) or outPath(index) }
		-- A file left over from a run this pid happens to repeat would read as this run's result.
		os.remove(slices[index].out)
	end
	table.sort(pieces, function(a, b) return a.bytes > b.bytes end)
	for _, piece in ipairs(pieces) do
		local lightest = slices[1]
		for index = 2, workers do
			if slices[index].bytes < lightest.bytes then lightest = slices[index] end
		end
		for _, path in ipairs(piece.files) do lightest.files[#lightest.files + 1] = path end
		lightest.bytes += piece.bytes
	end
	for _, slice in ipairs(slices) do table.sort(slice.files) end
	return slices
end

--- Hand the groups out as slices, for a caller that writes something other than diagnostics — an
--- index record, say — and runs the slices itself.
parallel.splitWork = splitWork

--- Run a slice's work in a forked child, and the slice this process keeps while the children run.
--- `work` writes wherever the slice says its answer goes and returns whether it did. A child that
--- ends with anything but success leaves its slice to this process, which runs it again: a caller
--- that merges what the children wrote never sees a missing shard.
---@param slices lye.parallel.Slice[]
---@param work fun(slice: lye.parallel.Slice, index: integer, isChild: boolean): boolean
---@param spawn fun(): integer? process creation, injectable for a test that watches or refuses it
---@return integer workers how many processes ran a slice
---@return integer fellBack how many slices a failed child left to this process
function parallel.dispatch(slices, work, spawn)
	spawn = spawn or function() return ffi.C.fork() --[[@as integer? ]] end

	-- Everything this process has buffered goes out before a copy of it exists, so a child that
	-- writes cannot echo it a second time.
	io.stdout:flush()
	io.stderr:flush()

	local started = 0
	for index = 2, #slices do
		local slice = slices[index]
		if #slice.files == 0 then break end
		local pid = spawn()
		---@cast pid integer?
		if pid == 0 then
			-- The child. It must not come back: returning would run the rest of this process's
			-- work a second time, in a process the parent is not watching.
			ffi.C._exit(work(slice, index, true) and 0 or 2)
		end
		if pid and pid > 0 then
			slice.pid = pid
			started += 1
		else
			-- No fork: the rest of the slices are this process's to run.
			break
		end
	end

	local fellBack = 0
	-- The slice this process keeps is worked while the children run, so no core sits idle.
	for index, slice in ipairs(slices) do
		if not slice.pid and #slice.files > 0 then
			slice.ranInParent = true
			work(slice, index, false)
		end
	end

	for index, slice in ipairs(slices) do
		if slice.pid then
			if waitFor(slice.pid) ~= 0 then
				-- A worker that could not write its record leaves its files to this process.
				fellBack += 1
				slice.ranInParent = true
				work(slice, index, false)
			end
		end
	end
	return 1 + started, fellBack
end

--- Read back one worker's findings: one record per line, the fields split at their tabs, and a
--- diagnostic or a file's own error by the letter it starts with.
---@param found lye.parallel.Found
---@param file string
---@return boolean isRead
local function absorb(found, file)
	local handle = io.open(file, "rb")
	if not handle then return false end
	local text = handle:read("*a") or ""
	handle:close()
	os.remove(file)
	for line in text:gmatch("[^\n]+") do
		local textLine = line --[[@as string ]]
		local fields = fieldsOf(textLine)
		if fields[1] == "d" then
			add(found, {
				path = unescaped(fields[2]), line = wholeOf(fields[3]), column = wholeOf(fields[4]),
				severity = wholeOf(fields[5]), message = unescaped(fields[6] or ""),
			})
		elseif fields[1] == "x" then
			add(found, { path = unescaped(fields[2]), err = unescaped(fields[3] or "") })
		end
	end
	return true
end

--- Check a batch across processes and give back what came of it, by path, in the order its
--- diagnostics were found: what one process checking every group in one go would have found.
---@param groups lye.parallel.Group[] the files, in the units one process has to hold together
---@param workers integer
---@param check fun(files: string[], report: lye.Collector) what a worker does with its files
function parallel.run(groups, workers, check)
	local found = {}

	local paths = {}
	for _, group in ipairs(groups) do
		for _, path in ipairs(group.files) do paths[#paths + 1] = path end
	end

	-- One process: a batch too small to be worth splitting, or a machine without `fork`.
	if workers <= 1 then
		local collector = report.collect()
		check(paths, collector)
		keep(found, collector.collect)
		return found
	end

	local slices = splitWork(groups, workers)

	-- Everything this process has buffered goes out before a copy of it exists, so a child that
	-- writes cannot echo it a second time.
	io.stdout:flush()
	io.stderr:flush()

	for index = 2, #slices do
		local slice = slices[index]
		if #slice.files == 0 then break end
		local pid = ffi.C.fork()
		if pid == 0 then
			-- The child. It must not come back: returning would run the rest of this process's
			-- work a second time, in a process the parent is not watching. 2 says its findings had
			-- no file to go in, which is the one outcome the parent checks again itself.
			ffi.C._exit(runSlice(slice, check) == nil and 0 or 2)
		end
		if pid > 0 then
			slice.pid = pid
		else
			-- No fork: the slice this one was for is this process's to check.
			break
		end
	end

	-- The slice this process keeps is checked while the children run, so no core sits idle: its
	-- findings are read back like any worker's, and kept here when it had no file to write them to.
	for _, slice in ipairs(slices) do
		if not slice.pid and #slice.files > 0 then
			local unwritten = runSlice(slice, check)
			if unwritten then
				keep(found, unwritten)
			else
				absorb(found, slice.out)
			end
		end
	end

	for _, slice in ipairs(slices) do
		if slice.pid then
			local code = waitFor(slice.pid)
			-- 0 is a result file to read. Anything else — a worker that could not write one, or one
			-- a signal ended — leaves its files unchecked, and a check that quietly skipped them is
			-- worse than one that takes longer: they are checked here instead.
			if code ~= 0 or not absorb(found, slice.out) then
				local unwritten = runSlice(slice, check)
				if unwritten then keep(found, unwritten) end
			end
		end
	end
	return found
end

return parallel
