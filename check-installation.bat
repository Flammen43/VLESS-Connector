@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-installation.ps1"
if %errorLevel% neq 0 (
    echo.
    echo [ERROR] PowerShell script failed with code %errorLevel%
)
echo.
pause
