# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$PackagePath,
    [string]$CertificatePath,
    [string]$StatePath,
    [string[]]$InstanceId,
    [switch]$IncludeSecondary,
    [switch]$AllowCompatibleSensor,
    [string]$InfVerifPath,
    [string]$SignToolPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DeckLux.Common.ps1')
. (Join-Path $PSScriptRoot 'DeckLux.SmbiosCalibration.ps1')

Assert-DeckLux64Bit
Assert-DeckLuxAdministrator

if (-not (Test-DeckLuxTestSigningEnabled)) {
    throw 'Windows is not currently booted with TESTSIGNING enabled. This script never changes boot configuration; follow scripts\README.md and reboot into Test Mode first.'
}

$secureBootValue = Get-ItemPropertyValue `
    -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' `
    -Name 'UEFISecureBootEnabled' `
    -ErrorAction SilentlyContinue
if ($secureBootValue -eq 1) {
    throw 'Secure Boot is enabled. DeckLux does not change firmware security settings; stop and prepare the test machine manually.'
}

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Get-DeckLuxDefaultPackagePath
}
if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Get-DeckLuxDefaultStatePath
}
$StatePath = [IO.Path]::GetFullPath($StatePath)

$package = Test-DeckLuxPackageInternal `
    -PackagePath $PackagePath `
    -CertificatePath $CertificatePath `
    -InfVerifPath $InfVerifPath `
    -SignToolPath $SignToolPath

foreach ($warningText in @($package.Warnings)) {
    Write-Warning $warningText
}

$platform = Get-DeckLuxPlatformSnapshot
$requestedIds = @($InstanceId | Sort-Object -Unique)
$hasExplicitInstance = $requestedIds.Count -gt 0
$installSecondaryByDefault =
    $platform.IsKnownSteamDeck -and $platform.DeckProduct -ieq 'Galileo'
if ($AllowCompatibleSensor -and -not $hasExplicitInstance) {
    throw '-AllowCompatibleSensor requires at least one exact -InstanceId; compatible hardware is never auto-selected.'
}

if (-not $platform.IsKnownSteamDeck -and -not $AllowCompatibleSensor) {
    throw ("DeckLux default installation is limited to Valve Steam Deck Jupiter/Galileo. " +
        "Detected '$($platform.SystemManufacturer) $($platform.SystemProductName)' " +
        "(baseboard '$($platform.BaseBoardManufacturer) $($platform.BaseBoardProduct)'). " +
        'For independently verified LTR-F216A hardware, supply an exact -InstanceId with -AllowCompatibleSensor.')
}

$allInstanceIds = @(Get-DeckLuxMatchingInstanceIds)
if ($allInstanceIds.Count -eq 0) {
    throw 'No present ACPI\PRP0001 devices were found.'
}

$allSnapshots = @($allInstanceIds | ForEach-Object {
    Get-DeckLuxDeviceSnapshot -InstanceId $_
})

$selectedSnapshots = @()
if ($hasExplicitInstance) {
    if ($IncludeSecondary) {
        throw '-IncludeSecondary cannot be combined with explicit -InstanceId values.'
    }

    foreach ($requestedId in $requestedIds) {
        $matchingSnapshot = @($allSnapshots | Where-Object {
            $_.InstanceId -ieq $requestedId
        })
        if ($matchingSnapshot.Count -ne 1) {
            throw "Requested instance '$requestedId' is not a unique, present ACPI\PRP0001 device."
        }
        $selectedSnapshots += $matchingSnapshot[0]
    }
}
else {
    $primary = @($allSnapshots | Where-Object { $_.Role -eq 'Primary' })
    if ($primary.Count -ne 1) {
        throw "Expected exactly one Steam Deck LTRF primary instance; found $($primary.Count). Supply an exact -InstanceId only if the hardware has been independently verified."
    }
    $selectedSnapshots += $primary[0]

    if ($IncludeSecondary -or $installSecondaryByDefault) {
        $secondary = @($allSnapshots | Where-Object { $_.Role -eq 'Secondary' })
        if ($secondary.Count -ne 1) {
            throw "Expected exactly one Steam Deck LTRS secondary instance; found $($secondary.Count)."
        }
        $selectedSnapshots += $secondary[0]
    }
}

if ($selectedSnapshots.Count -eq 0) {
    throw 'No target devices were selected; refusing installation.'
}

foreach ($snapshot in $selectedSnapshots) {
    Assert-DeckLuxTargetSnapshot `
        -Snapshot $snapshot `
        -AllowCompatibleSensor:$AllowCompatibleSensor
}

if ($selectedSnapshots.Count -gt 1 -and
    $selectedSnapshots[0].Role -ne 'Primary') {
    throw 'Multi-device installation order must begin with the LTRF primary sensor.'
}

# Resolve and validate all firmware calibration before the first system
# mutation. Generic compatible devices never inherit Steam Deck constants.
$calibrationPlans = @{}
$deckTargets = @($selectedSnapshots | Where-Object {
    $_.Role -in @('Primary', 'Secondary')
})
$factoryCalibrations = @()
if ($platform.IsKnownSteamDeck -and $deckTargets.Count -gt 0) {
    $factoryCalibrations = @(Get-DeckLuxFactoryCalibration)
    $expectedCalibrationCount = if ($platform.DeckProduct -ieq 'Galileo') {
        2
    }
    elseif ($platform.DeckProduct -ieq 'Jupiter') {
        1
    }
    else {
        0
    }
    if ($factoryCalibrations.Count -ne $expectedCalibrationCount) {
        throw ("Valve $($platform.DeckProduct) firmware produced " +
            "$($factoryCalibrations.Count) factory ALS calibrations; " +
            "expected $expectedCalibrationCount.")
    }
}
foreach ($snapshot in $selectedSnapshots) {
    $plan = $null
    if ($platform.IsKnownSteamDeck -and
        $snapshot.Role -in @('Primary', 'Secondary')) {
        $instanceSuffix = [int](($snapshot.InstanceId -split '\\')[-1])
        $biosLeaf = ([string]$snapshot.BiosDeviceName -split '\.')[-1]
        $matchingPlans = @($factoryCalibrations | Where-Object {
            $_.Role -eq $snapshot.Role -and
            $_.BiosLeaf -eq $biosLeaf -and
            $_.InstanceSuffix -eq $instanceSuffix
        })
        if ($matchingPlans.Count -ne 1) {
            throw ("Factory calibration did not map uniquely to '$($snapshot.InstanceId)' " +
                "('$($snapshot.BiosDeviceName)', role '$($snapshot.Role)').")
        }
        $plan = $matchingPlans[0]
    }
    $calibrationPlans[$snapshot.InstanceId] = $plan
}

function New-DeckLuxCalibrationState {
    param(
        [Parameter(Mandatory = $true)][string]$TargetInstanceId,
        [Parameter(Mandatory = $true)][psobject]$Plan
    )

    $desiredPpm = [uint32]$Plan.ScalePpm
    if (-not (Test-DeckLuxCalibrationScalePpm -ScalePpm ([long]$desiredPpm))) {
        throw "Firmware calibration for '$TargetInstanceId' is outside the driver ppm contract."
    }
    $desiredDataBase64 = [Convert]::ToBase64String(
        [BitConverter]::GetBytes($desiredPpm))
    $previous = Get-DeckLuxCalibrationPropertySnapshot `
        -InstanceId $TargetInstanceId

    return [pscustomobject][ordered]@{
        Source = 'ValveSmbiosType11'
        FirmwareSource = [string]$Plan.Provenance.Source
        OemStringIndex = [int]$Plan.OemStringIndex
        FactoryGain = [double]$Plan.FactoryGain
        ConversionScale = [double]$Plan.ConversionScale
        Transform = [string]$Plan.Provenance.Formula
        DesiredPpm = $desiredPpm
        DesiredDataBase64 = $desiredDataBase64
        PreviousPresent = [bool]$previous.Present
        PreviousPropertyType = [uint32]$previous.PropertyType
        PreviousDataBase64 = [string]$previous.DataBase64
        PreviousPpm = if ($previous.Valid) {
            [uint32]$previous.ScalePpm
        }
        else {
            $null
        }
        WritePending = $false
        SetByInstaller = $false
        AppliedDataBase64 = $null
        Verified = $false
        ExternalChangePreserved = $false
    }
}

$existingState = $null
$existingStateConflict = $false
if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
    $existingState = Read-DeckLuxState -Path $StatePath
    if (-not $existingState.Uninstalled) {
        $existingStateConflict =
            $existingState.Package.CertificateThumbprint -ine $package.CertificateThumbprint -or
            $existingState.Package.InfSha256 -ine $package.Hashes.'DeckLuxSensor.inf'
    }
    else {
        $existingState = $null
    }
}

if ($WhatIfPreference) {
    [pscustomobject][ordered]@{
        Product = 'DeckLux'
        Mode = 'ReadOnlyInstallPlan'
        CanInstall = -not $existingStateConflict
        RequiredAction = if ($existingStateConflict) {
            "Uninstall the active DeckLux journal at '$StatePath' before installing this build."
        }
        else {
            $null
        }
        PackagePath = $package.PackagePath
        DriverVersion = $package.DriverVersion
        StatePath = $StatePath
        CertificateThumbprint = $package.CertificateThumbprint
        Targets = @($selectedSnapshots | ForEach-Object {
            [pscustomobject][ordered]@{
                InstanceId = $_.InstanceId
                BiosDeviceName = $_.BiosDeviceName
                Role = $_.Role
                FactoryCalibrationPpm = if ($null -ne $calibrationPlans[$_.InstanceId]) {
                    [uint32]$calibrationPlans[$_.InstanceId].ScalePpm
                }
                else {
                    $null
                }
            }
        })
    }
    return
}

if ($existingStateConflict) {
    throw "An active rollback state exists for a different DeckLux build: $StatePath. Uninstall it before installing another build."
}

$rootCertificatePreExisting = Test-DeckLuxCertificateInStore `
    -Store 'Root' `
    -Thumbprint $package.CertificateThumbprint
$publisherCertificatePreExisting = Test-DeckLuxCertificateInStore `
    -Store 'TrustedPublisher' `
    -Thumbprint $package.CertificateThumbprint

if ($null -eq $existingState) {
    $state = [pscustomobject][ordered]@{
        SchemaVersion = 3
        Project = 'DeckLux'
        InstallId = [Guid]::NewGuid().ToString('D')
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Completed = $false
        Uninstalled = $false
        UninstalledUtc = $null
        NeedReboot = $false
        LastError = $null
        Package = [pscustomobject][ordered]@{
            PackagePath = $package.PackagePath
            InfPath = $package.InfPath
            CatalogPath = $package.CatalogPath
            DllPath = $package.DllPath
            CertificatePath = $package.CertificatePath
            CertificateThumbprint = $package.CertificateThumbprint
            DriverVersion = $package.DriverVersion
            InfSha256 = $package.Hashes.'DeckLuxSensor.inf'
            CatalogSha256 = $package.Hashes.'deckluxsensor.cat'
            DllSha256 = $package.Hashes.'DeckLuxSensor.dll'
            PublishedInf = $null
            StageOutput = @()
            PreExisting = $false
            StagePending = $false
            StagedByInstaller = $false
            Removed = $false
            PreStageDriverNames = @()
        }
        Certificate = [pscustomobject][ordered]@{
            RootPreExisting = $rootCertificatePreExisting
            TrustedPublisherPreExisting = $publisherCertificatePreExisting
            RootAdded = $false
            TrustedPublisherAdded = $false
            RootWritePending = $false
            TrustedPublisherWritePending = $false
        }
        Boot = [pscustomobject][ordered]@{
            TestSigningEnabled = $true
            SecureBootEnabled = ($secureBootValue -eq 1)
            ChangedByInstaller = $false
        }
        Platform = $platform
        Targets = @()
        RollbackLog = @()
    }
}
else {
    $state = $existingState
    $state.SchemaVersion = 3
    $state.Completed = $false
    $state.LastError = $null
    $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
}

foreach ($snapshot in $selectedSnapshots) {
    $existingTarget = @($state.Targets | Where-Object {
        $_.InstanceId -ieq $snapshot.InstanceId
    })
    if ($existingTarget.Count -gt 1) {
        throw "Rollback state contains duplicate target '$($snapshot.InstanceId)'."
    }

    if ($existingTarget.Count -eq 0) {
        $optInState = [DeckLux.NativeMethods]::GetBooleanProperty(
            $snapshot.InstanceId,
            $script:DeckLuxOptInPropertyGuid,
            $script:DeckLuxOptInPropertyPid)
        $calibrationPlan = $calibrationPlans[$snapshot.InstanceId]
        $calibrationRecord = $null
        if ($null -ne $calibrationPlan) {
            $calibrationRecord = New-DeckLuxCalibrationState `
                -TargetInstanceId $snapshot.InstanceId `
                -Plan $calibrationPlan
        }
        $record = [pscustomobject][ordered]@{
            InstanceId = $snapshot.InstanceId
            BiosDeviceName = $snapshot.BiosDeviceName
            Role = $snapshot.Role
            Before = $snapshot
            OptInPreExisting = ($optInState -eq 1)
            OptInSetByInstaller = $false
            OptInWritePending = $false
            Calibration = $calibrationRecord
            BindingPreExisting = -not [string]::IsNullOrWhiteSpace(
                [string]$snapshot.DriverInfPath)
            BoundByInstaller = $false
            BindingRequested = $false
            BindingWritePending = $false
            BindingTransitionRecorded = $false
            BindingWasAlreadyActive = $false
            BindingOwnedBeforeWrite = $false
            Installed = $false
            NeedReboot = $false
            After = $null
            LastError = $null
        }
        $state.Targets = @($state.Targets) + @($record)
    }
    else {
        $target = $existingTarget[0]
        $calibrationPlan = $calibrationPlans[$snapshot.InstanceId]
        $calibrationProperty = $target.PSObject.Properties['Calibration']
        if ($null -eq $calibrationProperty) {
            $calibrationRecord = $null
            if ($null -ne $calibrationPlan) {
                $calibrationRecord = New-DeckLuxCalibrationState `
                    -TargetInstanceId $snapshot.InstanceId `
                    -Plan $calibrationPlan
            }
            $target | Add-Member -NotePropertyName Calibration -NotePropertyValue $calibrationRecord
        }
        elseif ($null -ne $calibrationPlan -and
            $null -ne $calibrationProperty.Value) {
            $desiredPpm = [uint32]$calibrationPlan.ScalePpm
            $desiredDataBase64 = [Convert]::ToBase64String(
                [BitConverter]::GetBytes($desiredPpm))
            if ($null -eq $target.Calibration.PSObject.Properties['DesiredDataBase64']) {
                throw "Rollback state contains an obsolete calibration format for '$($snapshot.InstanceId)'."
            }
            if ([string]$target.Calibration.DesiredDataBase64 -cne $desiredDataBase64 -and
                ($target.Calibration.SetByInstaller -or $target.Calibration.WritePending)) {
                throw ("Factory calibration for '$($snapshot.InstanceId)' changed while the " +
                    'installer owns the previous value; uninstall before applying new firmware data.')
            }
            $target.Calibration.Source = 'ValveSmbiosType11'
            $target.Calibration.FirmwareSource = [string]$calibrationPlan.Provenance.Source
            $target.Calibration.OemStringIndex = [int]$calibrationPlan.OemStringIndex
            $target.Calibration.FactoryGain = [double]$calibrationPlan.FactoryGain
            $target.Calibration.ConversionScale = [double]$calibrationPlan.ConversionScale
            $target.Calibration.Transform = [string]$calibrationPlan.Provenance.Formula
            $target.Calibration.DesiredPpm = $desiredPpm
            $target.Calibration.DesiredDataBase64 = $desiredDataBase64
        }
        elseif ($null -ne $calibrationPlan) {
            throw "Rollback state lacks calibration ownership data for '$($snapshot.InstanceId)'."
        }
    }
}

foreach ($packageField in ([ordered]@{
    PreExisting = $false
    StagePending = $false
    StagedByInstaller = $false
    Removed = $false
    PreStageDriverNames = @()
}).GetEnumerator()) {
    if ($null -eq $state.Package.PSObject.Properties[$packageField.Key]) {
        $state.Package | Add-Member -NotePropertyName $packageField.Key -NotePropertyValue $packageField.Value
    }
}
foreach ($certificateField in ([ordered]@{
    RootWritePending = $false
    TrustedPublisherWritePending = $false
}).GetEnumerator()) {
    if ($null -eq $state.Certificate.PSObject.Properties[$certificateField.Key]) {
        $state.Certificate | Add-Member -NotePropertyName $certificateField.Key -NotePropertyValue $certificateField.Value
    }
}
foreach ($target in @($state.Targets)) {
    if ($null -eq $target.PSObject.Properties['OptInWritePending']) {
        $target | Add-Member -NotePropertyName OptInWritePending -NotePropertyValue $false
    }
    if ($null -eq $target.PSObject.Properties['BindingWritePending']) {
        $target | Add-Member -NotePropertyName BindingWritePending -NotePropertyValue $false
    }
    foreach ($bindingField in ([ordered]@{
        BindingTransitionRecorded = $false
        BindingWasAlreadyActive = $false
        BindingOwnedBeforeWrite = $false
    }).GetEnumerator()) {
        if ($null -eq $target.PSObject.Properties[$bindingField.Key]) {
            $target | Add-Member `
                -NotePropertyName $bindingField.Key `
                -NotePropertyValue $bindingField.Value
        }
    }
    $beforeDriverInf = $null
    $beforeProperty = $target.PSObject.Properties['Before']
    if ($null -ne $beforeProperty -and $null -ne $beforeProperty.Value) {
        $beforeInfProperty = $beforeProperty.Value.PSObject.Properties['DriverInfPath']
        if ($null -ne $beforeInfProperty) {
            $beforeDriverInf = [string]$beforeInfProperty.Value
        }
    }
    if ($null -eq $target.PSObject.Properties['BindingPreExisting']) {
        $target | Add-Member `
            -NotePropertyName BindingPreExisting `
            -NotePropertyValue (-not [string]::IsNullOrWhiteSpace($beforeDriverInf))
    }
    if ($null -eq $target.PSObject.Properties['BoundByInstaller']) {
        $ownedBinding = -not [bool]$target.BindingPreExisting -and
            ([bool]$target.BindingRequested -or [bool]$target.Installed)
        $target | Add-Member -NotePropertyName BoundByInstaller -NotePropertyValue $ownedBinding
    }
}

Write-DeckLuxState -State $state -Path $StatePath

$changedThisRun = New-Object System.Collections.Generic.List[string]
$authorizedThisRun = New-Object System.Collections.Generic.List[string]
$calibratedThisRun = New-Object System.Collections.Generic.List[string]
$certificateRootAddedThisRun = $false
$certificatePublisherAddedThisRun = $false
$packageStagedThisRun = $false
$hadInstalledTargetBeforeRun = @($state.Targets | Where-Object { $_.Installed }).Count -gt 0

try {
    if ($state.Certificate.RootWritePending) {
        $state.Certificate.RootAdded = Test-DeckLuxCertificateInStore `
            -Store 'Root' `
            -Thumbprint $package.CertificateThumbprint
        $state.Certificate.RootWritePending = $false
        $certificateRootAddedThisRun = [bool]$state.Certificate.RootAdded -and
            -not [bool]$state.Certificate.RootPreExisting
        Write-DeckLuxState -State $state -Path $StatePath
    }
    if ($state.Certificate.TrustedPublisherWritePending) {
        $state.Certificate.TrustedPublisherAdded = Test-DeckLuxCertificateInStore `
            -Store 'TrustedPublisher' `
            -Thumbprint $package.CertificateThumbprint
        $state.Certificate.TrustedPublisherWritePending = $false
        $certificatePublisherAddedThisRun =
            [bool]$state.Certificate.TrustedPublisherAdded -and
            -not [bool]$state.Certificate.TrustedPublisherPreExisting
        Write-DeckLuxState -State $state -Path $StatePath
    }

    if (-not (Test-DeckLuxCertificateInStore -Store 'Root' -Thumbprint $package.CertificateThumbprint)) {
        if (-not $PSCmdlet.ShouldProcess(
            "LocalMachine Root certificate store",
            "Trust DeckLux test certificate $($package.CertificateThumbprint)")) {
            throw 'Certificate trust was declined.'
        }
        $state.Certificate.RootWritePending = $true
        Write-DeckLuxState -State $state -Path $StatePath
        Import-Certificate `
            -FilePath $package.CertificatePath `
            -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
        $state.Certificate.RootAdded = $true
        $state.Certificate.RootWritePending = $false
        $certificateRootAddedThisRun = $true
        Write-DeckLuxState -State $state -Path $StatePath
    }

    if (-not (Test-DeckLuxCertificateInStore -Store 'TrustedPublisher' -Thumbprint $package.CertificateThumbprint)) {
        if (-not $PSCmdlet.ShouldProcess(
            'LocalMachine TrustedPublisher certificate store',
            "Trust DeckLux test publisher $($package.CertificateThumbprint)")) {
            throw 'Publisher trust was declined.'
        }
        $state.Certificate.TrustedPublisherWritePending = $true
        Write-DeckLuxState -State $state -Path $StatePath
        Import-Certificate `
            -FilePath $package.CertificatePath `
            -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null
        $state.Certificate.TrustedPublisherAdded = $true
        $state.Certificate.TrustedPublisherWritePending = $false
        $certificatePublisherAddedThisRun = $true
        Write-DeckLuxState -State $state -Path $StatePath
    }

    $trustedPackage = Test-DeckLuxPackageInternal `
        -PackagePath $package.PackagePath `
        -CertificatePath $package.CertificatePath `
        -InfVerifPath $package.InfVerifPath `
        -SignToolPath $package.SignToolPath `
        -RequireTrustedSignature

    $published = $null
    if ($state.Package.StagePending) {
        $pendingPackages = @(Get-DeckLuxPublishedDrivers | Where-Object {
            $_.OriginalName -ieq $script:DeckLuxExpectedInfName -and
            $_.ProviderName -ieq $script:DeckLuxExpectedProvider -and
            ([string]$_.DriverVersion).Trim().EndsWith($trustedPackage.DriverVersion)
        })
        if ($pendingPackages.Count -gt 1) {
            throw 'More than one DeckLux package matches an interrupted staging operation.'
        }
        if ($pendingPackages.Count -eq 1) {
            $published = $pendingPackages[0]
            $state.Package.PublishedInf = [string]$published.DriverName
            $state.Package.PreExisting = @($state.Package.PreStageDriverNames) -contains [string]$published.DriverName
            $state.Package.StagedByInstaller = -not $state.Package.PreExisting
            $packageStagedThisRun = [bool]$state.Package.StagedByInstaller
        }
        $state.Package.StagePending = $false
        Write-DeckLuxState -State $state -Path $StatePath
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$state.Package.PublishedInf)) {
        $published = @(Get-DeckLuxPublishedDrivers | Where-Object {
            $_.DriverName -ieq $state.Package.PublishedInf -and
            $_.OriginalName -ieq $script:DeckLuxExpectedInfName -and
            $_.ProviderName -ieq $script:DeckLuxExpectedProvider
        }) | Select-Object -First 1
    }

    if ($null -eq $published) {
        $beforeDriverNames = @(Get-DeckLuxPublishedDrivers |
            ForEach-Object { [string]$_.DriverName })
        if (-not $PSCmdlet.ShouldProcess(
            $trustedPackage.InfPath,
            'Stage the DeckLux package in Driver Store')) {
            throw 'Driver package staging was declined.'
        }
        $state.Package.PreStageDriverNames = @($beforeDriverNames)
        $state.Package.StagePending = $true
        Write-DeckLuxState -State $state -Path $StatePath
        $stageResult = Invoke-DeckLuxPnpUtil -Arguments @(
            '/add-driver',
            $trustedPackage.InfPath)
        $afterDriverNames = @(Get-DeckLuxPublishedDrivers |
            ForEach-Object { [string]$_.DriverName })
        $newNames = @($afterDriverNames | Where-Object {
            $beforeDriverNames -notcontains $_
        })
        $published = Get-DeckLuxPublishedDriver `
            -DriverVersion $trustedPackage.DriverVersion `
            -PreferNewDriverNames $newNames
        if ($null -eq $published) {
            throw 'PnPUtil returned success, but the staged DeckLux package could not be identified safely.'
        }
        $state.Package.PublishedInf = [string]$published.DriverName
        $state.Package.StageOutput = @($stageResult.Output)
        $packageStagedThisRun = $beforeDriverNames -notcontains [string]$published.DriverName
        $state.Package.PreExisting = -not $packageStagedThisRun
        $state.Package.StagedByInstaller = $packageStagedThisRun
        $state.Package.StagePending = $false
        $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Write-DeckLuxState -State $state -Path $StatePath
    }

    $stopForReboot = $false
    foreach ($selected in $selectedSnapshots) {
        $target = @($state.Targets | Where-Object {
            $_.InstanceId -ieq $selected.InstanceId
        })[0]

        $current = Get-DeckLuxDeviceSnapshot -InstanceId $selected.InstanceId
        Assert-DeckLuxTargetSnapshot `
            -Snapshot $current `
            -AllowCompatibleSensor:$AllowCompatibleSensor

        if ($target.BindingWritePending) {
            $beforeDriverInf = [string]$target.Before.DriverInfPath
            $currentDriverInf = [string]$current.DriverInfPath
            if ($target.BindingTransitionRecorded) {
                if ($currentDriverInf -ieq [string]$state.Package.PublishedInf) {
                    $bindingTransition = Resolve-DeckLuxBindingTransition `
                        -WasAlreadyBoundToPackage ([bool]$target.BindingWasAlreadyActive) `
                        -WasOwnedByInstaller ([bool]$target.BindingOwnedBeforeWrite)
                    $target.BoundByInstaller = [bool]$bindingTransition.BoundByInstaller
                    if ($bindingTransition.ChangedThisRun) {
                        $target.BindingRequested = $true
                        if (-not $changedThisRun.Contains([string]$selected.InstanceId)) {
                            $changedThisRun.Add([string]$selected.InstanceId)
                        }
                    }
                    $target.Installed = $true
                }
                elseif ($currentDriverInf -ieq $beforeDriverInf) {
                    $target.BoundByInstaller = [bool]$target.BindingOwnedBeforeWrite
                }
                else {
                    throw "Device '$($selected.InstanceId)' changed to '$currentDriverInf' while DeckLux binding was pending; refusing to overwrite it."
                }
            }
            elseif ($currentDriverInf -ieq [string]$state.Package.PublishedInf) {
                if ([string]::IsNullOrWhiteSpace($beforeDriverInf)) {
                    $target.BindingPreExisting = $false
                    $target.BoundByInstaller = $true
                    $target.BindingRequested = $true
                    $target.Installed = $true
                    if (-not $changedThisRun.Contains([string]$selected.InstanceId)) {
                        $changedThisRun.Add([string]$selected.InstanceId)
                    }
                }
                elseif ($beforeDriverInf -ieq [string]$state.Package.PublishedInf) {
                    $target.BindingPreExisting = $true
                    $target.BoundByInstaller = $false
                    $target.BindingRequested = $false
                    $target.Installed = $true
                }
                else {
                    throw "Device '$($selected.InstanceId)' changed to the DeckLux package while a different prior binding was journaled."
                }
            }
            elseif ($currentDriverInf -ieq $beforeDriverInf) {
                $target.BoundByInstaller = $false
                $target.BindingRequested = $false
                $target.Installed = $false
            }
            else {
                throw "Device '$($selected.InstanceId)' changed to '$currentDriverInf' while DeckLux binding was pending; refusing to overwrite it."
            }
            $target.BindingWritePending = $false
            $target.BindingTransitionRecorded = $false
            $target.BindingWasAlreadyActive = $false
            $target.BindingOwnedBeforeWrite = $false
            Write-DeckLuxState -State $state -Path $StatePath
        }

        if (-not [string]::IsNullOrWhiteSpace($current.DriverInfPath) -and
            $current.DriverInfPath -ine $state.Package.PublishedInf) {
            throw "Device '$($selected.InstanceId)' already uses '$($current.DriverInfPath)'; refusing to replace it."
        }

        $calibrationChangedForTarget = $false
        if ($null -ne $target.Calibration) {
            $calibration = $target.Calibration
            $desiredPpm = [uint32]$calibration.DesiredPpm
            $desiredDataBase64 = [string]$calibration.DesiredDataBase64
            $currentCalibration = Get-DeckLuxCalibrationPropertySnapshot `
                -InstanceId $selected.InstanceId
            $currentMatchesDesired = Test-DeckLuxCalibrationPropertyMatches `
                -Snapshot $currentCalibration `
                -ScalePpm $desiredPpm
            $currentMatchesPrevious = if ($calibration.PreviousPresent) {
                $currentCalibration.Present -and
                    [uint32]$currentCalibration.PropertyType -eq
                        [uint32]$calibration.PreviousPropertyType -and
                    [string]$currentCalibration.DataBase64 -ceq
                        [string]$calibration.PreviousDataBase64
            }
            else {
                -not $currentCalibration.Present
            }

            if ($calibration.WritePending) {
                if ($currentMatchesDesired) {
                    # A prior run reached the devnode write but not the journal
                    # confirmation. Adopt only the exact intended value.
                    $calibration.SetByInstaller = $true
                    $calibration.AppliedDataBase64 = $desiredDataBase64
                    $calibration.WritePending = $false
                    $calibration.Verified = $true
                    $calibrationChangedForTarget = $true
                    if (-not $calibratedThisRun.Contains([string]$selected.InstanceId)) {
                        $calibratedThisRun.Add([string]$selected.InstanceId)
                    }
                    Write-DeckLuxState -State $state -Path $StatePath
                }
                else {
                    if (-not $currentMatchesPrevious) {
                        throw ("Calibration property on '$($selected.InstanceId)' changed " +
                            'while an installer write was pending; refusing to overwrite it.')
                    }
                    $calibration.WritePending = $false
                    Write-DeckLuxState -State $state -Path $StatePath
                }
            }

            if ($calibration.SetByInstaller -and
                $null -ne $calibration.AppliedDataBase64 -and
                (-not $currentCalibration.Present -or
                 [uint32]$currentCalibration.PropertyType -ne 0x00000007 -or
                 [string]$currentCalibration.DataBase64 -cne
                    [string]$calibration.AppliedDataBase64)) {
                throw ("Calibration property on '$($selected.InstanceId)' no longer " +
                    'matches the installer journal; refusing to overwrite a later change.')
            }

            if (-not $currentMatchesDesired) {
                if (-not $PSCmdlet.ShouldProcess(
                    $selected.InstanceId,
                    "Apply factory calibration $desiredPpm ppm")) {
                    throw 'Factory-calibration property write was declined.'
                }

                $calibration.WritePending = $true
                Write-DeckLuxState -State $state -Path $StatePath
                $calibratedThisRun.Add($selected.InstanceId)

                Set-DeckLuxCalibrationScaleProperty `
                    -InstanceId $selected.InstanceId `
                    -ScalePpm $desiredPpm

                $readback = Get-DeckLuxCalibrationPropertySnapshot `
                    -InstanceId $selected.InstanceId
                if (-not (Test-DeckLuxCalibrationPropertyMatches `
                    -Snapshot $readback `
                    -ScalePpm $desiredPpm)) {
                    throw ("Calibration property readback mismatch on '$($selected.InstanceId)': " +
                        "expected $desiredPpm ppm.")
                }

                $calibration.SetByInstaller = $true
                $calibration.AppliedDataBase64 = $desiredDataBase64
                $calibration.WritePending = $false
                $calibration.Verified = $true
                $calibrationChangedForTarget = $true
                Write-DeckLuxState -State $state -Path $StatePath
            }
            elseif (-not $calibration.Verified) {
                $calibration.Verified = $true
                Write-DeckLuxState -State $state -Path $StatePath
            }
        }

        if ($target.OptInWritePending) {
            $pendingOptIn = [DeckLux.NativeMethods]::GetBooleanProperty(
                $selected.InstanceId,
                $script:DeckLuxOptInPropertyGuid,
                $script:DeckLuxOptInPropertyPid)
            $target.OptInSetByInstaller = ($pendingOptIn -eq 1)
            if ($target.OptInSetByInstaller -and
                -not $target.OptInPreExisting -and
                -not $authorizedThisRun.Contains([string]$selected.InstanceId)) {
                $authorizedThisRun.Add([string]$selected.InstanceId)
            }
            $target.OptInWritePending = $false
            Write-DeckLuxState -State $state -Path $StatePath
        }

        if (-not $target.OptInPreExisting -and -not $target.OptInSetByInstaller) {
            if (-not $PSCmdlet.ShouldProcess(
                $selected.InstanceId,
                'Authorize this exact device instance for DeckLux')) {
                throw 'Exact-device authorization was declined.'
            }
            $target.OptInWritePending = $true
            Write-DeckLuxState -State $state -Path $StatePath
            [DeckLux.NativeMethods]::SetOptInProperty(
                $selected.InstanceId,
                $script:DeckLuxOptInPropertyGuid,
                $script:DeckLuxOptInPropertyPid,
                $true)
            $target.OptInSetByInstaller = $true
            $target.OptInWritePending = $false
            $authorizedThisRun.Add($selected.InstanceId)
            Write-DeckLuxState -State $state -Path $StatePath
        }

        if ($target.Installed -and
            $current.DriverInfPath -ieq $state.Package.PublishedInf -and
            -not $calibrationChangedForTarget -and
            ($null -eq $current.ProblemCode -or $current.ProblemCode -eq 0)) {
            Write-Verbose "DeckLux is already active on $($selected.InstanceId); leaving it unchanged."
            continue
        }

        if (-not $PSCmdlet.ShouldProcess(
            "$($selected.InstanceId) ($($selected.BiosDeviceName))",
            "Bind exact instance to $($state.Package.PublishedInf)")) {
            throw 'Exact device binding was declined.'
        }

        $bindingWasAlreadyActive = $current.DriverInfPath -ieq
            $state.Package.PublishedInf
        $target.BindingTransitionRecorded = $true
        $target.BindingWasAlreadyActive = $bindingWasAlreadyActive
        $target.BindingOwnedBeforeWrite = [bool]$target.BoundByInstaller
        $target.BindingWritePending = $true
        Write-DeckLuxState -State $state -Path $StatePath
        $bindingTransition = Resolve-DeckLuxBindingTransition `
            -WasAlreadyBoundToPackage $bindingWasAlreadyActive `
            -WasOwnedByInstaller ([bool]$target.BindingOwnedBeforeWrite)
        $needReboot = [DeckLux.NativeMethods]::InstallDevice(
            $selected.InstanceId,
            $false)
        $target.BindingRequested = $true
        $target.BoundByInstaller = [bool]$bindingTransition.BoundByInstaller
        $target.BindingWritePending = $false
        $target.BindingTransitionRecorded = $false
        $target.BindingWasAlreadyActive = $false
        $target.BindingOwnedBeforeWrite = $false
        $target.NeedReboot = $needReboot
        $state.NeedReboot = [bool]($state.NeedReboot -or $needReboot)
        if ($bindingTransition.ChangedThisRun) {
            $changedThisRun.Add($selected.InstanceId)
        }
        Write-DeckLuxState -State $state -Path $StatePath

        if ($needReboot) {
            $target.LastError = 'Windows reported that a reboot is required; the script did not reboot.'
            $stopForReboot = $true
            Write-DeckLuxState -State $state -Path $StatePath
            Write-Warning "Windows requested a reboot for '$($selected.InstanceId)'. No reboot was performed, and no later target was installed."
            break
        }

        $after = $null
        for ($attempt = 0; $attempt -lt 12; ++$attempt) {
            Start-Sleep -Milliseconds 250
            $after = Get-DeckLuxDeviceSnapshot -InstanceId $selected.InstanceId
            if ($after.DriverInfPath -ieq $state.Package.PublishedInf) {
                break
            }
        }
        $target.After = $after

        if ($null -eq $after -or
            $after.DriverInfPath -ine $state.Package.PublishedInf -or
            ($null -ne $after.ProblemCode -and $after.ProblemCode -ne 0)) {
            $problemText = if ($null -eq $after) {
                'device could not be queried'
            }
            else {
                "driver '$($after.DriverInfPath)', problem code '$($after.ProblemCode)'"
            }
            throw "DeckLux did not start cleanly on '$($selected.InstanceId)': $problemText."
        }

        $target.Installed = $true
        $target.LastError = $null
        $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Write-DeckLuxState -State $state -Path $StatePath
    }

    $state.Completed = -not $stopForReboot
    $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Write-DeckLuxState -State $state -Path $StatePath

    $state
}
catch {
    $originalError = $_
    $state.LastError = $originalError.Exception.Message
    $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')

    foreach ($changedId in @($changedThisRun)) {
        $target = @($state.Targets | Where-Object {
            $_.InstanceId -ieq $changedId
        })[0]
        try {
            $rollbackReboot = [DeckLux.NativeMethods]::InstallDevice($changedId, $true)
            $target.Installed = $false
            $target.BindingRequested = $false
            $target.BoundByInstaller = $false
            $target.BindingWritePending = $false
            $target.NeedReboot = $rollbackReboot
            $state.NeedReboot = [bool]($state.NeedReboot -or $rollbackReboot)
            $state.RollbackLog = @($state.RollbackLog) + @(
                "$(Get-Date -Format o): restored null driver on $changedId")
        }
        catch {
            $state.RollbackLog = @($state.RollbackLog) + @(
                "$(Get-Date -Format o): failed to restore null driver on ${changedId}: $($_.Exception.Message)")
        }

    }

    $calibratedIds = @($calibratedThisRun)
    [array]::Reverse($calibratedIds)
    foreach ($calibratedId in $calibratedIds) {
        $target = @($state.Targets | Where-Object {
            $_.InstanceId -ieq $calibratedId
        })[0]
        $calibration = $target.Calibration
        try {
            $currentCalibration = Get-DeckLuxCalibrationPropertySnapshot `
                -InstanceId $calibratedId
            $matchesDesired = Test-DeckLuxCalibrationPropertyMatches `
                -Snapshot $currentCalibration `
                -ScalePpm ([uint32]$calibration.DesiredPpm)
            $matchesPrevious = if ($calibration.PreviousPresent) {
                $currentCalibration.Present -and
                    [uint32]$currentCalibration.PropertyType -eq
                        [uint32]$calibration.PreviousPropertyType -and
                    [string]$currentCalibration.DataBase64 -ceq
                        [string]$calibration.PreviousDataBase64
            }
            else {
                -not $currentCalibration.Present
            }

            if ($matchesDesired) {
                Restore-DeckLuxCalibrationProperty `
                    -InstanceId $calibratedId `
                    -CalibrationState $calibration
                $state.RollbackLog = @($state.RollbackLog) + @(
                    "$(Get-Date -Format o): restored calibration property on $calibratedId")
            }
            elseif (-not $matchesPrevious) {
                $calibration.ExternalChangePreserved = $true
                $state.RollbackLog = @($state.RollbackLog) + @(
                    "$(Get-Date -Format o): preserved later calibration-property change on $calibratedId")
            }

            $calibration.SetByInstaller = $false
            $calibration.WritePending = $false
            $calibration.AppliedDataBase64 = $null
            $calibration.Verified = $false
        }
        catch {
            $state.RollbackLog = @($state.RollbackLog) + @(
                "$(Get-Date -Format o): failed to restore calibration on ${calibratedId}: $($_.Exception.Message)")
        }
    }

    foreach ($authorizedId in @($authorizedThisRun)) {
        $target = @($state.Targets | Where-Object {
            $_.InstanceId -ieq $authorizedId
        })[0]
        if ($target.OptInSetByInstaller -and -not $target.OptInPreExisting) {
            try {
                [DeckLux.NativeMethods]::SetOptInProperty(
                    $authorizedId,
                    $script:DeckLuxOptInPropertyGuid,
                    $script:DeckLuxOptInPropertyPid,
                    $false)
                $target.OptInSetByInstaller = $false
                $state.RollbackLog = @($state.RollbackLog) + @(
                    "$(Get-Date -Format o): removed exact-device authorization from $authorizedId")
            }
            catch {
                $state.RollbackLog = @($state.RollbackLog) + @(
                    "$(Get-Date -Format o): failed to remove authorization from ${authorizedId}: $($_.Exception.Message)")
            }
        }
    }

    $rollbackDevicesSafe = $true
    foreach ($changedId in @($changedThisRun)) {
        try {
            $afterRollback = Get-DeckLuxDeviceSnapshot -InstanceId $changedId
            if ($afterRollback.DriverInfPath -ieq $state.Package.PublishedInf) {
                $rollbackDevicesSafe = $false
            }
        }
        catch {
            $rollbackDevicesSafe = $false
        }
    }
    $rollbackPackageAbsent =
        [string]::IsNullOrWhiteSpace([string]$state.Package.PublishedInf) -and
        -not [bool]$state.Package.StagePending
    if (-not [string]::IsNullOrWhiteSpace([string]$state.Package.PublishedInf)) {
        $rollbackPackageAbsent = @(Get-DeckLuxPublishedDrivers | Where-Object {
            $_.DriverName -ieq $state.Package.PublishedInf
        }).Count -eq 0
    }
    if ($packageStagedThisRun -and $rollbackDevicesSafe -and -not $hadInstalledTargetBeforeRun -and
        -not [string]::IsNullOrWhiteSpace([string]$state.Package.PublishedInf)) {
        $deleteResult = Invoke-DeckLuxPnpUtil `
            -Arguments @('/delete-driver', [string]$state.Package.PublishedInf) `
            -AllowFailure
        $state.RollbackLog = @($state.RollbackLog) + @(
            "$(Get-Date -Format o): package rollback exit $($deleteResult.ExitCode): $($deleteResult.Output -join ' | ')")
        $rollbackPackageAbsent = @(Get-DeckLuxPublishedDrivers | Where-Object {
            $_.DriverName -ieq $state.Package.PublishedInf
        }).Count -eq 0
    }

    if ($certificatePublisherAddedThisRun -and
        -not $state.Certificate.TrustedPublisherPreExisting -and
        -not $hadInstalledTargetBeforeRun -and
        $rollbackDevicesSafe -and
        $rollbackPackageAbsent) {
        try {
            Remove-DeckLuxCertificateFromStore `
                -Store 'TrustedPublisher' `
                -Thumbprint $package.CertificateThumbprint
            $state.Certificate.TrustedPublisherAdded = $false
        }
        catch {
            $state.RollbackLog = @($state.RollbackLog) + @(
                "$(Get-Date -Format o): failed to remove TrustedPublisher certificate: $($_.Exception.Message)")
        }
    }

    if ($certificateRootAddedThisRun -and
        -not $state.Certificate.RootPreExisting -and
        -not $hadInstalledTargetBeforeRun -and
        $rollbackDevicesSafe -and
        $rollbackPackageAbsent) {
        try {
            Remove-DeckLuxCertificateFromStore `
                -Store 'Root' `
                -Thumbprint $package.CertificateThumbprint
            $state.Certificate.RootAdded = $false
        }
        catch {
            $state.RollbackLog = @($state.RollbackLog) + @(
                "$(Get-Date -Format o): failed to remove Root certificate: $($_.Exception.Message)")
        }
    }

    Write-DeckLuxState -State $state -Path $StatePath
    throw $originalError
}
