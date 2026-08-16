# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Assert-DeckLuxReleaseTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "DeckLux release test failed: $Message"
    }
}

$requiredFiles = @(
    'README.md',
    'CHANGELOG.md',
    'LICENSE',
    'NOTICE.md',
    'AUTHORS.md',
    'THIRD_PARTY_NOTICES.md',
    'scripts\Install-DeckLux.ps1',
    'scripts\Uninstall-DeckLux.ps1',
    'scripts\Compare-DeckLuxSensors.ps1',
    'scripts\New-DeckLuxRelease.ps1',
    'setup\DeckLux.Setup.cs',
    'setup\DeckLux.Setup.manifest')
foreach ($relativePath in $requiredFiles) {
    Assert-DeckLuxReleaseTest `
        -Condition (Test-Path -LiteralPath (Join-Path $projectRoot $relativePath) -PathType Leaf) `
        -Message "required file '$relativePath' exists"
}

Assert-DeckLuxReleaseTest `
    -Condition (-not (Test-Path -LiteralPath `
        (Join-Path $projectRoot 'scripts\Install-DeckLuxCanary.ps1'))) `
    -Message 'obsolete canary installer is absent'

$infText = Get-Content -LiteralPath `
    (Join-Path $projectRoot 'src\DeckLuxSensor.inx') -Raw
$resourceText = Get-Content -LiteralPath `
    (Join-Path $projectRoot 'src\Version.rc') -Raw
$setupText = Get-Content -LiteralPath `
    (Join-Path $projectRoot 'setup\DeckLux.Setup.cs') -Raw
$setupManifestText = Get-Content -LiteralPath `
    (Join-Path $projectRoot 'setup\DeckLux.Setup.manifest') -Raw
$readmeText = Get-Content -LiteralPath `
    (Join-Path $projectRoot 'README.md') -Raw
$deviceText = Get-Content -LiteralPath `
    (Join-Path $projectRoot 'src\Device.cpp') -Raw
$deviceHeaderText = Get-Content -LiteralPath `
    (Join-Path $projectRoot 'src\Device.h') -Raw
$sensorText = Get-Content -LiteralPath `
    (Join-Path $projectRoot 'src\Sensor.cpp') -Raw

Assert-DeckLuxReleaseTest `
    -Condition ($infText -match '(?m)^DriverVer\s*=\s*08/15/2026,1\.1\.0\.0\s*$') `
    -Message 'INF reports the 1.1.0.0 release version and date'
Assert-DeckLuxReleaseTest `
    -Condition ($resourceText -match 'FILEVERSION 1,1,0,0' -and
        $resourceText -match 'PRODUCTVERSION 1,1,0,0' -and
        $resourceText -match '"FileVersion", "1\.1\.0\.0\\0"' -and
        $resourceText -match '"ProductVersion", "1\.1\.0\.0\\0"') `
    -Message 'DLL resource versions are 1.1.0.0'
Assert-DeckLuxReleaseTest `
    -Condition ($setupText -match 'const string Version = "1\.1\.0"' -and
        $setupText -match 'const string DriverVersion = "1\.1\.0\.0"') `
    -Message 'setup version constants are consistent'
Assert-DeckLuxReleaseTest `
    -Condition ($setupManifestText -match 'assemblyIdentity version="1\.1\.0\.0"') `
    -Message 'setup manifest version is 1.1.0.0'

Assert-DeckLuxReleaseTest `
    -Condition ($setupText -notmatch 'IncludeSecondary|AllowCompatibleSensor') `
    -Message 'graphical installer has no topology or generic-device option'
Assert-DeckLuxReleaseTest `
    -Condition ($setupText -match 'both sensors on Steam Deck OLED' -and
        $setupText -match 'single sensor on Steam Deck LCD') `
    -Message 'graphical installer describes the platform-default sensor topology'
Assert-DeckLuxReleaseTest `
    -Condition ($setupText -match 'ValidateInstalledDefaultState\(\);' -and
        ([regex]::Matches($setupText, 'ValidateSupportedState\(\);')).Count -eq 1) `
    -Message 'setup strictly validates new installs while preserving legacy uninstall validation'
Assert-DeckLuxReleaseTest `
    -Condition ((Get-Content -LiteralPath `
        (Join-Path $projectRoot 'scripts\New-DeckLuxRelease.ps1') -Raw) `
        -match "'scripts\\Compare-DeckLuxSensors\.ps1'") `
    -Message 'release payload includes the dual-sensor comparator'
Assert-DeckLuxReleaseTest `
    -Condition ($setupText -match 'CommonApplicationData' -and
        $setupText -match 'ProgramFiles') `
    -Message 'setup uses Program Files and ProgramData'
Assert-DeckLuxReleaseTest `
    -Condition ($setupText -match 'Uninstall\\DeckLux' -and
        $setupText -match 'QuietUninstallString') `
    -Message 'setup registers Windows uninstall metadata'
Assert-DeckLuxReleaseTest `
    -Condition ($setupText -match 'IList targets' -and
        $setupText -match 'SetupMutexName' -and
        $setupText -match 'HardenProtectedTree') `
    -Message 'setup validates JSON arrays, serializes transactions, and hardens persistent data'
Assert-DeckLuxReleaseTest `
    -Condition ($deviceText -notmatch 'WdfDeviceAssignS0IdleSettings\s*\(' -and
        $deviceText -match 'BackgroundSampling') `
    -Message 'secondary background sampling respects SensorsCx power-policy ownership'
Assert-DeckLuxReleaseTest `
    -Condition ($deviceHeaderText -match 'OwnerDevice' -and
        $deviceHeaderText -match 'FusionPairKey' -and
        $deviceText -match 'DlxRegisterFusionChannel' -and
        $deviceText -match 'DlxQueryInstanceId' -and
        $sensorText -match 'STATUS_DEVICE_CONFIGURATION_ERROR' -and
        $sensorText -match 'ACPI\\\\PRP0001\\\\0' -and
        $sensorText -match 'ACPI\\\\PRP0001\\\\1' -and
        $sensorText -match 'unpaired:LTRF' -and
        $sensorText -match 'unpaired:LTRS') `
    -Message 'fusion coordinator keys the canonical Deck pair by instance identity and isolates unsupported leaves'
Assert-DeckLuxReleaseTest `
    -Condition ($deviceHeaderText -match 'SampleTimesMs' -and
        $sensorText -match 'DlxFusionFreshMedian' -and
        $sensorText -notmatch 'UpdatedAtMs') `
    -Message 'fusion median evaluates freshness for each stored sample'
Assert-DeckLuxReleaseTest `
    -Condition ($sensorText -match 'FusionFieldMetadata' -and
        $sensorText -match 'DlxFusionResolution' -and
        $sensorText -notmatch '(?s)DlxFieldRangeMaximum.*DLX_CALIBRATION_SCALE_PPM_MAXIMUM') `
    -Message 'fused range and resolution derive from registered sensor calibrations'
Assert-DeckLuxReleaseTest `
    -Condition ($sensorText -match '(?s)DlxFusionPairIsActive\(.*if \(!pairActive\).*return false;') `
    -Message 'single-sensor primaries bypass temporal and spatial fusion'
Assert-DeckLuxReleaseTest `
    -Condition ($sensorText -match '(?s)DlxFusionSamplingInterval\(\s*Context->BackgroundSampling,\s*Context->ClientRequestedStart,') `
    -Message 'secondary background cadence depends on client state rather than a stale requested interval'

$installText = Get-Content -LiteralPath `
    (Join-Path $projectRoot 'scripts\Install-DeckLux.ps1') -Raw
$uninstallText = Get-Content -LiteralPath `
    (Join-Path $projectRoot 'scripts\Uninstall-DeckLux.ps1') -Raw
Assert-DeckLuxReleaseTest `
    -Condition ($installText -match 'installSecondaryByDefault' -and
        $installText -match "DeckProduct -ieq 'Galileo'" -and
        $installText -match 'IncludeSecondary -or \$installSecondaryByDefault') `
    -Message 'default installation selects Galileo secondary while Jupiter remains primary-only'
Assert-DeckLuxReleaseTest `
    -Condition ($installText -match '-IncludeSecondary cannot be combined with explicit -InstanceId' -and
        $installText -match '(?s)if \(\$hasExplicitInstance\) \{\s*if \(\$IncludeSecondary\) \{') `
    -Message 'explicit instance selection cannot be mixed with topology expansion'
Assert-DeckLuxReleaseTest `
    -Condition ($installText -match 'isCanonicalGalileoPair' -and
        $installText -match 'Multi-device installation is limited to the canonical Steam Deck OLED LTRF/LTRS pair') `
    -Message 'installer rejects multi-device topologies that the fusion singleton cannot represent'
Assert-DeckLuxReleaseTest `
    -Condition ($installText -match 'BindingPreExisting' -and
        $installText -match 'BoundByInstaller' -and
        $uninstallText -match 'StagePending' -and
        $uninstallText -match 'RootWritePending' -and
        $uninstallText -match 'BindingWritePending') `
    -Message 'schema 3 records binding ownership and reconciles interrupted mutations'

$forbiddenReadme = '(?i)generated by AI|\bsession log\b|\btest diary\b|\bTODO\b|\broadmap\b'
Assert-DeckLuxReleaseTest `
    -Condition ($readmeText -notmatch $forbiddenReadme) `
    -Message 'README contains product documentation rather than session notes'

$sourceFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'scripts') -Filter '*.ps1' -File
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'tests') -Filter '*.ps1' -File)
foreach ($file in $sourceFiles) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors) | Out-Null
    Assert-DeckLuxReleaseTest `
        -Condition ($parseErrors.Count -eq 0) `
        -Message "PowerShell file '$($file.Name)' parses"
}

. (Join-Path $projectRoot 'scripts\DeckLux.Common.ps1')
$expectedStatePath = [IO.Path]::GetFullPath((Join-Path `
    ([Environment]::GetFolderPath('CommonApplicationData')) `
    'DeckLux\install-state.json'))
Assert-DeckLuxReleaseTest `
    -Condition ((Get-DeckLuxDefaultStatePath) -eq $expectedStatePath) `
    -Message 'default rollback journal is machine-wide under ProgramData'

$temporaryStateRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('DeckLux-State-Test-' + [Guid]::NewGuid().ToString('N'))
$temporaryStatePath = Join-Path $temporaryStateRoot 'state.json'
try {
    $state = [pscustomobject][ordered]@{
        SchemaVersion = 3
        Project = 'DeckLux'
        Completed = $false
        Uninstalled = $false
        Package = [pscustomobject]@{
            DriverVersion = '1.1.0.0'
            PublishedInf = 'oem42.inf'
        }
        Targets = @()
    }
    Write-DeckLuxState -State $state -Path $temporaryStatePath
    $roundTrip = Read-DeckLuxState -Path $temporaryStatePath
    Assert-DeckLuxReleaseTest `
        -Condition ($roundTrip.SchemaVersion -eq 3 -and $roundTrip.Project -eq 'DeckLux') `
        -Message 'schema 3 state round-trips atomically'

    $beforeWhatIf = (Get-FileHash -LiteralPath $temporaryStatePath -Algorithm SHA256).Hash
    $uninstallPlan = & (Join-Path $projectRoot 'scripts\Uninstall-DeckLux.ps1') `
        -StatePath $temporaryStatePath `
        -WhatIf
    $afterWhatIf = (Get-FileHash -LiteralPath $temporaryStatePath -Algorithm SHA256).Hash
    Assert-DeckLuxReleaseTest `
        -Condition ($uninstallPlan.Mode -eq 'ReadOnlyUninstallPlan' -and
            $beforeWhatIf -eq $afterWhatIf) `
        -Message 'uninstall WhatIf returns a plan without changing its journal'
}
finally {
    if (Test-Path -LiteralPath $temporaryStateRoot) {
        Remove-Item -LiteralPath $temporaryStateRoot -Recurse -Force
    }
}

'DeckLux release tests passed.'
