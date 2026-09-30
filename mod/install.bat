@echo off
rem Changed Co-op installer. Usage: install.bat "C:\...\steamapps\common\Changed"
rem (or put this folder inside the game folder and double-click).
setlocal
set "GAME=%~1"
if "%GAME%"=="" set "GAME=%~dp0.."
for %%I in ("%GAME%") do set "GAME=%%~fI"
if not exist "%GAME%\Game.rgss2a" (
  echo Game.rgss2a not found in "%GAME%".
  echo Usage: install.bat "C:\...\steamapps\common\Changed"
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0coop-install.ps1" -Game "%GAME%" -Source "%~dp0Coop"
pause
