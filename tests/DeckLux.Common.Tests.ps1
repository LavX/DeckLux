# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\scripts\DeckLux.Common.ps1')

function Assert-DeckLuxTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "DeckLux.Common test failed: $Message"
    }
}

Import-DeckLuxNativeMethods
Assert-DeckLuxTest `
    -Condition (('DeckLux.NativeMethods' -as [type]) -ne $null) `
    -Message 'native property helper compiles'

$propertyScalePpm = [uint32]22222222
Assert-DeckLuxTest `
    -Condition (Test-DeckLuxCalibrationScalePpm -ScalePpm $propertyScalePpm) `
    -Message 'synthetic ppm scale is accepted'

foreach ($invalidScalePpm in @(0, 9999, 100000001)) {
    Assert-DeckLuxTest `
        -Condition (-not (Test-DeckLuxCalibrationScalePpm -ScalePpm $invalidScalePpm)) `
        -Message "invalid ppm scale '$invalidScalePpm' is rejected"
}

$expectedData = [BitConverter]::GetBytes($propertyScalePpm)
$matchingSnapshot = [pscustomobject]@{
    Present = $true
    PropertyType = [uint32]0x00000007
    DataBase64 = [Convert]::ToBase64String($expectedData)
}
Assert-DeckLuxTest `
    -Condition (Test-DeckLuxCalibrationPropertyMatches `
        -Snapshot $matchingSnapshot `
        -ScalePpm $propertyScalePpm) `
    -Message 'exact UINT32 ppm property matches'

$wrongTypeSnapshot = [pscustomobject]@{
    Present = $true
    PropertyType = [uint32]0x0000000A
    DataBase64 = [Convert]::ToBase64String($expectedData)
}
Assert-DeckLuxTest `
    -Condition (-not (Test-DeckLuxCalibrationPropertyMatches `
        -Snapshot $wrongTypeSnapshot `
        -ScalePpm $propertyScalePpm)) `
    -Message 'same bytes with the wrong DEVPROP type do not match'

$adoptedBinding = Resolve-DeckLuxBindingTransition `
    -WasAlreadyBoundToPackage $true `
    -WasOwnedByInstaller $false
Assert-DeckLuxTest `
    -Condition (-not $adoptedBinding.BoundByInstaller -and
        -not $adoptedBinding.ChangedThisRun) `
    -Message 'adopted binding remains unowned and is excluded from run rollback'

$existingOwnedBinding = Resolve-DeckLuxBindingTransition `
    -WasAlreadyBoundToPackage $true `
    -WasOwnedByInstaller $true
Assert-DeckLuxTest `
    -Condition ($existingOwnedBinding.BoundByInstaller -and
        -not $existingOwnedBinding.ChangedThisRun) `
    -Message 'existing owned binding retains ownership without becoming a run change'

$freshBinding = Resolve-DeckLuxBindingTransition `
    -WasAlreadyBoundToPackage $false `
    -WasOwnedByInstaller $false
Assert-DeckLuxTest `
    -Condition ($freshBinding.BoundByInstaller -and
        $freshBinding.ChangedThisRun) `
    -Message 'fresh binding is owned and included in run rollback'

'DeckLux.Common tests passed.'
