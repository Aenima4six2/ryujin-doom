param(
    [Parameter(Mandatory)] [string] $StatePath,
    [Parameter(Mandatory)] [string] $LogPath
)

# Best-effort companion for the Windows service. Never fail the service start.
$ErrorActionPreference = "Stop"

function Write-ArmouryLog([string] $Message) {
    try {
        $directory = Split-Path -Parent $LogPath
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        Add-Content -LiteralPath $LogPath -Value (
            "{0:u} stop: {1}" -f [DateTime]::UtcNow, $Message)
    } catch { }
}

try {
    if (Test-Path -LiteralPath $StatePath) {
        Write-ArmouryLog "existing state retained after an unclean service stop"
        exit 0
    }

    # Match the task action, not an ASUS install path or a particular Armoury
    # Crate release. Unknown releases are intentionally left untouched.
    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $_.Actions | Where-Object {
            $_.Execute -match '(?i)(ArmourySocketServer|AIOFanSDK)'
        }
    })
    if (-not $tasks) {
        Write-ArmouryLog "no supported Armoury LCD task discovered"
        exit 0
    }

    $disabled = @()
    foreach ($task in $tasks) {
        if (-not $task.Settings.Enabled) {
            continue
        }
        try {
            Disable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName |
                Out-Null
            $disabled += [pscustomobject]@{
                TaskPath = $task.TaskPath
                TaskName = $task.TaskName
            }
        } catch {
            Write-ArmouryLog "could not disable $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)"
        }
    }

    if ($disabled.Count -eq 0) {
        Write-ArmouryLog "no enabled Armoury LCD task was disabled"
        exit 0
    }

    foreach ($name in 'ArmourySocketServer', 'AIOFanSDK') {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction Stop }
            catch { Write-ArmouryLog "could not stop ${name}: $($_.Exception.Message)" }
        }
    }

    $stateDirectory = Split-Path -Parent $StatePath
    New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
    [pscustomobject]@{
        Schema = 1
        DisabledTasks = $disabled
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StatePath -Encoding utf8
    Write-ArmouryLog "disabled $($disabled.Count) discovered Armoury LCD task(s)"
} catch {
    Write-ArmouryLog "ignored error: $($_.Exception.Message)"
}

exit 0
