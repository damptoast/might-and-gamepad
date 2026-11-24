# Runs install.ps1 against a made-up game folder in a temp dir: find, install,
# install again, uninstall. Never touches a real game or the desktop.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $root 'install.ps1'
$script:fails = 0
function Check([bool]$ok, [string]$msg) {
    if ($ok) { Write-Host "ok   $msg" } else { Write-Host "FAIL $msg"; $script:fails++ }
}
function Run([string[]]$extra) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -NoPause -NoShortcut -NoSystemSearch -SourceDir $src @extra 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}
function Sha([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("lm-fake-" + [guid]::NewGuid().ToString('N'))
$games = Join-Path $tmp 'Games'
$game = Join-Path $games 'Fake Merge'
$src = Join-Path $tmp 'src'
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $game 'Scripts\General'), (Join-Path $games 'Not A Game'), $src | Out-Null
    Set-Content -LiteralPath (Join-Path $game 'MM8.exe') -Value 'fake exe'
    Set-Content -LiteralPath (Join-Path $game 'dinput.dll') -Value 'original dinput'
    Set-Content -LiteralPath (Join-Path $game 'Scripts\General\LM_Gamepad.lua') -Value '-- original script'
    Set-Content -LiteralPath (Join-Path $game 'mm8.ini') -Value "[Settings]`r`nNoIntro=0`r`nOther=keep`r`n"
    Set-Content -LiteralPath (Join-Path $games 'Not A Game\readme.txt') -Value 'x'
    Set-Content -LiteralPath (Join-Path $src 'LM_MMMerge.exe') -Value 'new overlay'
    Set-Content -LiteralPath (Join-Path $src 'dinput.dll') -Value 'new shim'
    Copy-Item (Join-Path $root 'LM_*.lua') $src
    $iniOrig = Sha (Join-Path $game 'mm8.ini')
    $dllOrig = Sha (Join-Path $game 'dinput.dll')
    $luaOrig = Sha (Join-Path $game 'Scripts\General\LM_Gamepad.lua')

    # Find: only the real game folder is picked from the search root.
    $r = Run @('-ExtraSearchRoot', $games)
    Check ($r.Code -eq 0) ("install finds the game and succeeds" + $(if ($r.Code) { ": $($r.Out)" }))
    Check ($r.Out -like "*Game folder: $game*") 'the found folder is the fake game'
    Check ((Get-Content -Raw (Join-Path $game 'LM_MMMerge.exe')).Trim() -eq 'new overlay') 'overlay installed'
    Check ((Get-Content -Raw (Join-Path $game 'dinput.dll')).Trim() -eq 'new shim') 'dinput.dll replaced'
    Check ((Sha (Join-Path $game 'dinput.dll.lm-bak')) -eq $dllOrig) 'dinput.dll backed up unchanged'
    Check ((Sha (Join-Path $game 'Scripts\General\LM_Gamepad.lua.lm-bak')) -eq $luaOrig) 'existing script backed up unchanged'
    Check ((Sha (Join-Path $game 'mm8.ini.lm-bak')) -eq $iniOrig) 'mm8.ini backed up unchanged'
    $ini = Get-Content -Raw (Join-Path $game 'mm8.ini')
    Check (($ini -match 'NoIntro=1') -and ($ini -match 'PaperDollInChests=2') -and ($ini -match 'Other=keep')) 'mm8.ini patched, other keys kept'
    Check (Test-Path (Join-Path $game 'Scripts\General\LM_SkipIntro.lua')) 'every script copied'
    $want = @(Get-ChildItem -LiteralPath $src -Filter 'LM_*.lua').Count
    Check (@(Get-ChildItem -LiteralPath (Join-Path $game 'Scripts\General') -Filter 'LM_*.lua').Count -eq $want) 'no stray scripts'

    # Install again: backups still hold the originals.
    $r = Run @('-GameFolder', $game)
    Check ($r.Code -eq 0) 'installing again succeeds'
    Check ((Sha (Join-Path $game 'dinput.dll.lm-bak')) -eq $dllOrig) 'second install keeps the original backup'

    # Uninstall.
    $r = Run @('-Uninstall', '-ExtraSearchRoot', $games)
    Check ($r.Code -eq 0) ("uninstall succeeds" + $(if ($r.Code) { ": $($r.Out)" }))
    Check ((Sha (Join-Path $game 'dinput.dll')) -eq $dllOrig) 'dinput.dll restored'
    Check ((Sha (Join-Path $game 'Scripts\General\LM_Gamepad.lua')) -eq $luaOrig) 'script restored'
    Check ((Sha (Join-Path $game 'mm8.ini')) -eq $iniOrig) 'mm8.ini restored'
    Check (-not (Test-Path (Join-Path $game 'LM_MMMerge.exe'))) 'overlay removed'
    Check (-not (Test-Path (Join-Path $game 'Scripts\General\LM_SkipIntro.lua'))) 'new scripts removed'
    Check (@(Get-ChildItem -Recurse -LiteralPath $game -Filter '*.lm-bak').Count -eq 0) 'no backups left'
    Check (-not (Test-Path (Join-Path $game 'lm-install.txt'))) 'install record removed'

    # Refusals.
    $r = Run @('-GameFolder', (Join-Path $games 'Not A Game'))
    Check ($r.Code -ne 0) 'a folder without MM8.exe is refused'
    $r = Run @('-ExtraSearchRoot', (Join-Path $tmp 'nothing-here'))
    Check ($r.Code -ne 0) 'no game found without a dialog when -NoPause'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fails) { Write-Host "`n$($script:fails) check(s) failed"; exit 1 }
Write-Host "`nall passed"
