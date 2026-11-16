@echo off
setlocal
chcp 65001 >nul
set "PS1=%~dp0oci-help.ps1"

if not exist "%PS1%" (
    echo [ERROR] oci-help.ps1 not found in %~dp0
    pause
    exit /b 1
)

if "%~1"=="" goto :help

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" goto :eof
echo.
pause
exit /b %RC%

:help
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" --help
echo.
pause
exit /b 0
