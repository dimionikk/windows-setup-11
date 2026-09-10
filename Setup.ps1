[CmdletBinding()]
param([switch]$NoElevate, [switch]$SkipPwsh)

$ErrorActionPreference = 'Continue'
$ProgressPreference     = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and -not $NoElevate) {
    Write-Host "Потрібні права адміністратора - зараз буде вікно UAC..." -ForegroundColor Yellow
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    if ($SkipPwsh) { $a += '-SkipPwsh' }
    try { Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $a -ErrorAction Stop; exit }
    catch { Write-Warning "UAC відхилено."; exit 1 }
}

function Have($n) { [bool](Get-Command $n -ErrorAction SilentlyContinue) }
function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }

Write-Host "`n  Залежності для Take-SystemSnapshot`n" -ForegroundColor Cyan

Get-ChildItem $PSScriptRoot -Recurse -Include *.ps1,*.cmd -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
Say "файли репозиторію розблоковано" Green

$ep = Get-ExecutionPolicy -Scope CurrentUser
if ($ep -in 'Restricted','AllSigned') {
    try { Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force; Say "ExecutionPolicy CurrentUser -> RemoteSigned" Green }
    catch { Say "ExecutionPolicy $ep - .cmd запускає з -ExecutionPolicy Bypass, це не завадить" Yellow }
} else {
    Say "ExecutionPolicy CurrentUser: $ep" Green
}

function Repair-Winget {
    if (Have winget) {
        try {
            Say ("winget: " + (winget --version).Trim()) Green
            winget source update 2>$null | Out-Null
            return $true
        } catch {}
    }
    Say "winget не працює - відновлюю..." Yellow
    $ai = Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue
    if ($ai) {
        try {
            Add-AppxPackage -DisableDevelopmentMode -Register "$($ai.InstallLocation)\AppXManifest.xml" -ErrorAction Stop
            if (Have winget) { Say "winget відновлено з наявного пакета" Green; return $true }
        } catch {}
    }
    Say "завантажую App Installer (GitHub)..." Yellow
    $tmp = Join-Path $env:TEMP ("wg_" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $vclibs = Join-Path $tmp 'vclibs.appx'
        Invoke-WebRequest 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' -OutFile $vclibs

        $nupkg = Join-Path $tmp 'xaml.zip'; $xaml = Join-Path $tmp 'xaml.appx'
        Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/2.8.6' -OutFile $nupkg
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
        $e = $zip.Entries | Where-Object { $_.FullName -like 'tools/AppX/x64/Release/*.appx' } | Select-Object -First 1
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $xaml, $true)
        $zip.Dispose()

        $rel = Invoke-RestMethod 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{ 'User-Agent' = 'winget-setup' }
        $bundle = Join-Path $tmp 'winget.msixbundle'; $lic = Join-Path $tmp 'license.xml'
        Invoke-WebRequest (($rel.assets | Where-Object { $_.name -like '*.msixbundle' })[0].browser_download_url) -OutFile $bundle
        Invoke-WebRequest (($rel.assets | Where-Object { $_.name -like '*License1.xml' })[0].browser_download_url) -OutFile $lic

        try { Add-AppxProvisionedPackage -Online -PackagePath $bundle -DependencyPackagePath $vclibs, $xaml -LicensePath $lic -ErrorAction Stop | Out-Null }
        catch { Add-AppxPackage -Path $vclibs; Add-AppxPackage -Path $xaml; Add-AppxPackage -Path $bundle }
    } catch {
        Say "автоматично не вийшло: $($_.Exception.Message)" Red
        Say "постав 'App Installer' з Microsoft Store вручну, потім запусти знову" Red
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue) {
        Say "App Installer встановлено (може знадобитись новий термінал)" Green
        return $true
    }
    return $false
}

$wg = Repair-Winget

if (-not $SkipPwsh) {
    if (Have pwsh) {
        Say "PowerShell 7: вже є" Green
    } elseif ($wg -and (Have winget)) {
        Say "ставлю PowerShell 7..." Yellow
        winget install --id Microsoft.PowerShell -e --source winget --accept-package-agreements --accept-source-agreements --silent 2>$null | Out-Null
        if (Have pwsh) { Say "PowerShell 7 встановлено" Green } else { Say "PowerShell 7: постав вручну (winget install Microsoft.PowerShell)" Yellow }
    } else {
        Say "PowerShell 7 пропущено (немає winget)" Yellow
    }
}

Write-Host "`n  Готово. Тепер запусти: Зробити знімок.cmd`n" -ForegroundColor Green
if ($MyInvocation.MyCommand.Path -and -not $NoElevate) { Start-Sleep -Seconds 8 }
