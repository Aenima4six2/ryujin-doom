param(
    [Parameter(Mandatory)] [string] $StatePath,
    [Parameter(Mandatory)] [string] $LogPath,
    [switch] $Refresh,
    [switch] $Background,
    [ValidateRange(0, 300)] [int] $DelaySeconds = 0
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
    if ($Background) {
        $arguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $PSCommandPath),
            '-StatePath', ('"{0}"' -f $StatePath),
            '-LogPath', ('"{0}"' -f $LogPath),
            '-Refresh', '-DelaySeconds', $DelaySeconds
        )
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments `
            -WindowStyle Hidden
        Write-ArmouryLog "scheduled delayed Armoury LCD refresh"
        exit 0
    }

    if ($DelaySeconds) {
        Start-Sleep -Seconds $DelaySeconds
    }

    $hasState = Test-Path -LiteralPath $StatePath
    if ($Refresh -and -not $hasState) {
        Write-ArmouryLog "skipped delayed refresh after service stopped"
        exit 0
    }
    if ($hasState -and -not $Refresh) {
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
    if (-not $hasState) {
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
    }

    foreach ($name in 'ArmourySocketServer', 'AIOFanSDK') {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction Stop }
            catch { Write-ArmouryLog "could not stop ${name}: $($_.Exception.Message)" }
        }
    }

    if ($hasState) {
        Write-ArmouryLog "refreshed late-starting Armoury LCD writer"
    } else {
        $stateDirectory = Split-Path -Parent $StatePath
        New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
        [pscustomobject]@{
            Schema = 1
            DisabledTasks = $disabled
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StatePath -Encoding utf8
        Write-ArmouryLog "disabled $($disabled.Count) discovered Armoury LCD task(s)"
    }
} catch {
    Write-ArmouryLog "ignored error: $($_.Exception.Message)"
}

exit 0
