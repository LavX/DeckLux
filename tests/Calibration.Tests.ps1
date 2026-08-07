# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'DeckLux.Common.Tests.ps1')
& (Join-Path $PSScriptRoot 'DeckLux.Release.Tests.ps1')
& (Join-Path $PSScriptRoot 'DeckLux.Setup.Tests.ps1')

Import-Module Pester -ErrorAction Stop
$pesterResult = Invoke-Pester `
    -Script (Join-Path $PSScriptRoot 'DeckLux.SmbiosCalibration.Tests.ps1') `
    -PassThru
if ($pesterResult.FailedCount -ne 0) {
    throw "$($pesterResult.FailedCount) DeckLux SMBIOS calibration test(s) failed."
}

Write-Host 'All DeckLux PowerShell tests passed.'
