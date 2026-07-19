param(
    [Parameter(Mandatory)] [string] $InstallDir,
    [int] $TimeoutSeconds = 10
)

$ErrorActionPreference = "Stop"
$installPath = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$cpuProvider = Join-Path $installPath "hardware-monitor\cpu-temp.ps1"
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

function Get-RyujinChildProcess {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -eq (Join-Path $installPath "ryujin-doom.exe") -or
            ($_.Name -ieq "powershell.exe" -and $_.CommandLine -and
             $_.CommandLine.IndexOf($cpuProvider,
                 [StringComparison]::OrdinalIgnoreCase) -ge 0)
        }
}

do {
    $processes = @(Get-RyujinChildProcess)
    if (-not $processes) {
        exit 0
    }
    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 250
} while ([DateTime]::UtcNow -lt $deadline)

$remaining = @(Get-RyujinChildProcess)
if ($remaining) {
    $pids = $remaining.ProcessId -join ", "
    throw "Ryujin Doom child process(es) did not exit: $pids"
}
