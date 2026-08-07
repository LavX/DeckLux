# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

[CmdletBinding()]
param(
    [string]$PackagePath,
    [string]$CertificatePath,
    [string]$InfVerifPath,
    [string]$SignToolPath,
    [switch]$RequireTrustedSignature,
    [switch]$RequireWdkTools,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DeckLux.Common.ps1')

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Get-DeckLuxDefaultPackagePath
}

$result = Test-DeckLuxPackageInternal `
    -PackagePath $PackagePath `
    -CertificatePath $CertificatePath `
    -InfVerifPath $InfVerifPath `
    -SignToolPath $SignToolPath `
    -RequireTrustedSignature:$RequireTrustedSignature `
    -RequireWdkTools:$RequireWdkTools

foreach ($warningText in @($result.Warnings)) {
    Write-Warning $warningText
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 8
}
else {
    $result
}
