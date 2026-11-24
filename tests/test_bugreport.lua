-- Tests for the pure parts of LM_BugReport.lua. Run: luajit tests/test_bugreport.lua
local here = (arg and arg[0] or ""):gsub("[^\\/]*$", "")
dofile(here .. "../LM_BugReport.lua")
local M = LM_BugReport

local fails = 0
local function check(ok, msg)
	print((ok and "ok   " or "FAIL ") .. msg)
	if not ok then fails = fails + 1 end
end

-- Scrubbing
local game = [[C:\Games\Might and Magic Merge]]
local s = M.scrub_paths([[C:\Games\Might and Magic Merge\Scripts\General\LM_Gamepad.lua:12: boom]], { game })
check(s == [[<game>\Scripts\General\LM_Gamepad.lua:12: boom]], "game folder becomes <game>: " .. s)
s = M.scrub_paths("c:/games/might and magic merge/Scripts/x.lua", { game })
check(s == "<game>/Scripts/x.lua", "forward slashes and case: " .. s)
s = M.scrub_paths([[C:\\Games\\Might and Magic Merge\\Scripts]], { game })
check(s == [[<game>\\Scripts]], "escaped backslashes: " .. s)
s = M.scrub_paths([[D:\Elsewhere\MM\Scripts\General\a.lua:3: x]], { game })
check(s == [[<game>\Scripts\General\a.lua:3: x]], "other game folder still scrubbed: " .. s)
s = M.scrub_paths([[C:\Users\someone\AppData\x.txt and /home/other/y]], {})
check(s == [[<user>\AppData\x.txt and <user>/y]], "user folders: " .. s)
check(not M.scrub_paths([[Users C:\Users\Zed Name\x]], {}):find("Zed"), "user name is gone")
check(M.scrub_paths("nothing to hide", { game }) == "nothing to hide", "plain text untouched")

-- Ring buffer
M.errors = {}
for i = 1, 40 do M.record("t", "e" .. i) end
check(#M.errors == M.MAX_ERRORS and M.errors[1].text == "e16", "ring buffer keeps the newest " .. M.MAX_ERRORS)
M.record("t", "e40")
check(M.errors[#M.errors].count == 2, "a repeated error is counted, not listed twice")
M.record("t", ("x"):rep(5000))
check(#M.errors[#M.errors].text < 1600, "a long error is cut")

-- Link building
local long = ("line of report text with <odd> & chars %\n"):rep(2000)
local url, trimmed = M.issue_url({ report = long, title = "Bug: map", description = "note" })
check(#url <= M.MAX_URL and trimmed, "long report is trimmed to the limit (" .. #url .. ")")
check(url:find("^https://github.com/damptoast/might%-and%-gamepad/issues/new%?template=bug_report%.yml&title=") ~= nil, "link starts with the issue form")
check(url:find("trimmed%%20to%%20fit") ~= nil, "trim marker present")
url, trimmed = M.issue_url({ report = "short", title = "t" })
check(not trimmed and url:find("report=short$") ~= nil, "short report is not trimmed")
url, trimmed = M.issue_url({ report = long, description = ("n"):rep(5000), max = 800 })
check(#url <= 800, "huge note and report still fit a small limit (" .. #url .. ")")
check(M.url_encode("a b&c%") == "a%20b%26c%25", "url encoding")
url = M.issue_url({ report = "x", repo = "https://example.invalid/a/b/" })
check(url:find("^https://example%.invalid/a/b/issues/new") ~= nil, "repo override, trailing slash dropped")

-- Report text
local text = M.format_report({
	pack = "test", map = "Dagger Wound", screen = 0, scripts = { "LM_Gamepad", "LM_SkipIntro" },
	pad = { overlay = true, connected = true, layout = 15, look = 1, grid = 32, move = "smooth", buttons = 0x1000 },
	errors = { { time = "t", kind = "print", text = game .. [[\Scripts\a.lua:1: oops]], count = 2 } },
	log = { "10:00:00 pad=none game=found" },
}, { game })
check(text:find([[<game>\Scripts\a.lua:1: oops]], 1, true) ~= nil and not text:find("Games", 1, true), "report is scrubbed")
check(text:find("Enabled scripts (2):", 1, true) and text:find("LM_Gamepad, LM_SkipIntro", 1, true), "scripts listed")
check(text:find("buttons 0x1000", 1, true) ~= nil, "pad info listed")
check(#M.tail_lines("a\nb\nc\nd\n", 2) == 2 and M.tail_lines("a\nb\nc\nd\n", 2)[2] == "d", "tail_lines")

print(fails == 0 and "\nall passed" or ("\n" .. fails .. " check(s) failed"))
os.exit(fails == 0 and 0 or 1)
