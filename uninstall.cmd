@echo off
rem Double-click to remove the Might and Magic Merge pad mod.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall %*
