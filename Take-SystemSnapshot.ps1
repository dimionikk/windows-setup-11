# $Steps і $RepoDrives - рядки з розділювачем "|" (не масиви!). "|" - заборонений
# символ у Windows-шляхах, тож він ніколи не зіткнеться зі шляхом репозиторію
# (на відміну від коми, яка в шляху цілком легальна). Через -File PowerShell не
# збирає кілька пробільних аргументів у масив-параметр - бере лише перше слово,
# а решта падає з "positional parameter cannot be found".
[CmdletBinding()]
param(
    [string]$OutputRoot,
    [switch]$NoPrompt,
    [string]$Steps,
    [string]$RepoDrives
)

$ErrorActionPreference = 'Continue'
$ProgressPreference     = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Setup.ps1 має свій param() з тим самим ім'ям -Steps; dot-source виконує його в
# цьому ж scope, тож без явної передачі він тихо обнулить наш $Steps.
. (Join-Path $PSScriptRoot 'Setup.ps1') -Steps $Steps

function Invoke-SystemSnapshot {
    [CmdletBinding()]
    param(
        [string]$OutputRoot,
        [switch]$NoPrompt,
        [string[]]$Steps,
        [string[]]$RepoDrives
    )

    $script:selectedSteps = if ($Steps) { [System.Collections.Generic.HashSet[string]]::new([string[]]$Steps, [StringComparer]::OrdinalIgnoreCase) } else { $null }

    $missing = @()
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { $missing += 'winget (App Installer) - потрібен для programs.json' }
    $ep = try { Get-ExecutionPolicy } catch { $null }
    if ($ep -in 'Restricted','AllSigned') { $missing += "ExecutionPolicy = $ep" }

    if ($missing) {
        Write-Host "`n  Бракує залежностей:" -ForegroundColor Yellow
        $missing | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
        if ($NoPrompt) {
            Write-Host "  Пропускаю - знімок буде неповний. Постав залежності окремим пунктом меню.`n" -ForegroundColor DarkYellow
        } else {
            $ans = Read-Host "`n  Встановити все зараз? [Y/n]"
            if ($ans -notmatch '^\s*[nNнН]') {
                Invoke-DependencySetup
            } else {
                Write-Host "  Пропускаю - знімок буде неповний.`n" -ForegroundColor DarkYellow
            }
        }
    }

    if (-not $OutputRoot) { $OutputRoot = [Environment]::GetFolderPath('Desktop') }
    if (-not (Test-Path -LiteralPath $OutputRoot)) { throw "Немає такого шляху: $OutputRoot" }

    $stamp    = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $dir      = Join-Path $OutputRoot "SystemSnapshot_$stamp"
    $settings = Join-Path $dir 'settings'
    $visual   = Join-Path $dir 'visual'
    $manifest = Join-Path $dir '_manifest.log'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    "Знімок системи $stamp"                                   | Set-Content $manifest -Encoding UTF8
    "Комп'ютер: $env:COMPUTERNAME   Користувач: $env:USERNAME`r`n" | Add-Content $manifest -Encoding UTF8

    Write-Host "`n  Знімок -> $dir`n" -ForegroundColor Cyan

    function Have([string]$name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }
    function F([string]$name)    { Join-Path $dir $name }

    # $Id порожній (або $null) - крок вважається завжди вибраним (README), інакше -
    # звіряється зі списком -Steps. Кілька Step з одним Id - один пункт у GUI, кілька рядків логу.
    function Step {
        param([string]$Id, [string]$Label, [scriptblock]$Do)
        if ($Id -and $script:selectedSteps -and -not $script:selectedSteps.Contains($Id)) {
            Write-Host ("  {0,-46}" -f $Label) -NoNewline
            Write-Host "не вибрано" -ForegroundColor DarkGray
            "SKIP-UNSELECTED  $Label" | Add-Content $manifest -Encoding UTF8
            return
        }
        Write-Host ("  {0,-46}" -f $Label) -NoNewline
        try {
            & $Do
            Write-Host "OK" -ForegroundColor Green
            "OK    $Label" | Add-Content $manifest -Encoding UTF8
        } catch {
            Write-Host "пропущено" -ForegroundColor DarkYellow
            "SKIP  $Label  --  $($_.Exception.Message)" | Add-Content $manifest -Encoding UTF8
        }
    }

    function CopyIf([string]$src, [string]$dst) {
        if ($src -and (Test-Path -LiteralPath $src)) { Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force }
    }

    Step 'programs' "Програми: winget export" {
        if (-not (Have winget)) { throw "winget не встановлено" }
        winget export -o (F 'programs.json') --include-versions --accept-source-agreements | Out-Null
    }

    Step 'programs' "Програми: повний список (реєстр)" {
        Get-ItemProperty @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        ) -ErrorAction SilentlyContinue |
            Where-Object DisplayName |
            Select-Object DisplayName,DisplayVersion,Publisher,InstallDate |
            Sort-Object DisplayName -Unique |
            Export-Csv (F 'programs-all.csv') -NoTypeInformation -Encoding UTF8
    }

    Step 'vscode_ext' "Розширення VS Code" {
        if (-not (Have code)) { throw "code не в PATH" }
        code --list-extensions --show-versions | Set-Content (F 'vscode-extensions.txt') -Encoding UTF8
    }

    Step 'settings' "Налаштування (git / SSH / PowerShell / Windows Terminal / VS Code)" {
        New-Item -ItemType Directory -Force -Path $settings | Out-Null
        @(
            "$HOME\.gitconfig", "$HOME\.ssh\config", [string]$PROFILE,
            "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
            "$env:APPDATA\Code\User\settings.json", "$env:APPDATA\Code\User\keybindings.json",
            "$env:APPDATA\Code\User\snippets"
        ) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
            $safe = ($_ -replace [regex]::Escape($HOME),'~') -replace '[:\\/]','_'
            Copy-Item -LiteralPath $_ -Destination (Join-Path $settings $safe) -Recurse -Force
        }
    }

    Step 'repos' "Git-репозиторії" {
        if (-not $RepoDrives) { throw "диски для пошуку не обрано" }
        $exclude = @('node_modules','.venv','venv','AppData','$Recycle.Bin','System Volume Information',
                     'Windows','ProgramData','vendor','target','dist','build','.cache')

        function Find-GitRepos([string]$root) {
            $stack = [System.Collections.Generic.Stack[string]]::new()
            $stack.Push($root)
            $found = [System.Collections.Generic.List[string]]::new()
            while ($stack.Count -gt 0) {
                $cur = $stack.Pop()
                $entries = Get-ChildItem -LiteralPath $cur -Directory -Force -ErrorAction SilentlyContinue
                if ($entries.Name -contains '.git') {
                    # Це корінь репозиторію - не сканувати всередину (не шукати
                    # вкладені .git по всьому робочому дереву, це і повільно, і зайве).
                    $found.Add($cur)
                    continue
                }
                foreach ($e in $entries) {
                    if ($exclude -contains $e.Name) { continue }
                    # Пропускаємо junction/symlink - інакше самопосилальні системні
                    # переходи (напр. Local Settings -> AppData\Local) зациклюють обхід.
                    if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push($e.FullName)
                }
            }
            $found
        }

        function Get-OriginUrl([string]$repoPath) {
            $content = Get-Content -LiteralPath (Join-Path $repoPath '.git\config') -Raw -ErrorAction SilentlyContinue
            if (-not $content) { return $null }
            # Спершу виділяємо секцію [remote "origin"] аж до наступного заголовка
            # секції - інакше -match міг би захопити url з іншої, пізнішої секції.
            if ($content -match '(?ms)\[remote "origin"\]\r?\n((?:(?!\r?\n\[).)*)') {
                if ($matches[1] -match 'url\s*=\s*(\S+)') { return $matches[1] }
            }
            $null
        }

        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($drive in $RepoDrives) {
            $root = if ($drive -match '^[A-Za-z]:$') { "$drive\" } else { $drive }
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($repoPath in (Find-GitRepos $root)) {
                $url = Get-OriginUrl $repoPath
                $rows.Add([pscustomobject]@{
                    Path      = $repoPath
                    RemoteUrl = if ($url) { $url } else { '(локальний, без remote)' }
                })
            }
        }
        $rows | Sort-Object Path | Export-Csv (F 'repos.csv') -NoTypeInformation -Encoding UTF8
    }

    Step 'visual' "Візуальне оформлення" {
        New-Item -ItemType Directory -Force -Path $visual | Out-Null
        $keys = @(
            @{ Name = 'desktop';           Path = 'HKCU\Control Panel\Desktop' }
            @{ Name = 'cursors';           Path = 'HKCU\Control Panel\Cursors' }
            @{ Name = 'personalize';       Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' }
            @{ Name = 'explorer-advanced'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' }
            @{ Name = 'taskbar-position';  Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3' }
            @{ Name = 'search';            Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' }
            @{ Name = 'dwm';               Path = 'HKCU\Software\Microsoft\Windows\DWM' }
            @{ Name = 'accent';            Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' }
        )
        foreach ($k in $keys) {
            & reg.exe export $k.Path (Join-Path $visual "$($k.Name).reg") /y 2>$null | Out-Null
        }
        CopyIf "$env:APPDATA\Microsoft\Windows\Themes\TranscodedWallpaper" (Join-Path $visual 'wallpaper.jpg')

        # desktop.reg зберігає ШЛЯХ до оригінального файлу шпалини (не сам файл). Якщо
        # скопіювати лише кешовану TranscodedWallpaper, після відновлення на новій
        # системі реєстр вказуватиме на файл, якого там немає. Копіюємо і оригінал -
        # окрім стокових шпалин Windows, які й так є на будь-якій чистій системі.
        try {
            $wallpaperPath = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -ErrorAction Stop).Wallpaper
            if ($wallpaperPath -and (Test-Path -LiteralPath $wallpaperPath) -and $wallpaperPath -notlike "$env:WINDIR\*") {
                $ext = [IO.Path]::GetExtension($wallpaperPath)
                Copy-Item -LiteralPath $wallpaperPath -Destination (Join-Path $visual "wallpaper-original$ext") -Force
                $wallpaperPath | Set-Content (Join-Path $visual 'wallpaper-original-path.txt') -Encoding UTF8
            }
        } catch {}
    }

    Step '' "Генерую README.md" {
@"
# Знімок системи $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm')

| Файл / папка              | Що з ним робити |
|----------------------------|-----------------|
| programs.json               | ``winget import -i .\programs.json --accept-package-agreements --accept-source-agreements`` |
| programs-all.csv            | повний перелік встановлених програм (реєстр) - звірка, якщо чогось нема в programs.json |
| vscode-extensions.txt       | розширення VS Code |
| settings\                   | .gitconfig, .ssh\config, профіль PowerShell, Windows Terminal, VS Code |
| repos.csv                   | git-репозиторії цього комп'ютера і їх адреси |
| visual\                     | шпалина, тема, панель задач, провідник |

## Відновлення

Найпростіше: у меню SystemSnapshot -> "Встановити зі знімка", обрати цю папку і
позначити галочками потрібне.

Вручну:
1. ``winget import -i .\programs.json --accept-package-agreements --accept-source-agreements``
2. Звірити ``programs-all.csv`` - чи є щось, чого winget не поставив
3. ``code --install-extension <id>`` для кожного рядка з ``vscode-extensions.txt``
4. Файли з ``settings\`` скопіювати назад на їхні місця
5. ``git clone <url> <шлях>`` для кожного рядка з ``repos.csv``
6. ``reg import`` для кожного ``.reg`` з ``visual\``, потім перезапустити провідник (``explorer.exe``)
"@ | Set-Content (F 'README.md') -Encoding UTF8
    }

    $files = Get-ChildItem $dir -Recurse -File
    $size  = [math]::Round(($files | Measure-Object Length -Sum).Sum/1MB, 2)

    Write-Host "`n  ГОТОВО." -ForegroundColor Green
    Write-Host "  Папка : $dir"
    Write-Host "  Файлів: $($files.Count)   Розмір: $size MB`n"

    try { Invoke-Item $dir } catch {}
}

if ($MyInvocation.InvocationName -ne '.') {
    $stepsArr      = @(if ($Steps)      { $Steps -split '\|' | Where-Object { $_ } })
    $repoDrivesArr = @(if ($RepoDrives) { $RepoDrives -split '\|' | Where-Object { $_ } })
    try {
        Invoke-SystemSnapshot -OutputRoot $OutputRoot -NoPrompt:$NoPrompt -Steps $stepsArr -RepoDrives $repoDrivesArr
    } catch {
        Write-Host "`n  ПОМИЛКА: $($_.Exception.Message)`n" -ForegroundColor Red
        exit 1
    }

    if ($MyInvocation.MyCommand.Path -and -not $NoPrompt) {
        Write-Host "  (вікно закриється за 20 с)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 20
    }
}
