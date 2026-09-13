[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SnapshotDir,
    [switch]$NoElevate,
    [switch]$List,
    [string[]]$Steps
)

$ErrorActionPreference = 'Continue'
$ProgressPreference     = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Have([string]$name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# Має ТОЧНО відповідати списку джерел у Take-SystemSnapshot.ps1 (крок config_files) -
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
        winget = @(); vscode_ext = @(); config_files = @()
        hosts = $false; windows_features = $false
    }

    $wg = F 'winget-packages.json'
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
        if (Test-Path -LiteralPath (Join-Path $SnapshotDir "config-files\$($item.SafeName)")) {
            $result.config_files += [ordered]@{ id = $item.Id; label = $item.Label }
        }
    }

    $result.hosts = [bool](Test-Path -LiteralPath (F 'hosts.txt'))
    $result.windows_features = [bool](Test-Path -LiteralPath (F 'windows-features-enabled.csv'))

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

    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

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
            Step "Конфіг: $($item.Label)" {
                $src = Join-Path $SnapshotDir "config-files\$($item.SafeName)"
                if (-not (Test-Path -LiteralPath $src)) { throw "у знімку немає цього файлу" }
                $dst = $item.Dest
                $dstDir = Split-Path $dst -Parent
                if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
                if (Test-Path -LiteralPath $dst) { Copy-Item -LiteralPath $dst -Destination "$dst.bak-$stamp" -Recurse -Force -ErrorAction SilentlyContinue }
                Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
            }
        }
    }
    if (Sel 'hosts') {
        Step "hosts-файл (з бекапом)" {
            $src = F 'hosts.txt'
            if (-not (Test-Path -LiteralPath $src)) { throw "немає hosts.txt у знімку" }
            $target = "$env:WINDIR\System32\drivers\etc\hosts"
            Copy-Item -LiteralPath $target -Destination "$target.bak-$stamp" -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $src -Destination $target -Force
        }
    }
    if (Sel 'windows_features') {
        Step "Компоненти Windows" {
            if (-not $isAdmin) { throw "потрібні права адміністратора" }
            $csv = F 'windows-features-enabled.csv'
            if (-not (Test-Path -LiteralPath $csv)) { throw "немає windows-features-enabled.csv у знімку" }
            Import-Csv -LiteralPath $csv | ForEach-Object {
                Enable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }

    Write-Host "`n  ГОТОВО.`n" -ForegroundColor Green
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($List) {
        Get-SnapshotCatalog -SnapshotDir $SnapshotDir | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }

    $principal  = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdminNow = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdminNow -and -not $NoElevate) {
        Write-Host "Потрібні права адміністратора - зараз буде вікно UAC..." -ForegroundColor Yellow
        $relaunch = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),
                      '-SnapshotDir', ('"{0}"' -f $SnapshotDir))
        if ($Steps) { $relaunch += '-Steps'; $relaunch += $Steps }
        try { Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $relaunch -ErrorAction Stop; exit }
        catch { Write-Warning "UAC відхилено. Продовжую без адмін-прав - hosts і компоненти Windows не виконаються." }
    }

    Invoke-SystemRestore -SnapshotDir $SnapshotDir -Steps $Steps

    if ($MyInvocation.MyCommand.Path -and -not $NoElevate) { Start-Sleep -Seconds 15 }
}
