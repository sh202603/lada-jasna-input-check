@echo off
rem Check-VideoInput.bat - cmd wrapper for Check-VideoInput.ps1
rem Uses pwsh (PowerShell 7) if available, otherwise powershell.exe (5.1).
rem Passes through all arguments and the exit code (0=OK / 1=WARN / 2=FAIL).
rem NOTE: keep this file ASCII-only; cmd reads .bat files as the OEM codepage,
rem       so UTF-8 Japanese comments corrupt the parser.
setlocal
set "PSSCRIPT=%~dp0Check-VideoInput.ps1"
set "PSEXE=powershell.exe"
where pwsh.exe >nul 2>nul
if not errorlevel 1 set "PSEXE=pwsh.exe"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PSSCRIPT%" %*
exit /b %errorlevel%
