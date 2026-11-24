# Might and Gamepad

Gamepad support for Might and Magic Merge (MMMerge), the pack that plays MM6, MM7
and MM8 in the MM8 engine. Xbox pads (XInput) and DualShock / DualSense or other
DirectInput pads work. Every pad button can be rebound in the game, and the
intro movies are skipped.

## Requirements

- Might and Magic 8 from GOG with MMMerge on top of it. Made and played on the
  MMMerge release from 05.11.2023 with the 30.10.2024 patch. Older Merge
  versions may work but aren't checked.
- MMMerge already includes GrayFace's MMPatch and MMExtension. Don't install
  another GrayFace patch over it.
- Windows. One pad at a time: the first XInput pad wins, otherwise the first
  DirectInput pad.

## What's in it

| File | Goes to | What it does |
| --- | --- | --- |
| `LM_MMMerge.exe` | game folder | Small overlay that starts `MM8.exe`, reads the pad and shares its state with the game. Sits in the tray and quits when the game does. |
| `dinput.dll` | game folder | 32-bit shim that hides joysticks from MM8, so the engine can't grab the pad exclusively. Mouse and keyboard pass through untouched. |
| `LM_Gamepad.lua` | `Scripts\General` | Turns pad input into keys, clicks and game actions, and adds the Controller page to Extra settings. |
| `LM_BugReport.lua` | `Scripts\General` | The "Report a bug" button. |
| `LM_SkipIntro.lua` | `Scripts\General` | Skips the 3DO logos and the MM6/7/8 opening movies. Story cutscenes still play. |

## Pad layout

These are the defaults (bind layout 15). Names are Xbox ones; on a DualShock
A = Cross, B = Circle, X = Square, Y = Triangle, LB/RB = L1/R1, LT/RT = L2/R2,
Back = Share, Start = Options.

A trigger counts as held from a light press, so LT/RT chords also work on soft
triggers. While a trigger is held, a button that has a chord binding never fires
its bare action.

### Sticks

| Input | Action |
| --- | --- |
| Left stick | Walk and turn (arrow keys). In menus it moves the cursor too |
| Right stick | Mouse cursor, on every screen. Tilt further to go faster |
| LT + RT + left stick | Fly up / down / left / right |

### Bare buttons

| Button | Action |
| --- | --- |
| A | Left click |
| B | Back (Esc in menus) |
| X | Attack |
| Y | Quick spell |
| LB | Left click |
| RB | Toggle right mouse hold (inspect) |
| Start | Menu (Esc) |
| Back | Map |
| L3 | Mouse look (the patch's Caps Lock toggle) |
| R3 (tap) | Cursor mode: smooth or grid |
| D-pad left / right | Previous / next character |
| D-pad up | Inventory |
| D-pad down | Stats |

### LT + button

| Button | Action |
| --- | --- |
| LT + A / B / X / Y | Quick spell slot 1 / 2 / 3 / 4 |
| LT + D-pad left / right / up / down | NPC 1 / 2 / 3 / 4 |
| LT + Start | NPC panel |
| LT + Back | Calendar |
| LT + L3 | Fly on / off |
| LT + R3 | Zoom in |

LB, RB and the bare face buttons have no LT binding by default.

### RT + button

| Button | Action |
| --- | --- |
| RT + A | Pass |
| RT + B | Cast |
| RT + X | Jump |
| RT + Y | Rest |
| RT + LB | Pass |
| RT + Start | History book |
| RT + Back | Autonotes |
| RT + L3 | Land (fly off, then drop) |
| RT + R3 | Zoom out |
| RT + D-pad left | Skills |
| RT + D-pad right | Awards |

### LT + RT + button

| Button | Action |
| --- | --- |
| LT + RT + A | Cast ready |
| LT + RT + X | Always run |
| LT + RT + R3 | Center view |
| LT + RT + D-pad up / down / left / right | Fly up / down / left / right |

### Fixed combos

These are always on and can't be rebound.

| Combo | Action |
| --- | --- |
| Hold R3 + D-pad up / down | Cursor and look speed up / down (0.3 to 3.0) |
| Hold R3 + D-pad left / right | Grid step smaller / bigger (8 to 80) |
| Back + Start + Y | Quit the game at once, no save prompt |
| Shift + F10 (keyboard) | Same quick quit |

On the title screen Start and B work as Esc, and A / LB click. In Extra settings Start or B closes the menu. Keyboard keys stay in the
game's own Controls screen.

Quick spells 1 to 4 do nothing on an empty slot, where Merge would attack
instead.

## Remapping

Open Extra settings → Controller. Extra settings is linked from the Esc menu,
the title screen and the Controls screen.

- The list shows every pad action, every Controls key and every Merge extra key,
  with the buttons bound to it. D-pad (or Prev / Next) pages through it.
- Click a row, then press the button to bind it to. Hold LT, RT or both while
  pressing it to make a chord. Press B or click the row again to cancel.
  Binding a row removes its old button, so one action has one button.
- The arrows at the top set cursor speed and grid size.
- Reset defaults puts the layout above back.

Binds are saved in `LM_Gamepad.ini` in the game folder, one `button=action` per
line (for example `LT+A=xkey:1`). When a new mod version bumps the bind layout,
old binds are reset to the new defaults.

## Install

1. Install MMMerge and start it once without the mod, so you know it runs.
2. Download the release zip and unpack it anywhere.
3. Close the game.
4. Double-click `install.cmd`.
5. The installer looks for the Merge folder: the GOG registry entries, the GOG
   Galaxy and GOG Games folders, and `Games` folders on each drive. If it finds
   more than one it asks you to type a number. If it finds none, a window opens
   and you pick the folder that holds `MM8.exe`.
6. It copies the files, makes a `.lm-bak` copy of every file it replaces (the
   game's own `dinput.dll`, `mm8.ini`, any older script with the same name), and
   sets these in `mm8.ini`: `NoIntro=1`, `PostponeIntro=0`, `NoIntoLogos=0`,
   `PaperDollInChests=2`.
7. It puts a "Might and Magic Merge (pad)" shortcut on the desktop. Always start
   the game from that shortcut. Without the overlay running the pad does nothing.

The installer can also be run from PowerShell with a folder:

```powershell
.\install.ps1 -GameFolder "C:\GOG Games\Might and Magic 8"
```

### Manual install

1. Copy `LM_MMMerge.exe` and `dinput.dll` into the game folder, next to
   `MM8.exe`. Keep a copy of the game's own `dinput.dll` first if it has one.
2. Copy `LM_Gamepad.lua`, `LM_BugReport.lua` and `LM_SkipIntro.lua` into
   `Scripts\General`.
3. Optionally set `NoIntro=1` and `PaperDollInChests=2` in `mm8.ini`.
4. Start the game with `LM_MMMerge.exe` (make a shortcut to it if you like).

### Uninstall

Double-click `uninstall.cmd`. It puts the `.lm-bak` files back, deletes the
files that were new, removes `LM_MMMerge.log`, `lm-bug-report.txt` and the
install record (`lm-install.txt`), and deletes the desktop shortcut. Saves and
`LM_Gamepad.ini` are left alone. Delete `LM_Gamepad.ini` by hand if you want
the binds gone too.

### Updating

Unpack the new zip and run its `install.cmd`. The backups from your first
install are kept, so uninstalling still gives you the original game files.
Your binds stay unless the bind layout changed.

## Building from source

You need [Zig](https://ziglang.org/download/) 0.14 or newer and Windows
PowerShell. Point the `LM_ZIG` environment variable at `zig.exe`, or put zig on
`PATH`, or unpack a Zig release into `.tools\` in this folder.

```powershell
.\build.ps1
```

This builds `dist\LM_MMMerge.exe` (64-bit) and `dist\dinput.dll` (32-bit, like
MM8). The build has no timestamps or paths in it, so the same source gives the
same bytes.

```powershell
.\pack-release.ps1
```

This builds and then zips everything players need into
`dist\MightAndMagicMerge-PadMod-<version>.zip`. The version comes from
`M.VERSION` in `LM_BugReport.lua`.

```powershell
.\tests\run_tests.ps1
```

Runs the bug report tests (needs [LuaJIT](https://luajit.org/) on `PATH`,
skipped without it) and the installer tests, which install into a fake game
folder in your temp folder.

## Known issues

- The pad only works while the game window is in front. Alt-tabbing releases
  every held key and button.
- Steam Input or other remappers can grab the pad first. Turn them off for this
  game if buttons come out wrong.
- On DirectInput pads the triggers are on or off, with no analog range.
- The shim hides all joysticks from MM8, so the game's own joystick option does
  nothing while the mod is installed.
- The bug report may show the pack version as "(unknown)", and some script
  errors may not show up in it.
- Zoom changes the minimap zoom and the outdoor view distance. The Controls
  screen zoom keys are only used if both of those fail.

## Reporting bugs

In the game open Extra settings → Controller → Report a bug. It:

- copies a report to the clipboard,
- saves it as `lm-bug-report.txt` in the game folder,
- opens a new issue on GitHub with the report filled in.

The report has the mod and pack version, the map, the enabled scripts, recent
script errors, pad state and the last lines of `LM_MMMerge.log`. Folder names
are replaced with `<game>` and `<user>`. Read it through before you submit.

If the browser doesn't open, or the report was cut to fit the link, open an
issue at <https://github.com/damptoast/might-and-gamepad/issues> and attach
`lm-bug-report.txt`. Say what you did, what you expected and what happened.

## Credits

- Might and Magic Merge by the MMMerge team (Celestial Heavens forums), which
  this whole thing runs on.
- GrayFace, for MMPatch and MMExtension. The Lua side is built on MMExtension's
  scripting and Merge's CustomUI.
- Might and Magic 6, 7 and 8 belong to their owners. No game files are included.

## Licence

MIT, see [LICENSE](LICENSE). Might and Magic and its assets belong to their owners and are not included.
