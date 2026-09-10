<#
.SYNOPSIS
    Робить повний знімок налаштувань цієї Windows-системи в одну папку,
    щоб після переустановки Windows швидко все відновити.

.DESCRIPTION
    Збирає: список програм (winget + повний реєстр + Store + Chocolatey/Scoop),
    розширення VS Code, модулі PowerShell, pip/npm-пакети, змінні середовища,
    тему й вигляд, твіки реєстру, автозапуск, служби, заплановані задачі,
    драйвери, компоненти Windows, ігри Steam, принтери, VPN, hosts-файл,
    назви збережених облікових записів, конфіги (git / PowerShell / Terminal /
    VS Code / OBS / Notepad++), шпалери. Генерує README.md і ЩО-ВСТАНОВИТИ.txt.

    Скрипт лише ЧИТАЄ систему й пише в свою папку. Жодних мережевих
    вивантажень (єдиний виняток - winget export звертається до каталогу winget).

    Секрети НЕ збираються: приватні SSH-ключі, паролі браузера/DBeaver,
    креди .aws/.azure/.kube/.docker, OBS stream key, пароль WebUI qBittorrent,
    паролі Wi-Fi (без -IncludeWifiKeys). Наприкінці робиться автоскан усього
    зібраного на схожі на ключі рядки -> !МОЖЛИВІ-СЕКРЕТИ.txt.

.PARAMETER OutputRoot
    Куди покласти папку зі знімком. За замовчуванням - робочий стіл.
    Приклад: -OutputRoot E:\  (одразу на флешку)

.PARAMETER Zip
    Додатково запакувати результат у .zip поряд з папкою.

.PARAMETER NoElevate
    Не піднімати права адміністратора (частина даних не збереться).

.PARAMETER IncludeWifiKeys
    Додатково експортувати профілі Wi-Fi РАЗОМ З ПАРОЛЯМИ (key=clear)
    у підпапку wifi-profiles\. За замовчуванням зберігаються лише назви мереж.

.PARAMETER Redact
    Замінити підозрілі значення (схожі на ключі/токени/паролі) у зібраних
    текстових файлах на ***ВИРІЗАНО***. Для випадку, коли папку планується
    синхронізувати в хмару чи комусь передати. За замовчуванням вимкнено -
    знімок зберігає все як є, але робиться звіт !МОЖЛИВІ-СЕКРЕТИ.txt.

.EXAMPLE
    .\Take-SystemSnapshot.ps1
    .\Take-SystemSnapshot.ps1 -OutputRoot E:\ -Zip
    .\Take-SystemSnapshot.ps1 -IncludeWifiKeys
    .\Take-SystemSnapshot.ps1 -Redact
#>
[CmdletBinding()]
param(
    [string]$OutputRoot,
    [switch]$Zip,
    [switch]$NoElevate,
    [switch]$IncludeWifiKeys,
    [switch]$Redact
)

$ErrorActionPreference = 'Continue'
$ProgressPreference     = 'SilentlyContinue'

# ------------------------------------------------------------------
#  Підняти права адміністратора (один прохід, без цього не зчитуються
#  компоненти Windows і список драйверів)
# ------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $NoElevate) {
    Write-Host "Потрібні права адміністратора - зараз буде вікно UAC..." -ForegroundColor Yellow
    $relaunch = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    if ($OutputRoot)      { $relaunch += @('-OutputRoot', ('"{0}"' -f $OutputRoot)) }
    if ($Zip)             { $relaunch += '-Zip' }
    if ($IncludeWifiKeys) { $relaunch += '-IncludeWifiKeys' }
    if ($Redact)          { $relaunch += '-Redact' }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $relaunch -ErrorAction Stop
        exit
    } catch {
        Write-Warning "UAC відхилено. Продовжую без адмін-прав - компоненти Windows і драйвери не зберуться."
    }
}

# ------------------------------------------------------------------
#  Папка призначення
# ------------------------------------------------------------------
if (-not $OutputRoot) { $OutputRoot = [Environment]::GetFolderPath('Desktop') }
if (-not (Test-Path -LiteralPath $OutputRoot)) { throw "Немає такого шляху: $OutputRoot" }
$stamp    = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$dir      = Join-Path $OutputRoot "SystemSnapshot_$stamp"
$cfg      = Join-Path $dir 'config-files'
$manifest = Join-Path $dir '_manifest.log'
New-Item -ItemType Directory -Force -Path $dir, $cfg | Out-Null
"Знімок системи $stamp" | Set-Content $manifest -Encoding UTF8
"Комп'ютер: $env:COMPUTERNAME   Користувач: $env:USERNAME   Адмін: $isAdmin" | Add-Content $manifest -Encoding UTF8
"" | Add-Content $manifest -Encoding UTF8

Write-Host ""
Write-Host "  Знімок -> $dir" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------------
#  Хелпери
# ------------------------------------------------------------------
function Have([string]$name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Step {
    param([string]$Label, [scriptblock]$Do)
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

$P = { param($n) Join-Path $dir $n }   # shortcut для шляхів усередині папки

# ================================================================
#  ЗБІР ДАНИХ
# ================================================================

Step "Залізо та ОС" {
    $os=Get-CimInstance Win32_OperatingSystem; $cs=Get-CimInstance Win32_ComputerSystem
    $cpu=Get-CimInstance Win32_Processor; $gpu=Get-CimInstance Win32_VideoController
    $bb=Get-CimInstance Win32_BaseBoard;  $bios=Get-CimInstance Win32_BIOS
@"
OS            : $($os.Caption) $($os.Version) (build $($os.BuildNumber))
Встановлено   : $($os.InstallDate)
Комп'ютер     : $($cs.Manufacturer) $($cs.Model)
CPU           : $($cpu.Name)
RAM           : $([math]::Round($cs.TotalPhysicalMemory/1GB,1)) GB
GPU           : $(($gpu.Name) -join ', ')
Мат. плата    : $($bb.Manufacturer) $($bb.Product)
BIOS          : $($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)
Hostname      : $env:COMPUTERNAME
Користувач    : $env:USERNAME
"@ | Set-Content (& $P 'system-info.txt') -Encoding UTF8
    Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter,FileSystemLabel,FileSystem,
        @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},@{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}} |
        Export-Csv (& $P 'disks.csv') -NoTypeInformation -Encoding UTF8
}

Step "Встановлені програми (реєстр)" {
    $paths=@(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object DisplayName |
        Select-Object DisplayName,DisplayVersion,Publisher,InstallDate |
        Sort-Object DisplayName -Unique |
        Export-Csv (& $P 'installed-programs.csv') -NoTypeInformation -Encoding UTF8
}

Step "Застосунки Microsoft Store" {
    Get-AppxPackage | Select-Object Name,PackageFullName,Version | Sort-Object Name |
        Export-Csv (& $P 'store-appx-packages.csv') -NoTypeInformation -Encoding UTF8
}

Step "winget export (головний файл)" {
    if (-not (Have winget)) { throw "winget не встановлено" }
    winget export -o (& $P 'winget-packages.json') --include-versions --accept-source-agreements | Out-Null
}

Step "Chocolatey / Scoop (якщо є)" {
    $any=$false
    if (Have choco) { & choco export -o="$(& $P 'choco-packages.config')" | Out-Null; $any=$true }
    if (Have scoop) { scoop export 2>$null | Set-Content (& $P 'scoop.json') -Encoding UTF8; $any=$true }
    if (-not $any) { throw "ні choco, ні scoop не встановлено" }
}

Step "Розширення VS Code" {
    if (-not (Have code)) { throw "code не в PATH" }
    code --list-extensions --show-versions | Set-Content (& $P 'vscode-extensions.txt') -Encoding UTF8
}

Step "Модулі PowerShell (користувацькі)" {
    $mp=@("$HOME\Documents\PowerShell\Modules","$HOME\Documents\WindowsPowerShell\Modules")
    $rows=foreach($root in $mp){ if(Test-Path $root){
        Get-ChildItem $root -Directory -EA SilentlyContinue | ForEach-Object {
            $v=(Get-ChildItem $_.FullName -Directory -EA SilentlyContinue | Sort-Object Name -Desc | Select-Object -First 1).Name
            [pscustomobject]@{ Name=$_.Name; Version=$v; Root=$root }
        }
    }}
    $rows | Sort-Object Name -Unique | Export-Csv (& $P 'powershell-modules.csv') -NoTypeInformation -Encoding UTF8
}

Step "Python pip / Node npm (глобальні)" {
    if (Have python) { python -m pip list --format=freeze 2>$null | Set-Content (& $P 'python-pip-freeze.txt') -Encoding UTF8 }
    if (Have npm)    { cmd /c "npm ls -g --depth=0 2>nul"      | Set-Content (& $P 'npm-global.txt')        -Encoding UTF8 }
}

Step "Змінні середовища та PATH (лише постійні: User + Machine)" {
    # Навмисно НЕ беремо змінні процесу (Get-ChildItem Env:) - там летючий мотлох
    # і токени, які підкинула програма-запускач. Беремо тільки те, що реально
    # прописане в системі й потрібне для відновлення.
    foreach ($scope in 'User','Machine') {
        $h = [Environment]::GetEnvironmentVariables($scope)
        $h.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Name = $_; Value = $h[$_] } } |
            Export-Csv (& $P "environment-variables-$($scope.ToLower()).csv") -NoTypeInformation -Encoding UTF8
    }
    [Environment]::GetEnvironmentVariable('Path','User')    | Set-Content (& $P 'PATH-user.txt')    -Encoding UTF8
    [Environment]::GetEnvironmentVariable('Path','Machine') | Set-Content (& $P 'PATH-machine.txt') -Encoding UTF8
}

Step "Вигляд: тема, колір, шпалери" {
    $pers=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -EA SilentlyContinue
    $dwm =Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -EA SilentlyContinue
    $desk=Get-ItemProperty 'HKCU:\Control Panel\Desktop' -EA SilentlyContinue
    $wp  =$desk.WallPaper
    $ct  =(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes' -Name CurrentTheme -EA SilentlyContinue).CurrentTheme
@"
Шпалери (шлях)        : $wp
Стиль шпалер          : $($desk.WallpaperStyle)
Світла тема додатків  : $($pers.AppsUseLightTheme)
Світла тема системи   : $($pers.SystemUsesLightTheme)
Прозорість            : $($pers.EnableTransparency)
Колір акценту (DWM)   : $($dwm.AccentColor)
Colorization color    : $($dwm.ColorizationColor)
Колір на панелях      : $($dwm.ColorPrevalence)
Поточна тема          : $ct
"@ | Set-Content (& $P 'appearance.txt') -Encoding UTF8
    if ($ct -and (Test-Path -LiteralPath $ct)) {
        Copy-Item -LiteralPath $ct -Destination (& $P (Split-Path $ct -Leaf)) -Force
    }
    if ($wp -and (Test-Path -LiteralPath $wp)) {
        Copy-Item -LiteralPath $wp -Destination (& $P ("wallpaper" + [IO.Path]::GetExtension($wp))) -Force
    }
    CopyIf "$env:APPDATA\Microsoft\Windows\Themes\TranscodedWallpaper" (& $P 'TranscodedWallpaper.jpg')
}

Step "Твіки реєстру (.reg)" {
    $ex=@{
        'reg-explorer-advanced.reg'    = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        'reg-personalize.reg'          = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        'reg-controlpanel-desktop.reg' = 'HKCU\Control Panel\Desktop'
        'reg-keyboard-layouts.reg'     = 'HKCU\Keyboard Layout\Preload'
        'reg-taskbar-stuckrects.reg'   = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
        'reg-mouse.reg'                = 'HKCU\Control Panel\Mouse'
        'reg-accessibility.reg'        = 'HKCU\Control Panel\Accessibility'
        'reg-fileexts.reg'             = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
    }
    foreach($k in $ex.Keys){ & reg.exe export $ex[$k] (& $P $k) /y 2>$null | Out-Null }
}

Step "Шрифти (встановлені користувачем)" {
    Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" -EA SilentlyContinue |
        Select-Object Name,Length | Export-Csv (& $P 'fonts-user-installed.csv') -NoTypeInformation -Encoding UTF8
}

Step "Автозапуск (реєстр)" {
    Get-CimInstance Win32_StartupCommand | Select-Object Name,Command,Location,User |
        Export-Csv (& $P 'startup-programs.csv') -NoTypeInformation -Encoding UTF8
}

Step "Автозапуск (папки Startup)" {
    @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
      "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup") |
        ForEach-Object { Get-ChildItem $_ -EA SilentlyContinue } |
        Select-Object Name,FullName,LastWriteTime |
        Export-Csv (& $P 'startup-folder.csv') -NoTypeInformation -Encoding UTF8
}

Step "Заплановані задачі (не системні)" {
    Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
        Select-Object TaskName,TaskPath,State,@{n='Action';e={($_.Actions.Execute -join '; ')}} |
        Export-Csv (& $P 'scheduled-tasks-custom.csv') -NoTypeInformation -Encoding UTF8
}

Step "Служби (сторонні)" {
    Get-CimInstance Win32_Service | Where-Object { $_.PathName -and $_.PathName -notlike '*\Windows\*' } |
        Select-Object Name,DisplayName,StartMode,State,PathName | Sort-Object DisplayName |
        Export-Csv (& $P 'services-thirdparty.csv') -NoTypeInformation -Encoding UTF8
}

Step "Схема живлення" {
    & powercfg /getactivescheme | Set-Content (& $P 'power-plan.txt') -Encoding UTF8
    & powercfg /list           | Add-Content (& $P 'power-plan.txt') -Encoding UTF8
}

Step "Принтери" {
    Get-Printer -EA SilentlyContinue | Select-Object Name,DriverName,PortName,Shared,Published,Type |
        Export-Csv (& $P 'printers.csv') -NoTypeInformation -Encoding UTF8
}

Step "VPN-з'єднання (назви, сервери)" {
    $u = Get-VpnConnection -EA SilentlyContinue
    $a = Get-VpnConnection -AllUserConnection -EA SilentlyContinue
    @($u; $a) | Where-Object Name | Select-Object Name,ServerAddress,TunnelType,AuthenticationMethod -Unique |
        Export-Csv (& $P 'vpn-connections.csv') -NoTypeInformation -Encoding UTF8
}

Step "Збережені облікові записи (лише назви, без паролів)" {
    & cmdkey /list | Set-Content (& $P 'credential-manager-targets.txt') -Encoding UTF8
}

Step "hosts-файл" {
    CopyIf "$env:WINDIR\System32\drivers\etc\hosts" (& $P 'hosts.txt')
}

Step "Мови вводу та Wi-Fi (назви)" {
    Get-WinUserLanguageList | Select-Object LanguageTag,@{n='InputMethods';e={$_.InputMethodTips -join ','}} |
        Export-Csv (& $P 'input-languages.csv') -NoTypeInformation -Encoding UTF8
    (netsh wlan show profiles) 2>$null | Set-Content (& $P 'wifi-profile-names.txt') -Encoding UTF8
    if ($IncludeWifiKeys) {
        $wd = Join-Path $dir 'wifi-profiles'
        New-Item -ItemType Directory -Force -Path $wd | Out-Null
        netsh wlan export profile key=clear folder="$wd" 2>$null | Out-Null
    }
}

Step "WSL-дистрибутиви" {
    if (-not (Have wsl)) { throw "WSL не встановлено" }
    wsl --list --verbose 2>$null | Set-Content (& $P 'wsl-distros.txt') -Encoding UTF8
}

Step "Мережеві диски" {
    Get-SmbMapping -EA SilentlyContinue | Select-Object LocalPath,RemotePath,Status |
        Export-Csv (& $P 'mapped-drives.csv') -NoTypeInformation -Encoding UTF8
}

Step "Закріплене на панелі задач" {
    $tb="$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    if (Test-Path $tb) { (Get-ChildItem $tb -Filter *.lnk).BaseName | Set-Content (& $P 'taskbar-pinned.txt') -Encoding UTF8 }
}

Step "Конфіги (git / PowerShell / Terminal / VS Code / SSH config)" {
    $targets=@(
        "$HOME\.gitconfig", "$HOME\.wslconfig", "$HOME\.bashrc", "$HOME\.bash_profile", "$HOME\.condarc",
        "$HOME\.ssh\config",
        $PROFILE.CurrentUserAllHosts, $PROFILE,
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:APPDATA\Code\User\settings.json", "$env:APPDATA\Code\User\keybindings.json",
        "$env:APPDATA\Code\User\snippets",
        "$env:LOCALAPPDATA\oh-my-posh\themes\powerlevel10k_rainbow.omp.json",
        "$HOME\.config\starship.toml"
    )
    foreach($t in $targets){
        if (Test-Path -LiteralPath $t) {
            $safe = ($t -replace [regex]::Escape($HOME),'~') -replace '[:\\/]','_'
            Copy-Item -LiteralPath $t -Destination (Join-Path $cfg $safe) -Recurse -Force
        }
    }
}

Step "Конфіги застосунків (OBS / Notepad++ / qBittorrent)" {
    # OBS: копіюємо сцени/профілі, але ВИРІЗАЄМО service.json - там ключ трансляції (stream key)!
    $obsSrc = "$env:APPDATA\obs-studio\basic"
    if (Test-Path $obsSrc) {
        $obsDst = Join-Path $cfg 'obs-studio_basic'
        Copy-Item -LiteralPath $obsSrc -Destination $obsDst -Recurse -Force
        Get-ChildItem $obsDst -Recurse -File -Force -EA SilentlyContinue |
            Where-Object { $_.Name -in 'service.json','service.json.bak' } |
            Remove-Item -Force -EA SilentlyContinue
    }
    CopyIf "$env:APPDATA\Notepad++\config.xml"      (Join-Path $cfg 'notepad++_config.xml')
    CopyIf "$env:APPDATA\Notepad++\session.xml"     (Join-Path $cfg 'notepad++_session.xml')
    CopyIf "$env:APPDATA\Notepad++\shortcuts.xml"   (Join-Path $cfg 'notepad++_shortcuts.xml')
    # qBittorrent: .ini містить хеш пароля WebUI та (інколи) креди проксі - вирізаємо ці рядки
    $qb = "$env:APPDATA\qBittorrent\qBittorrent.ini"
    if (Test-Path $qb) {
        (Get-Content $qb) |
            Where-Object { $_ -notmatch '(?i)(password|username=|\bsecret\b|token)' } |
            Set-Content (Join-Path $cfg 'qBittorrent.ini') -Encoding UTF8
    }
}

Step "Ігри Steam" {
    $sp=(Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -EA SilentlyContinue).SteamPath
    if (-not $sp) { throw "Steam не знайдено" }
    $libs=@("$sp\steamapps")
    $vdf="$sp\steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' | ForEach-Object {
            $libs += (($_.Matches[0].Groups[1].Value) -replace '\\\\','\') + "\steamapps"
        }
    }
    $notGames='Steamworks Common Redistributables|^Proton|^Steam Linux Runtime|^SteamVR'
    $games=foreach($l in ($libs | Sort-Object -Unique)){
        Get-ChildItem "$l\appmanifest_*.acf" -EA SilentlyContinue | ForEach-Object {
            $m=Select-String -Path $_.FullName -Pattern '"name"\s+"([^"]+)"' | Select-Object -First 1
            if ($m) { $m.Matches[0].Groups[1].Value }
        }
    }
    $games | Where-Object { $_ -and $_ -notmatch $notGames } | Sort-Object -Unique |
        Set-Content (& $P 'steam-games.txt') -Encoding UTF8
}

# ---- тільки з правами адміністратора ----
if ($isAdmin) {
    Step "Компоненти Windows (увімкнені)" {
        Get-WindowsOptionalFeature -Online | Where-Object State -eq 'Enabled' |
            Select-Object FeatureName | Sort-Object FeatureName |
            Export-Csv (& $P 'windows-features-enabled.csv') -NoTypeInformation -Encoding UTF8
    }
    Step "Features on Demand (встановлені)" {
        Get-WindowsCapability -Online | Where-Object State -eq 'Installed' |
            Select-Object Name | Sort-Object Name |
            Export-Csv (& $P 'windows-capabilities-installed.csv') -NoTypeInformation -Encoding UTF8
    }
    Step "Компоненти Windows (таблиця DISM)" {
        & dism /online /get-features /format:table | Set-Content (& $P 'windows-features-dism.txt') -Encoding UTF8
    }
    Step "Сторонні драйвери" {
        & pnputil /enum-drivers | Set-Content (& $P 'drivers-thirdparty.txt') -Encoding UTF8
    }
} else {
    "SKIP  Компоненти Windows / драйвери  --  запущено без прав адміністратора" | Add-Content $manifest -Encoding UTF8
    Write-Host "  (компоненти Windows і драйвери пропущено - немає прав адміна)" -ForegroundColor DarkYellow
}

# ================================================================
#  СКАНУВАННЯ ЗІБРАНОГО НА СЕКРЕТИ (+ опційне вирізання -Redact)
# ================================================================
$secretCount = 0
Step "Сканування зібраного на секрети" {
    # шаблон широкий, але без грубих хибних спрацювань на кшталт PS-параметра -Key
    $rx = '(?i)(password|passwd|passphrase|\bsecret\b|api[_-]?key|\bapikey\b|access[_-]?key' +
          '|client[_-]?secret|private[_-]?key|[_-]token\b|\btoken\s*[:=]|authorization\s*[:=]' +
          '|bearer\s+[A-Za-z0-9._-]{10}|[_-](key|secret|token|pass)["' + "'" + '\s]*[:=]\s*\S' +
          '|connectionstring|-----BEGIN [A-Z ]*PRIVATE KEY-----' +
          '|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}' +
          '|glpat-[A-Za-z0-9_-]{15,}|xox[bpras]-[A-Za-z0-9-]{8,}|sk-ant-[A-Za-z0-9_-]{20,}' +
          '|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{35}' +
          '|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.)'
    $exts = @('.txt','.csv','.json','.reg','.xml','.ini','.ps1','.toml','.config','.gitconfig')
    $scan = Get-ChildItem $dir -Recurse -File -Force -EA SilentlyContinue | Where-Object {
        $_.Length -lt 8MB -and $_.Name -notmatch 'МОЖЛИВІ-СЕКРЕТИ' -and (
            $exts -contains $_.Extension.ToLower() -or
            $_.Name -like '*profile.ps1' -or $_.Name -like '~_.*'
        )
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $scan) {
        Select-String -LiteralPath $f.FullName -Pattern $rx -EA SilentlyContinue |
            Select-Object -First 40 |
            ForEach-Object { $rows.Add([pscustomobject]@{ File=$f.FullName.Replace("$dir\",''); Where="рядок $($_.LineNumber)" }) }
    }
    # окремо: змінні середовища - ловимо за ІМЕНЕМ, навіть якщо значення "звичайне"
    foreach ($csv in 'environment-variables-user.csv','environment-variables-machine.csv') {
        $cp = & $P $csv
        if (Test-Path $cp) {
            Import-Csv $cp | Where-Object {
                $_.Name -match '(?i)(pass|pwd|secret|token|apikey|api_key|access_key|cred|auth|bearer|session|cookie|private|signing|\bsas\b|connectionstring|licen[cs]e)'
            } | ForEach-Object { $rows.Add([pscustomobject]@{ File=$csv; Where="змінна $($_.Name)" }) }
        }
    }
    $script:secretCount = $rows.Count

    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add("Місць, схожих на секрети / ключі / паролі: $($script:secretCount)")
    $body.Add("")
    $body.Add("Це ЕВРИСТИКА - бувають хибні спрацювання (напр. слово 'key' у назві")
    $body.Add("параметра). Перед тим як копіювати цю папку за межі флешки чи приватного")
    $body.Add("сховища - відкрий кожне місце й переконайся, що там немає справжніх ключів.")
    $body.Add("Найчастіші джерела: .bashrc / профіль PowerShell (export TOKEN=...),")
    $body.Add(".gitconfig (url з токеном), settings.json розширень VS Code,")
    $body.Add("environment-variables-*.csv (змінні середовища з ключами).")
    $body.Add("")
    foreach ($r in $rows) { $body.Add(("{0}  :  {1}" -f $r.File, $r.Where)) }
    if ($Redact) {
        foreach ($f in $scan) {
            $c = Get-Content -LiteralPath $f.FullName -EA SilentlyContinue
            if ($c) {
                $c2 = $c | ForEach-Object {
                    if ($_ -match $rx) { $_ -replace '([:=]\s*|","\s*)\S.*$', '$1***ВИРІЗАНО***' } else { $_ }
                }
                if (($c2 -join "`n") -ne ($c -join "`n")) { $c2 | Set-Content -LiteralPath $f.FullName -Encoding UTF8 }
            }
        }
        foreach ($csv in 'environment-variables-user.csv','environment-variables-machine.csv') {
            $cp = & $P $csv
            if (Test-Path $cp) {
                $ev = Import-Csv $cp
                foreach ($r in $ev) {
                    if ($r.Name -match '(?i)(pass|pwd|secret|token|key|cred|auth|bearer|session|cookie|private|signing|\bsas\b)') { $r.Value = '***ВИРІЗАНО***' }
                }
                $ev | Export-Csv $cp -NoTypeInformation -Encoding UTF8
            }
        }
        $body.Add("")
        $body.Add("РЕЖИМ -Redact: підозрілі значення у файлах вище замінено на ***ВИРІЗАНО***.")
    }
    $body | Set-Content (& $P '!МОЖЛИВІ-СЕКРЕТИ.txt') -Encoding UTF8
}

# ================================================================
#  ПОПЕРЕДЖЕННЯ ПРО ПРИВАТНІ ДАНІ
# ================================================================
Step "Файл-попередження про приватність" {
    $wifiLine = if ($IncludeWifiKeys) { "  - wifi-profiles\  - ПАРОЛІ ВІД WI-FI у відкритому вигляді" } else { "" }
@"
!!!  УВАГА - У ЦІЙ ПАПЦІ Є ПРИВАТНІ ДАНІ  !!!

Що саме:
  - environment-variables-user.csv / -machine.csv - постійні змінні середовища
    РАЗОМ ЗІ ЗНАЧЕННЯМИ. Там можуть бути API-ключі, токени, рядки підключення.
  - config-files\ - .gitconfig, .bashrc, .condarc, профіль PowerShell,
    settings.json (VS Code / Windows Terminal), .ssh\config
  - credential-manager-targets.txt - назви збережених у Windows логінів
    (лише назви, БЕЗ паролів)
  - hosts.txt, wifi-profile-names.txt, vpn-connections.csv (адреси серверів),
    mapped-drives.csv (мережеві шляхи), printers.csv
  - system-info.txt - hostname, серійні дані заліза, ім'я користувача
$wifiLine

Що скрипт уже НЕ бере (навмисно):
  - приватні SSH-ключі (~\.ssh\id_*), лише config
  - паролі браузера, з'єднання DBeaver, .aws/.azure/.kube/.docker креди
  - OBS stream key (service.json вирізано з obs-studio_basic\)
  - пароль WebUI / проксі qBittorrent (рядки вирізано з qBittorrent.ini)
  - паролі Wi-Fi (якщо не було -IncludeWifiKeys)

ЩО РОБИТИ:
  - Спершу глянь !МОЖЛИВІ-СЕКРЕТИ.txt - там перелік місць, які варто перевірити.
  - Тримай цю папку на флешці або в ПРИВАТНОМУ сховищі.
  - НЕ комміть її в Git і НЕ клади в публічну хмару.
  - Перед переустановкою просто скопіювати всю папку - це нормально.
  - Треба поділитися / залити в хмару? Запусти скрипт із -Redact,
    або видали environment-variables-*.csv, config-files\, credential-manager-targets.txt.
"@ | Set-Content (& $P '!ПРИВАТНЕ-НЕ-ПУБЛІКУВАТИ.txt') -Encoding UTF8
}

# ================================================================
#  ГЕНЕРАЦІЯ README.md
# ================================================================
Step "Генерую README.md" {
    $sysinfo = if (Test-Path (& $P 'system-info.txt')) { Get-Content (& $P 'system-info.txt') -Raw } else { '' }
    $nprog   = @(if (Test-Path (& $P 'installed-programs.csv')) { Import-Csv (& $P 'installed-programs.csv') }).Count
    $adminNote = if (Test-Path (& $P 'windows-features-enabled.csv')) { 'зібрано' } else { 'НЕ зібрано - запусти скрипт від адміністратора (через .cmd з UAC)' }

    $tpl = @'
# Знімок системи {HOST} - {DATE}

Автоматичний зліпок налаштувань, щоб після переустановки Windows не шукати все руками.
Створено скриптом Take-SystemSnapshot.ps1.

## !! Приватність

Ця папка містить змінні середовища зі значеннями, дотфайли й конфіги - там
можуть бути ключі та токени. Тримай на флешці / у приватному сховищі,
НЕ клади в публічний Git чи хмару.

- `!ПРИВАТНЕ-НЕ-ПУБЛІКУВАТИ.txt` - що саме тут чутливе.
- `!МОЖЛИВІ-СЕКРЕТИ.txt` - автоскан: перелік рядків, схожих на ключі/паролі. Перевір їх.
- Явні секрети вже НЕ потрапляють: OBS stream key, пароль WebUI qBittorrent,
  приватні SSH-ключі, паролі Wi-Fi (якщо без -IncludeWifiKeys), .aws/.azure/.docker.
- Для хмари/передачі - перегенеруй знімок із `-Redact`.

## Залізо
```
{SYSINFO}
```

## Порядок відновлення (коротко)

1. Постав Windows, увійди тим самим акаунтом Microsoft (активація підтягнеться).
2. Windows Update -> усі оновлення й драйвери.
3. Драйвери GPU: NVIDIA App / Intel DSA; решта - із сайту виробника ноутбука.
4. Компоненти Windows (від адміністратора):
   `Import-Csv .\windows-features-enabled.csv | ForEach-Object { Enable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -All -NoRestart }`
   -> перезавантаження (без цього не працюють WSL / VirtualBox).
5. Програми: `winget import -i .\winget-packages.json --accept-package-agreements --accept-source-agreements`
6. Те, чого нема в winget, і Steam-ігри - див. ЩО-ВСТАНОВИТИ.txt
7. Конфіги з папки config-files поклади назад:
   - `~_.gitconfig` -> `%USERPROFILE%\.gitconfig`
   - `*profile.ps1` -> `%USERPROFILE%\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`
   - `powerlevel10k_rainbow.omp.json` -> `%LOCALAPPDATA%\oh-my-posh\themes\`
   - Terminal / VS Code `settings.json`, `~_.ssh_config` -> `%USERPROFILE%\.ssh\config`
   - OBS: `obs-studio_basic` -> `%APPDATA%\obs-studio\basic`
8. VS Code: увімкни Settings Sync АБО постав розширення зі vscode-extensions.txt
9. Модулі PowerShell зі powershell-modules.csv: `Install-Module <Name> -Scope CurrentUser`
10. Вигляд: відкрий файл теми (*.theme), потім за потреби злий reg-*.reg (спершу переглянь у редакторі!).
11. Шпалери: постав файл wallpaper.* назад.
12. Панель задач: закріпи програми зі taskbar-pinned.txt (у Win11 - руками).
13. Firefox: увімкни Sync. Wi-Fi: під'єднайся заново (паролі не збережені, якщо не було -IncludeWifiKeys).
14. Принтери зі printers.csv, VPN зі vpn-connections.csv - додай заново.
15. Звірся з installed-programs.csv - чи нічого не забув.

## Що в папці

| Файл | Що це |
|---|---|
| ЩО-ВСТАНОВИТИ.txt | Простий список програм по категоріях, без команд |
| winget-packages.json | Головний файл - усі програми з winget, ставляться однією командою |
| choco-packages.config / scoop.json | Пакети Chocolatey / Scoop (якщо були) |
| installed-programs.csv | Повний список установлених програм ({NPROG} шт.) - для звірки |
| store-appx-packages.csv | Застосунки Microsoft Store |
| vscode-extensions.txt | Розширення VS Code |
| powershell-modules.csv | Модулі PowerShell для `Install-Module` |
| python-pip-freeze.txt / npm-global.txt | Глобальні пакети Python / Node |
| steam-games.txt | Встановлені ігри Steam |
| config-files\ | Копії конфігів (git, PowerShell, Terminal, VS Code, SSH config, OBS, Notepad++) |
| appearance.txt | Тема, колір акценту, прозорість, шлях до шпалер |
| *.theme | Файл теми Windows - подвійний клік після переустановки |
| wallpaper.* / TranscodedWallpaper.jpg | Шпалери робочого столу |
| reg-explorer-advanced.reg | Налаштування Провідника (розширення, приховані файли) |
| reg-personalize.reg / reg-controlpanel-desktop.reg | Тема, ефекти робочого столу |
| reg-taskbar-stuckrects.reg | Позиція / розмір панелі задач |
| reg-mouse.reg / reg-accessibility.reg | Миша, спец. можливості |
| reg-keyboard-layouts.reg / reg-fileexts.reg | Розкладки, асоціації файлів |
| windows-features-enabled.csv | Увімкнені компоненти Windows ({ADMINNOTE}) |
| windows-capabilities-installed.csv | Features on Demand (OpenSSH, RSAT, мовні пакети) |
| windows-features-dism.txt | Те саме таблицею DISM (резерв) |
| drivers-thirdparty.txt | Сторонні драйвери (імена oemNN.inf, версії) |
| startup-programs.csv / startup-folder.csv | Автозапуск (реєстр + папки Startup) |
| services-thirdparty.csv | Сторонні служби |
| scheduled-tasks-custom.csv | Твої заплановані задачі |
| printers.csv / vpn-connections.csv | Принтери, VPN-з'єднання |
| credential-manager-targets.txt | Назви збережених логінів (без паролів) |
| hosts.txt | Файл hosts (якщо змінювався) |
| environment-variables-user.csv / -machine.csv, PATH-*.txt | Постійні змінні середовища |
| system-info.txt, disks.csv | Залізо і диски |
| input-languages.csv, wifi-profile-names.txt | Мови вводу, назви Wi-Fi |
| wsl-distros.txt, mapped-drives.csv | WSL, мережеві диски |
| fonts-user-installed.csv | Шрифти, встановлені користувачем |
| power-plan.txt | Схема живлення |
| taskbar-pinned.txt | Що було закріплено на панелі задач |
| !ПРИВАТНЕ-НЕ-ПУБЛІКУВАТИ.txt / !МОЖЛИВІ-СЕКРЕТИ.txt | Попередження + автоскан на секрети |
| _manifest.log | Лог: що зібралось, що пропущено |

## Чого НЕМАЄ у знімку - зробити вручну

- Особисті файли (Documents, Downloads, проєкти) - на зовнішній диск / у хмару.
- SSH-ключі (`~\.ssh\id_*`) - лише config скопійовано, самі ключі НІ. Бекап окремо й безпечно.
- Паролі й ліцензійні ключі до платних програм.
- Креди хмар/контейнерів: `.aws\`, `.azure\`, `.kube\config`, `.docker\config.json` - НЕ копіюються.
- З'єднання DBeaver з паролями: `%APPDATA%\DBeaverData\workspace6\General\.dbeaver`
- Віртуалки VirtualBox (.vdi/.vbox), образи та томи Docker, локальні бази PostgreSQL (`pg_dumpall`).
- Firefox/Chrome: закладки/паролі/розширення - через Sync або експорт профілю.
- OBS stream key - вирізано з obs-studio_basic\ (постав заново в OBS -> Settings -> Stream).
- Пароль WebUI qBittorrent - вирізано з qBittorrent.ini.
- Паролі Wi-Fi (якщо скрипт запускали без -IncludeWifiKeys).

---
*Згенеровано автоматично {DATE}.*
'@
    $tpl = $tpl.Replace('{HOST}', $env:COMPUTERNAME).
                Replace('{DATE}', (Get-Date -Format 'yyyy-MM-dd HH:mm')).
                Replace('{SYSINFO}', $sysinfo.TrimEnd()).
                Replace('{NPROG}', "$nprog").
                Replace('{ADMINNOTE}', $adminNote)
    $tpl | Set-Content (& $P 'README.md') -Encoding UTF8
}

# ================================================================
#  ГЕНЕРАЦІЯ ЩО-ВСТАНОВИТИ.txt
# ================================================================
Step "Генерую ЩО-ВСТАНОВИТИ.txt" {

    # Дружні назви для відомих winget-ID, згруповані по категоріях
    $catalog = [ordered]@{
        "БРАУЗЕРИ" = [ordered]@{
            'Mozilla.Firefox'='Mozilla Firefox'
            'Google.Chrome'='Google Chrome'
            'Brave.Brave'='Brave'
        }
        "ЗВ'ЯЗОК / МЕСЕНДЖЕРИ" = [ordered]@{
            'Telegram.TelegramDesktop'='Telegram Desktop'
            'Discord.Discord'='Discord'
            'Zoom.Zoom'='Zoom (Zoom Workplace)'
            'SlackTechnologies.Slack'='Slack'
        }
        "РОЗРОБКА - РЕДАКТОРИ ТА ІНСТРУМЕНТИ" = [ordered]@{
            'Microsoft.VisualStudioCode'='Visual Studio Code'
            'DBeaver.DBeaver.Community'='DBeaver Community (клієнт БД)'
            'Postman.Postman'='Postman (тестування API)'
            'Notepad++.Notepad++'='Notepad++'
            'Anthropic.ClaudeCode'='Claude Code (CLI-асистент)'
            'Microsoft.VisualStudio.2022.Community'='Visual Studio 2022 Community'
        }
        "РОЗРОБКА - МОВИ ТА СЕРЕДОВИЩА" = [ordered]@{
            'Git.Git'='Git'
            'GitHub.cli'='GitHub CLI'
            'OpenJS.NodeJS.LTS'='Node.js LTS'
            'Python.Python.3.13'='Python 3.13'
            'Python.Python.3.12'='Python 3.12'
            'Python.Launcher'='Python Launcher'
            'EclipseAdoptium.Temurin.25.JDK'='Eclipse Temurin JDK 25 (Java)'
            'EclipseAdoptium.Temurin.21.JDK'='Eclipse Temurin JDK 21 (Java)'
            'PostgreSQL.PostgreSQL.17'='PostgreSQL 17 (сервер БД)'
            'Rustlang.Rustup'='Rust (rustup)'
            'GoLang.Go'='Go'
        }
        "ВІРТУАЛІЗАЦІЯ / КОНТЕЙНЕРИ" = [ordered]@{
            'Docker.DockerDesktop'='Docker Desktop'
            'Oracle.VirtualBox'='Oracle VirtualBox'
            'Microsoft.WSL'='WSL (Windows Subsystem for Linux)'
        }
        "ТЕРМІНАЛ / ОБОЛОНКА" = [ordered]@{
            'Microsoft.WindowsTerminal'='Windows Terminal'
            'Microsoft.PowerShell'='PowerShell 7'
            'JanDeDobbeleer.OhMyPosh'='Oh My Posh (промпт)'
            'ajeetdsouza.zoxide'='zoxide (розумний cd)'
            'M2Team.NanaZip'='NanaZip (архіватор, форк 7-Zip)'
            '7zip.7zip'='7-Zip'
        }
        "МУЛЬТИМЕДІА / ОФІС" = [ordered]@{
            'TheDocumentFoundation.LibreOffice'='LibreOffice'
            'OBSProject.OBSStudio'='OBS Studio (запис / стрім екрана)'
            'VideoLAN.VLC'='VLC'
            'GIMP.GIMP'='GIMP'
        }
        "ЗАВАНТАЖЕННЯ / ТЕЛЕФОН" = [ordered]@{
            'qBittorrent.qBittorrent'='qBittorrent (торренти)'
            'Genymobile.scrcpy'='scrcpy (керування Android з ПК)'
        }
        "МЕРЕЖА / ДІАГНОСТИКА" = [ordered]@{
            'WiresharkFoundation.Wireshark'='Wireshark'
            'WinsiderSS.SystemInformer'='System Informer (форк Process Hacker)'
            'CharlesMilette.TranslucentTB'='TranslucentTB (прозора панель задач)'
        }
        "ДРАЙВЕРИ ТА ФІРМОВІ УТИЛІТИ" = [ordered]@{
            'Intel.IntelDriverAndSupportAssistant'='Intel Driver & Support Assistant'
            'Nvidia.GeForceExperience'='NVIDIA GeForce Experience / NVIDIA App'
        }
        "ІГРИ (лаунчери)" = [ordered]@{
            'Valve.Steam'='Steam'
            'EpicGames.EpicGamesLauncher'='Epic Games Launcher'
        }
    }

    # ID, які ставляться самі як залежність - у список не виносимо
    $skipLike = @(
        'Microsoft.VCRedist*','Microsoft.DotNet*','Microsoft.UI.Xaml*','Microsoft.VCLibs*',
        'Microsoft.WindowsAppRuntime*','Microsoft.GameInput','Microsoft.AppInstaller',
        'Microsoft.DirectX','Nvidia.PhysX','Microsoft.WindowsSDK*','Microsoft.Edge*',
        'Microsoft.WebView2*','Microsoft.WindowsPCHealthCheck'
    )

    # Реальні ID з winget-export
    $ids=@()
    try {
        $j = Get-Content (& $P 'winget-packages.json') -Raw | ConvertFrom-Json
        $ids = @($j.Sources.Packages.PackageIdentifier)
    } catch {}

    $used = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $out  = New-Object System.Collections.Generic.List[string]

    $out.Add("====================================================================")
    $out.Add("  ЩО ВСТАНОВИТИ ПІСЛЯ ПЕРЕУСТАНОВКИ WINDOWS")
    $out.Add("  Простий список. Без команд. Знімок $env:COMPUTERNAME від $(Get-Date -Format 'yyyy-MM-dd').")
    $out.Add("====================================================================")
    $out.Add("")

    foreach($cat in $catalog.Keys){
        $lines=@()
        foreach($id in $catalog[$cat].Keys){
            if ($ids -contains $id) { $lines += "[ ] " + $catalog[$cat][$id]; [void]$used.Add($id) }
        }
        if ($lines.Count){
            $out.Add("--------------------------------------------------------------------")
            $out.Add($cat)
            $out.Add("--------------------------------------------------------------------")
            $lines | ForEach-Object { $out.Add($_) }
            $out.Add("")
        }
    }

    # Невідомі ID
    $unknown = @($ids | Where-Object {
        $id=$_; -not $used.Contains($id) -and -not ($skipLike | Where-Object { $id -like $_ })
    } | Sort-Object -Unique)
    if ($unknown.Count){
        $out.Add("--------------------------------------------------------------------")
        $out.Add("ІНШІ ПРОГРАМИ (winget import їх поставить; перевір, що це)")
        $out.Add("--------------------------------------------------------------------")
        $unknown | ForEach-Object { $out.Add("[ ] $_") }
        $out.Add("")
    }

    $out.Add("--------------------------------------------------------------------")
    $out.Add("СТАВЛЯТЬСЯ АВТОМАТИЧНО - окремо НЕ треба")
    $out.Add("--------------------------------------------------------------------")
    $out.Add("Visual C++ Redistributable, .NET Runtime/Desktop/ASP.NET, DirectX,")
    $out.Add("NVIDIA PhysX, Windows App Runtime, UI.Xaml, VCLibs, WebView2 -")
    $out.Add("прийдуть з Windows Update, з іграми або як залежність інших програм.")
    $out.Add("")

    # Ігри Steam
    if (Test-Path (& $P 'steam-games.txt')) {
        $g = Get-Content (& $P 'steam-games.txt') | Where-Object { $_ }
        if ($g) {
            $out.Add("--------------------------------------------------------------------")
            $out.Add("ІГРИ STEAM (зайти в акаунт і завантажити)")
            $out.Add("--------------------------------------------------------------------")
            $g | ForEach-Object { $out.Add("[ ] $_") }
            $out.Add("")
        }
    }

    # Розширення VS Code
    if (Test-Path (& $P 'vscode-extensions.txt')) {
        $friendly=@{
            'charliermarsh.ruff'='Ruff (лінтер Python)'
            'ms-python.python'='Python (Microsoft)'
            'ms-python.vscode-pylance'='Pylance'
            'ms-python.debugpy'='Python Debugger'
            'ms-python.vscode-python-envs'='Python Environments'
            'redhat.java'='Language Support for Java (Red Hat)'
            'vscjava.vscode-java-debug'='Debugger for Java'
            'vscjava.vscode-java-dependency'='Java Dependency Viewer'
            'vscjava.vscode-java-test'='Test Runner for Java'
            'vscjava.vscode-maven'='Maven for Java'
        }
        $out.Add("--------------------------------------------------------------------")
        $out.Add("РОЗШИРЕННЯ VS CODE  (простіше: увімкнути Settings Sync)")
        $out.Add("--------------------------------------------------------------------")
        Get-Content (& $P 'vscode-extensions.txt') | ForEach-Object {
            $eid = ($_ -split '@')[0]
            if ($eid) { $out.Add("[ ] " + ($(if($friendly[$eid]){$friendly[$eid]}else{$eid}))) }
        }
        $out.Add("")
    }

    # Модулі PowerShell
    if (Test-Path (& $P 'powershell-modules.csv')) {
        $m = Import-Csv (& $P 'powershell-modules.csv')
        if ($m) {
            $out.Add("--------------------------------------------------------------------")
            $out.Add("МОДУЛІ POWERSHELL  (Install-Module <Name> -Scope CurrentUser)")
            $out.Add("--------------------------------------------------------------------")
            $m | ForEach-Object { $out.Add("[ ] $($_.Name)") }
            $out.Add("[ ] PSReadLine  (оновити до останньої версії)")
            $out.Add("")
        }
    }

    $out.Add("--------------------------------------------------------------------")
    $out.Add("ВРУЧНУ (нема в winget / потребує уваги)")
    $out.Add("--------------------------------------------------------------------")
    $out.Add("[ ] Драйвери з сайту виробника ноутбука (звук, Wi-Fi, чіпсет)")
    $out.Add("[ ] Фірмові утиліти ноутбука (support assistant, аудіо-панель)")
    $out.Add("[ ] Nerd Font для терміналу (CaskaydiaCove NF або MesloLGS NF)")
    $out.Add("    -> потім вибрати цей шрифт у Windows Terminal")
    $out.Add("")
    $out.Add("--------------------------------------------------------------------")
    $out.Add("НАЛАШТУВАННЯ / АКАУНТИ (не програми - не забути)")
    $out.Add("--------------------------------------------------------------------")
    $out.Add("[ ] Увійти в той самий акаунт Microsoft (активація Windows)")
    $out.Add("[ ] Firefox / Chrome - увімкнути Sync")
    $out.Add("[ ] VS Code - Settings Sync")
    $out.Add("[ ] Steam / Postman - увійти в акаунт")
    $out.Add("[ ] Конфіги з папки config-files покласти назад")
    $out.Add("[ ] Тема Windows - відкрити файл *.theme")
    $out.Add("[ ] Шпалери - поставити файл wallpaper.*")
    $out.Add("[ ] Панель задач - закріпити програми зі taskbar-pinned.txt")
    $out.Add("[ ] Компоненти Windows - увімкнути за windows-features-enabled.csv")
    $out.Add("[ ] Принтери (printers.csv), VPN (vpn-connections.csv)")
    $out.Add("[ ] Розкладки клавіатури - за input-languages.csv")
    $out.Add("[ ] Wi-Fi - під'єднатись заново")
    $out.Add("")
    $out.Add("====================================================================")
    $out.Add("  Повний перелік з версіями - installed-programs.csv")
    $out.Add("  Команди та детальний план - README.md")
    $out.Add("====================================================================")

    $out -join "`r`n" | Set-Content (& $P 'ЩО-ВСТАНОВИТИ.txt') -Encoding UTF8
}

# ================================================================
#  ZIP + підсумок
# ================================================================
if ($Zip) {
    Step "Пакую в .zip" {
        $zipPath = "$dir.zip"
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Compress-Archive -Path "$dir\*" -DestinationPath $zipPath -CompressionLevel Optimal
    }
}

$files = Get-ChildItem $dir -Recurse -File
$size  = [math]::Round(($files | Measure-Object Length -Sum).Sum/1MB, 2)

Write-Host ""
Write-Host "  ГОТОВО." -ForegroundColor Green
Write-Host "  Папка : $dir"
Write-Host "  Файлів: $($files.Count)   Розмір: $size MB"
if ($Zip) { Write-Host "  Архів : $dir.zip" }
if ($secretCount -gt 0 -and -not $Redact) {
    Write-Host "  УВАГА: знайдено $secretCount рядків, схожих на ключі/паролі." -ForegroundColor Red
    Write-Host "         Перевір !МОЖЛИВІ-СЕКРЕТИ.txt перед тим, як кудись копіювати папку." -ForegroundColor Red
    Write-Host "         (для хмари/передачі перегенеруй із -Redact)" -ForegroundColor Red
    Write-Host ""
}
Write-Host "  Далі:  1) переглянь README.md і ЩО-ВСТАНОВИТИ.txt" -ForegroundColor Cyan
Write-Host "         2) папка містить приватні дані - тримай її на флешці / у приватному сховищі" -ForegroundColor Yellow
Write-Host "         3) СКОПІЮЙ цю папку кудись, де вона переживе переустановку" -ForegroundColor Cyan
Write-Host ""

try { Invoke-Item $dir } catch {}
if ($isAdmin -and $MyInvocation.MyCommand.Path -and -not $NoElevate) {
    Write-Host "  (вікно закриється за 20 с)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 20
}
