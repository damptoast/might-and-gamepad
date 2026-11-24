# Runs every test. Needs LuaJIT on PATH for the Lua part (skipped when missing).
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$failed = 0

$lua = Get-Command luajit -ErrorAction SilentlyContinue
if ($lua) {
    Write-Host '== bug report (Lua)'
    & $lua.Source (Join-Path $here 'test_bugreport.lua')
    if ($LASTEXITCODE -ne 0) { $failed++ }
} else {
    Write-Host 'SKIP bug report tests: luajit not on PATH'
}

Write-Host '== installer'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'test_installer.ps1')
if ($LASTEXITCODE -ne 0) { $failed++ }

if ($failed) { Write-Host "`n$failed test file(s) failed"; exit 1 }
Write-Host "`nAll test files passed"
