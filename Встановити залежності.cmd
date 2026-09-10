@echo off
chcp 65001 >nul
title Встановлення залежностей
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1" %*
echo.
pause
