# Builds the zip players download: dist\MightAndMagicMerge-PadMod-<version>.zip
# Builds the binaries first. The version is LM_BugReport.lua's VERSION, the one place it is written.
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$source = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'LM_BugReport.lua'))
if ($source -notmatch 'M\.VERSION\s*=\s*"([^"]+)"') { throw 'No VERSION in LM_BugReport.lua' }
$version = $matches[1]
$name = "MightAndMagicMerge-PadMod-$version"

& (Join-Path $PSScriptRoot 'build.ps1')

# Players get one flat folder: the installer takes everything from beside itself.
$files = @(
    @{ From = 'install.cmd'; To = 'install.cmd' },
    @{ From = 'uninstall.cmd'; To = 'uninstall.cmd' },
    @{ From = 'install.ps1'; To = 'install.ps1' },
    @{ From = 'README.md'; To = 'README.md' },
    @{ From = 'dist\LM_MMMerge.exe'; To = 'LM_MMMerge.exe' },
    @{ From = 'dist\dinput.dll'; To = 'dinput.dll' }
)
foreach ($lua in Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'LM_*.lua' -File) {
    $files += @{ From = $lua.Name; To = $lua.Name }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zipPath = Join-Path $OutDir "$name.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    foreach ($file in $files) {
        $full = Join-Path $PSScriptRoot $file.From
        if (-not (Test-Path -LiteralPath $full)) { throw "Missing $($file.From)" }
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $full, "$name/$($file.To)", [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $zip.Dispose()
}
Write-Host "Built $zipPath ($($files.Count) files)"
