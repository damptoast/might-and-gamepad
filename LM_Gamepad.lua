-- Might and Magic Merge pad support. LM_MMMerge.exe reads the pad and puts its
-- state in shared memory; this script turns it into keys, clicks and game actions.
-- Right stick is the cursor (smooth or grid, R3 tap toggles), stick tilt sets speed.
-- Fixed combos, not in the bind menu: Back+Start+Y quits, R3+D-pad speed/grid.

local ffi = require("ffi")
pcall(ffi.cdef, [[
typedef void* HANDLE;
HANDLE __stdcall OpenFileMappingA(unsigned long, int, const char*);
void* __stdcall MapViewOfFile(HANDLE, unsigned long, unsigned long, unsigned long, unsigned long);
typedef struct {
	unsigned int magic;
	unsigned int seq;
	unsigned short buttons;
	unsigned char lt, rt;
	short lx, ly, rx, ry;
	unsigned int connected;
} PadShared;
void __stdcall ExitProcess(unsigned int);
void __stdcall keybd_event(unsigned char, unsigned char, unsigned long, unsigned long);
void __stdcall mouse_event(unsigned long, long, long, unsigned long, unsigned long);
int __stdcall GetForegroundWindow(void);
int __stdcall GetClientRect(void*, void*);
int __stdcall ClientToScreen(void*, void*);
int __stdcall SetCursorPos(int, int);
int __stdcall PostMessageA(void*, unsigned int, unsigned int, long);
unsigned int __stdcall MapVirtualKeyA(unsigned int, unsigned int);
typedef struct { long left, top, right, bottom; } RECT;
typedef struct { long x, y; } POINT;
]])

local bit = require("bit")
local k32 = ffi.load("kernel32")
local user32 = ffi.load("user32")

local BTN_DPAD_UP, BTN_DPAD_DOWN = 0x0001, 0x0002
local BTN_DPAD_LEFT, BTN_DPAD_RIGHT = 0x0004, 0x0008
local BTN_START, BTN_BACK = 0x0010, 0x0020
local BTN_L3, BTN_R3 = 0x0040, 0x0080
local BTN_LB, BTN_RB = 0x0100, 0x0200
local BTN_A, BTN_B, BTN_X, BTN_Y = 0x1000, 0x2000, 0x4000, 0x8000
local MAGIC = 0x44504D4C
local KEYUP = 2

local pad, mapH
local held = {}
local prev = 0
local lmb, rmb = false, false
local last_screen = -1
local snap_cx, snap_cy = 320, 240
local look_sens = 1.0
local r3_used = false
local rmb_toggle = false
local extra_return_screen = 2
local pad_bg_poly
local cur_block = 1
local rt_held = false
local nav_cui = false
local grid_next = 0
local GRID_MS = 120

local cfg_path = (AppPath or "") .. "LM_Gamepad.ini"

local move_mode = "smooth"
local grid_size = 32
local binds = {}
local BIND_LAYOUT = 15
local map_held = {}
local listen_act = nil
local listen_wait_release = false
local pad_speed_txt, pad_grid_txt, pad_page_txt
-- Triggers: low press threshold + hysteresis so soft Xbox/Steam pads still chord.
local CHORD_ON = 40
local CHORD_OFF = 20
local prev_lt, prev_rt = 0, 0
local chord_lt, chord_rt = false, false

local BTN_NAMED = {
	{"DpadU", BTN_DPAD_UP}, {"DpadD", BTN_DPAD_DOWN},
	{"DpadL", BTN_DPAD_LEFT}, {"DpadR", BTN_DPAD_RIGHT},
	{"Start", BTN_START}, {"Back", BTN_BACK},
	{"L3", BTN_L3}, {"R3", BTN_R3},
	{"LB", BTN_LB}, {"RB", BTN_RB},
	{"A" , BTN_A}, {"B", BTN_B}, {"X", BTN_X}, {"Y", BTN_Y},
}

local BINDABLE = {
	A = true, B = true, X = true, Y = true,
	LB = true, RB = true, L3 = true, R3 = true,
	Start = true, Back = true,
	DpadU = true, DpadD = true, DpadL = true, DpadR = true,
}

local ACTIONS = {
	"click", "inspect", "back", "menu", "inventory", "stats", "skills", "awards", "attack",
	"cast", "rest", "always_run", "jump", "fly", "land", "fly_ls",
	"mouse_toggle", "mouse_look",
	"party_prev", "party_next", "map", "history",
	"stow", "loot_all",
}

-- Controls keys that should tap on press, not hold (info screens / toggles).
local EDGE_KEY_IDX = {
	[6] = true, [7] = true, [10] = true, [11] = true, [12] = true, [13] = true, [14] = true, [15] = true,
	[17] = true, [18] = true, [19] = true, [20] = true, [23] = true, [24] = true, [25] = true,
}

-- MM8 Game.KeyCodes[0..29] labels (same order as the Controls screen).
local KEYCODE_LABELS = {
	[0] = "Turn left", [1] = "Turn right", [2] = "Forward", [3] = "Backward",
	[4] = "Strafe left", [5] = "Strafe right", [6] = "Jump", [7] = "Fly",
	[8] = "Look up", [9] = "Look down", [10] = "Attack", [11] = "Cast ready",
	[12] = "Pass", [13] = "Next character", [14] = "Quick spell", [15] = "Always run",
	[16] = "Walk", [17] = "Rest", [18] = "Time/calendar", [19] = "Autonotes",
	[20] = "Map", [21] = "Look up 2", [22] = "Look down 2", [23] = "Center view",
	[24] = "Zoom in", [25] = "Zoom out", [26] = "Fly up", [27] = "Fly down",
	[28] = "Fly left", [29] = "Fly right",
}

local bind_catalog = {}
local LIST_ROWS = 11
local list_page = 0
local list_rows = {}
local bind_lock_mask = 0
local click_lock = false

local function hard_quit()
	pcall(function() k32.ExitProcess(0) end)
end

local function extra_open()
	local s = Game.CurrentScreen
	return s == const.Screens.LMPadSettings
		or s == const.Screens.MergeExtraSettings
		or s == const.Screens.ExtraKeybinds
		or s == const.Screens.MergeInterfaceSettings
		or s == const.Screens.BolsterFineTuning
end

local function on_pad_settings()
	return const.Screens.LMPadSettings and Game.CurrentScreen == const.Screens.LMPadSettings
end

local function vk_name(vk)
	if not vk or vk == 0 then return "-" end
	if const and const.Keys then
		local n = table.find(const.Keys, vk)
		if n then return n end
	end
	return tostring(vk)
end

local function rebuild_catalog()
	bind_catalog = {}
	for i = 1, #ACTIONS do
		bind_catalog[#bind_catalog + 1] = {id = ACTIONS[i], label = ACTIONS[i]}
	end
	if Game and Game.KeyCodes then
		for i = 0, 29 do
			local vk = Game.KeyCodes[i]
			local lab = KEYCODE_LABELS[i] or ("Control " .. i)
			bind_catalog[#bind_catalog + 1] = {
				id = "key:" .. i,
				label = lab .. " [" .. vk_name(vk) .. "]",
				kind = "key",
				idx = i,
			}
		end
	end
	local extra = Merge and Merge.Tables and Merge.Tables.ExtraKeyBinds
	if extra then
		for i, v in ipairs(extra) do
			bind_catalog[#bind_catalog + 1] = {
				id = "xkey:" .. i,
				label = (v.Label or ("Extra " .. i)) .. " [" .. vk_name(v.Key) .. "]",
				kind = "xkey",
				idx = i,
			}
		end
	end
end

local function default_binds()
	return {
		A = "click",
		B = "back",
		X = "attack",
		Y = "key:14", -- Quick spell
		LB = "click",
		RB = "inspect",
		Start = "menu",
		Back = "map",
		L3 = "mouse_look",
		R3 = "mouse_toggle",
		DpadL = "party_prev",
		DpadR = "party_next",
		DpadU = "inventory",
		DpadD = "stats",
		["LT+A"] = "xkey:1",
		["LT+B"] = "xkey:2",
		["LT+X"] = "xkey:3",
		["LT+Y"] = "xkey:4",
		["LT+DpadL"] = "xkey:6",
		["LT+DpadR"] = "xkey:7",
		["LT+DpadU"] = "xkey:8",
		["LT+DpadD"] = "xkey:9",
		["LT+Start"] = "xkey:5",
		["LT+Back"] = "key:18", -- Calendar
		["LT+L3"] = "fly",
		["LT+R3"] = "key:24", -- Zoom in
		["RT+A"] = "key:12", -- Pass
		["RT+B"] = "cast",
		["RT+X"] = "jump",
		["RT+Y"] = "rest",
		["RT+LB"] = "key:12",
		["RT+Start"] = "history",
		["RT+Back"] = "key:19", -- Autonotes
		["RT+L3"] = "land",
		["RT+R3"] = "key:25", -- Zoom out
		["RT+DpadL"] = "skills",
		["RT+DpadR"] = "awards",
		["LT+RT+A"] = "key:11", -- Cast ready
		["LT+RT+X"] = "always_run",
		["LT+RT+L3"] = "fly_ls",
		["LT+RT+R3"] = "key:23", -- Center view
		["LT+RT+DpadU"] = "key:26", -- Fly up
		["LT+RT+DpadD"] = "key:27",
		["LT+RT+DpadL"] = "key:28",
		["LT+RT+DpadR"] = "key:29",
	}
end

local function update_chord_latches()
	if not pad then
		chord_lt, chord_rt = false, false
		return
	end
	local lt = tonumber(pad.lt) or 0
	local rt = tonumber(pad.rt) or 0
	if lt >= CHORD_ON then chord_lt = true
	elseif lt <= CHORD_OFF then chord_lt = false end
	if rt >= CHORD_ON then chord_rt = true
	elseif rt <= CHORD_OFF then chord_rt = false end
end

local function trig_held(v)
	return (tonumber(v) or 0) >= CHORD_ON
end

-- Chord prefix for the bind menu.
local function chord_prefix()
	if not pad then return "" end
	update_chord_latches()
	local l = chord_lt or trig_held(pad.lt)
	local r = chord_rt or trig_held(pad.rt)
	if l and r then return "LT+RT+" end
	if l then return "LT+" end
	if r then return "RT+" end
	return ""
end

local ACTION_LABELS = {
	click = "Click (LMB)",
	inspect = "Inspect (RMB toggle)",
	back = "Back / Esc",
	menu = "Menu / Esc",
	inventory = "Inventory",
	stats = "Stats sheet",
	skills = "Skills sheet",
	awards = "Awards sheet",
	attack = "Attack",
	cast = "Cast",
	rest = "Rest / wait",
	always_run = "Always run",
	jump = "Jump",
	fly = "Fly toggle",
	land = "Land",
	fly_ls = "Fly axes on left stick",
	mouse_look = "Mouse-look",
	mouse_toggle = "Cursor smooth/grid",
	party_prev = "Party prev",
	party_next = "Party next",
	map = "Map (world book)",
	history = "History book",
	stow = "Stow cursor item",
	loot_all = "Loot all (chest)",
	["key:6"] = "Jump (Controls)",
	["key:7"] = "Fly (Controls)",
	["key:10"] = "Attack (Controls)",
	["key:11"] = "Cast ready",
	["key:12"] = "Pass",
	["key:13"] = "Next character (Controls)",
	["key:14"] = "Quick spell",
	["key:15"] = "Always run (Controls)",
	["key:17"] = "Rest (Controls)",
	["key:18"] = "Calendar (day/time book)",
	["key:19"] = "Autonotes journal",
	["key:20"] = "Map (Controls)",
	["key:23"] = "Center view",
	["key:24"] = "Zoom in",
	["key:25"] = "Zoom out",
	["key:26"] = "Fly up",
	["key:27"] = "Fly down",
	["key:28"] = "Fly left",
	["key:29"] = "Fly right",
	["xkey:1"] = "Q.Spell 1",
	["xkey:2"] = "Q.Spell 2",
	["xkey:3"] = "Q.Spell 3",
	["xkey:4"] = "Q.Spell 4",
	["xkey:5"] = "NPC panel",
	["xkey:6"] = "NPC 1",
	["xkey:7"] = "NPC 2",
	["xkey:8"] = "NPC 3",
	["xkey:9"] = "NPC 4",
}

local function action_label(id)
	if not id then return "NOTHING (no bind / chord blocked)" end
	return ACTION_LABELS[id] or id
end

local function report_pad(btn, id)
	if not Game or not Game.ShowStatusText then return end
	update_chord_latches()
	local l = chord_lt or trig_held(pad and pad.lt)
	local r = chord_rt or trig_held(pad and pad.rt)
	local mode
	if l and r then mode = "CHORD LT+RT"
	elseif l then mode = "CHORD LT"
	elseif r then mode = "CHORD RT"
	else mode = "BARE (no chord)" end
	local lt = pad and (tonumber(pad.lt) or 0) or 0
	local rt = pad and (tonumber(pad.rt) or 0) or 0
	pcall(Game.ShowStatusText,
		("%s | %s = %s | lt=%d rt=%d"):format(mode, btn, action_label(id), lt, rt), 3)
end

-- Triggers are latched with hysteresis so a chord still counts when the button
-- lands on the same frame the trigger crosses the threshold.
local function bound_action(btn, edge)
	if not pad then return binds[btn] end
	update_chord_latches()
	local l = chord_lt or trig_held(pad.lt)
	local r = chord_rt or trig_held(pad.rt)
	if l and r and binds["LT+RT+" .. btn] then return binds["LT+RT+" .. btn] end
	if l and binds["LT+" .. btn] then return binds["LT+" .. btn] end
	if r and binds["RT+" .. btn] then return binds["RT+" .. btn] end
	-- Modifier held and this button has a chord we didn't match: don't fall through to bare.
	if (l or r) and (binds["LT+" .. btn] or binds["RT+" .. btn] or binds["LT+RT+" .. btn]) then
		return nil
	end
	return binds[btn]
end

local STICK_BINDS = {
	["key:26"] = "LT+RT+LS up",
	["key:27"] = "LT+RT+LS down",
	["key:28"] = "LT+RT+LS left",
	["key:29"] = "LT+RT+LS right",
	fly_ls = "LT+RT+left stick",
}

local function keys_for(act)
	local t = {}
	for k, a in pairs(binds) do
		if a == act then t[#t + 1] = k end
	end
	if STICK_BINDS[act] then t[#t + 1] = STICK_BINDS[act] end
	table.sort(t)
	return #t > 0 and table.concat(t, ", ") or "(none)"
end

local function page_count()
	if #bind_catalog == 0 then return 1 end
	return math.max(1, math.ceil(#bind_catalog / LIST_ROWS))
end

local function clamp_page()
	local n = page_count()
	if list_page < 0 then list_page = 0 end
	if list_page > n - 1 then list_page = n - 1 end
end

local function refresh_pad_ui()
	if pad_speed_txt then pad_speed_txt.Text = ("Speed %.1f"):format(look_sens) end
	if pad_grid_txt then pad_grid_txt.Text = ("Grid %d"):format(grid_size) end
	if #bind_catalog == 0 then rebuild_catalog() end
	clamp_page()
	if pad_page_txt then
		pad_page_txt.Text = ("Page %d / %d"):format(list_page + 1, page_count())
	end
	local base = list_page * LIST_ROWS
	for i = 1, LIST_ROWS do
		local row = list_rows[i]
		if row then
			local e = bind_catalog[base + i]
			if e then
				row.Text = e.label .. "   " .. keys_for(e.id)
				row.Active = true
			else
				row.Text = ""
				row.Active = false
			end
		end
	end
end

local function page_list(dir)
	rebuild_catalog()
	list_page = list_page + dir
	clamp_page()
	refresh_pad_ui()
end

local function save_cfg(quiet)
	local f = io.open(cfg_path, "w")
	if not f then
		pcall(Game.ShowStatusText, "Could not save LM_Gamepad.ini", 3)
		return false
	end
	f:write(("look=%.2f\ngrid=%d\nmove=%s\nlayout=%d\n"):format(
		look_sens, grid_size, move_mode, BIND_LAYOUT))
	local keys = {}
	for k in pairs(binds) do keys[#keys + 1] = k end
	table.sort(keys)
	for i = 1, #keys do
		f:write(("%s=%s\n"):format(keys[i], binds[keys[i]]))
	end
	f:close()
	refresh_pad_ui()
	if not quiet then
		pcall(Game.ShowStatusText, "Saved controller binds", 2)
	end
	return true
end

local function reset_defaults()
	binds = default_binds()
	look_sens = 1.0
	grid_size = 32
	move_mode = "smooth"
	listen_act = nil
	listen_wait_release = false
	save_cfg(true)
	pcall(Game.ShowStatusText, "Controller binds reset to defaults (saved)", 4)
	refresh_pad_ui()
end

local function load_cfg()
	binds = default_binds()
	local f = io.open(cfg_path, "r")
	if not f then return end
	local file_binds, had_bind, file_layout = {}, false, 0
	for line in f:lines() do
		local k, v = line:match("^([%w%+]+)%s*=%s*([%w%.:_]+)%s*$")
		if k and v then
			if k == "look" then look_sens = tonumber(v) or look_sens
			elseif k == "grid" then grid_size = math.floor(tonumber(v) or grid_size)
			elseif k == "move" then
				if v == "grid" or v == "smooth" then move_mode = v end
			elseif k == "layout" then file_layout = tonumber(v) or 0
			elseif k == "mouse" then
				-- old ini key, ignored
			else
				had_bind = true
				file_binds[k] = v
			end
		end
	end
	f:close()
	local migrated = false
	if had_bind then
		local base = default_binds()
		for k, v in pairs(file_binds) do base[k] = v end
		binds = base
		if file_layout < BIND_LAYOUT then
			-- ini from an older layout: start over from the defaults
			binds = default_binds()
			migrated = true
		end
	else
		binds = default_binds()
	end
	if look_sens < 0.3 then look_sens = 0.3 end
	if look_sens > 3.0 then look_sens = 3.0 end
	if grid_size < 8 then grid_size = 8 end
	if grid_size > 80 then grid_size = 80 end
	if migrated or file_layout < BIND_LAYOUT then save_cfg(true) end
end

local function bump_sens(dir)
	look_sens = math.floor((look_sens + dir * 0.1) * 10 + 0.5) / 10
	if look_sens < 0.3 then look_sens = 0.3 end
	if look_sens > 3.0 then look_sens = 3.0 end
	save_cfg(true)
	pcall(Game.ShowStatusText, ("Look/mouse speed: %.1f"):format(look_sens), 2)
end

local function bump_grid(dir)
	grid_size = grid_size + dir * 4
	if grid_size < 8 then grid_size = 8 end
	if grid_size > 80 then grid_size = 80 end
	save_cfg(true)
	pcall(Game.ShowStatusText, ("Mouse grid: %d"):format(grid_size), 2)
end

local function toggle_mouse()
	move_mode = move_mode == "smooth" and "grid" or "smooth"
	save_cfg(true)
	pcall(Game.ShowStatusText, "Mouse: " .. move_mode, 3)
end

local function start_listen(act)
	if listen_act == act then
		listen_act = nil
		listen_wait_release = false
		pcall(Game.ShowStatusText, "Bind cancelled", 2)
		return
	end
	listen_act = act
	listen_wait_release = true
	pcall(Game.ShowStatusText, "Bind "..act..": press a button. Hold LT/RT for a chord. Click again to cancel.", 4)
end

local function action_down(act, now)
	for i = 1, #BTN_NAMED do
		local name, mask = BTN_NAMED[i][1], BTN_NAMED[i][2]
		if bit.band(now, mask) ~= 0 and bound_action(name, false) == act then return true end
	end
	return false
end

local function action_pressed(act, now, pressed)
	for i = 1, #BTN_NAMED do
		local name, mask = BTN_NAMED[i][1], BTN_NAMED[i][2]
		if bit.band(pressed, mask) ~= 0 and bound_action(name, true) == act then return true end
	end
	return false
end

load_cfg()

local function open_map()
	if pad then return true end
	mapH = k32.OpenFileMappingA(0x0004, 0, "Local\\LM_MMMergePad")
	if mapH == nil then return false end
	local view = k32.MapViewOfFile(mapH, 0x0004, 0, 0, 24)
	if view == nil then return false end
	pad = ffi.cast("PadShared*", view)
	return true
end

-- Read by LM_BugReport.lua for the pad part of a bug report.
function LM_PadInfo()
	local linked = open_map() and pad ~= nil
	return {
		overlay = linked,
		connected = linked and pad.connected ~= 0,
		buttons = linked and pad.buttons or 0,
		layout = BIND_LAYOUT,
		look = look_sens,
		grid = grid_size,
		move = move_mode,
	}
end

local function axis(v)
	local n = v / 32767
	if n > 1 then n = 1 end
	if n < -1 then n = -1 end
	if n > -0.28 and n < 0.28 then return 0 end
	return n
end

local function setkey(vk, on)
	on = not not on
	if held[vk] == on then return end
	held[vk] = on
	user32.keybd_event(vk, 0, on and 0 or KEYUP, 0)
end

local function tap(vk)
	if not vk or vk == 0 then return end
	user32.keybd_event(vk, 0, 0, 0)
	user32.keybd_event(vk, 0, KEYUP, 0)
end

local function vk_for_keybind(id)
	if not id or id:sub(1, 4) ~= "key:" then return nil end
	local i = tonumber(id:sub(5))
	if not i or not Game or not Game.KeyCodes then return nil end
	local vk = Game.KeyCodes[i]
	if not vk or vk == 0 then return nil end
	return vk
end

local function is_dpad_name(name)
	return name == "DpadU" or name == "DpadD" or name == "DpadL" or name == "DpadR"
end

local function keycode_vk(idx)
	if not Game or not Game.KeyCodes then return nil end
	local vk = Game.KeyCodes[idx]
	if not vk or vk == 0 then return nil end
	return vk
end

local function tap_keycode(idx, fallback_vk)
	local vk = keycode_vk(idx)
	if vk then tap(vk); return true end
	if fallback_vk then tap(fallback_vk); return true end
	return false
end

local function fire_quick_spell_safe(slot)
	if Game.Paused or Game.CurrentScreen ~= 0 then return end
	if Game.CurrentPlayer < 0 or Game.CurrentPlayer >= Party.count then return end
	local slots = ExtraQuickSpells and ExtraQuickSpells.SpellSlots
	if not slots then
		pcall(Game.ShowStatusText, "Quick spells unavailable", 2)
		return
	end
	local pl = Party[Game.CurrentPlayer]
	local pid = Party.PlayersIndexes[Game.CurrentPlayer]
	local spell = slots[pid] and slots[pid][slot] or 0
	if not spell or spell == 0 then
		pcall(Game.ShowStatusText, ("No quick spell in slot %d"):format(slot), 2)
		return
	end
	local need = Game.Spells[spell] and Game.Spells[spell].SpellPoints and Game.Spells[spell].SpellPoints[1]
	if need and pl.SP < need then
		pcall(Game.ShowStatusText, "Not enough SP", 2)
		return
	end
	if pl.RecoveryDelay and pl.RecoveryDelay > 0 then
		pcall(Game.ShowStatusText, "Still recovering", 2)
		return
	end
	if CastQuickSpell then
		pcall(CastQuickSpell, Game.CurrentPlayer, spell)
	end
end

-- Info books: the action type is the InfoDialog id itself (the Map button uses 202).
local function queue_action(act, p1, p2, now)
	if not act or act == 0 then return false end
	p1, p2 = p1 or 0, p2 or 0
	if now and DoGameAction then
		local ok = pcall(DoGameAction, act, p1, p2, true)
		if ok then return true end
	end
	if Game.Actions and Game.Actions.Add then
		local ok = pcall(Game.Actions.Add, act, p1, p2)
		if ok and now and Game.Actions.Process then
			pcall(Game.Actions.Process)
		end
		return ok
	end
	if DoGameAction then
		return pcall(DoGameAction, act, p1, p2, now and true or nil)
	end
	return false
end

local INFO_KEY_FALLBACK = {
	-- default letters for the books, used when the Controls slots are empty
	Map = 0x4D,       -- M
	Autonotes = 0x4E, -- N
	Calendar = 0x54,  -- T
	History = 0x48,   -- H
	Quests = 0x51,    -- Q
}

local function open_info_dialog(which)
	local id = which
	if type(which) == "string" and const.InfoDialog then
		id = const.InfoDialog[which]
	end
	if not id then return false end
	if queue_action(id, 0, 0, true) then
		pcall(Game.ShowStatusText, "Open " .. tostring(which), 1)
		return true
	end
	-- the info dialog (DlgID.Info = 9) with the book as param
	local dlg = const.DlgID and const.DlgID.Info or 9
	if queue_action(dlg, id, 0, true) then
		pcall(Game.ShowStatusText, "Open " .. tostring(which), 1)
		return true
	end
	if which == "Map" or id == (const.InfoDialog and const.InfoDialog.Map) then
		if tap_keycode(20) then return true end
	elseif which == "Calendar" or id == (const.InfoDialog and const.InfoDialog.Calendar) then
		if tap_keycode(18) then return true end
	elseif which == "Autonotes" or id == (const.InfoDialog and const.InfoDialog.Autonotes) then
		if tap_keycode(19) then return true end
	end
	local name = type(which) == "string" and which or nil
	if not name and const.InfoDialog then
		for k, v in pairs(const.InfoDialog) do
			if v == id then name = k; break end
		end
	end
	local vk = name and INFO_KEY_FALLBACK[name]
	if vk then
		tap(vk)
		pcall(Game.ShowStatusText, "Open " .. tostring(name) .. " (key)", 1)
		return true
	end
	return false
end

-- Zoom: Controls Zoom keys are usually unbound. Prefer minimap zoom (patch option)
-- plus OutdoorViewMul (inverse FOV outdoors).
local function zoom_view(dir)
	local changed = false
	pcall(function()
		local po = Game.PatchOptions
		if po and po.Present and po.Present("IndoorMinimapZoomPower") then
			local p = po.IndoorMinimapZoomPower or 0
			local np = p + dir
			if np < -6 then np = -6 end
			if np > 10 then np = 10 end
			po.IndoorMinimapZoomPower = np
			changed = true
		elseif po then
			local p = tonumber(po.IndoorMinimapZoomPower) or 0
			po.IndoorMinimapZoomPower = p + dir
			changed = true
		end
	end)
	pcall(function()
		local mul = Game.OutdoorViewMul
		if type(mul) ~= "number" or mul <= 0 then
			-- MM8 address fallback if struct read fails
			mul = mem and mem.u4 and mem.u4[0x6F300C] or 300
		end
		local step = math.max(20, math.floor(mul * 0.15 + 0.5))
		local next = mul - dir * step
		if next < 60 then next = 60 end
		if next > 1500 then next = 1500 end
		Game.OutdoorViewMul = next
		if Game.OutdoorViewDiv ~= nil then
			Game.OutdoorViewDiv = math.floor(0x10000 / next)
		end
		if mem and mem.u4 then
			mem.u4[0x6F300C] = next
			mem.u4[0x6F3010] = math.floor(0x10000 / next)
		end
		changed = true
		pcall(Game.ShowStatusText,
			dir > 0 and ("Zoom in (view %d)"):format(next) or ("Zoom out (view %d)"):format(next), 1)
	end)
	if changed then
		Game.NeedRedraw = true
		return true
	end
	return tap_keycode(dir > 0 and 24 or 25)
end

local function center_view()
	local ok = pcall(function()
		Party.LookAngle = 0
		Game.NeedRedraw = true
		pcall(Game.ShowStatusText, "Center view", 1)
	end)
	if ok then return true end
	return tap_keycode(23)
end

local function mouse_has_item()
	local ok, n = pcall(function()
		return Mouse.Item and Mouse.Item.Number or 0
	end)
	return ok and n and n ~= 0
end

-- ReleaseItem bags the cursor item, or drops it when the bag is full.
local function stow_mouse_item()
	if not mouse_has_item() then
		pcall(Game.ShowStatusText, "Nothing on cursor", 1)
		return false
	end
	local ok = pcall(function() Mouse.ReleaseItem() end)
	if ok then
		pcall(Game.ShowStatusText, mouse_has_item() and "Inventory full — item still held" or "Stowed", 1)
	end
	return ok
end

local function in_chest_ui()
	local s = Game.CurrentScreen
	return s == const.Screens.Chest
		or s == const.Screens.InventoryInChest
end

local stow_after_click = false

local last_chest_id = nil
function events.OpenChest(id)
	last_chest_id = id
end

local function loot_chest_all()
	if not in_chest_ui() then
		pcall(Game.ShowStatusText, "Open a chest first", 2)
		return false
	end
	local chest
	pcall(function()
		if last_chest_id ~= nil and Map and Map.Chests then
			chest = Map.Chests[last_chest_id]
		end
	end)
	if not chest then
		pcall(Game.ShowStatusText, "No chest id — click items; they auto-stow", 3)
		return false
	end
	local moved = 0
	pcall(function()
		for i = 1, 140 do
			local it = chest.Items[i]
			if it and it.Number and it.Number ~= 0 then
				-- AddItem bags whatever the cursor already holds first.
				Mouse.AddItem(it)
				it.Number = 0
				moved = moved + 1
			end
		end
		for i = 0, 139 do
			if chest.Inventory then chest.Inventory[i] = 0 end
		end
		if mouse_has_item() then Mouse.ReleaseItem() end
	end)
	pcall(Game.ShowStatusText, ("Looted %d item(s)"):format(moved), 2)
	Game.NeedRedraw = true
	return moved > 0
end

local function fire_mapped(id)
	if not id then return end
	if id == "map" then
		open_info_dialog("Map")
		return true
	end
	if id == "history" then
		open_info_dialog("History")
		return true
	end
	if id == "calendar" then
		open_info_dialog("Calendar")
		return true
	end
	if id == "autonotes" then
		open_info_dialog("Autonotes")
		return true
	end
	if id == "quests" then
		open_info_dialog("Quests")
		return true
	end
	if id == "zoom_in" then
		zoom_view(1)
		return true
	end
	if id == "zoom_out" then
		zoom_view(-1)
		return true
	end
	if id == "center_view" then
		center_view()
		return true
	end
	if id == "stow" then
		stow_mouse_item()
		return true
	end
	if id == "loot_all" then
		loot_chest_all()
		return true
	end
	if id:sub(1, 4) == "key:" then
		local i = tonumber(id:sub(5))
		if i == 18 then open_info_dialog("Calendar"); return true end
		if i == 19 then open_info_dialog("Autonotes"); return true end
		if i == 20 then open_info_dialog("Map"); return true end
		if i == 23 then center_view(); return true end
		if i == 24 then zoom_view(1); return true end
		if i == 25 then zoom_view(-1); return true end
		if i then tap_keycode(i) end
		return true
	end
	if id:sub(1, 5) == "xkey:" then
		local i = tonumber(id:sub(6))
		-- quick spells 1-4: Merge attacks on an empty slot, this does nothing
		if i and i >= 1 and i <= 4 then
			fire_quick_spell_safe(i)
			return true
		end
		local extra = Merge and Merge.Tables and Merge.Tables.ExtraKeyBinds
		local v = extra and extra[i]
		if v then
			if v.Action then pcall(v.Action)
			elseif v.Key and v.Key ~= 0 then tap(v.Key) end
		end
		return true
	end
	return false
end

local function oo_active()
	local ok, p = pcall(function()
		if Game.InOODialog then return 1 end
		if Game.OODialogPtr and Game.OODialogPtr ~= 0 then return Game.OODialogPtr end
		if Game.OODialogs and Game.OODialogs.CurrentDialogPtr and Game.OODialogs.CurrentDialogPtr ~= 0 then
			return Game.OODialogs.CurrentDialogPtr
		end
		return 0
	end)
	return ok and p and p ~= 0
end

local function win_key(vk)
	local hwnd = ffi.cast("void*", Game.WindowHandle)
	local sc = user32.MapVirtualKeyA(vk, 0)
	local lp = bit.bor(1, bit.lshift(sc, 16))
	user32.PostMessageA(hwnd, 0x0100, vk, lp)
	user32.PostMessageA(hwnd, 0x0101, vk, bit.bor(lp, 0xC0000000))
end

-- Title/new-game/load in MM8 are object-oriented dialogs. keybd_event never reaches them.
local function game_key(vk)
	if oo_active() and Game.OODialogProcessKey then
		pcall(Game.OODialogProcessKey, vk, 1)
		return
	end
	pcall(win_key, vk)
	tap(vk)
end

local function fire_next_character(times)
	-- Set the slot directly: KeyCodes[13] is often rebound to something else.
	local n = 0
	pcall(function() n = Party and Party.count or 0 end)
	if n and n > 0 and Game and Game.CurrentPlayer ~= nil then
		times = times or 1
		if times < 1 then times = 1 end
		local cur = Game.CurrentPlayer
		if type(cur) ~= "number" or cur < 0 then cur = 0 end
		cur = (cur + times) % n
		Game.CurrentPlayer = cur
		return
	end
	local vk = Game.KeyCodes and Game.KeyCodes[13]
	if vk and vk ~= 0 then
		for _ = 1, (times or 1) do tap(vk) end
	end
end

local function fire_prev_character()
	local n = 1
	pcall(function()
		local c = Party and Party.count
		if c and c > 1 then n = c - 1 end
	end)
	fire_next_character(n)
end

local function char_screen_open()
	local s = Game.CurrentScreen
	return s == const.Screens.Inventory or s == const.Screens.Inventory2
		or s == const.Screens.InventoryInShop or s == const.Screens.InventoryInChest
end

local function active_party_slot()
	local slot = 0
	pcall(function()
		if Game.CurrentPlayer and Game.CurrentPlayer >= 0 then
			slot = Game.CurrentPlayer
		end
		local n = Party and Party.count
		if n and n > 0 and slot >= n then slot = n - 1 end
	end)
	return slot
end

-- The char screen reopens on its last tab, so the tab is set by hand.
local function open_current_stats()
	if not char_screen_open() then
		tap(0x31 + active_party_slot())
	end
	pcall(function()
		if const.CharScreens then
			Game.CurrentCharScreen = const.CharScreens.Stats
		end
		Game.NeedRedraw = true
	end)
end

local function open_inventory_sheet()
	if not char_screen_open() then
		tap(0x49) -- I
	end
	pcall(function()
		if const.CharScreens then
			Game.CurrentCharScreen = const.CharScreens.Inventory
		end
		Game.NeedRedraw = true
	end)
end

local function open_char_tab(tab)
	if not char_screen_open() then
		tap(0x31 + active_party_slot())
	end
	pcall(function()
		if const.CharScreens and tab then
			Game.CurrentCharScreen = tab
		end
		Game.NeedRedraw = true
	end)
end

local function open_current_skills()
	open_char_tab(const.CharScreens and const.CharScreens.Skills)
end

local function open_current_awards()
	open_char_tab(const.CharScreens and const.CharScreens.Awards)
end

-- Fires once per press.
local function fire_playable_edge(id, in_ui)
	if not id then return end
	if id == "menu" then
		if in_ui then game_key(27) else tap(27) end
		return
	end
	if id == "back" then
		if in_ui then game_key(27) end
		return
	end
	if id == "inventory" then open_inventory_sheet(); return end
	if id == "stats" then open_current_stats(); return end
	if id == "skills" then open_current_skills(); return end
	if id == "awards" then open_current_awards(); return end
	if id == "attack" then
		-- action 23 is Merge's own attack; the Controls key is often unbound
		if DoGameAction then
			pcall(DoGameAction, 23, 0, 0)
		else
			user32.mouse_event(2, 0, 0, 0, 0)
			user32.mouse_event(4, 0, 0, 0, 0)
		end
		return
	end
	if id == "cast" then tap(0x43); return end
	if id == "rest" then
		-- Rest control, else R
		local vk = keycode_vk(17)
		if vk and vk ~= 0 then tap(vk) else tap(0x52) end
		return
	end
	if id == "always_run" then
		local vk = keycode_vk(15)
		local rest_vk = keycode_vk(17) or 0x52
		if vk and vk ~= 0 and vk ~= 0x52 and vk ~= rest_vk then
			tap(vk)
		else
			pcall(Game.ShowStatusText, "Rebind Always Run in Controls (not Rest)", 3)
		end
		return
	end
	if id == "jump" then
		local vk = keycode_vk(6) or 0x20
		-- Space if Jump shares a key with Rest, Cast or Autonotes
		local rest_vk = keycode_vk(17) or 0x52
		local auto_vk = keycode_vk(19)
		if vk == 0x52 or vk == rest_vk or vk == 0x43 or (auto_vk and vk == auto_vk) then
			vk = 0x20
		end
		tap(vk)
		return
	end
	if id == "fly" then
		if not tap_keycode(7) then
			pcall(Game.ShowStatusText, "Fly key unbound in Controls", 2)
		end
		return
	end
	if id == "land" then
		-- fly off, then jump to drop
		tap_keycode(7)
		local j = keycode_vk(6) or 0x20
		tap(j)
		pcall(Game.ShowStatusText, "Land / fly toggle", 1)
		return
	end
	if id == "fly_ls" then
		pcall(Game.ShowStatusText, "Hold LT+RT + left stick = fly axes", 2)
		return
	end
	if id == "mouse_look" then tap(20); return end
	if id == "inspect" then
		rmb_toggle = not rmb_toggle
		pcall(Game.ShowStatusText, rmb_toggle and "RMB hold ON" or "RMB hold OFF", 2)
		return
	end
	if id == "party_next" then
		fire_next_character(1)
		return
	end
	if id == "party_prev" then
		fire_prev_character()
		return
	end
	if id == "map" or id == "history" or id == "calendar" or id == "autonotes"
		or id == "quests" or id == "zoom_in" or id == "zoom_out" or id == "center_view"
		or id == "stow" or id == "loot_all" then
		fire_mapped(id)
		return
	end
	if id == "click" then
		if in_chest_ui() then stow_after_click = true end
		return
	end
	if id == "mouse_toggle" then
		return
	end
	if id:sub(1, 4) == "key:" then
		local idx = tonumber(id:sub(5))
		-- books, zoom and center view don't need the Controls key
		if idx == 18 or idx == 19 or idx == 20 or idx == 23 or idx == 24 or idx == 25 then
			fire_mapped(id)
		elseif idx and EDGE_KEY_IDX[idx] then
			tap_keycode(idx)
		end
		return
	end
	if id:sub(1, 5) == "xkey:" then
		fire_mapped(id)
	end
end

local function setmouse(downL, downR)
	if downL ~= lmb then
		user32.mouse_event(downL and 2 or 4, 0, 0, 0, 0)
		lmb = downL
	end
	if downR ~= rmb then
		user32.mouse_event(downR and 8 or 16, 0, 0, 0, 0)
		rmb = downR
	end
end

local function mouse_rel(dx, dy)
	dx, dy = math.floor(dx + 0.5), math.floor(dy + 0.5)
	if dx ~= 0 or dy ~= 0 then
		user32.mouse_event(1, dx, dy, 0, 0)
	end
end

local function now_ms()
	if timeGetTime then return timeGetTime() end
	return math.floor((os.clock() or 0) * 1000)
end

local function stick_band(x, y)
	local mag = math.sqrt(x * x + y * y)
	if mag < 0.28 then return 0, 0, 0 end
	local nx, ny = x / mag, y / mag
	if mag > 1 then mag = 1 end
	local band = 3
	if mag < 0.50 then band = 1
	elseif mag < 0.82 then band = 2
	end
	return band, nx, ny
end

local function smooth_speed(band)
	local px = ({4, 12, 22})[band] or 12
	return px * look_sens
end

local function grid_step_px(band)
	local mul = ({0.5, 1, 2})[band] or 1
	local step = math.floor(grid_size * mul + 0.5)
	if step < 4 then step = 4 end
	return step
end

local function adventure()
	return Game.MainMenuCode == -1 and Game.CurrentScreen == const.Screens.Game
end

local function ui_mode()
	if Game.MainMenuCode >= 0 then return true end
	return Game.CurrentScreen ~= const.Screens.Game
end

local function inv_screen()
	local s = Game.CurrentScreen
	return s == const.Screens.Inventory or s == const.Screens.Chest
		or s == const.Screens.SpellBook or s == const.Screens.House
		or s == const.Screens.InventoryInShop or s == const.Screens.InventoryInChest
end

local function warp_mouse(gx, gy)
	snap_cx, snap_cy = gx, gy
	pcall(function()
		Game.Mouse.X = math.floor(gx)
		Game.Mouse.Y = math.floor(gy)
	end)
	local rect = ffi.new("RECT")
	local pt = ffi.new("POINT")
	local hwnd = ffi.cast("void*", Game.WindowHandle)
	if user32.GetClientRect(hwnd, rect) == 0 then return end
	local cw, ch = rect.right, rect.bottom
	if cw < 1 or ch < 1 then return end
	pt.x = math.floor(gx * cw / 640)
	pt.y = math.floor(gy * ch / 480)
	user32.ClientToScreen(hwnd, pt)
	user32.SetCursorPos(pt.x, pt.y)
end

local function item_center(d, it)
	if it.Shape == 2 then
		return d.Left + it.Left, d.Top + it.Top
	end
	return d.Left + it.Left + (it.Width or 0) / 2, d.Top + it.Top + (it.Height or 0) / 2
end

local function clickable(it)
	local w, h = it.Width or 0, it.Height or 0
	local act = it.Action or 0
	local slot = inv_screen() and w >= 20 and w <= 80 and h >= 20 and h <= 80
	return w >= 8 and h >= 8 and w < 620 and h < 470 and (act ~= 0 or slot)
end

local function collect_custom(items)
	if not CustomUI or not CustomUI.ActiveElements then return end
	local ae = CustomUI.ActiveElements[Game.CurrentScreen]
	if not ae or not ae.Buttons then return end
	for layer = 0, 4 do
		local T = ae.Buttons[layer]
		if T then
			for _, v in pairs(T) do
				local ok, show = pcall(function()
					return v and v.Active and v.Act and (not v.Cond or v:Cond())
				end)
				if ok and show then
					local w, h = v.Wt or 1, v.Ht or 1
					local cx, cy
					if v.IsEllipse then
						local r = (w > 4 and w) or 48
						cx = v.X + r
						cy = v.Y + r
					else
						if w < 8 then w = 32 end
						if h < 8 then h = 24 end
						cx = v.X + w / 2
						cy = v.Y + h / 2
					end
					items[#items + 1] = {
						kind = "cui", btn = v, cx = cx, cy = cy, w = w, h = h, dlg = 2000 + layer
					}
				end
			end
		end
	end
end

local function collect_raw()
	local items = {}
	if Game.Dialogs and Game.Dialogs.High >= 0 then
		for di = Game.Dialogs.High, 0, -1 do
			local d = Game.Dialogs[di]
			if d and d.ItemsCount and d.ItemsCount > 0 then
				pcall(function()
					for _, it in d:Enum() do
						if clickable(it) then
							local cx, cy = item_center(d, it)
						items[#items + 1] = {
							kind = "hud", di = di, cx = cx, cy = cy, w = it.Width, h = it.Height, dlg = di,
							act = it.Action, p1 = it.ActionParam, p2 = it.ActionParam2
						}
						end
					end
				end)
			end
		end
	end
	collect_custom(items)
	return items
end

local function gap_split(list, key, gap)
	table.sort(list, function(a, b) return a[key] < b[key] end)
	local groups, cur = {}, {list[1]}
	for i = 2, #list do
		if list[i][key] - list[i - 1][key] > gap then
			groups[#groups + 1] = cur
			cur = {list[i]}
		else
			cur[#cur + 1] = list[i]
		end
	end
	groups[#groups + 1] = cur
	return groups
end

local function cluster_blocks(items)
	if #items == 0 then return items, {} end
	local bydlg, order = {}, {}
	for i = 1, #items do
		local d = items[i].dlg
		if not bydlg[d] then
			bydlg[d] = {}
			order[#order + 1] = d
		end
		bydlg[d][#bydlg[d] + 1] = items[i]
	end
	table.sort(order)
	local blocks = {}
	for oi = 1, #order do
		local xgroups = gap_split(bydlg[order[oi]], "cx", 70)
		for xi = 1, #xgroups do
			local ygroups = gap_split(xgroups[xi], "cy", 52)
			for yi = 1, #ygroups do
				blocks[#blocks + 1] = ygroups[yi]
			end
		end
	end
	table.sort(blocks, function(a, b)
		local function mn(t)
			local x, y = t[1].cx, t[1].cy
			for i = 2, #t do
				if t[i].cx < x then x = t[i].cx end
				if t[i].cy < y then y = t[i].cy end
			end
			return x, y
		end
		local ax, ay = mn(a)
		local bx, by = mn(b)
		if math.abs(ay - by) > 30 then return ay < by end
		return ax < bx
	end)
	for bi = 1, #blocks do
		for i = 1, #blocks[bi] do
			blocks[bi][i].block = bi
		end
	end
	return items, blocks
end

local function collect_ui()
	return cluster_blocks(collect_raw())
end

local function nearest(items, cx, cy, dx, dy)
	local best, bests
	for i = 1, #items do
		local it = items[i]
		local vx, vy = it.cx - cx, it.cy - cy
		local along = vx * dx + vy * dy
		if along > 10 then
			local side = vx * dy - vy * dx
			local score = along * along + side * side * 4
			if not bests or score < bests then
				best, bests = it, score
			end
		end
	end
	return best
end

local function block_at(items, cx, cy)
	local best, bd = 1, nil
	for i = 1, #items do
		local dx, dy = items[i].cx - cx, items[i].cy - cy
		local d = dx * dx + dy * dy
		if not bd or d < bd then
			best, bd = items[i].block or 1, d
		end
	end
	return best
end

local function focus_item(it)
	if not it then return end
	snap_cx, snap_cy = it.cx, it.cy
	cur_block = it.block or 1
	if it.kind == "cui" and it.btn and it.btn.MOAct then
		pcall(it.btn.MOAct, it.btn)
	end
	warp_mouse(it.cx, it.cy)
end

local function snap_dir(dx, dy)
	local items = collect_ui()
	if #items == 0 then return false end
	cur_block = block_at(items, snap_cx, snap_cy)
	local pool = {}
	for i = 1, #items do
		if items[i].block == cur_block then
			pool[#pool + 1] = items[i]
		end
	end
	local n = nearest(pool, snap_cx, snap_cy, dx, dy)
	if not n then
		n = nearest(items, snap_cx, snap_cy, dx, dy)
	end
	if not n then
		n = items[1]
	end
	focus_item(n)
	return true
end

local function snap_default()
	local items, blocks = collect_ui()
	if #items == 0 then return end
	cur_block = 1
	focus_item((blocks[1] and blocks[1][1]) or items[1])
end

local function cycle_block(dir)
	local items, blocks = collect_ui()
	if #blocks == 0 then return end
	cur_block = block_at(items, snap_cx, snap_cy)
	cur_block = ((cur_block - 1 + dir) % #blocks) + 1
	local bl = blocks[cur_block]
	local pick, pd = bl[1], nil
	for i = 1, #bl do
		local dx, dy = bl[i].cx - snap_cx, bl[i].cy - snap_cy
		local d = dx * dx + dy * dy
		if not pd or d < pd then
			pick, pd = bl[i], d
		end
	end
	focus_item(pick)
end

local function cui_only()
	local items = {}
	collect_custom(items)
	return cluster_blocks(items)
end

local function focused(items)
	local it, bd
	for i = 1, #items do
		local dx, dy = items[i].cx - snap_cx, items[i].cy - snap_cy
		local d = dx * dx + dy * dy
		if not bd or d < bd then it, bd = items[i], d end
	end
	return it or items[1]
end

local function ui_move(dx, dy)
	local items = collect_ui()
	if items and #items > 0 then
		nav_cui = true
		cur_block = block_at(items, snap_cx, snap_cy)
		local pool = {}
		for i = 1, #items do
			if items[i].block == cur_block then pool[#pool + 1] = items[i] end
		end
		local n = nearest(pool, snap_cx, snap_cy, dx, dy) or nearest(items, snap_cx, snap_cy, dx, dy) or items[1]
		focus_item(n)
		return true
	end
	nav_cui = false
	if dy < 0 then game_key(38)
	elseif dy > 0 then game_key(40)
	elseif dx < 0 then game_key(37)
	elseif dx > 0 then game_key(39)
	end
	return false
end

local function ui_activate()
	local items = collect_ui()
	if items and #items > 0 then
		local it = focused(items)
		focus_item(it)
		if it.kind == "cui" and it.btn and it.btn.Act then
			pcall(it.btn.Act, it.btn)
			return
		end
		if it.act and it.act ~= 0 then
			pcall(function()
				if Game.Actions and Game.Actions.Add then
					Game.Actions.Add(it.act, it.p1 or 0, it.p2 or 0)
				elseif DoGameAction then
					DoGameAction(it.act, it.p1 or 0, it.p2 or 0)
				end
			end)
			return
		end
	end
	game_key(13)
end

local function release_keys()
	for vk, on in pairs(held) do
		if on then setkey(vk, false) end
	end
	rmb_toggle = false
	setmouse(false, false)
	for k in pairs(map_held) do map_held[k] = nil end
end

function events.Tick()
	local ok, err = pcall(function()
		if not open_map() or pad.magic ~= MAGIC or pad.connected == 0 then
			release_keys()
			prev = 0
			prev_lt, prev_rt = 0, 0
			chord_lt, chord_rt = false, false
			return
		end
		if user32.GetForegroundWindow() ~= Game.WindowHandle then
			release_keys()
			prev = 0
			prev_lt, prev_rt = 0, 0
			chord_lt, chord_rt = false, false
			return
		end

		update_chord_latches()
		local now = pad.buttons
		local pressed = bit.band(now, bit.bnot(prev))
		local lx, ly = axis(pad.lx), axis(pad.ly)
		local in_ui = ui_mode()
		local at_title = Game.MainMenuCode >= 0
		local playable = not at_title and not extra_open()
		local screen = Game.CurrentScreen + (Game.MainMenuCode + 2) * 100
		if screen ~= last_screen then
			last_screen = screen
			nav_cui = false
			click_lock = true
		end
		if click_lock and not action_down("click", now) then
			click_lock = false
		end

		if listen_act then
			if listen_wait_release then
				local held_bindable = false
				for i = 1, #BTN_NAMED do
					local name, mask = BTN_NAMED[i][1], BTN_NAMED[i][2]
					if BINDABLE[name] and bit.band(now, mask) ~= 0 then
						held_bindable = true
						break
					end
				end
				if not held_bindable then listen_wait_release = false end
			else
				local cancel_b = bit.band(pressed, BTN_B) ~= 0 and chord_prefix() == ""
					and listen_act ~= "back" and listen_act ~= "inspect"
				if cancel_b then
					listen_act = nil
					pcall(Game.ShowStatusText, "Bind cancelled", 2)
				else
					for i = 1, #BTN_NAMED do
						local name, mask = BTN_NAMED[i][1], BTN_NAMED[i][2]
						if BINDABLE[name] and bit.band(pressed, mask) ~= 0 then
							for k, a in pairs(binds) do
								if a == listen_act then binds[k] = nil end
							end
							binds[chord_prefix() .. name] = listen_act
							pcall(Game.ShowStatusText, listen_act .. " = " .. chord_prefix() .. name, 3)
							bind_lock_mask = mask
							listen_act = nil
							save_cfg(true)
							break
						end
					end
				end
			end
		end

		if not listen_act then
		if bind_lock_mask ~= 0 then
			if bit.band(now, bind_lock_mask) == 0 then
				bind_lock_mask = 0
			else
				pressed = bit.band(pressed, bit.bnot(bind_lock_mask))
				now = bit.band(now, bit.bnot(bind_lock_mask))
			end
		end

		if on_pad_settings() and not listen_act and bit.band(now, BTN_R3) == 0 then
			if bit.band(pressed, BTN_DPAD_UP) ~= 0 or bit.band(pressed, BTN_DPAD_LEFT) ~= 0 then
				page_list(-1)
			end
			if bit.band(pressed, BTN_DPAD_DOWN) ~= 0 or bit.band(pressed, BTN_DPAD_RIGHT) ~= 0 then
				page_list(1)
			end
		end

		if bit.band(now, BTN_R3) ~= 0 then
			if bit.band(pressed, BTN_DPAD_UP) ~= 0 then bump_sens(1); r3_used = true end
			if bit.band(pressed, BTN_DPAD_DOWN) ~= 0 then bump_sens(-1); r3_used = true end
			if bit.band(pressed, BTN_DPAD_RIGHT) ~= 0 then bump_grid(1); r3_used = true end
			if bit.band(pressed, BTN_DPAD_LEFT) ~= 0 then bump_grid(-1); r3_used = true end
		elseif bit.band(prev, BTN_R3) ~= 0 then
			if not r3_used and bound_action("R3", true) == "mouse_toggle" then toggle_mouse() end
			r3_used = false
		end

		if action_pressed("mouse_toggle", now, pressed) and bit.band(pressed, BTN_R3) == 0 then toggle_mouse() end

		-- Back+Start+Y quits at once
		local bs_mask = bit.bor(BTN_BACK, BTN_START)
		local bs_now = bit.band(now, bs_mask) == bs_mask
		if bs_now and bit.band(now, BTN_Y) ~= 0 then
			local y_edge = bit.band(pressed, BTN_Y) ~= 0
				or (bit.band(pressed, bs_mask) ~= 0 and bit.band(prev, BTN_Y) ~= 0)
			if y_edge then
				release_keys()
				hard_quit()
				return
			end
		end

		if extra_open() then
			if action_pressed("menu", now, pressed) or action_pressed("back", now, pressed) then
				pcall(CustomUI.ExitExtraSettingsMenu)
			end
		elseif at_title then
			if action_pressed("menu", now, pressed) or action_pressed("back", now, pressed) then
				game_key(27)
			end
			-- title screen OO dialogs ignore mouse_event
			if action_pressed("click", now, pressed) and oo_active() then
				ui_activate()
			end
		elseif playable then
			for i = 1, #BTN_NAMED do
				local name, mask = BTN_NAMED[i][1], BTN_NAMED[i][2]
				if BINDABLE[name] and bit.band(pressed, mask) ~= 0 then
					if not (is_dpad_name(name) and bit.band(now, BTN_R3) ~= 0) then
						local id = bound_action(name, true)
						report_pad(name, id)
						if id then fire_playable_edge(id, in_ui) end
					end
				end
			end
		end

		local want = {}
		if playable then
			for i = 1, #BTN_NAMED do
				local name, mask = BTN_NAMED[i][1], BTN_NAMED[i][2]
				if BINDABLE[name] and bit.band(now, mask) ~= 0 then
					if not (is_dpad_name(name) and bit.band(now, BTN_R3) ~= 0) then
						local id = bound_action(name, false)
						local idx = id and id:sub(1, 4) == "key:" and tonumber(id:sub(5))
						if idx and not EDGE_KEY_IDX[idx] then
							local vk = vk_for_keybind(id)
							if vk then want[vk] = true end
						end
					end
				end
			end
		end
		for vk, on in pairs(map_held) do
			if on and not want[vk] then
				map_held[vk] = nil
				if vk ~= 37 and vk ~= 38 and vk ~= 39 and vk ~= 40 then
					setkey(vk, false)
				end
			end
		end
		for vk in pairs(want) do
			map_held[vk] = true
			if vk ~= 37 and vk ~= 38 and vk ~= 39 and vk ~= 40 then
				setkey(vk, true)
			end
		end

		if adventure() then
			-- LT+RT + left stick flies instead of walking
			local lt_fly = chord_lt and chord_rt
			if lt_fly then
				setkey(38, false)
				setkey(40, false)
				setkey(37, false)
				setkey(39, false)
			else
				setkey(38, ly > 0 or want[38])
				setkey(40, ly < 0 or want[40])
				setkey(37, lx < 0 or want[37])
				setkey(39, lx > 0 or want[39])
			end
			local k = Game.KeyCodes
			if k then
				local fu, fd, fl, fr = k[26] or 0, k[27] or 0, k[28] or 0, k[29] or 0
				if fu ~= 0 then setkey(fu, (lt_fly and ly > 0) or want[fu] == true) end
				if fd ~= 0 then setkey(fd, (lt_fly and ly < 0) or want[fd] == true) end
				if fl ~= 0 then setkey(fl, (lt_fly and lx < 0) or want[fl] == true) end
				if fr ~= 0 then setkey(fr, (lt_fly and lx > 0) or want[fr] == true) end
			end
		else
			setkey(38, want[38] == true)
			setkey(40, want[40] == true)
			setkey(37, want[37] == true)
			setkey(39, want[39] == true)
			local k = Game.KeyCodes
			if k then
				for n = 26, 29 do
					local vk = k[n] or 0
					if vk ~= 0 then setkey(vk, want[vk] == true) end
				end
			end
		end
		end

		local cx = pad.rx / 32767
		local cy = pad.ry / 32767
		if not adventure() then
			cx = cx + pad.lx / 32767
			cy = cy + pad.ly / 32767
		end
		local band, nx, ny = stick_band(cx, cy)

		if move_mode == "smooth" then
			if band > 0 then
				local sp = smooth_speed(band)
				mouse_rel(nx * sp, -ny * sp)
			end
		elseif bit.band(now, BTN_R3) == 0 then
			local t = now_ms()
			if band > 0 and t >= grid_next then
				local step = grid_step_px(band)
				local dx, dy = 0, 0
				if math.abs(nx) >= math.abs(ny) then
					dx = nx > 0 and 1 or -1
				else
					dy = ny > 0 and -1 or 1
				end
				mouse_rel(dx * step, dy * step)
				grid_next = t + GRID_MS
			end
		end

		setmouse(action_down("click", now) and not click_lock, rmb_toggle and not in_ui)
		-- an item clicked out of a chest goes straight into the bag
		if stow_after_click then
			if mouse_has_item() then
				stow_mouse_item()
				stow_after_click = false
			elseif not action_down("click", now) then
				stow_after_click = false
			end
		end
		rt_held = false
		prev_lt, prev_rt = pad.lt, pad.rt
		prev = now
	end)
	if not ok then
		pcall(print, err)
		if LM_BugReport and LM_BugReport.record then LM_BugReport.record('pad', err) end
	end
end

local pad_bg_icon

local function fill_pad_bg()
	local s = Game.Screen
	if s and s.Buffer and s.Buffer ~= 0 then
		mem.fill(s.Buffer, 640 * 480 * 2, 0)
	end
	if not (Game.IsD3D and Game.RendererD3D and Game.RendererD3D ~= 0) then
		return
	end
	pad_bg_poly = pad_bg_poly or mem.allocMM(128)
	local u4, r4, i4, call = mem.u4, mem.r4, mem.i4, mem.call
	local function vtx(p, x, y, cl)
		r4[p], r4[p + 4], r4[p + 8], r4[p + 12] = x, y, 0, 1
		i4[p + 16], i4[p + 20] = cl, 0
		r4[p + 24], r4[p + 28] = 0, 0
		return p + 32
	end
	local cl, p = 0xFF101018, pad_bg_poly
	p = vtx(p, 0, 0, cl)
	p = vtx(p, 0, 480, cl)
	p = vtx(p, 640, 480, cl)
	vtx(p, 640, 0, cl)
	local dev = u4[Game.RendererD3D + 56]
	local vt = u4[dev]
	call(u4[vt + 152], 0, dev, 0, 0)
	call(u4[vt + 88], 0, dev, 28, 0)
	call(u4[vt + 88], 0, dev, 27, 0)
	call(u4[vt + 88], 0, dev, 14, 0)
	call(u4[vt + 88], 0, dev, 19, 2)
	call(u4[vt + 88], 0, dev, 20, 1)
	call(u4[vt + 88], 0, dev, 26, 0)
	call(u4[vt + 88], 0, dev, 23, 8)
	call(u4[vt + 112], 0, dev, 6, 452, pad_bg_poly, 4, 32)
	call(u4[vt + 88], 0, dev, 14, 1)
	call(u4[vt + 88], 0, dev, 26, 1)
	call(u4[vt + 88], 0, dev, 23, 2)
end

function events.L1InterfaceUpd()
	if not on_pad_settings() then return end
	-- the placeholder icon has no bitmap, so keep its BlockBG hitbox full screen
	if pad_bg_icon then
		pad_bg_icon.Wt = 640
		pad_bg_icon.Ht = 480
	end
	pcall(fill_pad_bg)
end

local function pad_stepper(screen, x, y, setter, label)
	CustomUI.CreateButton{
		IconUp = "ar_lt_up", IconDown = "ar_lt_dn", IconMouseOver = "ar_lt_ht",
		Action = function()
			pcall(Game.PlaySound, 24)
			setter(-1)
		end,
		Layer = 0, Screen = screen, X = x, Y = y}
	CustomUI.CreateButton{
		IconUp = "ar_rt_up", IconDown = "ar_rt_dn", IconMouseOver = "ar_rt_ht",
		Action = function()
			pcall(Game.PlaySound, 23)
			setter(1)
		end,
		Layer = 0, Screen = screen, X = x + 20, Y = y}
	return CustomUI.CreateText{
		Text = label(), Layer = 0, Screen = screen, Width = 160, Height = 16,
		X = x + 48, Y = y + 2}
end

function events.GameInitialized2()
	-- Merge's quick spell keys attack on an empty slot
	local extra = Merge and Merge.Tables and Merge.Tables.ExtraKeyBinds
	if extra then
		for i = 1, 4 do
			if extra[i] then
				extra[i].Action = function() fire_quick_spell_safe(i) end
			end
		end
	end
	if not CustomUI or not CustomUI.NewSettingsPage then return end
	local scr = CustomUI.NewSettingsPage("LMPadSettings", " Controller")
	-- No background art. A missing icon with NoPending skips ShowIcon and
	-- L1InterfaceUpd paints a dark fill under the text.
	pad_bg_icon = CustomUI.CreateIcon{
		Icon = "lm_pad_nodraw",
		NoPending = true,
		X = 0, Y = 0, Layer = 1, Screen = scr, BlockBG = true,
		Condition = function(self)
			self.Wt = 640
			self.Ht = 480
			if Keys.IsPressed(const.Keys.ESCAPE) then
				CustomUI.ExitExtraSettingsMenu()
			end
			return true
		end}
	if pad_bg_icon then
		pad_bg_icon.Wt = 640
		pad_bg_icon.Ht = 480
	end
	CustomUI.CreateText{
		Text = "Layout 15 · LT spells · RT skills/awards · LT+RT fly/zoom · Reset = layout 15",
		X = 40, Y = 52, Width = 560, Height = 16, Screen = scr, AlignLeft = true}
	pad_speed_txt = pad_stepper(scr, 80, 90, bump_sens,
		function() return ("Speed %.1f"):format(look_sens) end)
	pad_grid_txt = pad_stepper(scr, 80, 118, bump_grid,
		function() return ("Grid %d"):format(grid_size) end)
	pad_page_txt = CustomUI.CreateText{
		Text = "Page 1 / 1",
		X = 320, Y = 118, Width = 160, Height = 16, Screen = scr, AlignLeft = true}
	CustomUI.CreateText{
		Text = "Reset defaults",
		X = 480, Y = 118, Width = 140, Height = 16, Screen = scr, AlignLeft = true,
		Action = reset_defaults,
		ColorStd = 0xFFFF, ColorMouseOver = 0xe664}
	CustomUI.CreateText{
		Text = "Report a bug",
		X = 480, Y = 90, Width = 140, Height = 16, Screen = scr, AlignLeft = true,
		Action = function()
			if LM_BugReport and LM_BugReport.send then LM_BugReport.send() end
		end,
		ColorStd = 0xFFFF, ColorMouseOver = 0xe664}
	CustomUI.CreateText{
		Text = "Prev",
		X = 40, Y = 150, Width = 40, Height = 16, Screen = scr, AlignLeft = true,
		Action = function() page_list(-1) end,
		ColorStd = 0xFFFF, ColorMouseOver = 0xe664}
	CustomUI.CreateText{
		Text = "Next",
		X = 40, Y = 338, Width = 40, Height = 16, Screen = scr, AlignLeft = true,
		Action = function() page_list(1) end,
		ColorStd = 0xFFFF, ColorMouseOver = 0xe664}
	rebuild_catalog()
	for i = 1, LIST_ROWS do
		local y = 150 + (i - 1) * 18
		list_rows[i] = CustomUI.CreateText{
			Text = "",
			X = 80, Y = y, Width = 500, Height = 16, Screen = scr,
			AlignLeft = true,
			Action = function()
				local e = bind_catalog[list_page * LIST_ROWS + i]
				if e then start_listen(e.id) end
			end,
			ColorStd = 0xFFFF, ColorMouseOver = 0xe664}
	end
	refresh_pad_ui()
	function events.OpenExtraSettingsMenu()
		rebuild_catalog()
		refresh_pad_ui()
	end

	local function copy_extra_nav()
		local home = const.Screens.MergeExtraSettings
		if not home or not CustomUI.ActiveElements[home] then return end
		local src = CustomUI.ActiveElements[home].Buttons[0]
		if not src then return end
		local nav = {}
		for key, btn in pairs(src) do
			if key == "MergeExSet" or (btn.Y == 422 and type(btn.IUpSrc) == "string" and btn.IUpSrc:find("^ar_")) then
				nav[key] = btn
			end
		end
		local names = {
			"MergeExtraSettings", "LMPadSettings", "ExtraKeybinds",
			"MergeInterfaceSettings", "BolsterFineTuning",
		}
		for i = 1, #names do
			local id = const.Screens[names[i]]
			if id and CustomUI.ActiveElements[id] then
				CustomUI.ActiveElements[id].Buttons[0] = CustomUI.ActiveElements[id].Buttons[0] or {}
				for key, btn in pairs(nav) do
					CustomUI.ActiveElements[id].Buttons[0][key] = btn
				end
			end
		end
	end

	local function open_extra_settings()
		extra_return_screen = Game.CurrentScreen
		click_lock = true
		setmouse(false, false)
		copy_extra_nav()
		pcall(events.call, "OpenExtraSettingsMenu")
		pcall(Game.PlaySound, 412)
		Game.CurrentScreen = const.Screens.LMPadSettings or const.Screens.MergeExtraSettings or extra_return_screen
	end

	local extra_exit_wrapped = false
	if CustomUI.ExitExtraSettingsMenu and not extra_exit_wrapped then
		extra_exit_wrapped = true
		local orig_exit = CustomUI.ExitExtraSettingsMenu
		CustomUI.ExitExtraSettingsMenu = function()
			local ret = extra_return_screen or 2
			orig_exit()
			Game.CurrentScreen = ret
		end
	end

	local function extra_link(screen, x, y)
		CustomUI.CreateText{
			Text = "Extra settings",
			X = x, Y = y, Width = 180, Height = 16,
			Screen = screen, AlignLeft = true, Layer = 0, BlockBG = true,
			Action = open_extra_settings,
			ColorStd = 0xFFFF, ColorMouseOver = 0xe664}
	end
	-- Merge only links Extra settings from Controls; add it to the Esc menu and title
	extra_link(const.Screens.Menu, 40, 18)
	extra_link(const.Screens.Controls, 220, 28)
	extra_link(const.Screens.MainManu, 40, 18)
end

function events.KeyDown(t)
	local key = t.Key
	local shift = Keys.IsPressed(const.Keys.SHIFT)
		or Keys.IsPressed(const.Keys.LSHIFT)
		or Keys.IsPressed(const.Keys.RSHIFT)
	if key == const.Keys.F10 and shift then
		t.Key = 0
		release_keys()
		hard_quit()
		return
	end
end

