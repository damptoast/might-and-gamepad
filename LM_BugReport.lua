-- Bug report for the Merge pad mod.
--
-- Extra settings > Controller > "Report a bug" builds a report (mod and pack
-- version, enabled scripts, recent errors, pad info), then:
--   * copies it to the clipboard,
--   * saves it as lm-bug-report.txt in the game folder,
--   * opens a prefilled GitHub issue (the link is trimmed to fit).
-- Folder names are replaced with <game> or <user> first.
--
-- Everything above the "if not Game" line runs in plain LuaJIT for the tests.

LM_BugReport = LM_BugReport or {}
local M = LM_BugReport

M.VERSION = "1.0.0"

M.REPO_URL = "https://github.com/damptoast/might-and-gamepad"

M.ISSUE_TEMPLATE = "bug_report.yml"
M.REPORT_FILE = "lm-bug-report.txt"
M.OVERLAY_LOG = "LM_MMMerge.log"
M.MAX_ERRORS = 25
M.MAX_ERROR_CHARS = 1500
M.MAX_LOG_LINES = 20
M.MAX_URL = 7000
M.TRIM_MARKER = "\n[...trimmed to fit the link. The full report is on your clipboard and saved as "
	.. M.REPORT_FILE .. " in the game folder.]"

-- Recent errors (ring buffer)

M.errors = M.errors or {}

local function utc_now()
	return os.date("!%Y-%m-%d %H:%M:%SZ")
end

function M.record(kind, text)
	text = tostring(text == nil and "" or text)
	if #text > M.MAX_ERROR_CHARS then
		text = text:sub(1, M.MAX_ERROR_CHARS) .. " [...]"
	end
	local list = M.errors
	local last = list[#list]
	if last and last.kind == kind and last.text == text then
		last.count = last.count + 1
		last.time = utc_now()
		return last
	end
	last = { time = utc_now(), kind = kind, text = text, count = 1 }
	list[#list + 1] = last
	while #list > M.MAX_ERRORS do
		table.remove(list, 1)
	end
	return last
end

-- Scrubbing folder names out of the report

-- Same length as the input, so positions line up with the original text.
local function norm(s)
	return (s:gsub("\\", "/"):lower())
end

local function replace_plain_nocase(text, needle, with)
	if needle == "" then return text end
	local out, pos = {}, 1
	local hay = norm(text)
	while true do
		local a, b = hay:find(needle, pos, true)
		if not a then break end
		out[#out + 1] = text:sub(pos, a - 1)
		out[#out + 1] = with
		pos = b + 1
	end
	out[#out + 1] = text:sub(pos)
	return table.concat(out)
end

function M.scrub_paths(text, roots)
	local out = tostring(text == nil and "" or text)
	local variants = {}
	for _, root in ipairs(roots or {}) do
		local r = norm(tostring(root)):gsub("/+$", "")
		if r ~= "" then
			variants[#variants + 1] = r
			variants[#variants + 1] = (r:gsub("/", "//")) -- escaped backslashes
		end
	end
	table.sort(variants, function(a, b) return #a > #b end)
	for _, v in ipairs(variants) do
		out = replace_plain_nocase(out, v, "<game>")
	end
	-- Whatever still points into a game folder.
	out = out:gsub("[A-Za-z]:[\\/][^'\"<>|\r\n]-([\\/]Scripts[\\/])", function(tail)
		return "<game>" .. tail
	end)
	out = out:gsub("[A-Za-z]:[\\/]+Users[\\/]+[^\\/'\"<>|)]+", "<user>")
	out = out:gsub("/Users/[^/%s'\"<>|)]+", "<user>")
	out = out:gsub("/home/[^/%s'\"<>|)]+", "<user>")
	return out
end

-- The issue link

function M.url_encode(s)
	return (tostring(s):gsub("[^%w%-%._~]", function(c)
		return ("%%%02X"):format(c:byte())
	end))
end

function M.ascii(s)
	return (tostring(s):gsub("[\128-\255]", "?"))
end

-- The title, note and report are separate fields of
-- .github/ISSUE_TEMPLATE/bug_report.yml; the ids here match it.
-- Returns url, trimmed.
function M.issue_url(opts)
	local max = opts.max or M.MAX_URL
	local repo = tostring(opts.repo or M.REPO_URL):gsub("/+$", "")
	local base = repo .. "/issues/new?template=" .. M.url_encode(M.ISSUE_TEMPLATE)
	local title = M.ascii(opts.title or "Bug report"):sub(1, 100)
	local desc = M.ascii(opts.description or ""):sub(1, 600)
	local report = M.ascii(opts.report or "")

	local function build(rep, d)
		return base .. "&title=" .. M.url_encode(title)
			.. "&description=" .. M.url_encode(d)
			.. "&report=" .. M.url_encode(rep)
	end

	local url = build(report, desc)
	if #url <= max then return url, false end

	local lo, hi = 0, #report
	while lo < hi do
		local mid = math.ceil((lo + hi) / 2)
		if #build(report:sub(1, mid) .. M.TRIM_MARKER, desc) <= max then
			lo = mid
		else
			hi = mid - 1
		end
	end
	url = build(report:sub(1, lo) .. M.TRIM_MARKER, desc)
	if #url > max then
		-- Even an empty report does not fit beside this note.
		url = build(M.TRIM_MARKER, desc)
		while #url > max and #desc > 0 do
			desc = desc:sub(1, math.max(0, #desc - math.ceil((#url - max) / 3)))
			url = build(M.TRIM_MARKER, desc)
		end
	end
	return url, true
end

-- The report text

function M.format_report(info, roots)
	local L = {}
	local function add(s) L[#L + 1] = s end
	add("Merge pad mod bug report")
	add("Mod version: " .. tostring(info.version or M.VERSION))
	add("Date (UTC): " .. tostring(info.time or utc_now()))
	add("Pack version: " .. tostring(info.pack or "(unknown)"))
	add("Map: " .. tostring(info.map or "(unknown)") .. "   Screen: " .. tostring(info.screen or "?"))
	local p = info.pad
	if p then
		add(("Pad: overlay %s, controller %s, layout %s, speed %s, grid %s, mouse %s, buttons 0x%04X"):format(
			p.overlay and "linked" or "not linked",
			p.connected and "connected" or "not found",
			tostring(p.layout), tostring(p.look), tostring(p.grid), tostring(p.move),
			tonumber(p.buttons) or 0))
	else
		add("Pad: (not available)")
	end
	add("")
	local scripts = info.scripts or {}
	add("Enabled scripts (" .. #scripts .. "):")
	add("  " .. (#scripts > 0 and table.concat(scripts, ", ") or "(unknown)"))
	add("")
	local errors = info.errors or {}
	add("Recent errors (" .. #errors .. "):")
	if #errors == 0 then add("  (none recorded)") end
	for _, e in ipairs(errors) do
		add("  [" .. tostring(e.time) .. "] " .. tostring(e.kind)
			.. ((e.count or 1) > 1 and (" x" .. e.count) or ""))
		add("    " .. tostring(e.text):gsub("\r?\n", "\n    "))
	end
	add("")
	local log = info.log or {}
	add("Overlay log (last " .. #log .. " lines):")
	if #log == 0 then add("  (empty)") end
	for _, line in ipairs(log) do add("  " .. line) end
	return M.scrub_paths(M.ascii(table.concat(L, "\n") .. "\n"), roots)
end

-- Last n lines of a text, as a list.
function M.tail_lines(text, n)
	local lines = {}
	for line in tostring(text):gmatch("[^\r\n]+") do lines[#lines + 1] = line end
	local out = {}
	for i = math.max(1, #lines - n + 1), #lines do out[#out + 1] = lines[i] end
	return out
end

-- Game only from here on

if not Game then return end

local ffi = require("ffi")
pcall(ffi.cdef, [[
typedef struct {
	unsigned long attr, ct[2], at[2], wt[2], sizeHigh, sizeLow, res0, res1;
	char name[260];
	char alt[14];
} LM_FindData;
void *__stdcall FindFirstFileA(const char *, LM_FindData *);
int __stdcall FindNextFileA(void *, LM_FindData *);
int __stdcall FindClose(void *);
unsigned long __stdcall GetModuleFileNameA(void *, char *, unsigned long);
void *__stdcall GlobalAlloc(unsigned int, unsigned int);
void *__stdcall GlobalLock(void *);
int __stdcall GlobalUnlock(void *);
int __stdcall OpenClipboard(void *);
int __stdcall EmptyClipboard(void);
void *__stdcall SetClipboardData(unsigned int, void *);
int __stdcall CloseClipboard(void);
void *__stdcall ShellExecuteA(void *, const char *, const char *, const char *, const char *, int);
]])

local k32 = ffi.load("kernel32")
local user32 = ffi.load("user32")
local shell32 = ffi.load("shell32")

local function game_dir()
	if AppPath and AppPath ~= "" then return (AppPath:gsub("[\\/]+$", "")) end
	local buf = ffi.new("char[520]")
	local n = k32.GetModuleFileNameA(nil, buf, 520)
	if n > 0 then return (ffi.string(buf, n):gsub("[\\/][^\\/]*$", "")) end
	return ""
end

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function list_scripts()
	local out = {}
	local fd = ffi.new("LM_FindData")
	local h = k32.FindFirstFileA(game_dir() .. "\\Scripts\\General\\*.lua", fd)
	if h == nil or h == ffi.cast("void *", -1) then return out end
	repeat
		out[#out + 1] = ffi.string(fd.name):gsub("%.lua$", "")
	until k32.FindNextFileA(h, fd) == 0
	k32.FindClose(h)
	table.sort(out)
	return out
end

local function pack_version()
	for _, get in ipairs({
		function() return Merge.Version end,
		function() return Merge.Settings.Version end,
		function() return Game.Version end,
	}) do
		local ok, v = pcall(get)
		if ok and v and tostring(v) ~= "" then return tostring(v) end
	end
	return nil
end

local function overlay_log_lines()
	local text = read_file(game_dir() .. "\\" .. M.OVERLAY_LOG)
	return text and M.tail_lines(text, M.MAX_LOG_LINES) or {}
end

function M.collect_info()
	local info = { version = M.VERSION, time = utc_now() }
	info.pack = pack_version()
	pcall(function() info.map = Map.Name end)
	pcall(function() info.screen = Game.CurrentScreen end)
	local ok, p = pcall(function() return LM_PadInfo and LM_PadInfo() end)
	info.pad = ok and p or nil
	local sok, scripts = pcall(list_scripts)
	info.scripts = sok and scripts or {}
	info.errors = M.errors
	info.log = overlay_log_lines()
	return info
end

function M.copy(text)
	local ok = false
	pcall(function()
		local mem = k32.GlobalAlloc(2, #text + 1) -- GMEM_MOVEABLE
		if mem == nil then return end
		local p = k32.GlobalLock(mem)
		ffi.copy(p, text, #text + 1)
		k32.GlobalUnlock(mem)
		if user32.OpenClipboard(nil) ~= 0 then
			user32.EmptyClipboard()
			ok = user32.SetClipboardData(1, mem) ~= nil -- CF_TEXT
			user32.CloseClipboard()
		end
	end)
	return ok
end

function M.save(text)
	local path = game_dir() .. "\\" .. M.REPORT_FILE
	local f = io.open(path, "wb")
	if not f then return nil end
	f:write(text)
	f:close()
	return path
end

function M.open_url(url)
	-- explorer takes the address as it is; the shell would eat & and %.
	local r = shell32.ShellExecuteA(nil, "open", "explorer.exe", '"' .. url .. '"', nil, 1)
	return tonumber(ffi.cast("intptr_t", r)) > 32
end

local function status(text)
	pcall(Game.ShowStatusText, text, 4)
end

function M.send()
	local roots = { game_dir() }
	local ok, info = pcall(M.collect_info)
	if not ok then info = { version = M.VERSION, errors = M.errors, scripts = {}, log = {} } end
	local report = M.format_report(info, roots)
	local copied = M.copy(report)
	local file = M.save(report)
	local url = M.issue_url({ title = "Bug: " .. tostring(info.map or "in game"), report = report })
	local opened = M.open_url(url)
	local done = {}
	if copied then done[#done + 1] = "copied" end
	if file then done[#done + 1] = "saved " .. M.REPORT_FILE end
	if opened then done[#done + 1] = "issue page opened" end
	status("Bug report: " .. (#done > 0 and table.concat(done, ", ") or "could not be sent"))
	M.last = { report = report, url = url, copied = copied, file = file, opened = opened }
	return M.last
end

-- Error capture

if not M._hooked then
	M._hooked = true

	-- print() is where MMExtension reports script errors.
	local orig_print = print
	print = function(...)
		local args = { n = select("#", ...), ... }
		pcall(function()
			local parts = {}
			for i = 1, args.n do parts[#parts + 1] = tostring(args[i]) end
			local text = table.concat(parts, "\t")
			local low = text:lower()
			if low:find("error", 1, true) or low:find("traceback", 1, true)
					or low:find("attempt to", 1, true) then
				M.record("print", text)
			end
		end)
		return orig_print(...)
	end

	if events then
		for _, name in ipairs({ "LuaError", "ScriptError" }) do
			pcall(function()
				events[name] = function(...)
					local parts = {}
					for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
					M.record(name, table.concat(parts, " "))
				end
			end)
		end
	end
end
