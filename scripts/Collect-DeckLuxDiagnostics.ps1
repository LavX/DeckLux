# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$PackagePath,
    [string]$CertificatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DeckLux.Common.ps1')
. (Join-Path $PSScriptRoot 'DeckLux.SmbiosCalibration.ps1')

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $diagnosticRoot = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($diagnosticRoot)) {
        $diagnosticRoot = [Environment]::GetFolderPath('LocalApplicationData')
    }
    $OutputPath = Join-Path $diagnosticRoot "DeckLux\Diagnostics\diagnostics-$stamp"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

function Write-DeckLuxDiagnosticText {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $path = Join-Path $OutputPath $Name
    $Text | Set-Content -LiteralPath $path -Encoding UTF8
}

function Invoke-DeckLuxDiagnosticCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Command,
        [switch]$CheckNativeExitCode
    )

    try {
        $output = @(& $Command 2>&1 | ForEach-Object { [string]$_ })
        Write-DeckLuxDiagnosticText -Name $Name -Text ($output -join [Environment]::NewLine)
        $nativeExitCode = if ($CheckNativeExitCode) { $LASTEXITCODE } else { 0 }
        return [pscustomobject]@{
            Name = $Name
            Succeeded = ($nativeExitCode -eq 0)
            Error = if ($nativeExitCode -eq 0) {
                $null
            }
            else {
                "Native command exited with code $nativeExitCode."
            }
        }
    }
    catch {
        Write-DeckLuxDiagnosticText -Name $Name -Text $_.Exception.ToString()
        return [pscustomobject]@{
            Name = $Name
            Succeeded = $false
            Error = $_.Exception.Message
        }
    }
}

$collectionResults = New-Object System.Collections.Generic.List[object]
$testSigningEnabled = $null
$testSigningError = $null
try {
    $testSigningEnabled = Test-DeckLuxTestSigningEnabled
}
catch {
    $testSigningError = $_.Exception.Message
}

$secureBootValue = Get-ItemPropertyValue `
    -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' `
    -Name 'UEFISecureBootEnabled' `
    -ErrorAction SilentlyContinue
$hvciValue = Get-ItemPropertyValue `
    -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' `
    -Name 'Enabled' `
    -ErrorAction SilentlyContinue
$windowsInfo = Get-ItemProperty `
    -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
    -ErrorAction SilentlyContinue

$systemSummary = [pscustomobject][ordered]@{
    CollectedUtc = [DateTime]::UtcNow.ToString('o')
    ScriptVersion = 2
    IsAdministrator = Test-DeckLuxAdministrator
    Is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
    Is64BitProcess = [Environment]::Is64BitProcess
    WindowsProductName = [string]$windowsInfo.ProductName
    WindowsDisplayVersion = [string]$windowsInfo.DisplayVersion
    WindowsCurrentBuild = [string]$windowsInfo.CurrentBuild
    WindowsUbr = $windowsInfo.UBR
    TestSigningEnabled = $testSigningEnabled
    TestSigningQueryError = $testSigningError
    SecureBootEnabled = if ($null -eq $secureBootValue) { $null } else { $secureBootValue -eq 1 }
    HvciEnabled = if ($null -eq $hvciValue) { $null } else { $hvciValue -eq 1 }
    OutputPath = $OutputPath
}

$systemSummary | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $OutputPath 'system-summary.json') -Encoding UTF8

$pnpUtil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
$collectionResults.Add((Invoke-DeckLuxDiagnosticCommand `
    -Name 'pnp-prp0001.txt' `
    -CheckNativeExitCode `
    -Command {
        & $pnpUtil /enum-devices /deviceid 'ACPI\PRP0001' /properties /drivers /relations /services /stack /resources
    }))
$collectionResults.Add((Invoke-DeckLuxDiagnosticCommand `
    -Name 'pnp-sensor-devices.txt' `
    -CheckNativeExitCode `
    -Command {
        & $pnpUtil /enum-devices /class Sensor /properties /drivers /interfaces /services /stack
    }))
$collectionResults.Add((Invoke-DeckLuxDiagnosticCommand `
    -Name 'pnp-sensor-packages.txt' `
    -CheckNativeExitCode `
    -Command {
        & $pnpUtil /enum-drivers /class Sensor /files /devices
    }))
$collectionResults.Add((Invoke-DeckLuxDiagnosticCommand `
    -Name 'bitlocker-status.txt' `
    -CheckNativeExitCode `
    -Command {
        & (Join-Path $env:SystemRoot 'System32\manage-bde.exe') -status $env:SystemDrive
    }))
$collectionResults.Add((Invoke-DeckLuxDiagnosticCommand `
    -Name 'bcd-current.txt' `
    -CheckNativeExitCode `
    -Command {
        & (Join-Path $env:SystemRoot 'System32\bcdedit.exe') /enum '{current}'
    }))

$deviceSnapshots = New-Object System.Collections.Generic.List[object]
try {
    foreach ($id in @(Get-DeckLuxMatchingInstanceIds)) {
        try {
            $deviceSnapshots.Add((Get-DeckLuxDeviceSnapshot -InstanceId $id))
        }
        catch {
            $deviceSnapshots.Add([pscustomobject]@{
                InstanceId = $id
                QueryError = $_.Exception.Message
            })
        }
    }
}
catch {
    $deviceSnapshots.Add([pscustomobject]@{
        InstanceId = $null
        QueryError = $_.Exception.Message
    })
}
$deviceSnapshots | ConvertTo-Json -Depth 7 |
    Set-Content -LiteralPath (Join-Path $OutputPath 'device-snapshots.json') -Encoding UTF8

try {
    $factoryCalibration = @(Get-DeckLuxFactoryCalibration | ForEach-Object {
        [pscustomobject][ordered]@{
            Role = $_.Role
            BiosLeaf = $_.BiosLeaf
            InstanceSuffix = $_.InstanceSuffix
            OemStringIndex = $_.OemStringIndex
            FactoryGain = $_.FactoryGain
            ConversionScale = $_.ConversionScale
            SystemManufacturer = $_.Identity.SystemManufacturer
            SystemProductName = $_.Identity.SystemProductName
            SystemFamily = $_.Identity.SystemFamily
            Source = $_.Provenance.Source
            Formula = $_.Provenance.Formula
        }
    })
    $factoryCalibration | ConvertTo-Json -Depth 5 |
        Set-Content `
            -LiteralPath (Join-Path $OutputPath 'factory-calibration.json') `
            -Encoding UTF8
}
catch {
    [pscustomobject]@{
        Error = $_.Exception.Message
    } | ConvertTo-Json |
        Set-Content `
            -LiteralPath (Join-Path $OutputPath 'factory-calibration.json') `
            -Encoding UTF8
}

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Get-DeckLuxDefaultPackagePath
}
$packageReport = $null
try {
    if (Test-Path -LiteralPath $PackagePath -PathType Container) {
        $packageReport = Test-DeckLuxPackageInternal `
            -PackagePath $PackagePath `
            -CertificatePath $CertificatePath
    }
}
catch {
    $packageReport = [pscustomobject]@{
        Valid = $false
        Error = $_.Exception.Message
        PackagePath = [IO.Path]::GetFullPath($PackagePath)
    }
}
if ($null -ne $packageReport) {
    $packageReport | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $OutputPath 'package-report.json') -Encoding UTF8
}

$setupApiLog = Join-Path $env:SystemRoot 'INF\setupapi.dev.log'
if (Test-Path -LiteralPath $setupApiLog -PathType Leaf) {
    try {
        $matches = @(Select-String `
            -LiteralPath $setupApiLog `
            -Pattern 'DeckLux|DeckLuxSensor|ACPI\\PRP0001' `
            -Context 8, 20 `
            -ErrorAction Stop | Select-Object -Last 200)
        Write-DeckLuxDiagnosticText `
            -Name 'setupapi-decklux.txt' `
            -Text (($matches | Out-String -Width 240).TrimEnd())
    }
    catch {
        Write-DeckLuxDiagnosticText `
            -Name 'setupapi-decklux.txt' `
            -Text $_.Exception.ToString()
    }
}

$eventLogNames = @(
    'Microsoft-Windows-DriverFrameworks-UserMode/Operational',
    'Microsoft-Windows-Kernel-PnP/Configuration')
foreach ($logName in $eventLogNames) {
    $safeName = ($logName -replace '[^A-Za-z0-9.-]', '_') + '.txt'
    $collectionResults.Add((Invoke-DeckLuxDiagnosticCommand `
        -Name $safeName `
        -Command {
            $events = @(Get-WinEvent `
                -LogName $logName `
                -MaxEvents 300 `
                -ErrorAction Stop | Where-Object {
                    $_.Message -match '(?i)DeckLux|DeckLuxSensor|ACPI\\PRP0001|LTRF|LTRS'
            })
            $events | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
                Format-List |
                Out-String -Width 240
        }))
}

$diagnosticSummary = [pscustomobject][ordered]@{
    OutputPath = $OutputPath
    CollectedUtc = $systemSummary.CollectedUtc
    Files = @(Get-ChildItem -LiteralPath $OutputPath -File |
        Select-Object -ExpandProperty Name |
        Sort-Object)
    CollectionResults = @($collectionResults | ForEach-Object { $_ })
    Notice = 'Review diagnostic files before sharing them. DeckLux intentionally does not collect BitLocker recovery passwords or unrelated full device inventories.'
}
$diagnosticSummary | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $OutputPath 'collection-summary.json') -Encoding UTF8

$diagnosticSummary
