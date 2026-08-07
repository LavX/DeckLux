# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\scripts\DeckLux.SmbiosCalibration.ps1')

function New-TestSmbiosStructure {
    param(
        [Parameter(Mandatory = $true)]
        [byte]$Type,

        [byte[]]$FormattedTail = @(),

        [string[]]$Strings = @(),

        [UInt16]$Handle = 0
    )

    $bytes = New-Object System.Collections.Generic.List[byte]
    $bytes.Add($Type)
    $bytes.Add([byte](4 + $FormattedTail.Length))
    $bytes.Add([byte]($Handle -band 0xFF))
    $bytes.Add([byte](($Handle -shr 8) -band 0xFF))
    if ($FormattedTail.Length -gt 0) {
        $bytes.AddRange([byte[]]$FormattedTail)
    }

    if ($Strings.Count -eq 0) {
        $bytes.Add(0)
        $bytes.Add(0)
    }
    else {
        foreach ($text in $Strings) {
            $bytes.AddRange([Text.Encoding]::ASCII.GetBytes($text))
            $bytes.Add(0)
        }
        $bytes.Add(0)
    }

    return ,$bytes.ToArray()
}

function New-TestSteamDeckSmbios {
    param(
        [string]$Manufacturer = 'Valve',
        [string]$Product = 'Galileo',
        [string]$Family = 'Sephiroth',
        [string]$BaseBoardManufacturer = 'Valve',
        [string]$BaseBoardProduct = 'Galileo',
        [string[]]$OemStrings = @(
            'sensor-0-metadata',
            '12.5',
            'sensor-1-metadata',
            '11.25',
            'unused'
        ),
        [int]$DeclaredOemCount = -1,
        [switch]$OmitBaseBoard,
        [switch]$OmitEndOfTable,
        [switch]$DuplicateOemStructure
    )

    $table = New-Object System.Collections.Generic.List[byte]

    $type1Tail = New-Object byte[] 23
    $type1Tail[0] = 1
    $type1Tail[1] = 2
    $type1Tail[2] = 3
    $type1Tail[3] = 4
    if ($Family.Length -gt 0) {
        $type1Tail[22] = 5
    }
    $type1Strings = @($Manufacturer, $Product, '1', 'TEST-SERIAL')
    if ($Family.Length -gt 0) {
        $type1Strings += $Family
    }
    $table.AddRange([byte[]](New-TestSmbiosStructure `
                -Type 1 `
                -FormattedTail $type1Tail `
                -Strings $type1Strings `
                -Handle 1))

    if (-not $OmitBaseBoard) {
        $type2Tail = New-Object byte[] 12
        if ($BaseBoardManufacturer.Length -gt 0) {
            $type2Tail[0] = 1
        }
        if ($BaseBoardProduct.Length -gt 0) {
            $type2Tail[1] = if ($BaseBoardManufacturer.Length -gt 0) { 2 } else { 1 }
        }
        $type2Strings = @()
        if ($BaseBoardManufacturer.Length -gt 0) {
            $type2Strings += $BaseBoardManufacturer
        }
        if ($BaseBoardProduct.Length -gt 0) {
            $type2Strings += $BaseBoardProduct
        }
        $table.AddRange([byte[]](New-TestSmbiosStructure `
                    -Type 2 `
                    -FormattedTail $type2Tail `
                    -Strings $type2Strings `
                    -Handle 2))
    }

    $count = if ($DeclaredOemCount -ge 0) {
        $DeclaredOemCount
    }
    else {
        $OemStrings.Count
    }
    $oemStructure = [byte[]](New-TestSmbiosStructure `
            -Type 11 `
            -FormattedTail ([byte[]]@([byte]$count)) `
            -Strings $OemStrings `
            -Handle 0x1C)
    $table.AddRange($oemStructure)
    if ($DuplicateOemStructure) {
        $table.AddRange($oemStructure)
    }

    if (-not $OmitEndOfTable) {
        $table.AddRange([byte[]](New-TestSmbiosStructure -Type 127 -Handle 0x7F00))
    }

    return ,$table.ToArray()
}

Describe 'Get-DeckLuxFactoryCalibration' {
    It 'maps Galileo OEM strings 2 and 4 to LTRF and LTRS in authoritative order' {
        $calibration = @(Get-DeckLuxFactoryCalibration `
                -SmbiosData (New-TestSteamDeckSmbios) `
                -Source 'Pester fixture')

        $calibration.Count | Should Be 2

        $calibration[0].Role | Should Be 'Primary'
        $calibration[0].BiosLeaf | Should Be 'LTRF'
        $calibration[0].InstanceSuffix | Should Be 0
        $calibration[0].OemStringIndex | Should Be 2
        ([Math]::Abs($calibration[0].FactoryGain - 12.5)) |
            Should BeLessThan 0.000000000001
        ([Math]::Abs($calibration[0].ConversionScale - 22.22222222222222)) |
            Should BeLessThan 0.000000000001
        $calibration[0].ScalePpm | Should Be 22222222

        $calibration[1].Role | Should Be 'Secondary'
        $calibration[1].BiosLeaf | Should Be 'LTRS'
        $calibration[1].InstanceSuffix | Should Be 1
        $calibration[1].OemStringIndex | Should Be 4
        ([Math]::Abs($calibration[1].FactoryGain - 11.25)) |
            Should BeLessThan 0.000000000001
        ([Math]::Abs($calibration[1].ConversionScale - 20.0)) |
            Should BeLessThan 0.000000000001
        $calibration[1].ScalePpm | Should Be 20000000

        $calibration[0].Identity.SystemManufacturer | Should Be 'Valve'
        $calibration[0].Identity.SystemProductName | Should Be 'Galileo'
        $calibration[0].Identity.SystemFamily | Should Be 'Sephiroth'
        $calibration[0].Provenance.Source | Should Be 'Pester fixture'
        $calibration[0].Provenance.SmbiosType | Should Be 11
        $calibration[0].Provenance.SmbiosHandle | Should Be 0x1C
        $calibration[0].Provenance.OemStringIndex | Should Be 2
        $calibration[0].Provenance.Formula | Should Be 'FactoryGain * (16.0 / 9.0)'
    }

    It 'maps Jupiter OEM string 2 to its single LTRF instance at suffix 1' {
        $oemStrings = @('sensor-metadata', '9.0')
        $calibration = @(Get-DeckLuxFactoryCalibration `
                -SmbiosData (New-TestSteamDeckSmbios `
                    -Product 'Jupiter' `
                    -Family 'Arbitrary-Jupiter-Family' `
                    -BaseBoardProduct 'Jupiter' `
                    -OemStrings $oemStrings) `
                -Source 'Jupiter Pester fixture')

        $calibration.Count | Should Be 1
        $calibration[0].Role | Should Be 'Primary'
        $calibration[0].BiosLeaf | Should Be 'LTRF'
        $calibration[0].InstanceSuffix | Should Be 1
        $calibration[0].OemStringIndex | Should Be 2
        $calibration[0].FactoryGain | Should Be 9.0
        $calibration[0].ConversionScale | Should Be 16.0
        $calibration[0].ScalePpm | Should Be 16000000
        $calibration[0].Identity.SystemProductName | Should Be 'Jupiter'
        $calibration[0].Identity.SystemFamily | Should Be 'Arbitrary-Jupiter-Family'
        $calibration[0].Identity.BaseBoardProduct | Should Be 'Jupiter'
        $calibration[0].Provenance.Source | Should Be 'Jupiter Pester fixture'
    }

    It 'parses dot-decimal gains with invariant culture' {
        $oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        $oldUiCulture = [Threading.Thread]::CurrentThread.CurrentUICulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture =
                [Globalization.CultureInfo]::GetCultureInfo('hu-HU')
            [Threading.Thread]::CurrentThread.CurrentUICulture =
                [Globalization.CultureInfo]::GetCultureInfo('hu-HU')

            $calibration = @(Get-DeckLuxFactoryCalibration `
                    -SmbiosData (New-TestSteamDeckSmbios))
            ([Math]::Abs($calibration[0].FactoryGain - 12.5)) |
                Should BeLessThan 0.000000000001
        }
        finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture
            [Threading.Thread]::CurrentThread.CurrentUICulture = $oldUiCulture
        }
    }

    It 'returns no calibration for an unsupported identity' {
        $calibration = @(Get-DeckLuxFactoryCalibration `
                -SmbiosData (New-TestSteamDeckSmbios -Product 'Fremont'))
        $calibration.Count | Should Be 0
    }

    It 'tolerates an omitted family and baseboard after exact Type 1 identity' {
        $calibration = @(Get-DeckLuxFactoryCalibration `
                -SmbiosData (New-TestSteamDeckSmbios -Family '' -OmitBaseBoard))
        $calibration.Count | Should Be 2
        $calibration[0].Identity.SystemFamily | Should Be ''
        $calibration[0].Identity.BaseBoardManufacturer | Should Be ''
    }

    It 'rejects a contradictory nonempty Galileo family' {
        { Get-DeckLuxFactoryCalibration `
                -SmbiosData (New-TestSteamDeckSmbios -Family 'Unexpected') } |
            Should Throw
    }

    It 'rejects a contradictory populated Galileo baseboard' {
        { Get-DeckLuxFactoryCalibration `
                -SmbiosData (New-TestSteamDeckSmbios -BaseBoardProduct 'Jupiter') } |
            Should Throw
    }

    It 'rejects a contradictory populated Jupiter baseboard' {
        $oemStrings = @('sensor-metadata', '9.0')
        { Get-DeckLuxFactoryCalibration `
                -SmbiosData (New-TestSteamDeckSmbios `
                    -Product 'Jupiter' `
                    -Family 'Any-Family-Is-Tolerated' `
                    -BaseBoardProduct 'Galileo' `
                    -OemStrings $oemStrings) } |
            Should Throw
    }

    It 'rejects an ambiguous duplicate OEM-strings structure' {
        { Get-DeckLuxFactoryCalibration `
                -SmbiosData (New-TestSteamDeckSmbios -DuplicateOemStructure) } |
            Should Throw
    }

    It 'rejects a mismatched Type 11 declared string count' {
        { Get-DeckLuxFactoryCalibration `
                -SmbiosData (New-TestSteamDeckSmbios -DeclaredOemCount 4) } |
            Should Throw
    }

    It 'rejects a structurally truncated SMBIOS table' {
        $data = New-TestSteamDeckSmbios -OmitEndOfTable
        { Get-DeckLuxFactoryCalibration -SmbiosData $data } | Should Throw
    }

    foreach ($badGain in @('NaN', 'Infinity', '0', '-1', '1,25')) {
        It "rejects invalid invariant gain '$badGain'" {
            $strings = @('sensor-0', $badGain, 'sensor-1', '11.0')
            { Get-DeckLuxFactoryCalibration `
                    -SmbiosData (New-TestSteamDeckSmbios -OemStrings $strings) } |
                Should Throw
        }
    }

    It 'rejects a converted scale below the driver contract' {
        $strings = @('sensor-0', '0.005', 'sensor-1', '11.0')
        { Get-DeckLuxFactoryCalibration `
                -SmbiosData (New-TestSteamDeckSmbios -OemStrings $strings) } |
            Should Throw
    }

    It 'rejects a converted scale above the driver contract' {
        $strings = @('sensor-0', '56.3', 'sensor-1', '11.0')
        { Get-DeckLuxFactoryCalibration `
                -SmbiosData (New-TestSteamDeckSmbios -OemStrings $strings) } |
            Should Throw
    }
}
