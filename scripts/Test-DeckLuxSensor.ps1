# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

[CmdletBinding()]
param(
    [ValidateRange(1.0, 3600.0)]
    [double]$DurationSeconds = 10.0,

    [ValidateRange(50, 60000)]
    [int]$SampleIntervalMs = 500,

    [ValidateRange(0.0, 1000000.0)]
    [double]$ConstantToleranceLux = 0.001,

    [bool]$AdjustReportInterval = $true,

    [switch]$AllSensors,

    [ValidateSet('Object', 'Json', 'Csv')]
    [string]$OutputFormat = 'Object'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-DeckLuxWinRtOperation {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Operation,

        [Parameter(Mandatory = $true)]
        [type]$ResultType
    )

    $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.IsGenericMethodDefinition -and
            $_.GetGenericArguments().Count -eq 1 -and
            $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -like 'IAsyncOperation*'
        } |
        Select-Object -First 1
    if ($null -eq $asTaskMethod) {
        throw 'The WinRT AsTask adapter for IAsyncOperation<T> was not found.'
    }

    $task = $asTaskMethod.MakeGenericMethod($ResultType).Invoke(
        $null,
        @($Operation))
    return $task.GetAwaiter().GetResult()
}

function New-DeckLuxCsvRows {
    param([Parameter(Mandatory = $true)][psobject]$Result)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($sensorResult in @($Result.Sensors)) {
        $sensorSamples = @($Result.Samples | Where-Object {
            $_.SensorIndex -eq $sensorResult.SensorIndex
        })

        if ($sensorSamples.Count -eq 0) {
            $rows.Add([pscustomobject][ordered]@{
                RecordType = 'Status'
                OverallStatus = $Result.OverallStatus
                SensorStatus = $sensorResult.Status
                SensorIndex = $sensorResult.SensorIndex
                DeviceId = $sensorResult.DeviceId
                DeviceName = $sensorResult.DeviceName
                IsDefault = $sensorResult.IsDefault
                Sequence = $null
                ObservedUtc = $null
                ReadingTimestampUtc = $null
                Lux = $null
                IsValid = $false
                FailureKind = $null
                Error = $sensorResult.Error
                MinimumReportIntervalMs = $sensorResult.MinimumReportIntervalMs
                CurrentReportIntervalMsAtStart = $sensorResult.CurrentReportIntervalMsAtStart
                OriginalReportIntervalMs = $sensorResult.OriginalReportIntervalMs
                EffectiveReportIntervalMs = $sensorResult.EffectiveReportIntervalMs
                FinalReportIntervalMs = $sensorResult.FinalReportIntervalMs
                ReportIntervalChanged = $sensorResult.ReportIntervalChanged
                ReportIntervalRestored = $sensorResult.ReportIntervalRestored
            })
            continue
        }

        foreach ($sample in $sensorSamples) {
            $rows.Add([pscustomobject][ordered]@{
                RecordType = 'Sample'
                OverallStatus = $Result.OverallStatus
                SensorStatus = $sensorResult.Status
                SensorIndex = $sample.SensorIndex
                DeviceId = $sample.DeviceId
                DeviceName = $sensorResult.DeviceName
                IsDefault = $sample.IsDefault
                Sequence = $sample.Sequence
                ObservedUtc = $sample.ObservedUtc
                ReadingTimestampUtc = $sample.ReadingTimestampUtc
                Lux = $sample.Lux
                IsValid = $sample.IsValid
                FailureKind = $sample.FailureKind
                Error = $sample.Error
                MinimumReportIntervalMs = $sensorResult.MinimumReportIntervalMs
                CurrentReportIntervalMsAtStart = $sensorResult.CurrentReportIntervalMsAtStart
                OriginalReportIntervalMs = $sensorResult.OriginalReportIntervalMs
                EffectiveReportIntervalMs = $sensorResult.EffectiveReportIntervalMs
                FinalReportIntervalMs = $sensorResult.FinalReportIntervalMs
                ReportIntervalChanged = $sensorResult.ReportIntervalChanged
                ReportIntervalRestored = $sensorResult.ReportIntervalRestored
            })
        }
    }

    if ($rows.Count -eq 0) {
        $rows.Add([pscustomobject][ordered]@{
            RecordType = 'Status'
            OverallStatus = $Result.OverallStatus
            SensorStatus = $null
            SensorIndex = $null
            DeviceId = $null
            DeviceName = $null
            IsDefault = $null
            Sequence = $null
            ObservedUtc = $null
            ReadingTimestampUtc = $null
            Lux = $null
            IsValid = $false
            FailureKind = $null
            Error = ($Result.Errors -join ' | ')
            MinimumReportIntervalMs = $null
            CurrentReportIntervalMsAtStart = $null
            OriginalReportIntervalMs = $null
            EffectiveReportIntervalMs = $null
            FinalReportIntervalMs = $null
            ReportIntervalChanged = $false
            ReportIntervalRestored = $true
        })
    }

    return @($rows | ForEach-Object { $_ })
}

$startedUtc = [DateTime]::UtcNow
$errors = New-Object System.Collections.Generic.List[string]
$sensorSummaries = New-Object System.Collections.Generic.List[object]
$samples = New-Object System.Collections.Generic.List[object]
$enumeratedDevices = New-Object System.Collections.Generic.List[object]
$enumerationStatus = 'NotStarted'
$defaultSensor = $null
$lightSensorType = $null
$deviceInformationType = $null
$deviceInformationCollectionType = $null

try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $lightSensorType = [Windows.Devices.Sensors.LightSensor, Windows.Devices.Sensors, ContentType = WindowsRuntime]
    $deviceInformationType = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
    $deviceInformationCollectionType = [Windows.Devices.Enumeration.DeviceInformationCollection, Windows.Devices.Enumeration, ContentType = WindowsRuntime]

    try {
        $selector = $lightSensorType::GetDeviceSelector()
        $findOperation = $deviceInformationType::FindAllAsync($selector)
        $foundDevices = Wait-DeckLuxWinRtOperation `
            -Operation $findOperation `
            -ResultType $deviceInformationCollectionType
        foreach ($device in $foundDevices) {
            $enumeratedDevices.Add([pscustomobject][ordered]@{
                Id = [string]$device.Id
                Name = [string]$device.Name
                IsEnabled = [bool]$device.IsEnabled
            })
        }
        $enumerationStatus = if ($enumeratedDevices.Count -eq 0) {
            'NoSensor'
        }
        else {
            'Success'
        }
    }
    catch [IO.FileNotFoundException] {
        # FindAllAsync can return ERROR_FILE_NOT_FOUND when the sensor device
        # class has no registered instances. Treat that as an empty result.
        $enumerationStatus = 'NoSensor'
    }
    catch {
        $enumerationStatus = 'Error'
        $errors.Add("WinRT light-sensor enumeration failed: $($_.Exception.Message)")
    }

    try {
        $defaultSensor = $lightSensorType::GetDefault()
    }
    catch {
        $errors.Add("LightSensor.GetDefault failed: $($_.Exception.Message)")
    }
}
catch {
    $enumerationStatus = 'Unavailable'
    $errors.Add("Windows.Devices.Sensors.LightSensor is unavailable: $($_.Exception.Message)")
}

$sensorsToTest = New-Object System.Collections.Generic.List[object]
$seenDeviceIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if ($null -ne $defaultSensor) {
    [void]$seenDeviceIds.Add([string]$defaultSensor.DeviceId)
    $sensorsToTest.Add([pscustomobject]@{
        Sensor = $defaultSensor
        DeviceId = [string]$defaultSensor.DeviceId
        IsDefault = $true
    })
}

if ($AllSensors -and $null -ne $lightSensorType) {
    foreach ($device in $enumeratedDevices) {
        if ($seenDeviceIds.Contains([string]$device.Id)) {
            continue
        }

        try {
            $fromIdOperation = $lightSensorType::FromIdAsync([string]$device.Id)
            $sensor = Wait-DeckLuxWinRtOperation `
                -Operation $fromIdOperation `
                -ResultType $lightSensorType
            if ($null -ne $sensor) {
                [void]$seenDeviceIds.Add([string]$sensor.DeviceId)
                $sensorsToTest.Add([pscustomobject]@{
                    Sensor = $sensor
                    DeviceId = [string]$sensor.DeviceId
                    IsDefault = $false
                })
            }
            else {
                $errors.Add("LightSensor.FromIdAsync returned no sensor for '$($device.Id)'.")
            }
        }
        catch {
            $errors.Add("LightSensor.FromIdAsync failed for '$($device.Id)': $($_.Exception.Message)")
        }
    }
}

$sensorIndex = 0
foreach ($sensorEntry in $sensorsToTest) {
    $sensor = $sensorEntry.Sensor
    $deviceId = [string]$sensorEntry.DeviceId
    $isDefault = [bool]$sensorEntry.IsDefault
    $deviceInfo = @($enumeratedDevices | Where-Object { $_.Id -ieq $deviceId }) |
        Select-Object -First 1
    $deviceName = if ($null -eq $deviceInfo) { $null } else { [string]$deviceInfo.Name }
    $minimumInterval = [uint32]$sensor.MinimumReportInterval
    $originalInterval = [uint32]$sensor.ReportInterval
    $effectiveInterval = [uint32][Math]::Max($SampleIntervalMs, [int]$minimumInterval)
    $intervalChanged = $false
    $intervalRestored = $true
    $finalInterval = $originalInterval
    $restoreError = $null
    $sensorError = $null
    $sensorSampleStart = $samples.Count

    try {
        if ($AdjustReportInterval -and $originalInterval -ne $effectiveInterval) {
            $sensor.ReportInterval = $effectiveInterval
            $intervalChanged = $true
            $finalInterval = [uint32]$sensor.ReportInterval
        }

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $sequence = 0
        do {
            $observedUtc = [DateTime]::UtcNow.ToString('o')
            try {
                $reading = $sensor.GetCurrentReading()
                if ($null -eq $reading) {
                    $samples.Add([pscustomobject][ordered]@{
                        SensorIndex = $sensorIndex
                        DeviceId = $deviceId
                        IsDefault = $isDefault
                        Sequence = $sequence
                        ObservedUtc = $observedUtc
                        ReadingTimestampUtc = $null
                        Lux = $null
                        IsValid = $false
                        FailureKind = 'NoData'
                        Error = 'GetCurrentReading returned no data.'
                    })
                }
                else {
                    $lux = [double]$reading.IlluminanceInLux
                    $isFinite = -not [double]::IsNaN($lux) -and
                        -not [double]::IsInfinity($lux) -and
                        $lux -ge 0.0
                    $samples.Add([pscustomobject][ordered]@{
                        SensorIndex = $sensorIndex
                        DeviceId = $deviceId
                        IsDefault = $isDefault
                        Sequence = $sequence
                        ObservedUtc = $observedUtc
                        ReadingTimestampUtc = $reading.Timestamp.UtcDateTime.ToString('o')
                        Lux = if ($isFinite) { $lux } else { $null }
                        IsValid = $isFinite
                        FailureKind = if ($isFinite) { $null } else { 'InvalidValue' }
                        Error = if ($isFinite) { $null } else { "Invalid lux value '$lux'." }
                    })
                }
            }
            catch {
                $samples.Add([pscustomobject][ordered]@{
                    SensorIndex = $sensorIndex
                    DeviceId = $deviceId
                    IsDefault = $isDefault
                    Sequence = $sequence
                    ObservedUtc = $observedUtc
                    ReadingTimestampUtc = $null
                    Lux = $null
                    IsValid = $false
                    FailureKind = 'Error'
                    Error = $_.Exception.Message
                })
            }

            ++$sequence
            $remainingMs = [int][Math]::Floor(
                ($DurationSeconds - $stopwatch.Elapsed.TotalSeconds) * 1000.0)
            if ($remainingMs -le 0) {
                break
            }
            Start-Sleep -Milliseconds ([Math]::Min([int]$effectiveInterval, $remainingMs))
        } while ($stopwatch.Elapsed.TotalSeconds -lt $DurationSeconds)
        $stopwatch.Stop()
    }
    catch {
        $sensorError = $_.Exception.Message
    }
    finally {
        if ($intervalChanged) {
            try {
                $sensor.ReportInterval = $originalInterval
                $finalInterval = [uint32]$sensor.ReportInterval
                $intervalRestored = ($finalInterval -eq $originalInterval)
                if (-not $intervalRestored) {
                    $restoreError = "ReportInterval read back as $($sensor.ReportInterval), expected $originalInterval."
                }
            }
            catch {
                $intervalRestored = $false
                $restoreError = $_.Exception.Message
            }
        }
    }

    $sensorSamples = @($samples | Select-Object -Skip $sensorSampleStart)
    $validSamples = @($sensorSamples | Where-Object { $_.IsValid })
    $invalidSamples = @($sensorSamples | Where-Object { -not $_.IsValid })
    $errorSamples = @($invalidSamples | Where-Object {
        $_.FailureKind -eq 'Error' -or $_.FailureKind -eq 'InvalidValue'
    })
    $noDataSamples = @($invalidSamples | Where-Object {
        $_.FailureKind -eq 'NoData'
    })
    $luxValues = @($validSamples | ForEach-Object { [double]$_.Lux })
    $uniqueReadingTimestamps = @($validSamples |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.ReadingTimestampUtc) } |
        Select-Object -ExpandProperty ReadingTimestampUtc -Unique)
    $minimumLux = if ($luxValues.Count -gt 0) {
        [double]($luxValues | Measure-Object -Minimum).Minimum
    }
    else {
        $null
    }
    $maximumLux = if ($luxValues.Count -gt 0) {
        [double]($luxValues | Measure-Object -Maximum).Maximum
    }
    else {
        $null
    }
    $isConstant = $luxValues.Count -ge 2 -and
        (($maximumLux - $minimumLux) -le $ConstantToleranceLux)
    $timestampsAdvanced = $uniqueReadingTimestamps.Count -ge 2

    $status = if (-not $intervalRestored) {
        'RestoreError'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($sensorError) -and $validSamples.Count -eq 0) {
        'Error'
    }
    elseif ($validSamples.Count -eq 0 -and $errorSamples.Count -gt 0) {
        'Error'
    }
    elseif ($validSamples.Count -eq 0) {
        'NoData'
    }
    elseif ($isConstant) {
        'Constant'
    }
    elseif ($invalidSamples.Count -gt 0 -or -not [string]::IsNullOrWhiteSpace($sensorError)) {
        'PartialError'
    }
    elseif ($validSamples.Count -lt 2) {
        'InsufficientData'
    }
    else {
        'Healthy'
    }

    $summaryErrorParts = @()
    if (-not [string]::IsNullOrWhiteSpace($sensorError)) {
        $summaryErrorParts += $sensorError
    }
    if (-not [string]::IsNullOrWhiteSpace($restoreError)) {
        $summaryErrorParts += "ReportInterval restore failed: $restoreError"
    }

    $sensorSummaries.Add([pscustomobject][ordered]@{
        SensorIndex = $sensorIndex
        DeviceId = $deviceId
        DeviceName = $deviceName
        IsDefault = $isDefault
        Status = $status
        Error = if ($summaryErrorParts.Count -eq 0) { $null } else { $summaryErrorParts -join ' | ' }
        MinimumReportIntervalMs = $minimumInterval
        CurrentReportIntervalMsAtStart = $originalInterval
        OriginalReportIntervalMs = $originalInterval
        RequestedSampleIntervalMs = $SampleIntervalMs
        EffectiveReportIntervalMs = $effectiveInterval
        FinalReportIntervalMs = $finalInterval
        ReportIntervalChanged = $intervalChanged
        ReportIntervalRestored = $intervalRestored
        SampleCount = $sensorSamples.Count
        ValidSampleCount = $validSamples.Count
        InvalidSampleCount = $invalidSamples.Count
        ErrorSampleCount = $errorSamples.Count
        NoDataSampleCount = $noDataSamples.Count
        MinimumLux = $minimumLux
        MaximumLux = $maximumLux
        LuxRange = if ($luxValues.Count -gt 0) { $maximumLux - $minimumLux } else { $null }
        ConstantToleranceLux = $ConstantToleranceLux
        IsConstant = $isConstant
        DistinctReadingTimestampCount = $uniqueReadingTimestamps.Count
        ReadingTimestampsAdvanced = $timestampsAdvanced
    })
    ++$sensorIndex
}

$sensorStatusValues = @($sensorSummaries | ForEach-Object { [string]$_.Status })
$overallStatus = if ($sensorsToTest.Count -eq 0) {
    if ($enumerationStatus -eq 'Unavailable') { 'Unavailable' } else { 'NoSensor' }
}
elseif ($sensorStatusValues -contains 'RestoreError' -or
    $sensorStatusValues -contains 'Error' -or
    $sensorStatusValues -contains 'NoData') {
    'Failed'
}
elseif ($sensorStatusValues -contains 'Constant') {
    'WarningConstant'
}
elseif ($sensorStatusValues -contains 'PartialError' -or
    $sensorStatusValues -contains 'InsufficientData' -or
    $enumerationStatus -eq 'Error') {
    'Warning'
}
else {
    'Healthy'
}

$result = [pscustomobject][ordered]@{
    SchemaVersion = 1
    Test = 'DeckLux WinRT ambient-light sensor validation'
    StartedUtc = $startedUtc.ToString('o')
    CompletedUtc = [DateTime]::UtcNow.ToString('o')
    OverallStatus = $overallStatus
    DurationSeconds = $DurationSeconds
    RequestedSampleIntervalMs = $SampleIntervalMs
    ConstantToleranceLux = $ConstantToleranceLux
    AdjustReportInterval = $AdjustReportInterval
    AllSensorsRequested = [bool]$AllSensors
    EnumerationStatus = $enumerationStatus
    EnumeratedSensorCount = $enumeratedDevices.Count
    DefaultSensorFound = ($null -ne $defaultSensor)
    TestedSensorCount = $sensorSummaries.Count
    EnumeratedSensors = @($enumeratedDevices | ForEach-Object { $_ })
    Sensors = @($sensorSummaries | ForEach-Object { $_ })
    Samples = @($samples | ForEach-Object { $_ })
    Errors = @($errors | ForEach-Object { $_ })
}

switch ($OutputFormat) {
    'Json' {
        $result | ConvertTo-Json -Depth 10
    }
    'Csv' {
        New-DeckLuxCsvRows -Result $result | ConvertTo-Csv -NoTypeInformation
    }
    default {
        $result
    }
}
