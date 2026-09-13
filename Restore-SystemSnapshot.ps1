# $Steps - рядок з розділювачем "|" (не масив!) - див. коментар у Take-SystemSnapshot.ps1.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SnapshotDir,
    [switch]$List,
    [string]$Steps
)

$ErrorActionPreference = 'Continue'
$ProgressPreference     = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Have([string]$name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# Має ТОЧНО відповідати іменам файлів зі списку $keys у Take-SystemSnapshot.ps1 (крок
# visual) - потрібно, щоб перед reg import зробити бекап поточного значення ключа.
$VisualKeyMap = @{
    'desktop'           = 'HKCU\Control Panel\Desktop'
    'cursors'           = 'HKCU\Control Panel\Cursors'
    'personalize'       = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    'explorer-advanced' = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    'taskbar-position'  = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
    'search'            = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search'
    'dwm'               = 'HKCU\Software\Microsoft\Windows\DWM'
    'accent'            = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
}

# Має ТОЧНО відповідати списку джерел у Take-SystemSnapshot.ps1 (крок settings) -
# інакше SafeName розійдеться і файл із знімка не знайдеться при відновленні.
function Get-ConfigCatalog {
    $items = @(
        [pscustomobject]@{ Id='cfg_gitconfig';      Label='.gitconfig (Git)';                Src="$HOME\.gitconfig" }
        [pscustomobject]@{ Id='cfg_ssh_config';      Label='.ssh\config (SSH клієнт)';        Src="$HOME\.ssh\config" }
        [pscustomobject]@{ Id='cfg_ps_profile';      Label='PowerShell профіль';              Src=[string]$PROFILE }
        [pscustomobject]@{ Id='cfg_winterm';         Label='Windows Terminal settings.json';  Src="$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json" }
        [pscustomobject]@{ Id='cfg_vscode_settings'; Label='VS Code settings.json';           Src="$env:APPDATA\Code\User\settings.json" }
        [pscustomobject]@{ Id='cfg_vscode_keybindings'; Label='VS Code keybindings.json';     Src="$env:APPDATA\Code\User\keybindings.json" }
        [pscustomobject]@{ Id='cfg_vscode_snippets'; Label='VS Code snippets';                Src="$env:APPDATA\Code\User\snippets" }
    )
    foreach ($it in $items) {
        if (-not $it.Src) { continue }
        $safe = ($it.Src -replace [regex]::Escape($HOME),'~') -replace '[:\\/]','_'
        Add-Member -InputObject $it -NotePropertyName SafeName -NotePropertyValue $safe -Force
        Add-Member -InputObject $it -NotePropertyName Dest -NotePropertyValue $it.Src -Force
    }
    $items | Where-Object { $_.Src }
}

function Get-SnapshotCatalog {
    param([string]$SnapshotDir)

    function F([string]$n) { Join-Path $SnapshotDir $n }
    $result = [ordered]@{
        winget = @(); vscode_ext = @(); config_files = @(); repos = @(); visual = $false
    }

    $wg = F 'programs.json'
    if (Test-Path -LiteralPath $wg) {
        try {
            $data = Get-Content -LiteralPath $wg -Raw | ConvertFrom-Json
            $ids = @($data.Sources.Packages.PackageIdentifier) | Where-Object { $_ } | Sort-Object -Unique
            $result.winget = @($ids | ForEach-Object { [ordered]@{ id = $_; label = $_ } })
        } catch {}
    }

    $vs = F 'vscode-extensions.txt'
    if (Test-Path -LiteralPath $vs) {
        $ids = Get-Content -LiteralPath $vs | ForEach-Object { ($_ -split '@')[0] } | Where-Object { $_ } | Sort-Object -Unique
        $result.vscode_ext = @($ids | ForEach-Object { [ordered]@{ id = $_; label = $_ } })
    }

    foreach ($item in Get-ConfigCatalog) {
        if (Test-Path -LiteralPath (Join-Path $SnapshotDir "settings\$($item.SafeName)")) {
            $result.config_files += [ordered]@{ id = $item.Id; label = $item.Label }
        }
    }

    $rp = F 'repos.csv'
    if (Test-Path -LiteralPath $rp) {
        $rows = Import-Csv -LiteralPath $rp | Where-Object { $_.RemoteUrl -and $_.RemoteUrl -ne '(локальний, без remote)' }
        $result.repos = @($rows | ForEach-Object { [ordered]@{ id = $_.Path; label = "$($_.Path)  ->  $($_.RemoteUrl)" } })
    }

    $result.visual = [bool](Test-Path -LiteralPath (Join-Path $SnapshotDir 'visual'))

    $result
}

function Invoke-SystemRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SnapshotDir,
        [string[]]$Steps
    )

    if (-not (Test-Path -LiteralPath $SnapshotDir)) { throw "Не знайдено знімок: $SnapshotDir" }
    $selected = [System.Collections.Generic.HashSet[string]]::new([string[]]$Steps, [StringComparer]::OrdinalIgnoreCase)
    function Sel([string]$id) { $selected.Contains($id) }
    function F([string]$name) { Join-Path $SnapshotDir $name }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    $repoMap = @{}
    if (Test-Path -LiteralPath (F 'repos.csv')) {
        Import-Csv -LiteralPath (F 'repos.csv') | ForEach-Object { $repoMap[$_.Path] = $_.RemoteUrl }
    }

    function Step {
        param([string]$Label, [scriptblock]$Do)
        Write-Host ("  {0,-56}" -f $Label) -NoNewline
        try {
            & $Do
            Write-Host "OK" -ForegroundColor Green
        } catch {
            Write-Host "пропущено" -ForegroundColor DarkYellow
            Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    Write-Host "`n  Відновлення з $SnapshotDir`n" -ForegroundColor Cyan

    foreach ($id in $Steps) {
        if ($id -like 'winget:*') {
            $pkgId = $id.Substring(7)
            Step "winget: $pkgId" {
                if (-not (Have winget)) { throw "winget не встановлено" }
                winget install --id $pkgId -e --source winget --accept-package-agreements --accept-source-agreements --silent 2>$null | Out-Null
            }
        }
    }
    foreach ($id in $Steps) {
        if ($id -like 'vscode:*') {
            $extId = $id.Substring(7)
            Step "VS Code: $extId" {
                if (-not (Have code)) { throw "code не в PATH" }
                code --install-extension $extId --force 2>$null | Out-Null
            }
        }
    }
    foreach ($item in Get-ConfigCatalog) {
        if (Sel $item.Id) {
            Step "Налаштування: $($item.Label)" {
                $src = Join-Path $SnapshotDir "settings\$($item.SafeName)"
                if (-not (Test-Path -LiteralPath $src)) { throw "у знімку немає цього файлу" }
                $dst = $item.Dest
                $dstDir = Split-Path $dst -Parent
                if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
                if (Test-Path -LiteralPath $dst) { Copy-Item -LiteralPath $dst -Destination "$dst.bak-$stamp" -Recurse -Force -ErrorAction SilentlyContinue }
                Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
            }
        }
    }
    foreach ($id in $Steps) {
        if ($id -like 'repo:*') {
            $repoPath = $id.Substring(5)
            Step "Репозиторій: $repoPath" {
                $url = $repoMap[$repoPath]
                if (-not $url -or $url -eq '(локальний, без remote)') { throw "немає адреси репозиторію" }
                if (Test-Path -LiteralPath $repoPath) { throw "папка вже існує - пропускаю, щоб не перезаписати" }
                if (-not (Have git)) { throw "git не встановлено" }
                $parent = Split-Path $repoPath -Parent
                if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
                git clone $url $repoPath 2>$null | Out-Null
            }
        }
    }
    if (Sel 'visual') {
        Step "Візуальне оформлення" {
            $visualDir = F 'visual'
            if (-not (Test-Path -LiteralPath $visualDir)) { throw "немає папки visual у знімку" }

            $backupDir = Join-Path ([Environment]::GetFolderPath('Desktop')) "SystemSnapshot-visual-backup-$stamp"
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

            # відновити оригінальний файл шпалини ДО імпорту desktop.reg - інакше реєстр
            # вкаже на шлях, якого ще нема
            $origPathFile = Join-Path $visualDir 'wallpaper-original-path.txt'
            if (Test-Path -LiteralPath $origPathFile) {
                $origPath = (Get-Content -LiteralPath $origPathFile -Raw -ErrorAction SilentlyContinue).Trim()
                $origSrc  = Get-ChildItem -LiteralPath $visualDir -Filter 'wallpaper-original.*' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($origPath -and $origSrc) {
                    $origDir = Split-Path $origPath -Parent
                    if ($origDir -and -not (Test-Path -LiteralPath $origDir)) { New-Item -ItemType Directory -Force -Path $origDir | Out-Null }
                    Copy-Item -LiteralPath $origSrc.FullName -Destination $origPath -Force -ErrorAction SilentlyContinue
                }
            }

            Get-ChildItem -LiteralPath $visualDir -Filter '*.reg' -ErrorAction SilentlyContinue | ForEach-Object {
                $keyPath = $VisualKeyMap[[IO.Path]::GetFileNameWithoutExtension($_.Name)]
                if ($keyPath) { & reg.exe export $keyPath (Join-Path $backupDir $_.Name) /y 2>$null | Out-Null }
                & reg.exe import $_.FullName 2>$null | Out-Null
            }

            $wallpaperSrc = Join-Path $visualDir 'wallpaper.jpg'
            if (Test-Path -LiteralPath $wallpaperSrc) {
                $wallpaperDst = "$env:APPDATA\Microsoft\Windows\Themes\TranscodedWallpaper"
                if (Test-Path -LiteralPath $wallpaperDst) { Copy-Item -LiteralPath $wallpaperDst -Destination "$wallpaperDst.bak-$stamp" -Force -ErrorAction SilentlyContinue }
                Copy-Item -LiteralPath $wallpaperSrc -Destination $wallpaperDst -Force
            }
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            Start-Process explorer.exe
            Write-Host "      (бекап попереднього реєстру: $backupDir)" -ForegroundColor DarkGray
        }
    }

    Write-Host "`n  ГОТОВО.`n" -ForegroundColor Green
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($List) {
        Get-SnapshotCatalog -SnapshotDir $SnapshotDir | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }

    $stepsArr = @(if ($Steps) { $Steps -split '\|' | Where-Object { $_ } })
    try {
        Invoke-SystemRestore -SnapshotDir $SnapshotDir -Steps $stepsArr
    } catch {
        Write-Host "`n  ПОМИЛКА: $($_.Exception.Message)`n" -ForegroundColor Red
        exit 1
    }
}
