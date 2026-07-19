[CmdletBinding()]
param(
    [string] $InstallDir = "$env:ProgramFiles\ryujin-doom",
    [switch] $PurgeData
)

$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this uninstaller from an Administrator PowerShell session."
}

$serviceExe = Join-Path $InstallDir "ryujin-doom-service.exe"
if (Test-Path $serviceExe) {
    & $serviceExe stop 2>$null
    & $serviceExe uninstall 2>$null
}
elseif (Get-Service -Name ryujin-doom -ErrorAction SilentlyContinue) {
    & sc.exe stop ryujin-doom | Out-Null
    Start-Sleep -Seconds 2
    & sc.exe delete ryujin-doom | Out-Null
}

$stopHelper = Join-Path $InstallDir "stop-hardware-monitor.ps1"
if (Test-Path $stopHelper) {
    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $stopHelper -InstallDir $InstallDir
    if ($LASTEXITCODE -ne 0) {
        throw "The CPU temperature provider did not exit; installed files were left in place."
    }
}
else {
    $cpuProvider = Join-Path $InstallDir "hardware-monitor\cpu-temp.ps1"
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ieq "powershell.exe" -and $_.CommandLine -and
            $_.CommandLine.IndexOf($cpuProvider,
                [StringComparison]::OrdinalIgnoreCase) -ge 0
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

$pawnIoSetup = Join-Path $InstallDir "PawnIO_setup.exe"
if (Test-Path $pawnIoSetup) {
    & $pawnIoSetup -uninstall
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "PawnIO removal returned exit code $LASTEXITCODE."
    }
}

if (Test-Path $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
}

$dataDir = Join-Path $env:ProgramData "ryujin-doom"
if ($PurgeData -and (Test-Path $dataDir)) {
    Remove-Item -LiteralPath $dataDir -Recurse -Force
    Write-Host "Ryujin Doom service, installed files, and WAD data were removed."
}
else {
    Write-Host "Ryujin Doom removed; WAD data was preserved in $dataDir."
    Write-Host "Pass -PurgeData to remove it."
}
