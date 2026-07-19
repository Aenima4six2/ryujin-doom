param(
    [Parameter(Mandatory)] [string] $StatePath,
    [Parameter(Mandatory)] [string] $LogPath
)

# Best-effort companion for the Windows service. Never fail the service stop.
$ErrorActionPreference = "Stop"

function Write-ArmouryLog([string] $Message) {
    try {
        $directory = Split-Path -Parent $LogPath
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        Add-Content -LiteralPath $LogPath -Value (
            "{0:u} restore: {1}" -f [DateTime]::UtcNow, $Message)
    } catch { }
}

try {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        exit 0
    }

    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    foreach ($task in @($state.DisabledTasks)) {
        try {
            Enable-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName |
                Out-Null
            Start-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName
        } catch {
            Write-ArmouryLog "could not restore $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)"
        }
    }

    # When executed interactively, ask Windows to reopen the registered app
    # without assuming an AppX package family or an installation directory.
    try {
        $app = Get-StartApps | Where-Object { $_.Name -eq 'Armoury Crate' } |
            Select-Object -First 1
        if ($app) {
            Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$($app.AppID)"
        }
    } catch {
        Write-ArmouryLog "could not request Armoury Crate app launch: $($_.Exception.Message)"
    }

    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    Write-ArmouryLog "restored $(@($state.DisabledTasks).Count) Armoury LCD task(s)"
} catch {
    Write-ArmouryLog "ignored error: $($_.Exception.Message)"
}

exit 0
