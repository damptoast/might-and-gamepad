# Builds dist\LM_MMMerge.exe (64-bit overlay) and dist\dinput.dll (32-bit shim).
# Needs Zig 0.14 or newer: set LM_ZIG to zig.exe, or put zig on PATH, or unpack
# a Zig release into .tools\ in this folder.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Find-Zig {
    if ($env:LM_ZIG -and (Test-Path -LiteralPath $env:LM_ZIG)) { return $env:LM_ZIG }
    $cmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $local = Get-ChildItem -LiteralPath (Join-Path $root '.tools') -Recurse -Filter zig.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($local) { return $local.FullName }
    throw 'Zig not found. Set LM_ZIG to zig.exe, put zig on PATH, or unpack Zig into .tools\ (https://ziglang.org/download/).'
}

$zig = Find-Zig
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# Relative paths and no debug info keep the binaries free of folder names:
# no PDB path and no build-machine paths. Zig's linker writes no timestamp.
$common = @('-O2', '-Wall', '-g0', '-s', '-fno-ident', "-ffile-prefix-map=$root=.")

Push-Location $root
try {
    Write-Host 'Building dist\LM_MMMerge.exe'
    & $zig cc -target x86_64-windows-gnu @common -static -o 'dist\LM_MMMerge.exe' 'LM_MMMerge.c' `
        -luser32 -lkernel32 -lshell32 -lwinmm '-Wl,--subsystem,windows'
    if ($LASTEXITCODE -ne 0) { throw "zig cc failed: $LASTEXITCODE" }

    Write-Host 'Building dist\dinput.dll (32-bit)'
    & $zig cc -shared -target x86-windows-gnu @common -o 'dist\dinput.dll' 'LM_dinput.c' 'LM_dinput.def'
    if ($LASTEXITCODE -ne 0) { throw "dinput.dll build failed: $LASTEXITCODE" }

    # Zig leaves import libraries and debug files next to the output.
    Get-ChildItem -LiteralPath $dist -File | Where-Object { $_.Extension -in '.pdb', '.lib' } | Remove-Item -Force
    foreach ($f in 'LM_MMMerge.exe', 'dinput.dll') {
        $item = Get-Item -LiteralPath (Join-Path $dist $f)
        Write-Host ("OK {0} ({1} bytes)" -f $item.FullName.Substring($root.Length + 1), $item.Length)
    }
} finally {
    Pop-Location
}
