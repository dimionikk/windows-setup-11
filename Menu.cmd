@echo off
setlocal

where pythonw >nul 2>nul
if %errorlevel%==0 goto :launch
where python >nul 2>nul
if %errorlevel%==0 goto :launch

echo.
echo Python не знайдено, а без нього це меню не запуститься.
choice /C YN /N /M "Встановити Python автоматично через winget зараз? [Y/N] "
if errorlevel 2 (
    echo.
    echo Гаразд. Постав Python вручну з https://python.org ^(галочка "Add to PATH"^) і відкрий Menu.cmd ще раз.
    pause
    exit /b 1
)

where winget >nul 2>nul
if not %errorlevel%==0 (
    echo.
    echo Немає й winget - спершу лагоджу його...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1" -Steps winget
)

echo.
echo Встановлюю Python...
winget install --id Python.Python.3.13 -e --source winget --accept-package-agreements --accept-source-agreements
if not %errorlevel%==0 (
    echo.
    echo Не вдалося встановити Python автоматично. Постав вручну з https://python.org і відкрий Menu.cmd ще раз.
    pause
    exit /b 1
)

echo.
echo Готово. Відкрий Menu.cmd ще раз, щоб запустити SystemSnapshot.
pause
exit /b 0

:launch
where pythonw >nul 2>nul
if %errorlevel%==0 (
    start "" pythonw "%~dp0menu.pyw"
) else (
    start "" python "%~dp0menu.pyw"
)