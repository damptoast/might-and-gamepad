# Installs (or removes) the Might and Magic Merge pad mod.
# Players: double-click install.cmd or uninstall.cmd instead of running this.
#
#   install.ps1                       find the game, install
#   install.ps1 -Uninstall            find the game, restore what was replaced
#   install.ps1 -GameFolder <path>    use this folder, do not search
#   install.ps1 -NoPause              never wait for a key, never open a dialog
#
# Used by the tests:
#   -SourceDir <path>        take the files to install from here
#   -ExtraSearchRoot <path>  also look for games in the folders under this one
#   -NoSystemSearch          search nothing but -ExtraSearchRoot
#   -NoShortcut              do not touch the desktop shortcut
param(
    [switch]$Uninstall,
    [string]$GameFolder = '',
    [switch]$NoPause,
    [string]$SourceDir = '',
    [string]$ExtraSearchRoot = '',
    [switch]$NoSystemSearch,
    [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'

$BackupSuffix = '.lm-bak'
$ManifestName = 'lm-install.txt'
$ShortcutName = 'Might and Magic Merge (pad).lnk'

function Stop-Here([int]$code) {
    if (-not $NoPause) {
        Write-Host ''
        Write-Host 'Press any key to close this window...'
        [void][System.Console]::ReadKey($true)
    }
    exit $code
}

# Finding the game

# A Merge folder is a copy of Might and Magic 8 with a Scripts folder.
function Test-MergeFolder([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $path 'MM8.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $path 'Scripts') -PathType Container)
}

function Get-GogFolders {
    $found = @()
    foreach ($base in 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games', 'HKLM:\SOFTWARE\GOG.com\Games') {
        if (-not (Test-Path $base)) { continue }
        foreach ($key in Get-ChildItem $base -ErrorAction SilentlyContinue) {
            $p = (Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue).path
            if ($p) { $found += $p }
        }
    }
    return $found
}

function Find-MergeFolders {
    $candidates = New-Object System.Collections.Generic.List[string]
    $roots = New-Object System.Collections.Generic.List[string]
    if ($ExtraSearchRoot) { $roots.Add($ExtraSearchRoot) }
    if (-not $NoSystemSearch) {
        foreach ($p in Get-GogFolders) { $candidates.Add($p) }
        $pf86 = ${env:ProgramFiles(x86)}
        foreach ($p in $pf86, $env:ProgramFiles) {
            if ($p) { $roots.Add((Join-Path $p 'GOG Galaxy\Games')); $roots.Add((Join-Path $p 'GOG Games')) }
        }
        $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }
        foreach ($d in $drives) {
            foreach ($n in 'GOG Games', 'Games', 'GOG Galaxy\Games', 'Program Files (x86)\GOG Galaxy\Games') {
                $roots.Add((Join-Path $d.RootDirectory.FullName $n))
            }
        }
    }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $candidates.Add($root)
        foreach ($child in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
            $candidates.Add($child.FullName)
        }
    }
    $seen = @{}
    $out = @()
    foreach ($c in $candidates) {
        $full = [System.IO.Path]::GetFullPath($c).TrimEnd('\')
        if ($seen.ContainsKey($full.ToLowerInvariant())) { continue }
        $seen[$full.ToLowerInvariant()] = $true
        if (Test-MergeFolder $full) { $out += $full }
    }
    return $out
}

function Select-MergeFolder {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Pick the Might and Magic Merge folder (the one that contains MM8.exe)'
    $dialog.ShowNewFolderButton = $false
    while ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        if (Test-MergeFolder $dialog.SelectedPath) { return $dialog.SelectedPath }
        [void][System.Windows.Forms.MessageBox]::Show(
            "MM8.exe and a Scripts folder were not found in:`n$($dialog.SelectedPath)`n`nPick the Merge game folder.",
            'Might and Magic Merge')
    }
    return $null
}

# Files

function Get-Payload([string]$source) {
    $items = @()
    foreach ($name in 'LM_MMMerge.exe', 'dinput.dll') {
        $items += [pscustomobject]@{ From = $name; To = $name }
    }
    foreach ($lua in Get-ChildItem -LiteralPath $source -Filter 'LM_*.lua' -File) {
        $items += [pscustomobject]@{ From = $lua.Name; To = "Scripts\General\$($lua.Name)" }
    }
    return $items
}

function Find-Source {
    $dirs = @()
    if ($SourceDir) { $dirs += $SourceDir }
    $dirs += $PSScriptRoot, (Join-Path $PSScriptRoot 'dist')
    foreach ($d in $dirs) {
        if ((Test-Path -LiteralPath (Join-Path $d 'LM_MMMerge.exe')) -and
            (Test-Path -LiteralPath (Join-Path $d 'dinput.dll'))) { return $d }
    }
    throw 'LM_MMMerge.exe and dinput.dll not found next to the installer. Run build.ps1 first.'
}

# The game's own file is saved once, so installing again never overwrites the
# original with ours.
function Backup-Once([string]$path) {
    $bak = $path + $BackupSuffix
    if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $path -Destination $bak
        Write-Host "Backed up $(Split-Path -Leaf $path)"
    }
}

function Set-IniKey([string]$iniPath, [string]$key, [string]$value) {
    $text = [IO.File]::ReadAllText($iniPath)
    $pattern = "(?m)^$([regex]::Escape($key))=.*$"
    if ([regex]::IsMatch($text, $pattern)) {
        $text = [regex]::Replace($text, $pattern, "$key=$value")
    } elseif ($text -match '(?m)^NoIntro=') {
        $text = [regex]::Replace($text, '(?m)^(NoIntro=.*)$', "`$1`r`n$key=$value")
    } elseif ($text -match '(?m)^\[Settings\]') {
        $text = [regex]::Replace($text, '(?m)^(\[Settings\])', "`$1`r`n$key=$value")
    } else {
        $text = $text.TrimEnd() + "`r`n$key=$value`r`n"
    }
    [IO.File]::WriteAllText($iniPath, $text)
}

function Get-DesktopShortcut {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop) { return (Join-Path $desktop $ShortcutName) }
    return $null
}

function Install-Mod([string]$game, [string]$source) {
    $manifest = @()
    # Files a previous install already put there are ours, not the game's: no backup of them.
    $manifestPath = Join-Path $game $ManifestName
    $ours = @()
    if (Test-Path -LiteralPath $manifestPath) { $ours = @(Get-Content -LiteralPath $manifestPath) }
    foreach ($item in Get-Payload $source) {
        $dest = Join-Path $game $item.To
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        if ($ours -notcontains $item.To) { Backup-Once $dest }
        Copy-Item -LiteralPath (Join-Path $source $item.From) -Destination $dest -Force
        $manifest += $item.To
        Write-Host "Installed $($item.To)"
    }

    $ini = Join-Path $game 'mm8.ini'
    if (Test-Path -LiteralPath $ini) {
        if ($ours -notcontains 'mm8.ini') { Backup-Once $ini }
        Set-IniKey $ini 'NoIntro' '1'
        Set-IniKey $ini 'PostponeIntro' '0'
        Set-IniKey $ini 'NoIntoLogos' '0'
        Set-IniKey $ini 'PaperDollInChests' '2'
        $manifest += 'mm8.ini'
        Write-Host 'Patched mm8.ini (intro skip, paper doll in chests)'
    }

    if (-not $NoShortcut) {
        $link = Get-DesktopShortcut
        if ($link) {
            $w = New-Object -ComObject WScript.Shell
            $sc = $w.CreateShortcut($link)
            $sc.TargetPath = Join-Path $game 'LM_MMMerge.exe'
            $sc.WorkingDirectory = $game
            $sc.IconLocation = (Join-Path $game 'MM8.exe') + ',0'
            $sc.Save()
            Write-Host "Desktop shortcut: $ShortcutName"
        }
    }
    Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding ASCII
}

function Uninstall-Mod([string]$game) {
    $manifestPath = Join-Path $game $ManifestName
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Write-Host 'No install record here. Nothing to remove.'
        return
    }
    foreach ($rel in Get-Content -LiteralPath $manifestPath) {
        if (-not $rel) { continue }
        $path = Join-Path $game $rel
        $bak = $path + $BackupSuffix
        if (Test-Path -LiteralPath $bak) {
            Copy-Item -LiteralPath $bak -Destination $path -Force
            Remove-Item -LiteralPath $bak -Force
            Write-Host "Restored $rel"
        } elseif (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            Write-Host "Removed $rel"
        }
    }
    foreach ($extra in 'LM_MMMerge.log', 'lm-bug-report.txt', $ManifestName) {
        $p = Join-Path $game $extra
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    if (-not $NoShortcut) {
        $link = Get-DesktopShortcut
        if ($link -and (Test-Path -LiteralPath $link)) {
            Remove-Item -LiteralPath $link -Force
            Write-Host 'Removed the desktop shortcut'
        }
    }
}

function Test-GameRunning([string]$game) {
    $prefix = [System.IO.Path]::GetFullPath($game).TrimEnd('\') + '\'
    foreach ($p in Get-Process -Name 'MM8', 'LM_MMMerge' -ErrorAction SilentlyContinue) {
        try {
            if ($p.Path -and $p.Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        } catch { }
    }
    return $false
}

# Main

# Dot-sourcing for tests: define the functions only.
if ($env:LM_INSTALL_NO_RUN) { return }

try {
    $verb = if ($Uninstall) { 'Uninstalling' } else { 'Installing' }
    Write-Host "Might and Magic Merge pad mod: $verb"
    Write-Host ''

    if ($GameFolder) {
        if (-not (Test-MergeFolder $GameFolder)) {
            throw "'$GameFolder' has no MM8.exe and Scripts folder. Give the folder that contains MM8.exe."
        }
        $game = $GameFolder
    } else {
        Write-Host 'Looking for Might and Magic Merge...'
        $games = @(Find-MergeFolders)
        if ($games.Count -eq 0) {
            if ($NoPause) { throw 'Could not find the game. Run again with -GameFolder <path>.' }
            Write-Host 'Not found automatically. Pick the game folder in the window that opens.'
            $game = Select-MergeFolder
            if (-not $game) {
                Write-Host 'No folder chosen. Nothing was changed.'
                Stop-Here 1
            }
        } elseif ($games.Count -eq 1) {
            $game = $games[0]
        } elseif ($NoPause) {
            throw ("Found several games:`n  " + ($games -join "`n  ") + "`nRun again with -GameFolder <path>.")
        } else {
            Write-Host 'Found:'
            for ($i = 0; $i -lt $games.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $games[$i]) }
            $answer = Read-Host 'Type a number'
            if ($answer -notmatch '^\d+$' -or [int]$answer -lt 1 -or [int]$answer -gt $games.Count) {
                throw 'No game chosen. Nothing was changed.'
            }
            $game = $games[[int]$answer - 1]
        }
    }
    Write-Host "Game folder: $game"

    if (Test-GameRunning $game) {
        throw 'The game is running. Close it and run this again.'
    }

    if ($Uninstall) {
        Uninstall-Mod $game
        Write-Host ''
        Write-Host 'Done. The mod is removed and your original files are back. Saves were not touched.'
    } else {
        Install-Mod $game (Find-Source)
        Write-Host ''
        Write-Host 'Done. Start the game from the new desktop shortcut so the pad overlay starts with it.'
        Write-Host 'Quit from the pad: Back + Start + Y. Bug report: Extra settings > Controller > Report a bug.'
        Write-Host 'To remove the mod later, run uninstall.cmd.'
    }
    Stop-Here 0
} catch {
    Write-Host ''
    Write-Host "Something went wrong: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'If the game stops starting, run uninstall.cmd.'
    Stop-Here 1
}
