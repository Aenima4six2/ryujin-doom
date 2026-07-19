param(
    [Parameter(Mandatory)] [string] $ExecutablePath,
    [Parameter(Mandatory)] [string] $IwadPath,
    [Parameter(Mandatory)] [string] $StatePath,
    [Parameter(Mandatory)] [string] $LogPath
)

# Keep the Armoury behavior outside the native application. Every companion
# script is best-effort, so an absent or unsupported Armoury install cannot
# prevent Ryujin Doom from being launched.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSCommandPath
$stopScript = Join-Path $root 'armoury-crate-stop.ps1'
$restoreScript = Join-Path $root 'armoury-crate-restore.ps1'
$doom = $null

try {
    & $stopScript -StatePath $StatePath -LogPath $LogPath
    & $stopScript -StatePath $StatePath -LogPath $LogPath -Background -DelaySeconds 75
    $doom = Start-Process -FilePath $ExecutablePath -ArgumentList @('-iwad', $IwadPath) `
        -WorkingDirectory $root -PassThru -NoNewWindow
    Wait-Process -Id $doom.Id
} finally {
    & $restoreScript -StatePath $StatePath -LogPath $LogPath
}

if ($doom) {
    exit $doom.ExitCode
}
exit 1
