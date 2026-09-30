@echo off
setlocal
set "GAME=%~1"
if "%GAME%"=="" set "GAME=%~dp0.."
for %%I in ("%GAME%") do set "GAME=%%~fI"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0coop-install.ps1" -Game "%GAME%" -Uninstall
