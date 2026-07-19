[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("list", "install", "import", "current")]
    [string] $Action = "list",

    [Parameter(Position = 1)]
    [string] $Value,

    [switch] $NoStart
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$CatalogPath = Join-Path $PSScriptRoot "wads.catalog"
$InstalledService = Get-Service -Name ryujin-doom -ErrorAction SilentlyContinue
if ($InstalledService -and $env:ProgramData) {
    $DataDirectory = Join-Path $env:ProgramData "ryujin-doom"
}
else {
    $DataDirectory = $PSScriptRoot
}
$Destination = Join-Path $DataDirectory "IWAD.WAD"
$CacheDirectory = Join-Path $DataDirectory "wad-cache"

function Get-Catalog {
    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        throw "WAD catalog not found: $CatalogPath"
    }

    foreach ($line in Get-Content -LiteralPath $CatalogPath) {
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }
        $field = $line.Split("|")
        [PSCustomObject]@{
            Id            = $field[0]
            Title         = $field[1]
            Version       = $field[2]
            Url           = $field[3]
            ArchiveSha256 = $field[4]
            Format        = $field[5]
            Member        = $field[6]
            Output        = $field[7]
            OutputSha256  = $field[8]
            License       = $field[9]
        }
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-CanActivate {
    $service = Get-Service -Name ryujin-doom -ErrorAction SilentlyContinue
    $underProgramFiles = $PSScriptRoot.StartsWith(
        $env:ProgramFiles,
        [StringComparison]::OrdinalIgnoreCase
    )
    if (($service -or $underProgramFiles) -and -not (Test-Administrator)) {
        throw "Run PowerShell as Administrator to change the installed Ryujin Doom WAD."
    }
}

function Get-Sha256([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Hash([string] $Path, [string] $Expected) {
    $actual = Get-Sha256 $Path
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "Checksum mismatch for '$Path': expected $Expected, got $actual"
    }
}

function Assert-Iwad([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "WAD not found: $Path"
    }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $header = New-Object byte[] 4
        if ($stream.Read($header, 0, 4) -ne 4) {
            throw "WAD is too short: $Path"
        }
    }
    finally {
        $stream.Dispose()
    }
    $magic = [Text.Encoding]::ASCII.GetString($header)
    if ($magic -ne "IWAD") {
        throw "'$Path' is not an IWAD (found '$magic'). PWAD add-ons need a separate IWAD."
    }
}

function Get-VerifiedArchive($Record) {
    New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
    $name = [IO.Path]::GetFileName(([Uri] $Record.Url).LocalPath)
    $archive = Join-Path $CacheDirectory $name
    if ((Test-Path -LiteralPath $archive) -and
        (Get-Sha256 $archive) -eq $Record.ArchiveSha256.ToLowerInvariant()) {
        return $archive
    }

    $partial = "$archive.part"
    Write-Host "Downloading $($Record.Title) $($Record.Version)"
    Invoke-WebRequest -UseBasicParsing -Uri $Record.Url -OutFile $partial -TimeoutSec 180
    try {
        Assert-Hash $partial $Record.ArchiveSha256
        Move-Item -LiteralPath $partial -Destination $archive -Force
    }
    finally {
        if (Test-Path -LiteralPath $partial) {
            Remove-Item -LiteralPath $partial -Force
        }
    }
    return $archive
}

function Expand-CatalogWad($Record, [string] $Archive, [string] $OutputPath) {
    if ($Record.Format -eq "zip") {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
        try {
            $entry = $zip.Entries | Where-Object FullName -eq $Record.Member |
                Select-Object -First 1
            if (-not $entry) {
                throw "Archive member not found: $($Record.Member)"
            }
            $input = $entry.Open()
            $output = [IO.File]::Create($OutputPath)
            try {
                $input.CopyTo($output)
            }
            finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
        finally {
            $zip.Dispose()
        }
        return
    }

    if ($Record.Format -eq "tar.gz") {
        $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
        if (-not $tar) {
            throw "tar.exe is required to extract $($Record.Title)."
        }
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $tar.Source
        $start.Arguments = "-xOzf `"$Archive`" `"$($Record.Member)`""
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        $output = [IO.File]::Create($OutputPath)
        try {
            $process.StandardOutput.BaseStream.CopyTo($output)
        }
        finally {
            $output.Dispose()
        }
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "tar.exe failed: $errorText"
        }
        return
    }

    throw "Unsupported archive format: $($Record.Format)"
}

function Set-ActiveWad([string] $Source, [string] $Label) {
    Assert-CanActivate
    Assert-Iwad $Source
    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    $temporary = "$Destination.new"
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary -Force
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
        $failureNotice = Join-Path $DataDirectory "README-WAD.txt"
        if (Test-Path -LiteralPath $failureNotice) {
            Remove-Item -LiteralPath $failureNotice -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }

    $service = Get-Service -Name ryujin-doom -ErrorAction SilentlyContinue
    if ($service -and -not $NoStart) {
        Set-Service -Name ryujin-doom -StartupType Automatic
        if ($service.Status -eq "Running") {
            Restart-Service -Name ryujin-doom
        }
        else {
            Start-Service -Name ryujin-doom
        }
    }
    Write-Host "Active Ryujin Doom WAD: $Label"
    Write-Host "Installed at: $Destination"
}

$catalog = @(Get-Catalog)
switch ($Action) {
    "list" {
        $catalog | Format-Table Id, Title, Version, License -AutoSize
    }
    "install" {
        if (-not $Value) {
            throw "Specify a catalog ID, for example: .\ryujin-doom-wad.ps1 install doom-shareware"
        }
        $record = $catalog | Where-Object Id -eq $Value | Select-Object -First 1
        if (-not $record) {
            throw "Unknown WAD '$Value'. Run '.\ryujin-doom-wad.ps1 list' for available IDs."
        }
        Assert-CanActivate
        $archive = Get-VerifiedArchive $record
        $extracted = Join-Path $CacheDirectory $record.Output
        Expand-CatalogWad $record $archive $extracted
        Assert-Hash $extracted $record.OutputSha256
        Set-ActiveWad $extracted $record.Id
    }
    "import" {
        if (-not $Value) {
            throw "Specify an owned IWAD path, for example: .\ryujin-doom-wad.ps1 import C:\Games\DOOM2.WAD"
        }
        Set-ActiveWad (Resolve-Path -LiteralPath $Value).Path ([IO.Path]::GetFileName($Value))
    }
    "current" {
        Assert-Iwad $Destination
        Write-Host $Destination
        Write-Host "SHA256: $(Get-Sha256 $Destination)"
    }
}
