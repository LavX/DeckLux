# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

<#
.SYNOPSIS
Compares every Windows ambient-light sensor in synchronized sampling cycles.

.DESCRIPTION
The tool temporarily configures every WinRT LightSensor report interval, then
subscribes to ReadingChanged on all sensors before collecting data. Each shared
cycle drains every sensor's event queue consecutively and correlates a selected
pair by the timestamps supplied by Windows.

On a firmware-identified Valve Galileo running DeckLux fusion, LTRF is the
preferred fused Windows channel and LTRS remains the secondary raw diagnostic
channel. The physical ACPI origin is still recorded, but the LTRF reading must
not be interpreted as raw left-sensor lux.

The tool temporarily changes only per-client WinRT sampling properties. It
captures ReportInterval, ReportLatency, ReportThreshold.LuxPercentage, and
ReportThreshold.AbsoluteLux; requests unbatched, zero-threshold events; and
restores each property independently in a finally block. No driver, PnP,
registry, display-brightness, or power-policy state is changed.

.EXAMPLE
.\Compare-DeckLuxSensors.ps1 -DurationSeconds 20 -SampleIntervalMs 250

.EXAMPLE
.\Compare-DeckLuxSensors.ps1 -DurationSeconds 20 -OutputFormat Json |
    Set-Content .\decklux-sensor-comparison.json
#>

[CmdletBinding()]
param(
    [ValidateRange(1.0, 3600.0)]
    [double]$DurationSeconds = 15.0,

    [ValidateRange(50, 60000)]
    [int]$SampleIntervalMs = 250,

    [ValidateRange(0, 600000)]
    [int]$MaxReadingAgeMs = 0,

    [ValidateRange(0, 600000)]
    [int]$MaxPairSkewMs = 0,

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

function ConvertTo-DeckLuxPnpInstanceId {
    param([AllowNull()][string]$DeviceId)

    if ([string]::IsNullOrWhiteSpace($DeviceId)) {
        return $null
    }

    $match = [regex]::Match(
        $DeviceId,
        '^\\\\\?\\(?<enumerator>[^#]+)#(?<device>[^#]+)#(?<instance>[^#]+)#')
    if (-not $match.Success) {
        return $null
    }

    return '{0}\{1}\{2}' -f
        $match.Groups['enumerator'].Value,
        $match.Groups['device'].Value,
        $match.Groups['instance'].Value
}

function Get-DeckLuxPlatformIdentity {
    $systemManufacturer = $null
    $systemProductName = $null
    $systemFamily = $null
    $baseBoardManufacturer = $null
    $baseBoardProduct = $null
    $source = 'Unavailable'

    try {
        $bios = Get-ItemProperty `
            -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' `
            -ErrorAction Stop
        $systemManufacturer = [string]$bios.SystemManufacturer
        $systemProductName = [string]$bios.SystemProductName
        $systemFamily = [string]$bios.SystemFamily
        $baseBoardManufacturer = [string]$bios.BaseBoardManufacturer
        $baseBoardProduct = [string]$bios.BaseBoardProduct
        $source = 'Firmware registry'
    }
    catch {
        try {
            $computerSystem = Get-CimInstance `
                -ClassName Win32_ComputerSystem `
                -ErrorAction Stop
            $baseBoard = Get-CimInstance `
                -ClassName Win32_BaseBoard `
                -ErrorAction Stop |
                Select-Object -First 1
            $systemManufacturer = [string]$computerSystem.Manufacturer
            $systemProductName = [string]$computerSystem.Model
            $systemFamily = [string]$computerSystem.SystemFamily
            $baseBoardManufacturer = [string]$baseBoard.Manufacturer
            $baseBoardProduct = [string]$baseBoard.Product
            $source = 'CIM'
        }
        catch {
            $source = 'Unavailable'
        }
    }

    $systemMatches = $systemManufacturer -ieq 'Valve' -and
        $systemProductName -ieq 'Galileo'
    $boardContradicts =
        (-not [string]::IsNullOrWhiteSpace($baseBoardManufacturer) -and
         $baseBoardManufacturer -ine 'Valve') -or
        (-not [string]::IsNullOrWhiteSpace($baseBoardProduct) -and
         $baseBoardProduct -ine 'Galileo')

    return [pscustomobject][ordered]@{
        Source = $source
        SystemManufacturer = $systemManufacturer
        SystemProductName = $systemProductName
        SystemFamily = $systemFamily
        BaseBoardManufacturer = $baseBoardManufacturer
        BaseBoardProduct = $baseBoardProduct
        IsValveGalileo = [bool]($systemMatches -and -not $boardContradicts)
    }
}

function Get-DeckLuxBiosDeviceName {
    param([AllowNull()][string]$PnpInstanceId)

    if ([string]::IsNullOrWhiteSpace($PnpInstanceId) -or
        $null -eq (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $property = Get-PnpDeviceProperty `
            -InstanceId $PnpInstanceId `
            -KeyName 'DEVPKEY_Device_BiosDeviceName' `
            -ErrorAction Stop
        return [string]$property.Data
    }
    catch {
        return $null
    }
}

function Resolve-DeckLuxSensorIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceId,

        [Parameter(Mandatory = $true)]
        [psobject]$Platform
    )

    $pnpInstanceId = ConvertTo-DeckLuxPnpInstanceId -DeviceId $DeviceId
    $biosDeviceName = Get-DeckLuxBiosDeviceName -PnpInstanceId $pnpInstanceId
    $biosLeaf = if ([string]::IsNullOrWhiteSpace($biosDeviceName)) {
        $null
    }
    else {
        ($biosDeviceName -split '\.')[-1]
    }

    $instanceSuffix = $null
    if (-not [string]::IsNullOrWhiteSpace($pnpInstanceId)) {
        $suffixMatch = [regex]::Match($pnpInstanceId, '\\(?<suffix>[0-9]+)$')
        if ($suffixMatch.Success) {
            $instanceSuffix = [int]$suffixMatch.Groups['suffix'].Value
        }
    }

    $role = switch -Regex ([string]$biosLeaf) {
        '^(?i:LTRF)$' { 'Primary'; break }
        '^(?i:LTRS)$' { 'Secondary'; break }
        default { 'Unknown' }
    }
    $physicalSide = 'Unknown'
    $signalKind = switch ($role) {
        'Primary' { 'PrimaryRaw' }
        'Secondary' { 'SecondaryRaw' }
        default { 'Unknown' }
    }
    $identitySource = if (-not [string]::IsNullOrWhiteSpace($biosLeaf)) {
        'PnP BIOS device name'
    }
    elseif ($null -ne $instanceSuffix) {
        'DeviceId only (no role or side inference)'
    }
    else {
        'Unavailable'
    }

    if ($Platform.IsValveGalileo) {
        if ($biosLeaf -ieq 'LTRF') {
            $physicalSide = 'Left'
            $signalKind = 'PreferredFused'
            $identitySource = 'Valve Galileo PnP BIOS device name'
        }
        elseif ($biosLeaf -ieq 'LTRS') {
            $physicalSide = 'Right'
            $signalKind = 'SecondaryRaw'
            $identitySource = 'Valve Galileo PnP BIOS device name'
        }
    }

    return [pscustomobject][ordered]@{
        PnpInstanceId = $pnpInstanceId
        BiosDeviceName = $biosDeviceName
        BiosLeaf = $biosLeaf
        InstanceSuffix = $instanceSuffix
        Role = $role
        PhysicalSide = $physicalSide
        SignalKind = $signalKind
        IdentitySource = $identitySource
    }
}

function New-DeckLuxComparisonCsvRows {
    param([Parameter(Mandatory = $true)][psobject]$Result)

    $pairByCycle = @{}
    foreach ($pair in @($Result.PairComparisons)) {
        $pairByCycle[[int]$pair.CycleIndex] = $pair
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($reading in @($Result.Readings)) {
        $pair = $null
        if ($pairByCycle.ContainsKey([int]$reading.CycleIndex)) {
            $pair = $pairByCycle[[int]$reading.CycleIndex]
        }
        $sensor = @($Result.Sensors | Where-Object {
            $_.SensorIndex -eq $reading.SensorIndex
        }) | Select-Object -First 1

        $rows.Add([pscustomobject][ordered]@{
            RecordType = 'Reading'
            OverallStatus = $Result.OverallStatus
            SensorStatus = if ($null -eq $sensor) { $null } else { $sensor.Status }
            ConfigurationErrors = if ($null -eq $sensor) { $null } else { $sensor.ConfigurationErrors }
            CleanupErrors = if ($null -eq $sensor) { $null } else { $sensor.CleanupErrors }
            CycleIndex = $reading.CycleIndex
            CycleStartedUtc = $reading.CycleStartedUtc
            CycleCompletedUtc = $reading.CycleCompletedUtc
            SensorIndex = $reading.SensorIndex
            DeviceId = $reading.DeviceId
            PnpInstanceId = $reading.PnpInstanceId
            BiosDeviceName = $reading.BiosDeviceName
            Role = $reading.Role
            PhysicalSide = $reading.PhysicalSide
            SignalKind = $reading.SignalKind
            IsDefault = $reading.IsDefault
            EventReceivedUtc = $reading.EventReceivedUtc
            ReadingTimestampUtc = $reading.ReadingTimestampUtc
            ReadingAgeMs = $reading.ReadingAgeMs
            Lux = $reading.Lux
            RawLux = $reading.RawLux
            IsValid = $reading.IsValid
            FailureKind = $reading.FailureKind
            Error = $reading.Error
            EventsDrained = $reading.EventsDrained
            EventsDiscarded = $reading.EventsDiscarded
            OriginalReportIntervalMs = if ($null -eq $sensor) { $null } else { $sensor.OriginalReportIntervalMs }
            EffectiveReportIntervalMs = if ($null -eq $sensor) { $null } else { $sensor.EffectiveReportIntervalMs }
            FinalReportIntervalMs = if ($null -eq $sensor) { $null } else { $sensor.FinalReportIntervalMs }
            ReportIntervalRestored = if ($null -eq $sensor) { $null } else { $sensor.ReportIntervalRestored }
            OriginalReportLatencyMs = if ($null -eq $sensor) { $null } else { $sensor.OriginalReportLatencyMs }
            EffectiveReportLatencyMs = if ($null -eq $sensor) { $null } else { $sensor.EffectiveReportLatencyMs }
            FinalReportLatencyMs = if ($null -eq $sensor) { $null } else { $sensor.FinalReportLatencyMs }
            ReportLatencyRestored = if ($null -eq $sensor) { $null } else { $sensor.ReportLatencyRestored }
            OriginalLuxPercentageThreshold = if ($null -eq $sensor) { $null } else { $sensor.OriginalLuxPercentageThreshold }
            EffectiveLuxPercentageThreshold = if ($null -eq $sensor) { $null } else { $sensor.EffectiveLuxPercentageThreshold }
            FinalLuxPercentageThreshold = if ($null -eq $sensor) { $null } else { $sensor.FinalLuxPercentageThreshold }
            LuxPercentageThresholdRestored = if ($null -eq $sensor) { $null } else { $sensor.LuxPercentageThresholdRestored }
            OriginalAbsoluteLuxThreshold = if ($null -eq $sensor) { $null } else { $sensor.OriginalAbsoluteLuxThreshold }
            EffectiveAbsoluteLuxThreshold = if ($null -eq $sensor) { $null } else { $sensor.EffectiveAbsoluteLuxThreshold }
            FinalAbsoluteLuxThreshold = if ($null -eq $sensor) { $null } else { $sensor.FinalAbsoluteLuxThreshold }
            AbsoluteLuxThresholdRestored = if ($null -eq $sensor) { $null } else { $sensor.AbsoluteLuxThresholdRestored }
            PairStatus = if ($null -eq $pair) { $null } else { $pair.Status }
            PairSensorAIndex = if ($null -eq $pair) { $null } else { $pair.SensorAIndex }
            PairSensorBIndex = if ($null -eq $pair) { $null } else { $pair.SensorBIndex }
            PairReadingTimestampSkewMs = if ($null -eq $pair) { $null } else { $pair.ReadingTimestampSkewMs }
            SensorBMinusSensorALux = if ($null -eq $pair) { $null } else { $pair.SensorBMinusSensorALux }
            AbsoluteDeltaLux = if ($null -eq $pair) { $null } else { $pair.AbsoluteDeltaLux }
            SensorBToSensorARatio = if ($null -eq $pair) { $null } else { $pair.SensorBToSensorARatio }
        })
    }

    if ($rows.Count -eq 0) {
        $rows.Add([pscustomobject][ordered]@{
            RecordType = 'Status'
            OverallStatus = $Result.OverallStatus
            SensorStatus = $null
            ConfigurationErrors = $null
            CleanupErrors = $null
            CycleIndex = $null
            CycleStartedUtc = $null
            CycleCompletedUtc = $null
            SensorIndex = $null
            DeviceId = $null
            PnpInstanceId = $null
            BiosDeviceName = $null
            Role = $null
            PhysicalSide = $null
            SignalKind = $null
            IsDefault = $null
            EventReceivedUtc = $null
            ReadingTimestampUtc = $null
            ReadingAgeMs = $null
            Lux = $null
            RawLux = $null
            IsValid = $false
            FailureKind = $Result.OverallStatus
            Error = $Result.Errors -join ' | '
            EventsDrained = 0
            EventsDiscarded = 0
            OriginalReportIntervalMs = $null
            EffectiveReportIntervalMs = $null
            FinalReportIntervalMs = $null
            ReportIntervalRestored = $null
            OriginalReportLatencyMs = $null
            EffectiveReportLatencyMs = $null
            FinalReportLatencyMs = $null
            ReportLatencyRestored = $null
            OriginalLuxPercentageThreshold = $null
            EffectiveLuxPercentageThreshold = $null
            FinalLuxPercentageThreshold = $null
            LuxPercentageThresholdRestored = $null
            OriginalAbsoluteLuxThreshold = $null
            EffectiveAbsoluteLuxThreshold = $null
            FinalAbsoluteLuxThreshold = $null
            AbsoluteLuxThresholdRestored = $null
            PairStatus = $null
            PairSensorAIndex = $null
            PairSensorBIndex = $null
            PairReadingTimestampSkewMs = $null
            SensorBMinusSensorALux = $null
            AbsoluteDeltaLux = $null
            SensorBToSensorARatio = $null
        })
    }

    return @($rows | ForEach-Object { $_ })
}

Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

if ($null -eq ('DeckLux.Diagnostics.SensorEventSubscription' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Reflection;
using System.Threading;

namespace DeckLux.Diagnostics
{
    public sealed class SensorEventSample
    {
        public DateTime EventReceivedUtc { get; set; }
        public DateTime ReadingTimestampUtc { get; set; }
        public bool HasReadingTimestamp { get; set; }
        public double IlluminanceInLux { get; set; }
        public bool HasLux { get; set; }
        public bool ValueIsValid { get; set; }
        public string Error { get; set; }
    }

    public sealed class SensorEventSubscription : IDisposable
    {
        private readonly object sensor;
        private readonly MethodInfo removeMethod;
        private readonly object registrationToken;
        private readonly Delegate handler;
        private readonly ConcurrentQueue<SensorEventSample> queue =
            new ConcurrentQueue<SensorEventSample>();
        private int disposed;

        public SensorEventSubscription(object sensor)
        {
            if (sensor == null)
            {
                throw new ArgumentNullException("sensor");
            }

            this.sensor = sensor;
            EventInfo readingChanged = sensor.GetType().GetEvent("ReadingChanged");
            if (readingChanged == null)
            {
                throw new MissingMemberException(sensor.GetType().FullName, "ReadingChanged");
            }

            MethodInfo callback = GetType().GetMethod(
                "OnReadingChanged",
                BindingFlags.Instance | BindingFlags.NonPublic);
            handler = Delegate.CreateDelegate(
                readingChanged.EventHandlerType,
                this,
                callback);
            removeMethod = readingChanged.GetRemoveMethod();
            registrationToken = readingChanged.GetAddMethod().Invoke(
                sensor,
                new object[] { handler });
        }

        private void OnReadingChanged(object sender, object eventArgs)
        {
            SensorEventSample sample = new SensorEventSample();
            sample.EventReceivedUtc = DateTime.UtcNow;

            try
            {
                if (eventArgs == null)
                {
                    throw new InvalidOperationException(
                        "ReadingChanged supplied no event arguments.");
                }

                PropertyInfo readingProperty = eventArgs.GetType().GetProperty("Reading");
                object reading = readingProperty == null
                    ? null
                    : readingProperty.GetValue(eventArgs, null);
                if (reading == null)
                {
                    throw new InvalidOperationException(
                        "ReadingChanged supplied no sensor reading.");
                }

                PropertyInfo luxProperty = reading.GetType().GetProperty("IlluminanceInLux");
                object luxValue = luxProperty == null
                    ? null
                    : luxProperty.GetValue(reading, null);
                if (luxValue != null)
                {
                    sample.IlluminanceInLux = Convert.ToDouble(
                        luxValue,
                        CultureInfo.InvariantCulture);
                    sample.HasLux = true;
                    sample.ValueIsValid =
                        !Double.IsNaN(sample.IlluminanceInLux) &&
                        !Double.IsInfinity(sample.IlluminanceInLux) &&
                        sample.IlluminanceInLux >= 0.0;
                }

                PropertyInfo timestampProperty = reading.GetType().GetProperty("Timestamp");
                object timestampValue = timestampProperty == null
                    ? null
                    : timestampProperty.GetValue(reading, null);
                if (timestampValue is DateTimeOffset)
                {
                    sample.ReadingTimestampUtc =
                        ((DateTimeOffset)timestampValue).UtcDateTime;
                    sample.HasReadingTimestamp = true;
                }
                else if (timestampValue is DateTime)
                {
                    sample.ReadingTimestampUtc =
                        ((DateTime)timestampValue).ToUniversalTime();
                    sample.HasReadingTimestamp = true;
                }
            }
            catch (Exception exception)
            {
                Exception current = exception;
                while (current is TargetInvocationException &&
                       current.InnerException != null)
                {
                    current = current.InnerException;
                }
                sample.Error = current.GetType().Name + ": " + current.Message;
            }

            queue.Enqueue(sample);
        }

        public SensorEventSample[] Drain()
        {
            List<SensorEventSample> samples = new List<SensorEventSample>();
            SensorEventSample sample;
            while (queue.TryDequeue(out sample))
            {
                samples.Add(sample);
            }
            return samples.ToArray();
        }

        public void Dispose()
        {
            if (Interlocked.CompareExchange(ref disposed, 1, 0) != 0)
            {
                return;
            }

            try
            {
                removeMethod.Invoke(sensor, new object[] { registrationToken });
                GC.KeepAlive(handler);
            }
            catch
            {
                Interlocked.Exchange(ref disposed, 0);
                throw;
            }
        }
    }
}
'@ -ErrorAction Stop
}

$startedUtc = [DateTime]::UtcNow
$errors = New-Object System.Collections.Generic.List[string]
$enumeratedDevices = New-Object System.Collections.Generic.List[object]
$sensorEntries = New-Object System.Collections.Generic.List[object]
$readings = New-Object System.Collections.Generic.List[object]
$cycles = New-Object System.Collections.Generic.List[object]
$pairComparisons = New-Object System.Collections.Generic.List[object]
$platform = Get-DeckLuxPlatformIdentity
$enumerationStatus = 'NotStarted'
$lightSensorType = $null
$deviceInformationType = $null
$deviceInformationCollectionType = $null
$defaultSensorDeviceId = $null

try {
    $lightSensorType = [Windows.Devices.Sensors.LightSensor, Windows.Devices.Sensors, ContentType = WindowsRuntime]
    $deviceInformationType = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
    $deviceInformationCollectionType = [Windows.Devices.Enumeration.DeviceInformationCollection, Windows.Devices.Enumeration, ContentType = WindowsRuntime]

    try {
        $defaultSensor = $lightSensorType::GetDefault()
        if ($null -ne $defaultSensor) {
            $defaultSensorDeviceId = [string]$defaultSensor.DeviceId
        }
    }
    catch {
        $errors.Add("LightSensor.GetDefault failed: $($_.Exception.Message)")
    }

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
        $enumerationStatus = 'NoSensor'
    }
    catch {
        $enumerationStatus = 'Error'
        $errors.Add("WinRT light-sensor enumeration failed: $($_.Exception.Message)")
    }
}
catch {
    $enumerationStatus = 'Unavailable'
    $errors.Add("Windows.Devices.Sensors.LightSensor is unavailable: $($_.Exception.Message)")
}

$sensorIndex = 0
if ($null -ne $lightSensorType) {
    foreach ($device in $enumeratedDevices) {
        $identity = Resolve-DeckLuxSensorIdentity `
            -DeviceId ([string]$device.Id) `
            -Platform $platform
        $sensor = $null
        $openError = $null
        $minimumReportInterval = $null
        $originalReportInterval = $null
        $originalReportLatency = $null
        $maximumBatchSize = $null
        $reportThreshold = $null
        $originalLuxPercentage = $null
        $originalAbsoluteLux = $null

        try {
            $fromIdOperation = $lightSensorType::FromIdAsync([string]$device.Id)
            $sensor = Wait-DeckLuxWinRtOperation `
                -Operation $fromIdOperation `
                -ResultType $lightSensorType
            if ($null -eq $sensor) {
                throw 'LightSensor.FromIdAsync returned no sensor.'
            }
            $minimumReportInterval = [uint32]$sensor.MinimumReportInterval
            $originalReportInterval = [uint32]$sensor.ReportInterval
            $originalReportLatency = [uint32]$sensor.ReportLatency
            $maximumBatchSize = [uint32]$sensor.MaxBatchSize
            $reportThreshold = $sensor.ReportThreshold
            if ($null -eq $reportThreshold) {
                throw 'LightSensor.ReportThreshold returned no threshold object.'
            }
            $originalLuxPercentage = [single]$reportThreshold.LuxPercentage
            $originalAbsoluteLux = [single]$reportThreshold.AbsoluteLux
        }
        catch {
            $openError = $_.Exception.Message
            $errors.Add("LightSensor.FromIdAsync or sampling-property capture failed for '$($device.Id)': $openError")
            $sensor = $null
            $reportThreshold = $null
        }

        $effectiveReportInterval = if ($null -eq $minimumReportInterval) {
            $SampleIntervalMs
        }
        else {
            [int][Math]::Max($SampleIntervalMs, [int]$minimumReportInterval)
        }

        $sensorEntries.Add([pscustomobject][ordered]@{
            SensorIndex = $sensorIndex
            DeviceId = [string]$device.Id
            DeviceName = [string]$device.Name
            IsEnabled = [bool]$device.IsEnabled
            IsDefault = [bool]([string]$device.Id -ieq $defaultSensorDeviceId)
            PnpInstanceId = $identity.PnpInstanceId
            BiosDeviceName = $identity.BiosDeviceName
            BiosLeaf = $identity.BiosLeaf
            InstanceSuffix = $identity.InstanceSuffix
            Role = $identity.Role
            PhysicalSide = $identity.PhysicalSide
            SignalKind = $identity.SignalKind
            IdentitySource = $identity.IdentitySource
            Sensor = $sensor
            Threshold = $reportThreshold
            Subscription = $null
            OpenError = $openError
            SubscribeError = $null
            UnsubscribeError = $null
            MinimumReportIntervalMs = $minimumReportInterval
            MaximumBatchSize = $maximumBatchSize
            OriginalReportIntervalMs = $originalReportInterval
            EffectiveReportIntervalMs = $effectiveReportInterval
            FinalReportIntervalMs = $null
            ReportIntervalWriteAttempted = $false
            ReportIntervalWriteSucceeded = $false
            ReportIntervalRestoreAttempted = $false
            ReportIntervalRestored = $null
            ReportIntervalConfigureError = $null
            ReportIntervalRestoreError = $null
            OriginalReportLatencyMs = $originalReportLatency
            EffectiveReportLatencyMs = $originalReportLatency
            FinalReportLatencyMs = $null
            ReportLatencyWriteAttempted = $false
            ReportLatencyWriteSucceeded = $false
            ReportLatencyRestoreAttempted = $false
            ReportLatencyRestored = $null
            ReportLatencyConfigureError = $null
            ReportLatencyRestoreError = $null
            OriginalLuxPercentageThreshold = $originalLuxPercentage
            EffectiveLuxPercentageThreshold = $originalLuxPercentage
            FinalLuxPercentageThreshold = $null
            LuxPercentageWriteAttempted = $false
            LuxPercentageWriteSucceeded = $false
            LuxPercentageRestoreAttempted = $false
            LuxPercentageThresholdRestored = $null
            LuxPercentageConfigureError = $null
            LuxPercentageRestoreError = $null
            OriginalAbsoluteLuxThreshold = $originalAbsoluteLux
            EffectiveAbsoluteLuxThreshold = $originalAbsoluteLux
            FinalAbsoluteLuxThreshold = $null
            AbsoluteLuxWriteAttempted = $false
            AbsoluteLuxWriteSucceeded = $false
            AbsoluteLuxRestoreAttempted = $false
            AbsoluteLuxThresholdRestored = $null
            AbsoluteLuxConfigureError = $null
            AbsoluteLuxRestoreError = $null
        })
        ++$sensorIndex
    }
}

$pairSelection = $null
$primary = @($sensorEntries | Where-Object { $_.Role -eq 'Primary' }) |
    Select-Object -First 1
$secondary = @($sensorEntries | Where-Object { $_.Role -eq 'Secondary' }) |
    Select-Object -First 1
if ($null -ne $primary -and $null -ne $secondary) {
    if ($platform.IsValveGalileo) {
        $pairSelection = [pscustomobject][ordered]@{
            Kind = 'GalileoFusedSecondary'
            SensorAIndex = $primary.SensorIndex
            SensorALabel = 'PreferredFused'
            SensorBIndex = $secondary.SensorIndex
            SensorBLabel = 'SecondaryRaw'
        }
    }
    else {
        $pairSelection = [pscustomobject][ordered]@{
            Kind = 'PrimarySecondary'
            SensorAIndex = $primary.SensorIndex
            SensorALabel = 'Primary'
            SensorBIndex = $secondary.SensorIndex
            SensorBLabel = 'Secondary'
        }
    }
}
elseif ($sensorEntries.Count -ge 2) {
    $pairSelection = [pscustomobject][ordered]@{
        Kind = 'EnumerationOrder'
        SensorAIndex = $sensorEntries[0].SensorIndex
        SensorALabel = 'First'
        SensorBIndex = $sensorEntries[1].SensorIndex
        SensorBLabel = 'Second'
    }
}

$cycleIntervalMs = $SampleIntervalMs
foreach ($entry in $sensorEntries) {
    $cycleIntervalMs = [Math]::Max(
        $cycleIntervalMs,
        [int]$entry.EffectiveReportIntervalMs)
}
$effectiveMaxReadingAgeMs = if ($MaxReadingAgeMs -eq 0) {
    [Math]::Max(1000, 3 * $cycleIntervalMs)
}
else {
    $MaxReadingAgeMs
}
$effectiveMaxPairSkewMs = if ($MaxPairSkewMs -eq 0) {
    $cycleIntervalMs
}
else {
    $MaxPairSkewMs
}
$fatalError = $null
$subscriptionsStartedUtc = $null

try {
    # Configure every client's sampling properties before any subscription.
    # Writes are independent so one failure cannot skip another field.
    foreach ($entry in $sensorEntries) {
        if ($null -eq $entry.Sensor -or $null -eq $entry.Threshold) {
            continue
        }

        $entry.ReportIntervalWriteAttempted = $true
        try {
            $entry.Sensor.ReportInterval = [uint32]$entry.EffectiveReportIntervalMs
            $entry.ReportIntervalWriteSucceeded = $true
            $entry.EffectiveReportIntervalMs = [uint32]$entry.Sensor.ReportInterval
            if ($entry.EffectiveReportIntervalMs -ne
                [uint32][Math]::Max($SampleIntervalMs, [int]$entry.MinimumReportIntervalMs)) {
                throw "ReportInterval readback was $($entry.EffectiveReportIntervalMs) ms."
            }
        }
        catch {
            $entry.ReportIntervalConfigureError = $_.Exception.Message
            $errors.Add("Could not configure ReportInterval for '$($entry.DeviceId)': $($entry.ReportIntervalConfigureError)")
        }

        # ReportLatency zero means immediate delivery. Avoid a no-op write when
        # the client is already unbatched (the normal DeckLux state).
        if ([uint32]$entry.OriginalReportLatencyMs -ne 0) {
            $entry.ReportLatencyWriteAttempted = $true
            try {
                $entry.Sensor.ReportLatency = [uint32]0
                $entry.ReportLatencyWriteSucceeded = $true
                $entry.EffectiveReportLatencyMs = [uint32]$entry.Sensor.ReportLatency
                if ($entry.EffectiveReportLatencyMs -ne 0) {
                    throw "ReportLatency readback was $($entry.EffectiveReportLatencyMs) ms."
                }
            }
            catch {
                $entry.ReportLatencyConfigureError = $_.Exception.Message
                $errors.Add("Could not configure ReportLatency for '$($entry.DeviceId)': $($entry.ReportLatencyConfigureError)")
            }
        }

        $entry.LuxPercentageWriteAttempted = $true
        try {
            $entry.Threshold.LuxPercentage = [single]0
            $entry.LuxPercentageWriteSucceeded = $true
            $entry.EffectiveLuxPercentageThreshold =
                [single]$entry.Threshold.LuxPercentage
            if ($entry.EffectiveLuxPercentageThreshold -ne [single]0) {
                throw "LuxPercentage threshold readback was $($entry.EffectiveLuxPercentageThreshold)."
            }
        }
        catch {
            $entry.LuxPercentageConfigureError = $_.Exception.Message
            $errors.Add("Could not configure LuxPercentage for '$($entry.DeviceId)': $($entry.LuxPercentageConfigureError)")
        }

        $entry.AbsoluteLuxWriteAttempted = $true
        try {
            $entry.Threshold.AbsoluteLux = [single]0
            $entry.AbsoluteLuxWriteSucceeded = $true
            $entry.EffectiveAbsoluteLuxThreshold =
                [single]$entry.Threshold.AbsoluteLux
            if ($entry.EffectiveAbsoluteLuxThreshold -ne [single]0) {
                throw "AbsoluteLux threshold readback was $($entry.EffectiveAbsoluteLuxThreshold)."
            }
        }
        catch {
            $entry.AbsoluteLuxConfigureError = $_.Exception.Message
            $errors.Add("Could not configure AbsoluteLux for '$($entry.DeviceId)': $($entry.AbsoluteLuxConfigureError)")
        }
    }

    # ReadingChanged activates WinRT acquisition; polling GetCurrentReading alone
    # can return an indefinitely stale cached value.
    $subscriptionsStartedUtc = [DateTime]::UtcNow
    foreach ($entry in $sensorEntries) {
        if ($null -eq $entry.Sensor) {
            continue
        }

        try {
            $entry.Subscription =
                [DeckLux.Diagnostics.SensorEventSubscription]::new($entry.Sensor)
        }
        catch {
            $entry.SubscribeError = $_.Exception.Message
            $errors.Add("Could not subscribe to '$($entry.DeviceId)': $($entry.SubscribeError)")
        }
    }

    # Shared sampling cycles drain each event queue consecutively.
    if ($sensorEntries.Count -gt 0) {
        $durationMs = [int][Math]::Ceiling($DurationSeconds * 1000.0)
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $nextCycleDueMs = [Math]::Min($cycleIntervalMs, $durationMs)
        $cycleIndex = 0

        while ($true) {
            $sleepMs = $nextCycleDueMs - [int]$stopwatch.ElapsedMilliseconds
            if ($sleepMs -gt 0) {
                Start-Sleep -Milliseconds $sleepMs
            }

            $cycleStartedUtc = [DateTime]::UtcNow
            $cycleReadings = New-Object System.Collections.Generic.List[object]
            foreach ($entry in $sensorEntries) {
                $observedUtc = [DateTime]::UtcNow
                $eventsDrained = 0
                $eventReceivedUtc = $null
                $readingTimestampUtc = $null
                $readingAgeMs = $null
                $lux = $null
                $isValid = $false
                $failureKind = $null
                $readingError = $null

                if ($null -eq $entry.Sensor) {
                    $failureKind = 'OpenError'
                    $readingError = $entry.OpenError
                }
                elseif ($null -eq $entry.Subscription) {
                    $failureKind = 'SubscriptionError'
                    $readingError = $entry.SubscribeError
                }
                else {
                    $eventSamples = @($entry.Subscription.Drain())
                    $eventsDrained = $eventSamples.Count
                    if ($eventsDrained -eq 0) {
                        $failureKind = 'NoFreshEvent'
                        $readingError = 'No ReadingChanged event arrived during this cycle.'
                    }
                    else {
                        $latest = $eventSamples[-1]
                        $eventReceivedUtc = $latest.EventReceivedUtc.ToString('o')
                        if ($latest.HasReadingTimestamp) {
                            $readingTimestampUtc =
                                $latest.ReadingTimestampUtc.ToString('o')
                            $readingAgeMs = [Math]::Round(
                                ($observedUtc - $latest.ReadingTimestampUtc).TotalMilliseconds,
                                3)
                        }
                        if ($latest.HasLux) {
                            $lux = [double]$latest.IlluminanceInLux
                        }

                        if (-not [string]::IsNullOrWhiteSpace($latest.Error)) {
                            $failureKind = 'EventError'
                            $readingError = [string]$latest.Error
                        }
                        elseif (-not $latest.HasLux) {
                            $failureKind = 'NoData'
                            $readingError = 'The event contained no illuminance value.'
                        }
                        elseif (-not $latest.ValueIsValid) {
                            $failureKind = 'InvalidValue'
                            $readingError = "Invalid lux value '$lux'."
                        }
                        elseif (-not $latest.HasReadingTimestamp) {
                            $failureKind = 'MissingTimestamp'
                            $readingError = 'The event contained no reading timestamp.'
                        }
                        elseif ($readingAgeMs -lt -2000.0) {
                            $failureKind = 'FutureTimestamp'
                            $readingError = 'The reading timestamp is more than two seconds in the future.'
                        }
                        elseif ($readingAgeMs -gt $effectiveMaxReadingAgeMs) {
                            $failureKind = 'StaleReading'
                            $readingError = "The reading is older than $effectiveMaxReadingAgeMs ms."
                        }
                        else {
                            $isValid = $true
                        }
                    }
                }

                $reading = [pscustomobject][ordered]@{
                    CycleIndex = $cycleIndex
                    CycleStartedUtc = $cycleStartedUtc.ToString('o')
                    CycleCompletedUtc = $null
                    ObservedUtc = $observedUtc.ToString('o')
                    SensorIndex = $entry.SensorIndex
                    DeviceId = $entry.DeviceId
                    PnpInstanceId = $entry.PnpInstanceId
                    BiosDeviceName = $entry.BiosDeviceName
                    Role = $entry.Role
                    PhysicalSide = $entry.PhysicalSide
                    SignalKind = $entry.SignalKind
                    IsDefault = $entry.IsDefault
                    EventReceivedUtc = $eventReceivedUtc
                    ReadingTimestampUtc = $readingTimestampUtc
                    ReadingAgeMs = $readingAgeMs
                    Lux = if ($isValid) { $lux } else { $null }
                    RawLux = $lux
                    IsValid = $isValid
                    FailureKind = $failureKind
                    Error = $readingError
                    EventsDrained = $eventsDrained
                    EventsDiscarded = [Math]::Max(0, $eventsDrained - 1)
                }
                $cycleReadings.Add($reading)
                $readings.Add($reading)
            }

            $cycleCompletedUtc = [DateTime]::UtcNow
            foreach ($reading in $cycleReadings) {
                $reading.CycleCompletedUtc = $cycleCompletedUtc.ToString('o')
            }
            $cycles.Add([pscustomobject][ordered]@{
                CycleIndex = $cycleIndex
                StartedUtc = $cycleStartedUtc.ToString('o')
                CompletedUtc = $cycleCompletedUtc.ToString('o')
                ReadingCount = $cycleReadings.Count
                ValidReadingCount = @($cycleReadings | Where-Object { $_.IsValid }).Count
            })

            if ($null -ne $pairSelection) {
                $a = @($cycleReadings | Where-Object {
                    $_.SensorIndex -eq $pairSelection.SensorAIndex
                }) | Select-Object -First 1
                $b = @($cycleReadings | Where-Object {
                    $_.SensorIndex -eq $pairSelection.SensorBIndex
                }) | Select-Object -First 1
                $pairInputsValid = $null -ne $a -and $null -ne $b -and
                    [bool]$a.IsValid -and [bool]$b.IsValid
                $timestampSkewMs = if ($pairInputsValid) {
                    [Math]::Round([Math]::Abs((
                        [DateTime]::Parse($b.ReadingTimestampUtc).ToUniversalTime() -
                        [DateTime]::Parse($a.ReadingTimestampUtc).ToUniversalTime()
                    ).TotalMilliseconds), 3)
                }
                else {
                    $null
                }
                $withinSkew = $pairInputsValid -and
                    $null -ne $timestampSkewMs -and
                    $timestampSkewMs -le $effectiveMaxPairSkewMs
                $pairStatus = if (-not $pairInputsValid) {
                    'InvalidInput'
                }
                elseif (-not $withinSkew) {
                    'TimestampSkew'
                }
                else {
                    'Comparable'
                }
                $deltaLux = if ($withinSkew) {
                    [double]$b.Lux - [double]$a.Lux
                }
                else {
                    $null
                }
                $ratio = if ($withinSkew -and [double]$a.Lux -gt 0.0) {
                    [double]$b.Lux / [double]$a.Lux
                }
                else {
                    $null
                }

                $pairComparisons.Add([pscustomobject][ordered]@{
                    CycleIndex = $cycleIndex
                    CycleStartedUtc = $cycleStartedUtc.ToString('o')
                    Kind = $pairSelection.Kind
                    SensorAIndex = $pairSelection.SensorAIndex
                    SensorALabel = $pairSelection.SensorALabel
                    SensorAReadingTimestampUtc = if ($null -eq $a) { $null } else { $a.ReadingTimestampUtc }
                    SensorALux = if ($pairInputsValid) { $a.Lux } else { $null }
                    SensorBIndex = $pairSelection.SensorBIndex
                    SensorBLabel = $pairSelection.SensorBLabel
                    SensorBReadingTimestampUtc = if ($null -eq $b) { $null } else { $b.ReadingTimestampUtc }
                    SensorBLux = if ($pairInputsValid) { $b.Lux } else { $null }
                    InputsValid = $pairInputsValid
                    ReadingTimestampSkewMs = $timestampSkewMs
                    MaximumAllowedSkewMs = $effectiveMaxPairSkewMs
                    IsComparable = $withinSkew
                    Status = $pairStatus
                    SensorBMinusSensorALux = $deltaLux
                    AbsoluteDeltaLux = if ($withinSkew) { [Math]::Abs($deltaLux) } else { $null }
                    SensorBToSensorARatio = $ratio
                    RatioUnavailableBecauseSensorAIsZero = [bool]($withinSkew -and [double]$a.Lux -eq 0.0)
                })
            }

            ++$cycleIndex
            if ($nextCycleDueMs -ge $durationMs -or
                $stopwatch.ElapsedMilliseconds -ge $durationMs) {
                break
            }

            # Move to the next future slot. Never emit catch-up cycles after a
            # slow read or scheduling pause.
            $nextSlot = (
                [Math]::Floor(
                    $stopwatch.ElapsedMilliseconds / [double]$cycleIntervalMs) +
                1) * $cycleIntervalMs
            $nextCycleDueMs = [Math]::Min($durationMs, [int]$nextSlot)
        }
        $stopwatch.Stop()
    }
}
catch {
    $fatalError = $_.Exception.Message
    $errors.Add("Comparison failed: $fatalError")
}
finally {
    foreach ($entry in $sensorEntries) {
        if ($null -ne $entry.Subscription) {
            try {
                $entry.Subscription.Dispose()
            }
            catch {
                $firstUnsubscribeError = $_.Exception.Message
                try {
                    # Dispose resets its guard after a failed remove accessor,
                    # so cleanup gets one immediate retry.
                    $entry.Subscription.Dispose()
                }
                catch {
                    $entry.UnsubscribeError =
                        "$firstUnsubscribeError | Retry: $($_.Exception.Message)"
                    $errors.Add("Could not unsubscribe from '$($entry.DeviceId)': $($entry.UnsubscribeError)")
                }
            }
        }
    }

    # Restore in reverse configuration order. Each field is attempted and
    # verified independently, even when another field's restore fails.
    foreach ($entry in $sensorEntries) {
        if ($null -eq $entry.Sensor -or $null -eq $entry.Threshold) {
            continue
        }

        if ($entry.AbsoluteLuxWriteAttempted) {
            $entry.AbsoluteLuxRestoreAttempted = $true
            try {
                $entry.Threshold.AbsoluteLux =
                    [single]$entry.OriginalAbsoluteLuxThreshold
            }
            catch {
                $entry.AbsoluteLuxRestoreError = $_.Exception.Message
            }
        }
        try {
            $entry.FinalAbsoluteLuxThreshold =
                [single]$entry.Threshold.AbsoluteLux
            $entry.AbsoluteLuxThresholdRestored =
                $entry.FinalAbsoluteLuxThreshold -eq
                [single]$entry.OriginalAbsoluteLuxThreshold
            if (-not $entry.AbsoluteLuxThresholdRestored -and
                [string]::IsNullOrWhiteSpace($entry.AbsoluteLuxRestoreError)) {
                $entry.AbsoluteLuxRestoreError =
                    "AbsoluteLux readback was $($entry.FinalAbsoluteLuxThreshold)."
            }
        }
        catch {
            $entry.AbsoluteLuxThresholdRestored = $false
            if ([string]::IsNullOrWhiteSpace($entry.AbsoluteLuxRestoreError)) {
                $entry.AbsoluteLuxRestoreError = $_.Exception.Message
            }
        }
        if (-not $entry.AbsoluteLuxThresholdRestored) {
            $errors.Add("Could not restore AbsoluteLux for '$($entry.DeviceId)': $($entry.AbsoluteLuxRestoreError)")
        }

        if ($entry.LuxPercentageWriteAttempted) {
            $entry.LuxPercentageRestoreAttempted = $true
            try {
                $entry.Threshold.LuxPercentage =
                    [single]$entry.OriginalLuxPercentageThreshold
            }
            catch {
                $entry.LuxPercentageRestoreError = $_.Exception.Message
            }
        }
        try {
            $entry.FinalLuxPercentageThreshold =
                [single]$entry.Threshold.LuxPercentage
            $entry.LuxPercentageThresholdRestored =
                $entry.FinalLuxPercentageThreshold -eq
                [single]$entry.OriginalLuxPercentageThreshold
            if (-not $entry.LuxPercentageThresholdRestored -and
                [string]::IsNullOrWhiteSpace($entry.LuxPercentageRestoreError)) {
                $entry.LuxPercentageRestoreError =
                    "LuxPercentage readback was $($entry.FinalLuxPercentageThreshold)."
            }
        }
        catch {
            $entry.LuxPercentageThresholdRestored = $false
            if ([string]::IsNullOrWhiteSpace($entry.LuxPercentageRestoreError)) {
                $entry.LuxPercentageRestoreError = $_.Exception.Message
            }
        }
        if (-not $entry.LuxPercentageThresholdRestored) {
            $errors.Add("Could not restore LuxPercentage for '$($entry.DeviceId)': $($entry.LuxPercentageRestoreError)")
        }

        if ($entry.ReportLatencyWriteAttempted) {
            $entry.ReportLatencyRestoreAttempted = $true
            try {
                $entry.Sensor.ReportLatency =
                    [uint32]$entry.OriginalReportLatencyMs
            }
            catch {
                $entry.ReportLatencyRestoreError = $_.Exception.Message
            }
        }
        try {
            $entry.FinalReportLatencyMs =
                [uint32]$entry.Sensor.ReportLatency
            $entry.ReportLatencyRestored =
                $entry.FinalReportLatencyMs -eq
                [uint32]$entry.OriginalReportLatencyMs
            if (-not $entry.ReportLatencyRestored -and
                [string]::IsNullOrWhiteSpace($entry.ReportLatencyRestoreError)) {
                $entry.ReportLatencyRestoreError =
                    "ReportLatency readback was $($entry.FinalReportLatencyMs) ms."
            }
        }
        catch {
            $entry.ReportLatencyRestored = $false
            if ([string]::IsNullOrWhiteSpace($entry.ReportLatencyRestoreError)) {
                $entry.ReportLatencyRestoreError = $_.Exception.Message
            }
        }
        if (-not $entry.ReportLatencyRestored) {
            $errors.Add("Could not restore ReportLatency for '$($entry.DeviceId)': $($entry.ReportLatencyRestoreError)")
        }

        if ($entry.ReportIntervalWriteAttempted) {
            $entry.ReportIntervalRestoreAttempted = $true
            try {
                $entry.Sensor.ReportInterval =
                    [uint32]$entry.OriginalReportIntervalMs
            }
            catch {
                $entry.ReportIntervalRestoreError = $_.Exception.Message
            }
        }
        try {
            $entry.FinalReportIntervalMs =
                [uint32]$entry.Sensor.ReportInterval
            $entry.ReportIntervalRestored =
                $entry.FinalReportIntervalMs -eq
                [uint32]$entry.OriginalReportIntervalMs
            if (-not $entry.ReportIntervalRestored -and
                [string]::IsNullOrWhiteSpace($entry.ReportIntervalRestoreError)) {
                $entry.ReportIntervalRestoreError =
                    "ReportInterval readback was $($entry.FinalReportIntervalMs) ms."
            }
        }
        catch {
            $entry.ReportIntervalRestored = $false
            if ([string]::IsNullOrWhiteSpace($entry.ReportIntervalRestoreError)) {
                $entry.ReportIntervalRestoreError = $_.Exception.Message
            }
        }
        if (-not $entry.ReportIntervalRestored) {
            $errors.Add("Could not restore ReportInterval for '$($entry.DeviceId)': $($entry.ReportIntervalRestoreError)")
        }
    }
}

$sensorSummaries = New-Object System.Collections.Generic.List[object]
foreach ($entry in $sensorEntries) {
    $sensorReadings = @($readings | Where-Object {
        $_.SensorIndex -eq $entry.SensorIndex
    })
    $validReadings = @($sensorReadings | Where-Object { $_.IsValid })
    $sensorStatus = if (-not [string]::IsNullOrWhiteSpace($entry.OpenError)) {
        'OpenError'
    }
    elseif (@(
        $entry.ReportIntervalRestored,
        $entry.ReportLatencyRestored,
        $entry.LuxPercentageThresholdRestored,
        $entry.AbsoluteLuxThresholdRestored) -contains $false) {
        'RestoreError'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($entry.UnsubscribeError)) {
        'CleanupError'
    }
    elseif (-not [string]::IsNullOrWhiteSpace(
            $entry.ReportIntervalConfigureError) -or
        -not [string]::IsNullOrWhiteSpace(
            $entry.ReportLatencyConfigureError) -or
        -not [string]::IsNullOrWhiteSpace(
            $entry.LuxPercentageConfigureError) -or
        -not [string]::IsNullOrWhiteSpace(
            $entry.AbsoluteLuxConfigureError)) {
        'ConfigurationError'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($entry.SubscribeError)) {
        'SubscriptionError'
    }
    elseif ($validReadings.Count -eq 0) {
        'NoValidReadings'
    }
    elseif ($validReadings.Count -lt $sensorReadings.Count) {
        'Partial'
    }
    else {
        'Healthy'
    }

    $configurationErrors = @(@(
        $entry.ReportIntervalConfigureError,
        $entry.ReportLatencyConfigureError,
        $entry.LuxPercentageConfigureError,
        $entry.AbsoluteLuxConfigureError) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $cleanupErrors = @(@(
        $entry.UnsubscribeError,
        $entry.ReportIntervalRestoreError,
        $entry.ReportLatencyRestoreError,
        $entry.LuxPercentageRestoreError,
        $entry.AbsoluteLuxRestoreError) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $sensorSummaries.Add([pscustomobject][ordered]@{
        SensorIndex = $entry.SensorIndex
        DeviceId = $entry.DeviceId
        DeviceName = $entry.DeviceName
        IsEnabled = $entry.IsEnabled
        IsDefault = $entry.IsDefault
        PnpInstanceId = $entry.PnpInstanceId
        BiosDeviceName = $entry.BiosDeviceName
        BiosLeaf = $entry.BiosLeaf
        InstanceSuffix = $entry.InstanceSuffix
        Role = $entry.Role
        PhysicalSide = $entry.PhysicalSide
        SignalKind = $entry.SignalKind
        IdentitySource = $entry.IdentitySource
        Status = $sensorStatus
        OpenError = $entry.OpenError
        SubscribeError = $entry.SubscribeError
        UnsubscribeError = $entry.UnsubscribeError
        ConfigurationErrors = if ($configurationErrors.Count -eq 0) {
            $null
        }
        else {
            $configurationErrors -join ' | '
        }
        CleanupErrors = if ($cleanupErrors.Count -eq 0) {
            $null
        }
        else {
            $cleanupErrors -join ' | '
        }
        MinimumReportIntervalMs = $entry.MinimumReportIntervalMs
        MaximumBatchSize = $entry.MaximumBatchSize
        OriginalReportIntervalMs = $entry.OriginalReportIntervalMs
        EffectiveReportIntervalMs = $entry.EffectiveReportIntervalMs
        FinalReportIntervalMs = $entry.FinalReportIntervalMs
        ReportIntervalWriteAttempted = $entry.ReportIntervalWriteAttempted
        ReportIntervalWriteSucceeded = $entry.ReportIntervalWriteSucceeded
        ReportIntervalRestoreAttempted = $entry.ReportIntervalRestoreAttempted
        ReportIntervalRestored = $entry.ReportIntervalRestored
        ReportIntervalConfigureError = $entry.ReportIntervalConfigureError
        ReportIntervalRestoreError = $entry.ReportIntervalRestoreError
        OriginalReportLatencyMs = $entry.OriginalReportLatencyMs
        EffectiveReportLatencyMs = $entry.EffectiveReportLatencyMs
        FinalReportLatencyMs = $entry.FinalReportLatencyMs
        ReportLatencyWriteAttempted = $entry.ReportLatencyWriteAttempted
        ReportLatencyWriteSucceeded = $entry.ReportLatencyWriteSucceeded
        ReportLatencyRestoreAttempted = $entry.ReportLatencyRestoreAttempted
        ReportLatencyRestored = $entry.ReportLatencyRestored
        ReportLatencyConfigureError = $entry.ReportLatencyConfigureError
        ReportLatencyRestoreError = $entry.ReportLatencyRestoreError
        OriginalLuxPercentageThreshold = $entry.OriginalLuxPercentageThreshold
        EffectiveLuxPercentageThreshold = $entry.EffectiveLuxPercentageThreshold
        FinalLuxPercentageThreshold = $entry.FinalLuxPercentageThreshold
        LuxPercentageWriteAttempted = $entry.LuxPercentageWriteAttempted
        LuxPercentageWriteSucceeded = $entry.LuxPercentageWriteSucceeded
        LuxPercentageRestoreAttempted = $entry.LuxPercentageRestoreAttempted
        LuxPercentageThresholdRestored = $entry.LuxPercentageThresholdRestored
        LuxPercentageConfigureError = $entry.LuxPercentageConfigureError
        LuxPercentageRestoreError = $entry.LuxPercentageRestoreError
        OriginalAbsoluteLuxThreshold = $entry.OriginalAbsoluteLuxThreshold
        EffectiveAbsoluteLuxThreshold = $entry.EffectiveAbsoluteLuxThreshold
        FinalAbsoluteLuxThreshold = $entry.FinalAbsoluteLuxThreshold
        AbsoluteLuxWriteAttempted = $entry.AbsoluteLuxWriteAttempted
        AbsoluteLuxWriteSucceeded = $entry.AbsoluteLuxWriteSucceeded
        AbsoluteLuxRestoreAttempted = $entry.AbsoluteLuxRestoreAttempted
        AbsoluteLuxThresholdRestored = $entry.AbsoluteLuxThresholdRestored
        AbsoluteLuxConfigureError = $entry.AbsoluteLuxConfigureError
        AbsoluteLuxRestoreError = $entry.AbsoluteLuxRestoreError
        ReadingCount = $sensorReadings.Count
        ValidReadingCount = $validReadings.Count
        InvalidReadingCount = $sensorReadings.Count - $validReadings.Count
    })
}

$validReadingCount = @($readings | Where-Object { $_.IsValid }).Count
$comparablePairCount = @($pairComparisons | Where-Object { $_.IsComparable }).Count
$restorationFailed = @($sensorEntries | Where-Object {
    $_.ReportIntervalRestored -eq $false -or
    $_.ReportLatencyRestored -eq $false -or
    $_.LuxPercentageThresholdRestored -eq $false -or
    $_.AbsoluteLuxThresholdRestored -eq $false
}).Count -gt 0
$cleanupFailed = @($sensorEntries | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_.UnsubscribeError)
}).Count -gt 0
$hasAcquisitionFailure = @($sensorSummaries | Where-Object {
    $_.Status -in @(
        'OpenError',
        'ConfigurationError',
        'SubscriptionError',
        'NoValidReadings')
}).Count -gt 0
$overallStatus = if ($enumeratedDevices.Count -eq 0) {
    if ($enumerationStatus -eq 'Unavailable') {
        'Unavailable'
    }
    elseif ($enumerationStatus -eq 'Error') {
        'EnumerationError'
    }
    else {
        'NoSensor'
    }
}
elseif ($restorationFailed) {
    'RestoreError'
}
elseif ($cleanupFailed) {
    'CleanupError'
}
elseif (-not [string]::IsNullOrWhiteSpace($fatalError) -or
    $hasAcquisitionFailure -or $validReadingCount -eq 0) {
    'Failed'
}
elseif ($enumeratedDevices.Count -eq 1) {
    'OneSensor'
}
elseif ($null -ne $pairSelection -and $comparablePairCount -eq 0) {
    'NoComparablePair'
}
elseif (@($readings | Where-Object { -not $_.IsValid }).Count -gt 0) {
    'Partial'
}
else {
    'Healthy'
}

$result = [pscustomobject][ordered]@{
    SchemaVersion = 1
    Test = 'DeckLux simultaneous ambient-light sensor comparison'
    StartedUtc = $startedUtc.ToString('o')
    SubscriptionsStartedUtc = if ($null -eq $subscriptionsStartedUtc) {
        $null
    }
    else {
        $subscriptionsStartedUtc.ToString('o')
    }
    CompletedUtc = [DateTime]::UtcNow.ToString('o')
    OverallStatus = $overallStatus
    DurationSeconds = $DurationSeconds
    RequestedSampleIntervalMs = $SampleIntervalMs
    EffectiveCycleIntervalMs = $cycleIntervalMs
    MaximumReadingAgeMs = $effectiveMaxReadingAgeMs
    MaximumPairSkewMs = $effectiveMaxPairSkewMs
    EnumerationStatus = $enumerationStatus
    EnumeratedSensorCount = $enumeratedDevices.Count
    OpenedSensorCount = @($sensorEntries | Where-Object { $null -ne $_.Sensor }).Count
    SubscribedSensorCount = @($sensorEntries | Where-Object { $null -ne $_.Subscription }).Count
    Platform = $platform
    PairSelection = $pairSelection
    Sensors = @($sensorSummaries | ForEach-Object { $_ })
    Cycles = @($cycles | ForEach-Object { $_ })
    Readings = @($readings | ForEach-Object { $_ })
    PairComparisons = @($pairComparisons | ForEach-Object { $_ })
    Errors = @($errors | ForEach-Object { $_ })
}

switch ($OutputFormat) {
    'Json' {
        $result | ConvertTo-Json -Depth 12
    }
    'Csv' {
        New-DeckLuxComparisonCsvRows -Result $result |
            ConvertTo-Csv -NoTypeInformation
    }
    default {
        $result
    }
}
