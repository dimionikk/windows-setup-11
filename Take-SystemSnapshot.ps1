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

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    $setup = Join-Path $PSScriptRoot 'Setup.ps1'
    if (Test-Path $setup) {
        $ans = Read-Host "  winget не знайдено - потрібні залежності. Встановити зараз? [Y/n]"
        if ($ans -notmatch '^\s*[nNнН]') {
            & $setup -NoElevate -SkipPwsh
            Write-Host "`n  Залежності оброблено. Запусти знімок ще раз.`n" -ForegroundColor Cyan
            exit
        }
    }
}

if (-not $OutputRoot) { $OutputRoot = [Environment]::GetFolderPath('Desktop') }
if (-not (Test-Path -LiteralPath $OutputRoot)) { throw "Немає такого шляху: $OutputRoot" }

$stamp    = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$dir      = Join-Path $OutputRoot "SystemSnapshot_$stamp"
$cfg      = Join-Path $dir 'config-files'
$manifest = Join-Path $dir '_manifest.log'
New-Item -ItemType Directory -Force -Path $dir, $cfg | Out-Null
"Знімок системи $stamp"                                                          | Set-Content $manifest -Encoding UTF8
"Комп'ютер: $env:COMPUTERNAME   Користувач: $env:USERNAME   Адмін: $isAdmin`r`n" | Add-Content $manifest -Encoding UTF8

Write-Host "`n  Знімок -> $dir`n" -ForegroundColor Cyan

function Have([string]$name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }
function F([string]$name)    { Join-Path $dir $name }

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
"@ | Set-Content (F 'system-info.txt') -Encoding UTF8
    Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter,FileSystemLabel,FileSystem,
        @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},@{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}} |
        Export-Csv (F 'disks.csv') -NoTypeInformation -Encoding UTF8
}

Step "Встановлені програми (реєстр)" {
    Get-ItemProperty @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    ) -ErrorAction SilentlyContinue |
        Where-Object DisplayName |
        Select-Object DisplayName,DisplayVersion,Publisher,InstallDate |
        Sort-Object DisplayName -Unique |
        Export-Csv (F 'installed-programs.csv') -NoTypeInformation -Encoding UTF8
}

Step "Застосунки Microsoft Store" {
    Get-AppxPackage | Select-Object Name,PackageFullName,Version | Sort-Object Name |
        Export-Csv (F 'store-appx-packages.csv') -NoTypeInformation -Encoding UTF8
}

Step "winget export" {
    if (-not (Have winget)) { throw "winget не встановлено" }
    winget export -o (F 'winget-packages.json') --include-versions --accept-source-agreements | Out-Null
}

Step "Chocolatey / Scoop" {
    $any = $false
    if (Have choco) { & choco export -o="$(F 'choco-packages.config')" | Out-Null; $any = $true }
    if (Have scoop) { scoop export 2>$null | Set-Content (F 'scoop.json') -Encoding UTF8; $any = $true }
    if (-not $any) { throw "ні choco, ні scoop не встановлено" }
}

Step "Розширення VS Code" {
    if (-not (Have code)) { throw "code не в PATH" }
    code --list-extensions --show-versions | Set-Content (F 'vscode-extensions.txt') -Encoding UTF8
}

Step "Модулі PowerShell" {
    @("$HOME\Documents\PowerShell\Modules","$HOME\Documents\WindowsPowerShell\Modules") |
        Where-Object { Test-Path $_ } |
        ForEach-Object {
            $root = $_
            Get-ChildItem $root -Directory -EA SilentlyContinue | ForEach-Object {
                $v = (Get-ChildItem $_.FullName -Directory -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1).Name
                [pscustomobject]@{ Name=$_.Name; Version=$v; Root=$root }
            }
        } | Sort-Object Name -Unique |
        Export-Csv (F 'powershell-modules.csv') -NoTypeInformation -Encoding UTF8
}

Step "Python pip / Node npm" {
    if (Have python) { python -m pip list --format=freeze 2>$null | Set-Content (F 'python-pip-freeze.txt') -Encoding UTF8 }
    if (Have npm)    { cmd /c "npm ls -g --depth=0 2>nul"      | Set-Content (F 'npm-global.txt')        -Encoding UTF8 }
}

Step "Змінні середовища та PATH (User + Machine)" {
    foreach ($scope in 'User','Machine') {
        $h = [Environment]::GetEnvironmentVariables($scope)
        $h.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Name=$_; Value=$h[$_] } } |
            Export-Csv (F "environment-variables-$($scope.ToLower()).csv") -NoTypeInformation -Encoding UTF8
    }
    [Environment]::GetEnvironmentVariable('Path','User')    | Set-Content (F 'PATH-user.txt')    -Encoding UTF8
    [Environment]::GetEnvironmentVariable('Path','Machine') | Set-Content (F 'PATH-machine.txt') -Encoding UTF8
}

Step "Вигляд: тема, колір, шпалери" {
    $pers = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -EA SilentlyContinue
    $dwm  = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -EA SilentlyContinue
    $desk = Get-ItemProperty 'HKCU:\Control Panel\Desktop' -EA SilentlyContinue
    $wp   = $desk.WallPaper
    $ct   = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes' -Name CurrentTheme -EA SilentlyContinue).CurrentTheme
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
"@ | Set-Content (F 'appearance.txt') -Encoding UTF8
    if ($ct -and (Test-Path -LiteralPath $ct)) {
        Copy-Item -LiteralPath $ct -Destination (F (Split-Path $ct -Leaf)) -Force
    }
    if ($wp -and (Test-Path -LiteralPath $wp)) {
        Copy-Item -LiteralPath $wp -Destination (F ("wallpaper" + [IO.Path]::GetExtension($wp))) -Force
    }
    CopyIf "$env:APPDATA\Microsoft\Windows\Themes\TranscodedWallpaper" (F 'TranscodedWallpaper.jpg')
}

Step "Твіки реєстру (.reg)" {
    $ex = @{
        'reg-explorer-advanced.reg'    = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        'reg-personalize.reg'          = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        'reg-controlpanel-desktop.reg' = 'HKCU\Control Panel\Desktop'
        'reg-keyboard-layouts.reg'     = 'HKCU\Keyboard Layout\Preload'
        'reg-taskbar-stuckrects.reg'   = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
        'reg-mouse.reg'                = 'HKCU\Control Panel\Mouse'
        'reg-accessibility.reg'        = 'HKCU\Control Panel\Accessibility'
        'reg-fileexts.reg'             = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
    }
    foreach ($k in $ex.Keys) { & reg.exe export $ex[$k] (F $k) /y 2>$null | Out-Null }
}

Step "Шрифти користувача" {
    Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" -EA SilentlyContinue |
        Select-Object Name,Length | Export-Csv (F 'fonts-user-installed.csv') -NoTypeInformation -Encoding UTF8
}

Step "Автозапуск (реєстр)" {
    Get-CimInstance Win32_StartupCommand | Select-Object Name,Command,Location,User |
        Export-Csv (F 'startup-programs.csv') -NoTypeInformation -Encoding UTF8
}

Step "Автозапуск (папки Startup)" {
    @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
      "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup") |
        ForEach-Object { Get-ChildItem $_ -EA SilentlyContinue } |
        Select-Object Name,FullName,LastWriteTime |
        Export-Csv (F 'startup-folder.csv') -NoTypeInformation -Encoding UTF8
}

Step "Заплановані задачі (не системні)" {
    Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
        Select-Object TaskName,TaskPath,State,@{n='Action';e={($_.Actions.Execute -join '; ')}} |
        Export-Csv (F 'scheduled-tasks-custom.csv') -NoTypeInformation -Encoding UTF8
}

Step "Служби (сторонні)" {
    Get-CimInstance Win32_Service | Where-Object { $_.PathName -and $_.PathName -notlike '*\Windows\*' } |
        Select-Object Name,DisplayName,StartMode,State,PathName | Sort-Object DisplayName |
        Export-Csv (F 'services-thirdparty.csv') -NoTypeInformation -Encoding UTF8
}

Step "Схема живлення" {
    & powercfg /getactivescheme | Set-Content (F 'power-plan.txt') -Encoding UTF8
    & powercfg /list           | Add-Content (F 'power-plan.txt') -Encoding UTF8
}

Step "Принтери" {
    Get-Printer -EA SilentlyContinue | Select-Object Name,DriverName,PortName,Shared,Published,Type |
        Export-Csv (F 'printers.csv') -NoTypeInformation -Encoding UTF8
}

Step "VPN-з'єднання" {
    @(Get-VpnConnection -EA SilentlyContinue; Get-VpnConnection -AllUserConnection -EA SilentlyContinue) |
        Where-Object Name | Select-Object Name,ServerAddress,TunnelType,AuthenticationMethod -Unique |
        Export-Csv (F 'vpn-connections.csv') -NoTypeInformation -Encoding UTF8
}

Step "Збережені логіни (лише назви)" {
    & cmdkey /list | Set-Content (F 'credential-manager-targets.txt') -Encoding UTF8
}

Step "hosts-файл" {
    CopyIf "$env:WINDIR\System32\drivers\etc\hosts" (F 'hosts.txt')
}

Step "Мови вводу та Wi-Fi" {
    Get-WinUserLanguageList | Select-Object LanguageTag,@{n='InputMethods';e={$_.InputMethodTips -join ','}} |
        Export-Csv (F 'input-languages.csv') -NoTypeInformation -Encoding UTF8
    netsh wlan show profiles 2>$null | Set-Content (F 'wifi-profile-names.txt') -Encoding UTF8
    if ($IncludeWifiKeys) {
        $wd = Join-Path $dir 'wifi-profiles'
        New-Item -ItemType Directory -Force -Path $wd | Out-Null
        netsh wlan export profile key=clear folder="$wd" 2>$null | Out-Null
    }
}

Step "WSL-дистрибутиви" {
    if (-not (Have wsl)) { throw "WSL не встановлено" }
    wsl --list --verbose 2>$null | Set-Content (F 'wsl-distros.txt') -Encoding UTF8
}

Step "Мережеві диски" {
    Get-SmbMapping -EA SilentlyContinue | Select-Object LocalPath,RemotePath,Status |
        Export-Csv (F 'mapped-drives.csv') -NoTypeInformation -Encoding UTF8
}

Step "Закріплене на панелі задач" {
    $tb = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    if (Test-Path $tb) { (Get-ChildItem $tb -Filter *.lnk).BaseName | Set-Content (F 'taskbar-pinned.txt') -Encoding UTF8 }
}

Step "Конфіги (git / PowerShell / Terminal / VS Code / SSH config)" {
    @(
        "$HOME\.gitconfig", "$HOME\.wslconfig", "$HOME\.bashrc", "$HOME\.bash_profile", "$HOME\.condarc",
        "$HOME\.ssh\config",
        $PROFILE.CurrentUserAllHosts, $PROFILE,
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:APPDATA\Code\User\settings.json", "$env:APPDATA\Code\User\keybindings.json",
        "$env:APPDATA\Code\User\snippets",
        "$env:LOCALAPPDATA\oh-my-posh\themes\powerlevel10k_rainbow.omp.json",
        "$HOME\.config\starship.toml"
    ) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
        $safe = ($_ -replace [regex]::Escape($HOME),'~') -replace '[:\\/]','_'
        Copy-Item -LiteralPath $_ -Destination (Join-Path $cfg $safe) -Recurse -Force
    }
}

Step "Конфіги застосунків (OBS / Notepad++ / qBittorrent)" {
    $obsSrc = "$env:APPDATA\obs-studio\basic"
    if (Test-Path $obsSrc) {
        $obsDst = Join-Path $cfg 'obs-studio_basic'
        Copy-Item -LiteralPath $obsSrc -Destination $obsDst -Recurse -Force
        Get-ChildItem $obsDst -Recurse -File -Force -EA SilentlyContinue |
            Where-Object { $_.Name -in 'service.json','service.json.bak' } |
            Remove-Item -Force -EA SilentlyContinue
    }
    CopyIf "$env:APPDATA\Notepad++\config.xml"    (Join-Path $cfg 'notepad++_config.xml')
    CopyIf "$env:APPDATA\Notepad++\session.xml"   (Join-Path $cfg 'notepad++_session.xml')
    CopyIf "$env:APPDATA\Notepad++\shortcuts.xml" (Join-Path $cfg 'notepad++_shortcuts.xml')
    $qb = "$env:APPDATA\qBittorrent\qBittorrent.ini"
    if (Test-Path $qb) {
        Get-Content $qb |
            Where-Object { $_ -notmatch '(?i)(password|username=|\bsecret\b|token)' } |
            Set-Content (Join-Path $cfg 'qBittorrent.ini') -Encoding UTF8
    }
}

Step "Ігри Steam" {
    $sp = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -EA SilentlyContinue).SteamPath
    if (-not $sp) { throw "Steam не знайдено" }
    $libs = @("$sp\steamapps")
    $vdf  = "$sp\steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' | ForEach-Object {
            $libs += (($_.Matches[0].Groups[1].Value) -replace '\\\\','\') + "\steamapps"
        }
    }
    $notGames = 'Steamworks Common Redistributables|^Proton|^Steam Linux Runtime|^SteamVR'
    $libs | Sort-Object -Unique | ForEach-Object {
        Get-ChildItem "$_\appmanifest_*.acf" -EA SilentlyContinue | ForEach-Object {
            $m = Select-String -Path $_.FullName -Pattern '"name"\s+"([^"]+)"' | Select-Object -First 1
            if ($m) { $m.Matches[0].Groups[1].Value }
        }
    } | Where-Object { $_ -and $_ -notmatch $notGames } | Sort-Object -Unique |
        Set-Content (F 'steam-games.txt') -Encoding UTF8
}

if ($isAdmin) {
    Step "Компоненти Windows (увімкнені)" {
        Get-WindowsOptionalFeature -Online | Where-Object State -eq 'Enabled' |
            Select-Object FeatureName | Sort-Object FeatureName |
            Export-Csv (F 'windows-features-enabled.csv') -NoTypeInformation -Encoding UTF8
    }
    Step "Features on Demand" {
        Get-WindowsCapability -Online | Where-Object State -eq 'Installed' |
            Select-Object Name | Sort-Object Name |
            Export-Csv (F 'windows-capabilities-installed.csv') -NoTypeInformation -Encoding UTF8
    }
    Step "Компоненти Windows (DISM)" {
        & dism /online /get-features /format:table | Set-Content (F 'windows-features-dism.txt') -Encoding UTF8
    }
    Step "Сторонні драйвери" {
        & pnputil /enum-drivers | Set-Content (F 'drivers-thirdparty.txt') -Encoding UTF8
    }
} else {
    "SKIP  Компоненти Windows / драйвери  --  запущено без прав адміністратора" | Add-Content $manifest -Encoding UTF8
    Write-Host "  (компоненти Windows і драйвери пропущено - немає прав адміна)" -ForegroundColor DarkYellow
}

$secretCount = 0
Step "Сканування зібраного на секрети" {
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
            $exts -contains $_.Extension.ToLower() -or $_.Name -like '*profile.ps1' -or $_.Name -like '~_.*'
        )
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $scan) {
        Select-String -LiteralPath $f.FullName -Pattern $rx -EA SilentlyContinue | Select-Object -First 40 |
            ForEach-Object { $rows.Add([pscustomobject]@{ File=$f.FullName.Replace("$dir\",''); Where="рядок $($_.LineNumber)" }) }
    }
    foreach ($csv in 'environment-variables-user.csv','environment-variables-machine.csv') {
        $cp = F $csv
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
    $body.Add("Евристика - можливі хибні спрацювання. Перед копіюванням папки кудись за")
    $body.Add("межі флешки / приватного сховища перевір ці місця. Часті джерела:")
    $body.Add(".bashrc, профіль PowerShell, .gitconfig, settings.json розширень VS Code,")
    $body.Add("environment-variables-*.csv.")
    $body.Add("")
    foreach ($r in $rows) { $body.Add(("{0}  :  {1}" -f $r.File, $r.Where)) }

    if ($Redact) {
        foreach ($f in $scan) {
            $c = Get-Content -LiteralPath $f.FullName -EA SilentlyContinue
            if ($c) {
                $c2 = $c | ForEach-Object { if ($_ -match $rx) { $_ -replace '([:=]\s*|","\s*)\S.*$', '$1***ВИРІЗАНО***' } else { $_ } }
                if (($c2 -join "`n") -ne ($c -join "`n")) { $c2 | Set-Content -LiteralPath $f.FullName -Encoding UTF8 }
            }
        }
        foreach ($csv in 'environment-variables-user.csv','environment-variables-machine.csv') {
            $cp = F $csv
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
    $body | Set-Content (F '!МОЖЛИВІ-СЕКРЕТИ.txt') -Encoding UTF8
}

Step "Файл-попередження про приватність" {
    $wifiLine = if ($IncludeWifiKeys) { "  - wifi-profiles\ - ПАРОЛІ ВІД WI-FI у відкритому вигляді" } else { "" }
@"
!!!  У ЦІЙ ПАПЦІ Є ПРИВАТНІ ДАНІ  !!!

Чутливе:
  - environment-variables-*.csv - постійні змінні середовища зі значеннями
  - config-files\ - .gitconfig, .bashrc, .condarc, профіль PowerShell,
    settings.json (VS Code / Terminal), .ssh\config
  - credential-manager-targets.txt - назви логінів (без паролів)
  - hosts.txt, vpn-connections.csv, mapped-drives.csv, printers.csv, system-info.txt
$wifiLine

НЕ береться навмисно:
  - приватні SSH-ключі, паролі браузера/DBeaver, .aws/.azure/.kube/.docker
  - OBS stream key, пароль WebUI qBittorrent
  - паролі Wi-Fi (якщо без -IncludeWifiKeys)

Що робити:
  - Спершу глянь !МОЖЛИВІ-СЕКРЕТИ.txt.
  - Тримай папку на флешці / у приватному сховищі. НЕ в публічному Git чи хмарі.
  - Для передачі / хмари - перегенеруй із -Redact.
"@ | Set-Content (F '!ПРИВАТНЕ-НЕ-ПУБЛІКУВАТИ.txt') -Encoding UTF8
}

Step "Генерую README.md" {
    $sysinfo   = if (Test-Path (F 'system-info.txt')) { (Get-Content (F 'system-info.txt') -Raw).TrimEnd() } else { '' }
    $nprog     = @(if (Test-Path (F 'installed-programs.csv')) { Import-Csv (F 'installed-programs.csv') }).Count
    $adminNote = if (Test-Path (F 'windows-features-enabled.csv')) { 'зібрано' } else { 'НЕ зібрано - запусти від адміністратора' }

    @"
# Знімок системи $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm')

Приватне. НЕ для публічного Git / хмари.
Чутливе - !ПРИВАТНЕ-НЕ-ПУБЛІКУВАТИ.txt ; автоскан ключів - !МОЖЛИВІ-СЕКРЕТИ.txt

``````
$sysinfo
``````

## Відновлення

1. Windows + той самий акаунт Microsoft (активація).
2. Windows Update + драйвери GPU (NVIDIA App / Intel DSA).
3. Компоненти Windows (адмін):
   Import-Csv .\windows-features-enabled.csv | ForEach-Object { Enable-WindowsOptionalFeature -Online -FeatureName `$_.FeatureName -All -NoRestart }
4. winget import -i .\winget-packages.json --accept-package-agreements --accept-source-agreements
5. Решта програм і Steam - ЩО-ВСТАНОВИТИ.txt
6. config-files\ назад: .gitconfig, профіль PowerShell, oh-my-posh тема,
   Terminal / VS Code settings.json, .ssh\config, obs-studio_basic -> %APPDATA%\obs-studio\basic
7. VS Code - Settings Sync або vscode-extensions.txt
8. Вигляд: *.theme, далі reg-*.reg (переглянь перед злиттям). Шпалери - wallpaper.*
9. taskbar-pinned.txt, printers.csv, vpn-connections.csv, input-languages.csv - вручну
10. Звірка - installed-programs.csv

## Ключові файли

| Файл | Що |
|---|---|
| winget-packages.json | усі програми з winget однією командою |
| ЩО-ВСТАНОВИТИ.txt | список решти по категоріях |
| installed-programs.csv | повний перелік ($nprog) для звірки |
| config-files\ | git, PowerShell, Terminal, VS Code, .ssh\config, OBS, Notepad++ |
| windows-features-enabled.csv | компоненти Windows ($adminNote) |
| *.theme, wallpaper.*, reg-*.reg | вигляд |
| environment-variables-*.csv | постійні змінні середовища |
| _manifest.log | що зібралось / пропущено |

## Не включено

Особисті файли, приватні SSH-ключі, паролі браузера/DBeaver, VM/Docker/БД,
креди .aws/.azure/.docker, OBS stream key, паролі Wi-Fi (без -IncludeWifiKeys).
"@ | Set-Content (F 'README.md') -Encoding UTF8
}

Step "Генерую ЩО-ВСТАНОВИТИ.txt" {
    $catalog = [ordered]@{
        "БРАУЗЕРИ" = [ordered]@{
            'Mozilla.Firefox'='Mozilla Firefox'; 'Google.Chrome'='Google Chrome'; 'Brave.Brave'='Brave'
        }
        "ЗВ'ЯЗОК / МЕСЕНДЖЕРИ" = [ordered]@{
            'Telegram.TelegramDesktop'='Telegram Desktop'; 'Discord.Discord'='Discord'
            'Zoom.Zoom'='Zoom (Zoom Workplace)'; 'SlackTechnologies.Slack'='Slack'
        }
        "РОЗРОБКА - РЕДАКТОРИ ТА ІНСТРУМЕНТИ" = [ordered]@{
            'Microsoft.VisualStudioCode'='Visual Studio Code'; 'DBeaver.DBeaver.Community'='DBeaver Community (клієнт БД)'
            'Postman.Postman'='Postman (тестування API)'; 'Notepad++.Notepad++'='Notepad++'
            'Anthropic.ClaudeCode'='Claude Code (CLI-асистент)'; 'Microsoft.VisualStudio.2022.Community'='Visual Studio 2022 Community'
        }
        "РОЗРОБКА - МОВИ ТА СЕРЕДОВИЩА" = [ordered]@{
            'Git.Git'='Git'; 'GitHub.cli'='GitHub CLI'; 'OpenJS.NodeJS.LTS'='Node.js LTS'
            'Python.Python.3.13'='Python 3.13'; 'Python.Python.3.12'='Python 3.12'; 'Python.Launcher'='Python Launcher'
            'EclipseAdoptium.Temurin.25.JDK'='Eclipse Temurin JDK 25 (Java)'; 'EclipseAdoptium.Temurin.21.JDK'='Eclipse Temurin JDK 21 (Java)'
            'PostgreSQL.PostgreSQL.17'='PostgreSQL 17 (сервер БД)'; 'Rustlang.Rustup'='Rust (rustup)'; 'GoLang.Go'='Go'
        }
        "ВІРТУАЛІЗАЦІЯ / КОНТЕЙНЕРИ" = [ordered]@{
            'Docker.DockerDesktop'='Docker Desktop'; 'Oracle.VirtualBox'='Oracle VirtualBox'; 'Microsoft.WSL'='WSL (Windows Subsystem for Linux)'
        }
        "ТЕРМІНАЛ / ОБОЛОНКА" = [ordered]@{
            'Microsoft.WindowsTerminal'='Windows Terminal'; 'Microsoft.PowerShell'='PowerShell 7'
            'JanDeDobbeleer.OhMyPosh'='Oh My Posh (промпт)'; 'ajeetdsouza.zoxide'='zoxide (розумний cd)'
            'M2Team.NanaZip'='NanaZip (архіватор, форк 7-Zip)'; '7zip.7zip'='7-Zip'
        }
        "МУЛЬТИМЕДІА / ОФІС" = [ordered]@{
            'TheDocumentFoundation.LibreOffice'='LibreOffice'; 'OBSProject.OBSStudio'='OBS Studio (запис / стрім екрана)'
            'VideoLAN.VLC'='VLC'; 'GIMP.GIMP'='GIMP'
        }
        "ЗАВАНТАЖЕННЯ / ТЕЛЕФОН" = [ordered]@{
            'qBittorrent.qBittorrent'='qBittorrent (торренти)'; 'Genymobile.scrcpy'='scrcpy (керування Android з ПК)'
        }
        "МЕРЕЖА / ДІАГНОСТИКА" = [ordered]@{
            'WiresharkFoundation.Wireshark'='Wireshark'; 'WinsiderSS.SystemInformer'='System Informer (форк Process Hacker)'
            'CharlesMilette.TranslucentTB'='TranslucentTB (прозора панель задач)'
        }
        "ДРАЙВЕРИ ТА ФІРМОВІ УТИЛІТИ" = [ordered]@{
            'Intel.IntelDriverAndSupportAssistant'='Intel Driver & Support Assistant'
            'Nvidia.GeForceExperience'='NVIDIA GeForce Experience / NVIDIA App'
        }
        "ІГРИ (лаунчери)" = [ordered]@{
            'Valve.Steam'='Steam'; 'EpicGames.EpicGamesLauncher'='Epic Games Launcher'
        }
    }
    $skipLike = @(
        'Microsoft.VCRedist*','Microsoft.DotNet*','Microsoft.UI.Xaml*','Microsoft.VCLibs*',
        'Microsoft.WindowsAppRuntime*','Microsoft.GameInput','Microsoft.AppInstaller',
        'Microsoft.DirectX','Nvidia.PhysX','Microsoft.WindowsSDK*','Microsoft.Edge*',
        'Microsoft.WebView2*','Microsoft.WindowsPCHealthCheck'
    )
    $friendly = @{
        'charliermarsh.ruff'='Ruff (лінтер Python)'; 'ms-python.python'='Python (Microsoft)'
        'ms-python.vscode-pylance'='Pylance'; 'ms-python.debugpy'='Python Debugger'
        'ms-python.vscode-python-envs'='Python Environments'; 'redhat.java'='Language Support for Java (Red Hat)'
        'vscjava.vscode-java-debug'='Debugger for Java'; 'vscjava.vscode-java-dependency'='Java Dependency Viewer'
        'vscjava.vscode-java-test'='Test Runner for Java'; 'vscjava.vscode-maven'='Maven for Java'
    }

    $ids = @()
    try { $ids = @((Get-Content (F 'winget-packages.json') -Raw | ConvertFrom-Json).Sources.Packages.PackageIdentifier) } catch {}

    $used = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $out  = New-Object System.Collections.Generic.List[string]
    function Section($title) { $out.Add(('-'*68)); $out.Add($title); $out.Add(('-'*68)) }

    $out.Add('='*68)
    $out.Add("  ЩО ВСТАНОВИТИ ПІСЛЯ ПЕРЕУСТАНОВКИ WINDOWS")
    $out.Add("  Знімок $env:COMPUTERNAME від $(Get-Date -Format 'yyyy-MM-dd').")
    $out.Add('='*68)
    $out.Add("")

    foreach ($cat in $catalog.Keys) {
        $lines = foreach ($id in $catalog[$cat].Keys) {
            if ($ids -contains $id) { [void]$used.Add($id); "[ ] " + $catalog[$cat][$id] }
        }
        if ($lines) { Section $cat; $lines | ForEach-Object { $out.Add($_) }; $out.Add("") }
    }

    $unknown = @($ids | Where-Object { $id=$_; -not $used.Contains($id) -and -not ($skipLike | Where-Object { $id -like $_ }) } | Sort-Object -Unique)
    if ($unknown) { Section "ІНШІ ПРОГРАМИ (winget import їх поставить; перевір, що це)"; $unknown | ForEach-Object { $out.Add("[ ] $_") }; $out.Add("") }

    Section "СТАВЛЯТЬСЯ АВТОМАТИЧНО - окремо НЕ треба"
    $out.Add("VC++ Redistributable, .NET, DirectX, PhysX, WebView2, UI.Xaml, VCLibs -")
    $out.Add("прийдуть з Windows Update, іграми або як залежність.")
    $out.Add("")

    if (Test-Path (F 'steam-games.txt')) {
        $g = Get-Content (F 'steam-games.txt') | Where-Object { $_ }
        if ($g) { Section "ІГРИ STEAM (зайти в акаунт)"; $g | ForEach-Object { $out.Add("[ ] $_") }; $out.Add("") }
    }
    if (Test-Path (F 'vscode-extensions.txt')) {
        Section "РОЗШИРЕННЯ VS CODE (простіше: Settings Sync)"
        Get-Content (F 'vscode-extensions.txt') | ForEach-Object {
            $eid = ($_ -split '@')[0]
            if ($eid) { $out.Add("[ ] " + $(if ($friendly[$eid]) { $friendly[$eid] } else { $eid })) }
        }
        $out.Add("")
    }
    if (Test-Path (F 'powershell-modules.csv')) {
        $m = Import-Csv (F 'powershell-modules.csv')
        if ($m) { Section "МОДУЛІ POWERSHELL (Install-Module <Name> -Scope CurrentUser)"; $m | ForEach-Object { $out.Add("[ ] $($_.Name)") }; $out.Add("[ ] PSReadLine (оновити)"); $out.Add("") }
    }

    Section "ВРУЧНУ"
    $out.Add("[ ] Драйвери з сайту виробника ноутбука (звук, Wi-Fi, чіпсет)")
    $out.Add("[ ] Фірмові утиліти ноутбука")
    $out.Add("[ ] Nerd Font для терміналу (CaskaydiaCove NF) -> вибрати в Windows Terminal")
    $out.Add("")
    Section "НАЛАШТУВАННЯ / АКАУНТИ"
    "Акаунт Microsoft (активація)","Firefox / Chrome Sync","VS Code Settings Sync",
    "Steam / Postman - вхід","Конфіги з config-files назад","Тема *.theme","Шпалери wallpaper.*",
    "Панель задач - taskbar-pinned.txt","Компоненти Windows - windows-features-enabled.csv",
    "Принтери / VPN - printers.csv / vpn-connections.csv","Розкладки - input-languages.csv",
    "Wi-Fi - під'єднатись заново" | ForEach-Object { $out.Add("[ ] $_") }
    $out.Add("")
    $out.Add('='*68)
    $out.Add("  Повний перелік - installed-programs.csv ; план - README.md")
    $out.Add('='*68)

    $out -join "`r`n" | Set-Content (F 'ЩО-ВСТАНОВИТИ.txt') -Encoding UTF8
}

if ($Zip) {
    Step "Пакую в .zip" {
        $zipPath = "$dir.zip"
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Compress-Archive -Path "$dir\*" -DestinationPath $zipPath -CompressionLevel Optimal
    }
}

$files = Get-ChildItem $dir -Recurse -File
$size  = [math]::Round(($files | Measure-Object Length -Sum).Sum/1MB, 2)

Write-Host "`n  ГОТОВО." -ForegroundColor Green
Write-Host "  Папка : $dir"
Write-Host "  Файлів: $($files.Count)   Розмір: $size MB"
if ($Zip) { Write-Host "  Архів : $dir.zip" }
if ($secretCount -gt 0 -and -not $Redact) {
    Write-Host "`n  УВАГА: $secretCount місць схожих на ключі/паролі - див. !МОЖЛИВІ-СЕКРЕТИ.txt" -ForegroundColor Red
    Write-Host "         (для передачі/хмари перегенеруй із -Redact)" -ForegroundColor Red
}
Write-Host "`n  Тримай папку на флешці / у приватному сховищі, не в публічному Git.`n" -ForegroundColor Yellow

try { Invoke-Item $dir } catch {}
if ($isAdmin -and $MyInvocation.MyCommand.Path -and -not $NoElevate) {
    Write-Host "  (вікно закриється за 20 с)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 20
}
