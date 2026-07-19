[CmdletBinding()]
param(
    [string] $InstallDir = "$env:ProgramFiles\ryujin-doom",
    [string] $MsysRoot = "C:\msys64",
    [ValidateSet("doom-shareware", "freedoom1", "freedoom2")]
    [string] $Wad = "doom-shareware",
    [switch] $SkipDependencies,
    [switch] $NoStart
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$WinSwVersion = "2.12.0"
$WinSwSha256 = "05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da"
$WinSwUrl = "https://github.com/winsw/winsw/releases/download/v$WinSwVersion/WinSW-x64.exe"
$LhmVersion = "0.9.6"
$LhmUrl = "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v$LhmVersion/LibreHardwareMonitor.zip"
$LhmSha256 = "086d9f1b5a99e643edc2cfaaac16051685b551e4c5ac0b32a57c58c0e529c001"
$LhmLicenseUrl = "https://raw.githubusercontent.com/LibreHardwareMonitor/LibreHardwareMonitor/v$LhmVersion/LICENSE"
$LhmLicenseSha256 = "1f256ecad192880510e84ad60474eab7589218784b9a50bc7ceee34c2b91f1d5"
$LhmNoticesUrl = "https://raw.githubusercontent.com/LibreHardwareMonitor/LibreHardwareMonitor/v$LhmVersion/THIRD-PARTY-NOTICES.txt"
$LhmNoticesSha256 = "a60d5ee62f4d700caff38566f42874d554b8b530437c72804fb28b958cfbda9b"
$PawnIoUrl = "https://raw.githubusercontent.com/LibreHardwareMonitor/LibreHardwareMonitor/v$LhmVersion/LibreHardwareMonitor/Resources/PawnIO_setup.exe"
$PawnIoSha256 = "a3a46226c5e2824f4cdd42be0eecbabfc672c86f7889710f5ab1e6ad385b47a0"
$RepoDir = Split-Path -Parent $PSScriptRoot
$DataDir = Join-Path $env:ProgramData "ryujin-doom"
$ServiceExe = Join-Path $InstallDir "ryujin-doom-service.exe"
$ServiceXml = Join-Path $InstallDir "ryujin-doom-service.xml"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this installer from an Administrator PowerShell session."
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE."
    }
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $Sha256,
        [Parameter(Mandatory)] [string] $Destination
    )

    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
    $actualHash = (Get-FileHash -Algorithm SHA256 $Destination).Hash.ToLowerInvariant()
    if ($actualHash -ne $Sha256) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "Checksum mismatch for $Uri`: expected $Sha256, got $actualHash"
    }
}

function Find-MsysBash {
    $roots = @(
        $MsysRoot,
        "C:\msys64",
        (Join-Path $env:LOCALAPPDATA "Programs\MSYS2")
    ) | Select-Object -Unique

    foreach ($root in $roots) {
        $candidate = Join-Path $root "usr\bin\bash.exe"
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    return $null
}

function Convert-ToMsysPath {
    param([Parameter(Mandatory)] [string] $WindowsPath)

    $env:RYUJIN_DOOM_WINDOWS_PATH = $WindowsPath
    $result = & $script:MsysBash -lc 'cygpath -u "$RYUJIN_DOOM_WINDOWS_PATH"'
    if ($LASTEXITCODE -ne 0 -or -not $result) {
        throw "Could not convert '$WindowsPath' to an MSYS2 path."
    }
    return $result.Trim()
}

function Get-DeviceDriverStatus {
    try {
        $interfaces = Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.InstanceId -like "USB\VID_0B05&PID_1BCB&MI_*" }
        if (-not $interfaces) {
            Write-Warning "Ryujin III Extreme USB interfaces were not detected. The service will retry when the cooler is connected."
            return
        }

        $compatible = $false
        foreach ($interface in $interfaces) {
            $property = Get-PnpDeviceProperty -InstanceId $interface.InstanceId `
                -KeyName "DEVPKEY_Device_DriverService" -ErrorAction SilentlyContinue
            if ($property.Data -in @("WinUSB", "libusbK", "libusb0")) {
                $compatible = $true
            }
        }
        if (-not $compatible) {
            Write-Warning "No WinUSB-compatible Ryujin interface was found. Use Zadig to assign WinUSB only to the LCD bulk interface; do not replace the HID interface driver."
        }
    }
    catch {
        Write-Warning "Could not inspect the Ryujin USB interface driver: $($_.Exception.Message)"
    }
}

Assert-Administrator

$script:MsysBash = Find-MsysBash
if (-not $script:MsysBash) {
    if ($SkipDependencies) {
        throw "MSYS2 was not found. Install it or omit -SkipDependencies."
    }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "MSYS2 is missing and winget is unavailable. Install MSYS2, then rerun this installer."
    }
    Invoke-Checked -FilePath $winget.Source -ArgumentList @(
        "install", "--id", "MSYS2.MSYS2", "--exact",
        "--accept-package-agreements", "--accept-source-agreements", "--silent"
    )
    $script:MsysBash = Find-MsysBash
    if (-not $script:MsysBash) {
        throw "MSYS2 installed, but usr\bin\bash.exe could not be located. Pass -MsysRoot with its install directory."
    }
}

if (-not $SkipDependencies) {
    $packages = @(
        "git", "make", "patch", "curl", "tar", "unzip", "ca-certificates",
        "mingw-w64-ucrt-x86_64-gcc",
        "mingw-w64-ucrt-x86_64-pkgconf",
        "mingw-w64-ucrt-x86_64-libusb",
        "mingw-w64-ucrt-x86_64-hidapi"
    ) -join " "

    # A new MSYS2 install may need the core update to run twice before all
    # package databases and runtime components are current.
    Invoke-Checked -FilePath $script:MsysBash -ArgumentList @("-lc", "pacman -Syu --noconfirm")
    Invoke-Checked -FilePath $script:MsysBash -ArgumentList @("-lc", "pacman -Syu --noconfirm")
    Invoke-Checked -FilePath $script:MsysBash -ArgumentList @("-lc", "pacman -S --needed --noconfirm $packages")
}

$repoPosix = Convert-ToMsysPath $RepoDir
$env:RYUJIN_DOOM_SOURCE_DIR = $repoPosix
$buildCommand = @'
export PATH=/ucrt64/bin:/usr/bin
cd "$RYUJIN_DOOM_SOURCE_DIR"
make PLATFORM=windows CC=gcc PKG_CONFIG=pkg-config clean
make -j$(nproc) PLATFORM=windows CC=gcc PKG_CONFIG=pkg-config all
'@
Invoke-Checked -FilePath $script:MsysBash -ArgumentList @("-lc", $buildCommand)

if (Test-Path $ServiceExe) {
    & $ServiceExe stop 2>$null
    & $ServiceExe uninstall 2>$null
}
elseif (Get-Service -Name ryujin-doom -ErrorAction SilentlyContinue) {
    & sc.exe stop ryujin-doom | Out-Null
    Start-Sleep -Seconds 2
    & sc.exe delete ryujin-doom | Out-Null
}

# WinSW normally stops this child with the service.  Make upgrades resilient
# to a delayed or orphaned LibreHardwareMonitor PowerShell host before files
# in its loaded directory are replaced.
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File (Join-Path $RepoDir "packaging\windows\stop-hardware-monitor.ps1") `
    -InstallDir $InstallDir
if ($LASTEXITCODE -ne 0) {
    throw "The previous CPU temperature provider did not exit; installation was not modified."
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $InstallDir "logs") -Force | Out-Null
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$providerDir = Join-Path $InstallDir "hardware-monitor"
New-Item -ItemType Directory -Path $providerDir -Force | Out-Null
Copy-Item (Join-Path $RepoDir "ryujin-doom.exe") (Join-Path $InstallDir "ryujin-doom.exe") -Force
Copy-Item (Join-Path $RepoDir "packaging\windows\ryujin-doom-service.xml") $ServiceXml -Force
Copy-Item (Join-Path $RepoDir "scripts\ryujin-doom-wad.ps1") (Join-Path $InstallDir "ryujin-doom-wad.ps1") -Force
Copy-Item (Join-Path $RepoDir "scripts\uninstall-windows.ps1") `
    (Join-Path $InstallDir "uninstall-windows.ps1") -Force
Copy-Item (Join-Path $RepoDir "packaging\windows\stop-hardware-monitor.ps1") `
    (Join-Path $InstallDir "stop-hardware-monitor.ps1") -Force
Copy-Item (Join-Path $RepoDir "assets\wads.catalog") (Join-Path $InstallDir "wads.catalog") -Force

$msysInstallRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:MsysBash))
$ucrtBin = Join-Path $msysInstallRoot "ucrt64\bin"
$requiredDlls = @("libusb-1.0.dll", "libhidapi-0.dll")
foreach ($dll in $requiredDlls) {
    $source = Join-Path $ucrtBin $dll
    if (-not (Test-Path $source)) {
        throw "Required runtime library not found: $source"
    }
    Copy-Item $source (Join-Path $InstallDir $dll) -Force
}

$download = Join-Path $env:TEMP "ryujin-doom-WinSW-x64-$WinSwVersion.exe"
Get-VerifiedDownload -Uri $WinSwUrl -Sha256 $WinSwSha256 -Destination $download
Copy-Item $download $ServiceExe -Force

$lhmArchive = Join-Path $env:TEMP "ryujin-doom-LibreHardwareMonitor-$LhmVersion.zip"
$lhmExtract = Join-Path $env:TEMP "ryujin-doom-LibreHardwareMonitor-$LhmVersion"
$lhmLicense = Join-Path $InstallDir "LIBREHARDWAREMONITOR-MPL-2.0.txt"
$lhmNotices = Join-Path $InstallDir "LIBREHARDWAREMONITOR-NOTICES.txt"
$pawnIoSetup = Join-Path $InstallDir "PawnIO_setup.exe"
Get-VerifiedDownload -Uri $LhmUrl -Sha256 $LhmSha256 -Destination $lhmArchive
Get-VerifiedDownload -Uri $LhmLicenseUrl -Sha256 $LhmLicenseSha256 -Destination $lhmLicense
Get-VerifiedDownload -Uri $LhmNoticesUrl -Sha256 $LhmNoticesSha256 -Destination $lhmNotices
Get-VerifiedDownload -Uri $PawnIoUrl -Sha256 $PawnIoSha256 -Destination $pawnIoSetup
Remove-Item -LiteralPath $lhmExtract -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $lhmArchive -DestinationPath $lhmExtract -Force
Get-ChildItem -LiteralPath $lhmExtract -Filter "*.dll" -File |
    Copy-Item -Destination $providerDir -Force
Copy-Item (Join-Path $RepoDir "packaging\windows\cpu-temp.ps1") `
    (Join-Path $providerDir "cpu-temp.ps1") -Force
try {
    Invoke-Checked -FilePath $pawnIoSetup -ArgumentList @("-install")
}
catch {
    Write-Warning "PawnIO installation failed; CPU temperature may be unavailable: $($_.Exception.Message)"
}

Get-DeviceDriverStatus
Invoke-Checked -FilePath $ServiceExe -ArgumentList @("install")
$activeWad = Join-Path $DataDir "IWAD.WAD"
$failureNotice = Join-Path $DataDir "README-WAD.txt"
if (-not (Test-Path -LiteralPath $activeWad)) {
    Write-Host "Attempting to download $Wad..."
    try {
        & (Join-Path $InstallDir "ryujin-doom-wad.ps1") install $Wad -NoStart:$NoStart
    }
    catch {
        Write-Warning "The default WAD download failed: $($_.Exception.Message)"
    }
}
if (Test-Path -LiteralPath $activeWad) {
    Remove-Item -LiteralPath $failureNotice -Force -ErrorAction SilentlyContinue
    if (-not $NoStart) {
        Set-Service -Name ryujin-doom -StartupType Automatic
        $service = Get-Service -Name ryujin-doom
        if ($service.Status -ne "Running") {
            try {
                Invoke-Checked -FilePath $ServiceExe -ArgumentList @("start")
            }
            catch {
                Write-Warning "The WAD is installed, but the service did not start: $($_.Exception.Message)"
            }
        }
    }
}
else {
    Copy-Item (Join-Path $RepoDir "packaging\windows\README-WAD.txt") $failureNotice -Force
    Write-Warning "Ryujin Doom installed without a WAD; see $failureNotice."
}

Write-Host "Ryujin Doom installed as the 'ryujin-doom' Windows service."
Write-Host "Install directory: $InstallDir"
Write-Host "WAD data: $DataDir"
Write-Host "Logs: $(Join-Path $InstallDir 'logs')"
Write-Host "Uninstall: powershell.exe -ExecutionPolicy Bypass -File $(Join-Path $InstallDir 'uninstall-windows.ps1')"
if ($NoStart) {
    Write-Host "Start it with: Start-Service ryujin-doom"
}
