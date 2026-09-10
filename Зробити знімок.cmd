@echo off
chcp 65001 >nul
title Знімок системи
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Take-SystemSnapshot.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Take-SystemSnapshot.ps1" %*
)
echo.
pause
