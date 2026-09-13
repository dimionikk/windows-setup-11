@echo off
where pythonw >nul 2>nul
if %errorlevel%==0 (
    start "" pythonw "%~dp0menu.pyw"
) else (
    where python >nul 2>nul
    if %errorlevel%==0 (
        start "" python "%~dp0menu.pyw"
    ) else (
        echo Python не знайдено. Постав з https://python.org (з опцією "Add to PATH") і запусти ще раз.
        pause
    )
)
