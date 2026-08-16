# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

param([switch]$LiveSensor)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-SensorComparisonTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Sensor-comparison test failed: $Message"
    }
}

$scriptPath = Join-Path $PSScriptRoot '..\scripts\Compare-DeckLuxSensors.ps1'
Assert-SensorComparisonTest `
    -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) `
    -Message 'Compare-DeckLuxSensors.ps1 is missing'

$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors)
$parseErrorMessages = @($parseErrors | ForEach-Object { $_.Message })
Assert-SensorComparisonTest `
    -Condition ($parseErrors.Count -eq 0) `
    -Message "script has parse errors: $($parseErrorMessages -join ' | ')"

$text = [IO.File]::ReadAllText($scriptPath)
foreach ($requiredText in @(
    '::GetDeviceSelector',
    '::FromIdAsync',
    'ReadingChanged',
    'SensorEventSubscription',
    'DEVPKEY_Device_BiosDeviceName',
    'IsValveGalileo',
    '$boardMatches',
    '$systemMatches -or $boardMatches',
    '$identitiesConflict',
    "`$physicalSide = 'Left'",
    "`$physicalSide = 'Right'",
    "`$signalKind = 'PreferredFused'",
    "Kind = 'GalileoFusedSecondary'",
    "SensorALabel = 'PreferredFused'",
    "SensorBLabel = 'SecondaryRaw'",
    'OriginalLuxPercentageThreshold',
    'EffectiveLuxPercentageThreshold',
    'FinalLuxPercentageThreshold',
    'OriginalAbsoluteLuxThreshold',
    'EffectiveAbsoluteLuxThreshold',
    'FinalAbsoluteLuxThreshold',
    'OriginalReportLatencyMs',
    'EffectiveReportLatencyMs',
    'FinalReportLatencyMs',
    'RawLux',
    'ConfigurationErrors',
    'CleanupErrors',
    "'EnumerationError'",
    'SensorBMinusSensorALux',
    'SensorBToSensorARatio',
    "[ValidateSet('Object', 'Json', 'Csv')]")) {
    Assert-SensorComparisonTest `
        -Condition ($text.Contains($requiredText)) `
        -Message "script is missing required contract text '$requiredText'"
}

Assert-SensorComparisonTest `
    -Condition (-not $text.Contains("Kind = 'GalileoLeftRight'")) `
    -Message 'fused LTRF output must not be presented as raw left-sensor data'

Assert-SensorComparisonTest `
    -Condition (-not [regex]::IsMatch($text, '\.GetCurrentReading\s*\(')) `
    -Message 'comparison must not rely on the stale polling cache'
Assert-SensorComparisonTest `
    -Condition (-not $text.Contains('Valve Galileo DeviceId instance suffix')) `
    -Message 'a numeric instance suffix must not infer a physical side'
Assert-SensorComparisonTest `
    -Condition (-not $text.Contains('$boardContradicts')) `
    -Message 'Galileo recognition must use the shared system-or-baseboard rule'

$configureInterval = $text.IndexOf(
    '$entry.Sensor.ReportInterval = [uint32]$entry.EffectiveReportIntervalMs')
$configureLatencyGuard = $text.IndexOf(
    'if ([uint32]$entry.OriginalReportLatencyMs -ne 0)')
$configureLatency = $text.IndexOf(
    '$entry.Sensor.ReportLatency = [uint32]0')
$configurePercentage = $text.IndexOf(
    '$entry.Threshold.LuxPercentage = [single]0')
$configureAbsolute = $text.IndexOf(
    '$entry.Threshold.AbsoluteLux = [single]0')
$subscribe = $text.IndexOf(
    '[DeckLux.Diagnostics.SensorEventSubscription]::new($entry.Sensor)')
Assert-SensorComparisonTest `
    -Condition ($configureInterval -ge 0 -and
        $configureInterval -lt $configureLatencyGuard -and
        $configureLatencyGuard -lt $configureLatency -and
        $configureLatency -lt $configurePercentage -and
        $configurePercentage -lt $configureAbsolute -and
        $configureAbsolute -lt $subscribe) `
    -Message 'all per-client sampling fields must be configured before subscription'

$finallyIndex = $text.LastIndexOf('finally {')
$restoreAbsolute = $text.LastIndexOf('$entry.Threshold.AbsoluteLux =')
$restorePercentage = $text.LastIndexOf('$entry.Threshold.LuxPercentage =')
$restoreLatency = $text.LastIndexOf('$entry.Sensor.ReportLatency =')
$restoreInterval = $text.LastIndexOf('$entry.Sensor.ReportInterval =')
Assert-SensorComparisonTest `
    -Condition ($finallyIndex -ge 0 -and
        $finallyIndex -lt $restoreAbsolute -and
        $restoreAbsolute -lt $restorePercentage -and
        $restorePercentage -lt $restoreLatency -and
        $restoreLatency -lt $restoreInterval) `
    -Message 'cleanup must restore sampling fields independently in reverse order'

$writes = [regex]::Matches(
    $text,
    '(?m)\.(?<owner>Sensor|Threshold)\.(?<property>[A-Za-z0-9_]+)\s*=')
$expectedWriteCounts = [ordered]@{
    ReportInterval = 2
    ReportLatency = 2
    LuxPercentage = 2
    AbsoluteLux = 2
}
Assert-SensorComparisonTest `
    -Condition ($writes.Count -eq 8) `
    -Message 'only the four reversible per-client sampling fields may be written'
foreach ($entry in $expectedWriteCounts.GetEnumerator()) {
    $count = @($writes | Where-Object {
        $_.Groups['property'].Value -eq $entry.Key
    }).Count
    Assert-SensorComparisonTest `
        -Condition ($count -eq $entry.Value) `
        -Message "sampling field '$($entry.Key)' must have one configure and one restore write"
}

foreach ($requiredCleanupText in @(
    'Interlocked.CompareExchange(ref disposed, 1, 0)',
    'Interlocked.Exchange(ref disposed, 0)',
    '$entry.ReportIntervalRestored',
    '$entry.ReportLatencyRestored',
    '$entry.LuxPercentageThresholdRestored',
    '$entry.AbsoluteLuxThresholdRestored',
    '$cleanupFailed')) {
    Assert-SensorComparisonTest `
        -Condition ($text.Contains($requiredCleanupText)) `
        -Message "cleanup contract is missing '$requiredCleanupText'"
}

Assert-SensorComparisonTest `
    -Condition ($text.Contains('[Math]::Max(1000, 3 * $cycleIntervalMs)')) `
    -Message 'automatic reading age must be max(1000 ms, three intervals)'
Assert-SensorComparisonTest `
    -Condition ($text.Contains("`$effectiveMaxPairSkewMs = if (`$MaxPairSkewMs -eq 0) {`r`n    `$cycleIntervalMs") -or
        $text.Contains("`$effectiveMaxPairSkewMs = if (`$MaxPairSkewMs -eq 0) {`n    `$cycleIntervalMs")) `
    -Message 'automatic pair skew must be no more than one cycle interval'
Assert-SensorComparisonTest `
    -Condition ($text.Contains('Never emit catch-up cycles')) `
    -Message 'sampling scheduler must skip missed deadlines'

$forbiddenMutation = [regex]::Match(
    $text,
    '(?im)\b(Set-PnpDevice|Enable-PnpDevice|Disable-PnpDevice|pnputil|bcdedit|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Set-CimInstance|Invoke-CimMethod)\b')
Assert-SensorComparisonTest `
    -Condition (-not $forbiddenMutation.Success) `
    -Message "unexpected system-mutating command '$($forbiddenMutation.Value)'"

$pairInput = $text.IndexOf('$pairInputsValid =')
$pairGate = $text.IndexOf('$withinSkew = $pairInputsValid', $pairInput)
$delta = $text.IndexOf('$deltaLux = if ($withinSkew)', $pairGate)
$ratio = $text.IndexOf('$ratio = if ($withinSkew', $pairGate)
Assert-SensorComparisonTest `
    -Condition ($pairInput -ge 0 -and $pairGate -gt $pairInput -and
        $delta -gt $pairGate -and $ratio -gt $pairGate) `
    -Message 'pair metrics must remain gated by valid timestamp-correlated inputs'

Write-Host 'DeckLux sensor-comparison static tests passed.'

if ($LiveSensor) {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $lightSensorType = [Windows.Devices.Sensors.LightSensor, Windows.Devices.Sensors, ContentType = WindowsRuntime]
    $defaultSensor = $lightSensorType::GetDefault()
    Assert-SensorComparisonTest `
        -Condition ($null -ne $defaultSensor) `
        -Message 'the opt-in live test requires a Windows ambient-light sensor'

    $before = [pscustomobject]@{
        ReportInterval = [uint32]$defaultSensor.ReportInterval
        ReportLatency = [uint32]$defaultSensor.ReportLatency
        LuxPercentage = [single]$defaultSensor.ReportThreshold.LuxPercentage
        AbsoluteLux = [single]$defaultSensor.ReportThreshold.AbsoluteLux
    }
    $result = & $scriptPath `
        -DurationSeconds 2 `
        -SampleIntervalMs 250 `
        -OutputFormat Object
    $after = [pscustomobject]@{
        ReportInterval = [uint32]$defaultSensor.ReportInterval
        ReportLatency = [uint32]$defaultSensor.ReportLatency
        LuxPercentage = [single]$defaultSensor.ReportThreshold.LuxPercentage
        AbsoluteLux = [single]$defaultSensor.ReportThreshold.AbsoluteLux
    }

    $validReadings = @($result.Readings | Where-Object { $_.IsValid })
    $distinctTimestamps = @($validReadings |
        Select-Object -ExpandProperty ReadingTimestampUtc -Unique)
    Assert-SensorComparisonTest `
        -Condition ($validReadings.Count -ge 2 -and $distinctTimestamps.Count -ge 2) `
        -Message 'zero thresholds did not produce fresh periodic readings'

    foreach ($sensor in @($result.Sensors)) {
        Assert-SensorComparisonTest `
            -Condition ($sensor.EffectiveLuxPercentageThreshold -eq 0 -and
                $sensor.EffectiveAbsoluteLuxThreshold -eq 0) `
            -Message "sensor $($sensor.SensorIndex) did not use zero thresholds"
        Assert-SensorComparisonTest `
            -Condition ($sensor.ReportIntervalRestored -and
                $sensor.ReportLatencyRestored -and
                $sensor.LuxPercentageThresholdRestored -and
                $sensor.AbsoluteLuxThresholdRestored) `
            -Message "sensor $($sensor.SensorIndex) did not restore every sampling field"
        Assert-SensorComparisonTest `
            -Condition ([string]::IsNullOrWhiteSpace($sensor.ConfigurationErrors) -and
                [string]::IsNullOrWhiteSpace($sensor.CleanupErrors)) `
            -Message "sensor $($sensor.SensorIndex) reported configuration or cleanup errors"
    }

    foreach ($property in @('ReportInterval', 'ReportLatency', 'LuxPercentage', 'AbsoluteLux')) {
        Assert-SensorComparisonTest `
            -Condition ($before.$property -eq $after.$property) `
            -Message "live test changed the caller's $property value"
    }

    Write-Host "DeckLux live sensor test passed with $($validReadings.Count) valid readings and $($distinctTimestamps.Count) distinct timestamps."
}
