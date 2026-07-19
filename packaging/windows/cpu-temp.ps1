# Persistent CPU package/control temperature provider for Ryujin Doom.
# LibreHardwareMonitor and its dependencies are installed beside this script.

$ErrorActionPreference = "Stop"
$providerDir = Split-Path -Parent $MyInvocation.MyCommand.Path

try {
    Set-Location -LiteralPath $providerDir
    [void][Reflection.Assembly]::LoadFrom(
        (Join-Path $providerDir "LibreHardwareMonitorLib.dll"))

    $computer = New-Object LibreHardwareMonitor.Hardware.Computer
    $computer.IsCpuEnabled = $true
    $computer.Open()

    $selected = $null
    $selectedScore = 0
    $reportedSensor = $false

    while ($true) {
        foreach ($hardware in $computer.Hardware) {
            if ($hardware.HardwareType -ne
                [LibreHardwareMonitor.Hardware.HardwareType]::Cpu) {
                continue
            }

            $hardware.Update()
            foreach ($sensor in $hardware.Sensors) {
                if ($sensor.SensorType -ne
                    [LibreHardwareMonitor.Hardware.SensorType]::Temperature) {
                    continue
                }

                # AMD exposes the physical package/die reading as Tdie when
                # a Tctl offset exists, or as the combined Tctl/Tdie sensor on
                # modern Ryzen. Intel exposes the package DTS as CPU Package.
                $score = switch ($sensor.Name) {
                    "CPU Package"       { 400 }
                    "Core (Tdie)"       { 390 }
                    "Core (Tctl/Tdie)"  { 380 }
                    "Core (Tctl)"       { 370 }
                    default             { 0 }
                }
                if ($score -gt $selectedScore) {
                    $selected = $sensor
                    $selectedScore = $score
                }
            }
        }

        if ($selected -and $selected.Value -ne $null) {
            if (-not $reportedSensor) {
                [Console]::Error.WriteLine(
                    "ryujin-doom: Windows CPU sensor: {0}", $selected.Name)
                $reportedSensor = $true
            }
            $tenths = [int][Math]::Round(
                [double]$selected.Value * 10.0,
                [MidpointRounding]::AwayFromZero)
            [Console]::Out.WriteLine($tenths)
            [Console]::Out.Flush()
        }

        Start-Sleep -Milliseconds 1000
    }
}
catch {
    [Console]::Error.WriteLine(
        "ryujin-doom: CPU temperature provider failed: {0}", $_.Exception.Message)
    exit 1
}
finally {
    if ($computer) {
        $computer.Close()
    }
}
