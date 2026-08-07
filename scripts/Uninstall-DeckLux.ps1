# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$StatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DeckLux.Common.ps1')

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Get-DeckLuxDefaultStatePath
}
$StatePath = [IO.Path]::GetFullPath($StatePath)
$state = Read-DeckLuxState -Path $StatePath

if ($WhatIfPreference) {
    [pscustomobject][ordered]@{
        Product = 'DeckLux'
        Mode = 'ReadOnlyUninstallPlan'
        StatePath = $StatePath
        DriverVersion = [string]$state.Package.DriverVersion
        PublishedInf = [string]$state.Package.PublishedInf
        AlreadyUninstalled = [bool]$state.Uninstalled
        Targets = @($state.Targets | ForEach-Object {
            [pscustomobject][ordered]@{
                InstanceId = [string]$_.InstanceId
                BiosDeviceName = [string]$_.BiosDeviceName
                Role = [string]$_.Role
            }
        })
    }
    return
}

Assert-DeckLux64Bit
Assert-DeckLuxAdministrator
Import-DeckLuxNativeMethods

foreach ($packageField in ([ordered]@{
    PreExisting = $false
    StagePending = $false
    StagedByInstaller = $true
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

$hasPendingWork = [bool]$state.Package.StagePending -or
    [bool]$state.Certificate.RootWritePending -or
    [bool]$state.Certificate.TrustedPublisherWritePending -or
    @($state.Targets | Where-Object {
        [bool]$_.OptInWritePending -or [bool]$_.BindingWritePending -or
        ($null -ne $_.PSObject.Properties['Calibration'] -and
         $null -ne $_.PSObject.Properties['Calibration'].Value -and
         [bool]$_.PSObject.Properties['Calibration'].Value.WritePending)
    }).Count -gt 0

if ($state.Uninstalled -and -not $hasPendingWork) {
    Write-Verbose "DeckLux state '$StatePath' is already marked uninstalled."
    $state
    return
}

if ($state.Package.StagePending) {
    $pendingPackages = @(Get-DeckLuxPublishedDrivers | Where-Object {
        $_.OriginalName -ieq $script:DeckLuxExpectedInfName -and
        $_.ProviderName -ieq $script:DeckLuxExpectedProvider -and
        ([string]$_.DriverVersion).Trim().EndsWith(
            [string]$state.Package.DriverVersion)
    })
    if ($pendingPackages.Count -gt 1) {
        throw 'More than one DeckLux package matches the interrupted staging operation; refusing ambiguous cleanup.'
    }
    if ($pendingPackages.Count -eq 1) {
        $pendingPackage = $pendingPackages[0]
        $state.Package.PublishedInf = [string]$pendingPackage.DriverName
        $state.Package.PreExisting = @($state.Package.PreStageDriverNames) -contains
            [string]$pendingPackage.DriverName
        $state.Package.StagedByInstaller = -not [bool]$state.Package.PreExisting
    }
    else {
        $state.Package.PublishedInf = $null
        $state.Package.PreExisting = $false
        $state.Package.StagedByInstaller = $false
    }
    $state.Package.StagePending = $false
    $state.RollbackLog = @($state.RollbackLog) + @(
        "$(Get-Date -Format o): reconciled interrupted package staging")
    Write-DeckLuxState -State $state -Path $StatePath
}

$certificateThumbprint = [string]$state.Package.CertificateThumbprint
if ($state.Certificate.RootWritePending) {
    $state.Certificate.RootAdded =
        -not [bool]$state.Certificate.RootPreExisting -and
        (Test-DeckLuxCertificateInStore -Store 'Root' -Thumbprint $certificateThumbprint)
    $state.Certificate.RootWritePending = $false
    $state.RollbackLog = @($state.RollbackLog) + @(
        "$(Get-Date -Format o): reconciled interrupted Root certificate write")
    Write-DeckLuxState -State $state -Path $StatePath
}
if ($state.Certificate.TrustedPublisherWritePending) {
    $state.Certificate.TrustedPublisherAdded =
        -not [bool]$state.Certificate.TrustedPublisherPreExisting -and
        (Test-DeckLuxCertificateInStore -Store 'TrustedPublisher' -Thumbprint $certificateThumbprint)
    $state.Certificate.TrustedPublisherWritePending = $false
    $state.RollbackLog = @($state.RollbackLog) + @(
        "$(Get-Date -Format o): reconciled interrupted TrustedPublisher certificate write")
    Write-DeckLuxState -State $state -Path $StatePath
}

foreach ($target in @($state.Targets)) {
    $instanceId = [string]$target.InstanceId
    if ($target.OptInWritePending) {
        $pendingOptIn = [DeckLux.NativeMethods]::GetBooleanProperty(
            $instanceId,
            $script:DeckLuxOptInPropertyGuid,
            $script:DeckLuxOptInPropertyPid)
        if ($pendingOptIn -notin @(-1, 0, 1)) {
            throw "Device '$instanceId' returned an invalid authorization property while recovery was pending."
        }
        $target.OptInSetByInstaller = $pendingOptIn -eq 1 -and
            -not [bool]$target.OptInPreExisting
        $target.OptInWritePending = $false
        $state.RollbackLog = @($state.RollbackLog) + @(
            "$(Get-Date -Format o): reconciled interrupted authorization write on $instanceId")
        Write-DeckLuxState -State $state -Path $StatePath
    }

    if ($target.BindingWritePending) {
        $snapshot = Get-DeckLuxDeviceSnapshot -InstanceId $instanceId
        $beforeDriverInf = [string]$target.Before.DriverInfPath
        $currentDriverInf = [string]$snapshot.DriverInfPath
        $pendingPublishedInf = [string]$state.Package.PublishedInf
        if ($target.BindingTransitionRecorded) {
            if (-not [string]::IsNullOrWhiteSpace($pendingPublishedInf) -and
                $currentDriverInf -ieq $pendingPublishedInf) {
                $bindingTransition = Resolve-DeckLuxBindingTransition `
                    -WasAlreadyBoundToPackage ([bool]$target.BindingWasAlreadyActive) `
                    -WasOwnedByInstaller ([bool]$target.BindingOwnedBeforeWrite)
                $target.BoundByInstaller = [bool]$bindingTransition.BoundByInstaller
                if ($bindingTransition.ChangedThisRun) {
                    $target.BindingRequested = $true
                }
                $target.Installed = $true
            }
            elseif ($currentDriverInf -ieq $beforeDriverInf) {
                $target.BoundByInstaller = [bool]$target.BindingOwnedBeforeWrite
            }
            else {
                throw "Device '$instanceId' changed to '$currentDriverInf' while DeckLux binding was pending; preserving the external change."
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($pendingPublishedInf) -and
            $currentDriverInf -ieq $pendingPublishedInf) {
            if ([string]::IsNullOrWhiteSpace($beforeDriverInf)) {
                $target.BindingPreExisting = $false
                $target.BoundByInstaller = $true
                $target.BindingRequested = $true
                $target.Installed = $true
            }
            elseif ($beforeDriverInf -ieq $pendingPublishedInf) {
                $target.BindingPreExisting = $true
                $target.BoundByInstaller = $false
                $target.BindingRequested = $false
                $target.Installed = $true
            }
            else {
                throw "Device '$instanceId' reached the DeckLux package from an unexpected prior binding; refusing cleanup."
            }
        }
        elseif ($currentDriverInf -ieq $beforeDriverInf) {
            $target.BoundByInstaller = $false
            $target.BindingRequested = $false
            $target.Installed = $false
        }
        else {
            throw "Device '$instanceId' changed to '$currentDriverInf' while DeckLux binding was pending; preserving the external change."
        }
        $target.BindingWritePending = $false
        $target.BindingTransitionRecorded = $false
        $target.BindingWasAlreadyActive = $false
        $target.BindingOwnedBeforeWrite = $false
        $state.RollbackLog = @($state.RollbackLog) + @(
            "$(Get-Date -Format o): reconciled interrupted binding on $instanceId")
        Write-DeckLuxState -State $state -Path $StatePath
    }
}

$publishedInf = [string]$state.Package.PublishedInf
if (-not [string]::IsNullOrWhiteSpace($publishedInf)) {
    $sameNamePackages = @(Get-DeckLuxPublishedDrivers | Where-Object {
        $_.DriverName -ieq $publishedInf
    })
    if ($sameNamePackages.Count -gt 1) {
        throw "Driver Store returned duplicate entries for '$publishedInf'."
    }
    if ($sameNamePackages.Count -eq 1 -and
        ($sameNamePackages[0].OriginalName -ine $script:DeckLuxExpectedInfName -or
         $sameNamePackages[0].ProviderName -ine $script:DeckLuxExpectedProvider -or
         -not ([string]$sameNamePackages[0].DriverVersion).Trim().EndsWith(
            [string]$state.Package.DriverVersion))) {
        throw "Published name '$publishedInf' no longer identifies the recorded DeckLux package; refusing removal."
    }
}

try {
    foreach ($target in @($state.Targets)) {
        $instanceId = [string]$target.InstanceId

        $snapshot = $null
        try {
            $snapshot = Get-DeckLuxDeviceSnapshot -InstanceId $instanceId
        }
        catch {
            $state.RollbackLog = @($state.RollbackLog) + @(
                "$(Get-Date -Format o): target $instanceId was not present during uninstall")
        }

        if ($null -eq $snapshot) {
            $target.LastError = 'The recorded device is not present; rollback was deferred.'
            $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            Write-DeckLuxState -State $state -Path $StatePath
            throw "Recorded device '$instanceId' is not present; reconnect or re-enable it before uninstalling DeckLux."
        }

        if ($null -ne $snapshot -and
            -not [string]::IsNullOrWhiteSpace($snapshot.DriverInfPath) -and
            $snapshot.DriverInfPath -ieq $publishedInf -and
            [bool]$target.BoundByInstaller) {
            if (-not $PSCmdlet.ShouldProcess(
                "$instanceId ($($snapshot.BiosDeviceName))",
                'Restore the exact device instance to the null driver')) {
                throw "Exact device rollback was declined for '$instanceId'."
            }

            $needReboot = [DeckLux.NativeMethods]::InstallDevice($instanceId, $true)
            $target.NeedReboot = $needReboot
            $state.NeedReboot = [bool]($state.NeedReboot -or $needReboot)
            $target.Installed = $false
            $target.BindingRequested = $false
            $target.BoundByInstaller = $false
            $target.BindingWritePending = $false
            $target.After = Get-DeckLuxDeviceSnapshot -InstanceId $instanceId
            $state.RollbackLog = @($state.RollbackLog) + @(
                "$(Get-Date -Format o): restored null driver on $instanceId")
            $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            Write-DeckLuxState -State $state -Path $StatePath
        }
        elseif ($null -ne $snapshot -and
            -not [string]::IsNullOrWhiteSpace($snapshot.DriverInfPath) -and
            $snapshot.DriverInfPath -ieq $publishedInf) {
            $target.BindingRequested = $false
            $target.BoundByInstaller = $false
            $target.BindingWritePending = $false
            $state.RollbackLog = @($state.RollbackLog) + @(
                "$(Get-Date -Format o): preserved pre-existing binding on $instanceId")
        }
        elseif ($null -ne $snapshot -and
            -not [string]::IsNullOrWhiteSpace($snapshot.DriverInfPath)) {
            $state.RollbackLog = @($state.RollbackLog) + @(
                "$(Get-Date -Format o): left $instanceId unchanged because it uses $($snapshot.DriverInfPath)")
        }
        elseif ($null -ne $snapshot) {
            $target.Installed = $false
            $target.BindingRequested = $false
            $target.BoundByInstaller = $false
            $target.BindingWritePending = $false
        }

        $calibrationProperty = $target.PSObject.Properties['Calibration']
        if ($null -ne $calibrationProperty -and
            $null -ne $calibrationProperty.Value -and
            ($target.Calibration.SetByInstaller -or
             $target.Calibration.WritePending)) {
            $calibration = $target.Calibration
            $currentCalibration = Get-DeckLuxCalibrationPropertySnapshot `
                -InstanceId $instanceId
            $installerDataBase64 = if ($null -ne $calibration.AppliedDataBase64) {
                [string]$calibration.AppliedDataBase64
            }
            else {
                [string]$calibration.DesiredDataBase64
            }
            $matchesInstaller = $currentCalibration.Present -and
                [uint32]$currentCalibration.PropertyType -eq 0x00000007 -and
                [string]$currentCalibration.DataBase64 -ceq $installerDataBase64
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

            if ($matchesInstaller) {
                if (-not $PSCmdlet.ShouldProcess(
                    $instanceId,
                    'Restore the prior DeckLux calibration property state')) {
                    throw "Calibration rollback was declined for '$instanceId'."
                }

                Restore-DeckLuxCalibrationProperty `
                    -InstanceId $instanceId `
                    -CalibrationState $calibration
                $state.RollbackLog = @($state.RollbackLog) + @(
                    "$(Get-Date -Format o): restored calibration property on $instanceId")
            }
            elseif (-not $matchesPrevious) {
                $calibration.ExternalChangePreserved = $true
                $state.RollbackLog = @($state.RollbackLog) + @(
                    "$(Get-Date -Format o): preserved later calibration-property change on $instanceId")
            }

            $calibration.SetByInstaller = $false
            $calibration.WritePending = $false
            $calibration.AppliedDataBase64 = $null
            $calibration.Verified = $false
            $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            Write-DeckLuxState -State $state -Path $StatePath
        }

        if ($target.OptInSetByInstaller -and -not $target.OptInPreExisting) {
            if (-not $PSCmdlet.ShouldProcess(
                $instanceId,
                'Remove the DeckLux exact-device authorization property')) {
                throw "Opt-in removal was declined for '$instanceId'."
            }
            [DeckLux.NativeMethods]::SetOptInProperty(
                $instanceId,
                $script:DeckLuxOptInPropertyGuid,
                $script:DeckLuxOptInPropertyPid,
                $false)
            $target.OptInSetByInstaller = $false
            $target.OptInWritePending = $false
            $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            Write-DeckLuxState -State $state -Path $StatePath
        }
    }

    $packageOwnershipProperty = $state.Package.PSObject.Properties['StagedByInstaller']
    $packageOwnedByInstaller = if ($null -eq $packageOwnershipProperty) {
        $true
    }
    else {
        [bool]$packageOwnershipProperty.Value
    }
    $packageAbsent = [string]::IsNullOrWhiteSpace($publishedInf)

    if (-not [string]::IsNullOrWhiteSpace($publishedInf)) {
        $publishedPackage = @(Get-DeckLuxPublishedDrivers | Where-Object {
            $_.DriverName -ieq $publishedInf -and
            $_.OriginalName -ieq $script:DeckLuxExpectedInfName -and
            $_.ProviderName -ieq $script:DeckLuxExpectedProvider -and
            ([string]$_.DriverVersion).Trim().EndsWith(
                [string]$state.Package.DriverVersion)
        })

        if ($publishedPackage.Count -eq 1 -and $packageOwnedByInstaller) {
            if (-not $PSCmdlet.ShouldProcess(
                $publishedInf,
                'Delete the recorded DeckLux package from Driver Store')) {
                throw "Driver package removal was declined for '$publishedInf'."
            }
            $deleteResult = Invoke-DeckLuxPnpUtil -Arguments @(
                '/delete-driver',
                $publishedInf)
            $state.RollbackLog = @($state.RollbackLog) + @(
                "$(Get-Date -Format o): package removal: $($deleteResult.Output -join ' | ')")
            $packageAbsent = @(Get-DeckLuxPublishedDrivers | Where-Object {
                $_.DriverName -ieq $publishedInf
            }).Count -eq 0
            if (-not $packageAbsent) {
                throw "Driver Store still contains '$publishedInf'; certificate trust was preserved."
            }
            if ($null -ne $state.Package.PSObject.Properties['Removed']) {
                $state.Package.Removed = $true
            }
            Write-DeckLuxState -State $state -Path $StatePath
        }
        elseif ($publishedPackage.Count -eq 1) {
            $state.RollbackLog = @($state.RollbackLog) + @(
                "$(Get-Date -Format o): preserved pre-existing package $publishedInf")
            $packageAbsent = $false
            Write-DeckLuxState -State $state -Path $StatePath
        }
        elseif ($publishedPackage.Count -gt 1) {
            throw "More than one package unexpectedly uses published name '$publishedInf'."
        }
        else {
            $packageAbsent = $true
        }
    }

    if ($state.Certificate.TrustedPublisherAdded -and
        -not $state.Certificate.TrustedPublisherPreExisting -and
        $packageAbsent) {
        if (-not $PSCmdlet.ShouldProcess(
            "LocalMachine TrustedPublisher $($state.Package.CertificateThumbprint)",
            'Remove the DeckLux test publisher certificate')) {
            throw 'TrustedPublisher certificate removal was declined.'
        }
        Remove-DeckLuxCertificateFromStore `
            -Store 'TrustedPublisher' `
            -Thumbprint ([string]$state.Package.CertificateThumbprint)
        $state.Certificate.TrustedPublisherAdded = $false
        Write-DeckLuxState -State $state -Path $StatePath
    }

    if ($state.Certificate.RootAdded -and
        -not $state.Certificate.RootPreExisting -and
        $packageAbsent) {
        if (-not $PSCmdlet.ShouldProcess(
            "LocalMachine Root $($state.Package.CertificateThumbprint)",
            'Remove the DeckLux test root certificate')) {
            throw 'Root certificate removal was declined.'
        }
        Remove-DeckLuxCertificateFromStore `
            -Store 'Root' `
            -Thumbprint ([string]$state.Package.CertificateThumbprint)
        $state.Certificate.RootAdded = $false
        Write-DeckLuxState -State $state -Path $StatePath
    }

    $remainingPending = [bool]$state.Package.StagePending -or
        [bool]$state.Certificate.RootWritePending -or
        [bool]$state.Certificate.TrustedPublisherWritePending -or
        @($state.Targets | Where-Object {
            [bool]$_.OptInWritePending -or [bool]$_.BindingWritePending -or
            ($null -ne $_.PSObject.Properties['Calibration'] -and
             $null -ne $_.PSObject.Properties['Calibration'].Value -and
             [bool]$_.PSObject.Properties['Calibration'].Value.WritePending)
        }).Count -gt 0
    if ($remainingPending) {
        throw 'DeckLux rollback cannot complete while journaled operations remain pending.'
    }

    $state.Completed = $false
    $state.Uninstalled = $true
    $state.UninstalledUtc = [DateTime]::UtcNow.ToString('o')
    $state.LastError = $null
    $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Write-DeckLuxState -State $state -Path $StatePath

    if ($state.NeedReboot) {
        Write-Warning 'Windows reported that a reboot is required. No reboot was performed.'
    }
    Write-Warning 'DeckLux did not change TESTSIGNING. Disable Test Mode manually only after confirming no other test drivers need it.'
    $state
}
catch {
    $state.LastError = $_.Exception.Message
    $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    Write-DeckLuxState -State $state -Path $StatePath
    throw
}
