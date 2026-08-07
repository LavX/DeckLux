# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

[CmdletBinding()]
param(
    [ValidateSet('Release')]
    [string]$Configuration = 'Release',

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.0.0',

    [string]$EwdkRoot = 'E:',

    [switch]$IncludeSymbols,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'DeckLux.Common.ps1')

function Copy-DeckLuxReleaseFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required release file is missing: $Source"
    }
    $parent = Split-Path $Destination -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function New-DeckLuxZip {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $SourceDirectory,
        $DestinationPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $false)
}

function Get-DeckLuxReleaseHashRecord {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [pscustomobject][ordered]@{
        File = Split-Path $Path -Leaf
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        Size = (Get-Item -LiteralPath $Path).Length
    }
}

if ($Version -ne $script:DeckLuxProductVersion) {
    throw "Release version '$Version' does not match source version '$script:DeckLuxProductVersion'."
}

$driverVersion = "$Version.0"
$packagePath = Join-Path $projectRoot "src\x64\$Configuration\DeckLux.Sensor"
$certificatePath = Join-Path $projectRoot "src\x64\$Configuration\DeckLuxSensor.cer"
$infVerifPath = Join-Path $EwdkRoot 'Program Files\Windows Kits\10\Tools\10.0.28000.0\x64\infverif.exe'
$signToolPath = Join-Path $EwdkRoot 'Program Files\Windows Kits\10\bin\10.0.28000.0\x64\signtool.exe'

$package = Test-DeckLuxPackageInternal `
    -PackagePath $packagePath `
    -CertificatePath $certificatePath `
    -InfVerifPath $infVerifPath `
    -SignToolPath $signToolPath `
    -RequireWdkTools

if ($package.DriverVersion -ne $driverVersion) {
    throw "Driver package version '$($package.DriverVersion)' does not match release '$driverVersion'."
}

$releaseParent = Join-Path $projectRoot 'artifacts\release'
$releaseRoot = Join-Path $releaseParent $Version
if (Test-Path -LiteralPath $releaseRoot) {
    if (-not $Force) {
        throw "Release directory already exists: $releaseRoot. Use -Force to replace it."
    }
    $resolvedRelease = [IO.Path]::GetFullPath($releaseRoot)
    $resolvedParent = [IO.Path]::GetFullPath($releaseParent).TrimEnd('\') + '\'
    if (-not $resolvedRelease.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to replace an unsafe release path: $resolvedRelease"
    }
    Remove-Item -LiteralPath $resolvedRelease -Recurse -Force
}
New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null

$workingRoot = Join-Path ([IO.Path]::GetTempPath()) ("DeckLux-Release-" + [Guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path $workingRoot 'payload'
$sourceRoot = Join-Path $workingRoot 'source'
New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null

try {
    $payloadFiles = [ordered]@{
        'driver\DeckLux.Sensor\DeckLuxSensor.inf' = $package.InfPath
        'driver\DeckLux.Sensor\deckluxsensor.cat' = $package.CatalogPath
        'driver\DeckLux.Sensor\DeckLuxSensor.dll' = $package.DllPath
        'driver\DeckLux.Sensor\NOTICE.md' = (Join-Path $package.PackagePath 'NOTICE.md')
        'driver\DeckLuxSensor.cer' = $package.CertificatePath
        'scripts\Install-DeckLux.ps1' = (Join-Path $projectRoot 'scripts\Install-DeckLux.ps1')
        'scripts\Uninstall-DeckLux.ps1' = (Join-Path $projectRoot 'scripts\Uninstall-DeckLux.ps1')
        'scripts\DeckLux.Common.ps1' = (Join-Path $projectRoot 'scripts\DeckLux.Common.ps1')
        'scripts\DeckLux.SmbiosCalibration.ps1' = (Join-Path $projectRoot 'scripts\DeckLux.SmbiosCalibration.ps1')
        'scripts\README.md' = (Join-Path $projectRoot 'scripts\README.md')
        'scripts\Test-DeckLuxSensor.ps1' = (Join-Path $projectRoot 'scripts\Test-DeckLuxSensor.ps1')
        'scripts\Collect-DeckLuxDiagnostics.ps1' = (Join-Path $projectRoot 'scripts\Collect-DeckLuxDiagnostics.ps1')
        'scripts\Test-DeckLuxPackage.ps1' = (Join-Path $projectRoot 'scripts\Test-DeckLuxPackage.ps1')
        'README.md' = (Join-Path $projectRoot 'README.md')
        'CHANGELOG.md' = (Join-Path $projectRoot 'CHANGELOG.md')
        'LICENSE' = (Join-Path $projectRoot 'LICENSE')
        'NOTICE.md' = (Join-Path $projectRoot 'NOTICE.md')
        'AUTHORS.md' = (Join-Path $projectRoot 'AUTHORS.md')
        'THIRD_PARTY_NOTICES.md' = (Join-Path $projectRoot 'THIRD_PARTY_NOTICES.md')
        'docs\CALIBRATION.md' = (Join-Path $projectRoot 'docs\CALIBRATION.md')
    }

    foreach ($entry in $payloadFiles.GetEnumerator()) {
        Copy-DeckLuxReleaseFile `
            -Source $entry.Value `
            -Destination (Join-Path $payloadRoot $entry.Key)
    }

    $payloadHashRecords = @(
        Get-ChildItem -LiteralPath $payloadRoot -Recurse -File |
            Sort-Object FullName |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    Path = $_.FullName.Substring($payloadRoot.Length + 1).Replace('\', '/')
                    Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                    Size = $_.Length
                }
            })
    $embeddedManifest = [pscustomobject][ordered]@{
        Product = 'DeckLux'
        Version = $Version
        DriverVersion = $driverVersion
        Architecture = 'x64'
        MinimumWindowsBuild = 22000
        TestSigned = $true
        CertificateSubject = $package.CertificateSubject
        CertificateThumbprint = $package.CertificateThumbprint
        Files = $payloadHashRecords
    }
    $embeddedManifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $payloadRoot 'release-manifest.json') -Encoding UTF8

    $payloadZip = Join-Path $workingRoot 'DeckLux.Payload.zip'
    New-DeckLuxZip -SourceDirectory $payloadRoot -DestinationPath $payloadZip
    $payloadHash = (Get-FileHash -LiteralPath $payloadZip -Algorithm SHA256).Hash
    $payloadHashPath = Join-Path $workingRoot 'DeckLux.Payload.sha256'
    [IO.File]::WriteAllText($payloadHashPath, $payloadHash, [Text.Encoding]::ASCII)

    $cscPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $cscPath -PathType Leaf)) {
        throw "64-bit .NET Framework C# compiler was not found: $cscPath"
    }

    $unsignedSetup = Join-Path $workingRoot 'DeckLux.Setup.exe'
    $compilerArguments = @(
        '/nologo',
        '/target:winexe',
        '/platform:x64',
        '/optimize+',
        '/warn:4',
        '/warnaserror+',
        "/out:$unsignedSetup",
        ("/win32manifest:" + (Join-Path $projectRoot 'setup\DeckLux.Setup.manifest')),
        "/resource:$payloadZip,DeckLux.Payload.zip",
        "/resource:$payloadHashPath,DeckLux.Payload.sha256",
        '/reference:System.dll',
        '/reference:System.Core.dll',
        '/reference:System.Drawing.dll',
        '/reference:System.Windows.Forms.dll',
        '/reference:System.Web.Extensions.dll',
        '/reference:System.IO.Compression.dll',
        '/reference:System.IO.Compression.FileSystem.dll',
        (Join-Path $projectRoot 'setup\DeckLux.Setup.cs'))
    & $cscPath @compilerArguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $unsignedSetup -PathType Leaf)) {
        throw "DeckLux Setup compilation failed with exit code $LASTEXITCODE."
    }

    $certificate = New-Object `
        System.Security.Cryptography.X509Certificates.X509Certificate2 `
        -ArgumentList $certificatePath
    $currentUserPrivate = Get-ChildItem -LiteralPath `
        ("Cert:\CurrentUser\My\" + $certificate.Thumbprint) `
        -ErrorAction SilentlyContinue
    $localMachinePrivate = Get-ChildItem -LiteralPath `
        ("Cert:\LocalMachine\My\" + $certificate.Thumbprint) `
        -ErrorAction SilentlyContinue
    if ($null -ne $currentUserPrivate -and $currentUserPrivate.HasPrivateKey) {
        $signArguments = @('sign', '/v', '/fd', 'sha256', '/sha1', $certificate.Thumbprint, $unsignedSetup)
    }
    elseif ($null -ne $localMachinePrivate -and $localMachinePrivate.HasPrivateKey) {
        $signArguments = @('sign', '/v', '/fd', 'sha256', '/sm', '/sha1', $certificate.Thumbprint, $unsignedSetup)
    }
    else {
        throw "The DeckLux test-signing certificate private key was not found."
    }
    & $signToolPath @signArguments
    if ($LASTEXITCODE -ne 0) {
        throw "DeckLux Setup signing failed with exit code $LASTEXITCODE."
    }
    $setupSignature = Get-AuthenticodeSignature -LiteralPath $unsignedSetup
    $setupUntrustedTestSignature = $setupSignature.Status -eq 'NotTrusted' -or
        ($setupSignature.Status -eq 'UnknownError' -and
         $setupSignature.StatusMessage -match '(?i)(not trusted|untrusted root)')
    if ($null -eq $setupSignature.SignerCertificate -or
        $setupSignature.SignerCertificate.Thumbprint -ine $certificate.Thumbprint -or
        ($setupSignature.Status -ne 'Valid' -and -not $setupUntrustedTestSignature)) {
        throw 'DeckLux Setup signature validation failed.'
    }

    $setupVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($unsignedSetup)
    if ($setupVersion.FileVersion -ne $driverVersion -or
        $setupVersion.ProductVersion -ne $Version) {
        throw "DeckLux Setup version metadata is inconsistent."
    }

    $setupReleasePath = Join-Path $releaseRoot "DeckLux-$Version-Setup.exe"
    Copy-DeckLuxReleaseFile -Source $unsignedSetup -Destination $setupReleasePath

    $portablePath = Join-Path $releaseRoot "DeckLux-$Version-portable.zip"
    Copy-DeckLuxReleaseFile -Source $payloadZip -Destination $portablePath

    $sourceFiles = @(
        'DeckLux.sln', 'README.md', 'CHANGELOG.md', 'LICENSE', 'NOTICE.md',
        'AUTHORS.md', 'THIRD_PARTY_NOTICES.md', '.gitignore')
    foreach ($relative in $sourceFiles) {
        Copy-DeckLuxReleaseFile `
            -Source (Join-Path $projectRoot $relative) `
            -Destination (Join-Path $sourceRoot $relative)
    }
    $sourcePatterns = [ordered]@{
        'src' = @('*.cpp', '*.h', '*.inx', '*.def', '*.vcxproj', '*.rc')
        'tests' = @('*.cpp', '*.cs', '*.ps1', '*.vcxproj')
        'scripts' = @('*.ps1', '*.cmd', '*.md')
        'setup' = @('*.cs', '*.manifest')
        'docs' = @('*.md')
    }
    foreach ($directoryEntry in $sourcePatterns.GetEnumerator()) {
        foreach ($pattern in $directoryEntry.Value) {
            Get-ChildItem -LiteralPath (Join-Path $projectRoot $directoryEntry.Key) `
                -Filter $pattern -File | ForEach-Object {
                    $destination = Join-Path `
                        (Join-Path $sourceRoot $directoryEntry.Key) $_.Name
                    Copy-DeckLuxReleaseFile -Source $_.FullName -Destination $destination
                }
        }
    }
    $sourceArchivePath = Join-Path $releaseRoot "DeckLux-$Version-source.zip"
    New-DeckLuxZip -SourceDirectory $sourceRoot -DestinationPath $sourceArchivePath

    $artifacts = @($setupReleasePath, $portablePath, $sourceArchivePath)
    if ($IncludeSymbols) {
        $pdb = Get-ChildItem -LiteralPath (Join-Path $projectRoot "src\x64\$Configuration") `
            -Filter 'DeckLuxSensor.pdb' -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $pdb) {
            throw 'The requested DeckLux symbol PDB was not found.'
        }
        $symbolRoot = Join-Path $workingRoot 'symbols'
        New-Item -ItemType Directory -Path $symbolRoot -Force | Out-Null
        Copy-DeckLuxReleaseFile -Source $pdb.FullName -Destination (Join-Path $symbolRoot $pdb.Name)
        $symbolsPath = Join-Path $releaseRoot "DeckLux-$Version-symbols.zip"
        New-DeckLuxZip -SourceDirectory $symbolRoot -DestinationPath $symbolsPath
        $artifacts += $symbolsPath
    }

    $hashRecords = @($artifacts | ForEach-Object { Get-DeckLuxReleaseHashRecord -Path $_ })
    $hashLines = @($hashRecords | ForEach-Object { "$($_.Sha256) *$($_.File)" })
    $hashPath = Join-Path $releaseRoot 'SHA256SUMS.txt'
    [IO.File]::WriteAllLines($hashPath, $hashLines, [Text.Encoding]::ASCII)

    $releaseManifest = [pscustomobject][ordered]@{
        Product = 'DeckLux'
        Version = $Version
        DriverVersion = $driverVersion
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        Architecture = 'x64'
        TestSigned = $true
        CertificateSubject = $package.CertificateSubject
        CertificateThumbprint = $package.CertificateThumbprint
        PackageHashes = $package.Hashes
        Artifacts = $hashRecords
    }
    $releaseManifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $releaseRoot 'release-manifest.json') -Encoding UTF8

    $forbidden = @(Get-ChildItem -LiteralPath $releaseRoot -Recurse -File | Where-Object {
        $relativePath = $_.FullName.Substring($releaseRoot.Length + 1)
        $_.Name -match '(?i)(install-state|diagnostic|\.binlog$|\.obj$|\.tlog$)' -or
        $relativePath -match '(?i)(^|[\\/])(artifacts|\.tools|\.git)([\\/]|$)'
    })
    if ($forbidden.Count -ne 0) {
        throw "Release contains forbidden machine/build artifacts: $($forbidden.FullName -join ', ')"
    }

    [pscustomobject][ordered]@{
        Product = 'DeckLux'
        Version = $Version
        ReleaseDirectory = $releaseRoot
        Setup = $setupReleasePath
        Portable = $portablePath
        Source = $sourceArchivePath
        CertificateThumbprint = $package.CertificateThumbprint
        Artifacts = $hashRecords
    }
}
finally {
    if (Test-Path -LiteralPath $workingRoot -PathType Container) {
        Remove-Item -LiteralPath $workingRoot -Recurse -Force
    }
}
