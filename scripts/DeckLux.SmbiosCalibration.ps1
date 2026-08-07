# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

Set-StrictMode -Version Latest

$script:DeckLuxMinimumConversionScale = 0.01
$script:DeckLuxMaximumConversionScale = 100.0
$script:DeckLuxCalibrationPpmDenominator = 1000000
$script:DeckLuxFactoryScaleFactor = 16.0 / 9.0

function ConvertFrom-DeckLuxSmbiosTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$SmbiosData
    )

    if ($null -eq $SmbiosData -or $SmbiosData.Length -lt 6) {
        throw 'The raw SMBIOS table is empty or too short to contain a structure.'
    }

    $structures = New-Object System.Collections.Generic.List[object]
    $offset = 0
    $sawEndOfTable = $false

    while ($offset -lt $SmbiosData.Length) {
        if (($SmbiosData.Length - $offset) -lt 4) {
            throw "The raw SMBIOS table has a truncated structure header at offset 0x$('{0:X}' -f $offset)."
        }

        $type = [int]$SmbiosData[$offset]
        $length = [int]$SmbiosData[$offset + 1]
        if ($length -lt 4) {
            throw "SMBIOS structure type ${type} at offset 0x$('{0:X}' -f $offset) has invalid length ${length}."
        }
        if (($offset + $length) -gt $SmbiosData.Length) {
            throw "SMBIOS structure type ${type} at offset 0x$('{0:X}' -f $offset) extends beyond the table."
        }

        $handle = [int]$SmbiosData[$offset + 2] -bor
            ([int]$SmbiosData[$offset + 3] -shl 8)
        $strings = New-Object System.Collections.Generic.List[string]
        $cursor = $offset + $length

        if (($cursor + 1) -ge $SmbiosData.Length) {
            throw "SMBIOS structure type ${type} at offset 0x$('{0:X}' -f $offset) has no double-NUL terminator."
        }

        if ($SmbiosData[$cursor] -eq 0 -and $SmbiosData[$cursor + 1] -eq 0) {
            $cursor += 2
        }
        else {
            while ($true) {
                $stringOffset = $cursor
                while ($cursor -lt $SmbiosData.Length -and $SmbiosData[$cursor] -ne 0) {
                    $cursor++
                }
                if ($cursor -ge $SmbiosData.Length) {
                    throw "SMBIOS structure type ${type} at offset 0x$('{0:X}' -f $offset) has an unterminated string set."
                }

                $strings.Add([Text.Encoding]::ASCII.GetString(
                        $SmbiosData,
                        $stringOffset,
                        $cursor - $stringOffset))

                if (($cursor + 1) -ge $SmbiosData.Length) {
                    throw "SMBIOS structure type ${type} at offset 0x$('{0:X}' -f $offset) has no double-NUL terminator."
                }
                if ($SmbiosData[$cursor + 1] -eq 0) {
                    $cursor += 2
                    break
                }
                $cursor++
            }
        }

        $formatted = New-Object byte[] $length
        [Array]::Copy($SmbiosData, $offset, $formatted, 0, $length)
        $structures.Add([pscustomobject][ordered]@{
                Type = $type
                Length = $length
                Handle = $handle
                Offset = $offset
                Formatted = $formatted
                Strings = [string[]]$strings.ToArray()
            })

        $offset = $cursor
        if ($type -eq 127) {
            $sawEndOfTable = $true
            break
        }
    }

    if (-not $sawEndOfTable) {
        throw 'The raw SMBIOS table does not contain an end-of-table (type 127) structure.'
    }

    while ($offset -lt $SmbiosData.Length) {
        if ($SmbiosData[$offset] -ne 0) {
            throw "The raw SMBIOS table contains nonzero data after the type 127 structure at offset 0x$('{0:X}' -f $offset)."
        }
        $offset++
    }

    return $structures.ToArray()
}

function Get-DeckLuxSmbiosString {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Structure,

        [Parameter(Mandatory = $true)]
        [int]$FormattedOffset,

        [Parameter(Mandatory = $true)]
        [string]$FieldName
    )

    if ($FormattedOffset -lt 0 -or $FormattedOffset -ge $Structure.Length) {
        return ''
    }

    $index = [int]$Structure.Formatted[$FormattedOffset]
    if ($index -eq 0) {
        return ''
    }
    if ($index -gt $Structure.Strings.Count) {
        throw "SMBIOS type $($Structure.Type) field '${FieldName}' references missing string ${index}."
    }

    return [string]$Structure.Strings[$index - 1]
}

function ConvertFrom-DeckLuxInvariantPositiveDouble {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$OemStringIndex
    )

    $value = 0.0
    $styles = [Globalization.NumberStyles]::Float
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse($Text.Trim(), $styles, $culture, [ref]$value)) {
        throw "SMBIOS type 11 OEM string ${OemStringIndex} is not an invariant floating-point ALS gain."
    }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0.0) {
        throw "SMBIOS type 11 OEM string ${OemStringIndex} is not a positive finite ALS gain."
    }

    return $value
}

function Get-DeckLuxLocalRawSmbiosTable {
    [CmdletBinding()]
    param()

    try {
        $rows = @(Get-CimInstance `
                -Namespace 'root\wmi' `
                -ClassName 'MSSmBios_RawSMBiosTables' `
                -ErrorAction Stop)
    }
    catch {
        throw "DeckLux could not read the Windows raw SMBIOS provider: $($_.Exception.Message)"
    }

    if ($rows.Count -ne 1 -or $null -eq $rows[0].SMBiosData) {
        throw "DeckLux expected one Windows raw SMBIOS table, but found $($rows.Count)."
    }

    $data = [byte[]]$rows[0].SMBiosData
    if ($data.Length -eq 0) {
        throw 'The Windows raw SMBIOS provider returned an empty table.'
    }

    return [pscustomobject][ordered]@{
        Data = $data
        Source = "Windows root\wmi:MSSmBios_RawSMBiosTables (SMBIOS $($rows[0].SmbiosMajorVersion).$($rows[0].SmbiosMinorVersion))"
    }
}

function Get-DeckLuxFactoryCalibration {
    <#
    .SYNOPSIS
    Reads factory ALS gains encoded in Valve Steam Deck SMBIOS type 11.

    .DESCRIPTION
    This function is read-only. It accepts a raw SMBIOS table for deterministic
    callers/tests, or reads the Windows MSSmBios_RawSMBiosTables provider when no
    table is supplied. Unsupported identities return no objects. A confirmed
    Jupiter or Galileo with contradictory identity fields or malformed
    calibration data is rejected instead of silently applying an untrusted scale.
    #>
    [CmdletBinding()]
    param(
        [byte[]]$SmbiosData,

        [string]$Source = 'Caller-provided raw SMBIOS table'
    )

    if (-not $PSBoundParameters.ContainsKey('SmbiosData')) {
        $raw = Get-DeckLuxLocalRawSmbiosTable
        $SmbiosData = $raw.Data
        $Source = $raw.Source
    }

    $structures = @(ConvertFrom-DeckLuxSmbiosTable -SmbiosData $SmbiosData)
    $systemStructures = @($structures | Where-Object { $_.Type -eq 1 })
    if ($systemStructures.Count -ne 1) {
        throw "The raw SMBIOS table must contain exactly one system-information (type 1) structure; found $($systemStructures.Count)."
    }

    $system = $systemStructures[0]
    $systemManufacturer = Get-DeckLuxSmbiosString $system 4 'Manufacturer'
    $systemProductName = Get-DeckLuxSmbiosString $system 5 'Product Name'
    $systemFamily = Get-DeckLuxSmbiosString $system 26 'Family'

    $supportedProducts = @('Jupiter', 'Galileo')
    if ($systemManufacturer -cne 'Valve' -or
        $supportedProducts -cnotcontains $systemProductName) {
        return @()
    }

    $isGalileo = $systemProductName -ceq 'Galileo'
    if ($isGalileo -and
        $systemFamily.Length -gt 0 -and
        $systemFamily -cne 'Sephiroth') {
        throw "Confirmed Valve Galileo SMBIOS has contradictory system family '$systemFamily'."
    }

    $baseBoardManufacturer = ''
    $baseBoardProduct = ''
    $baseBoards = @($structures | Where-Object { $_.Type -eq 2 })
    foreach ($baseBoard in $baseBoards) {
        $manufacturer = Get-DeckLuxSmbiosString $baseBoard 4 'Baseboard Manufacturer'
        $product = Get-DeckLuxSmbiosString $baseBoard 5 'Baseboard Product'
        if ($manufacturer.Length -eq 0 -and $product.Length -eq 0) {
            continue
        }
        if ($isGalileo) {
            if ($manufacturer -cne 'Valve' -or $product -cne 'Galileo') {
                throw "Confirmed Valve Galileo SMBIOS has contradictory baseboard identity '$manufacturer'/'$product'."
            }
        }
        elseif (($manufacturer.Length -gt 0 -and $manufacturer -cne 'Valve') -or
            ($product.Length -gt 0 -and $product -cne 'Jupiter')) {
            throw "Confirmed Valve Jupiter SMBIOS has contradictory baseboard identity '$manufacturer'/'$product'."
        }
        $baseBoardManufacturer = $manufacturer
        $baseBoardProduct = $product
    }

    $mapping = if ($isGalileo) {
        @(
            [pscustomobject][ordered]@{
                Role = 'Primary'
                BiosLeaf = 'LTRF'
                InstanceSuffix = 0
                OemStringIndex = 2
            },
            [pscustomobject][ordered]@{
                Role = 'Secondary'
                BiosLeaf = 'LTRS'
                InstanceSuffix = 1
                OemStringIndex = 4
            }
        )
    }
    else {
        @(
            [pscustomobject][ordered]@{
                Role = 'Primary'
                BiosLeaf = 'LTRF'
                InstanceSuffix = 1
                OemStringIndex = 2
            }
        )
    }
    $highestRequiredOemString = if ($isGalileo) { 4 } else { 2 }

    $oemStructures = @($structures | Where-Object { $_.Type -eq 11 })
    if ($oemStructures.Count -ne 1) {
        throw "Confirmed Valve $systemProductName SMBIOS must contain exactly one OEM-strings (type 11) structure; found $($oemStructures.Count)."
    }

    $oem = $oemStructures[0]
    if ($oem.Length -lt 5) {
        throw "The $systemProductName SMBIOS type 11 structure is too short to contain its string count."
    }
    $declaredCount = [int]$oem.Formatted[4]
    if ($declaredCount -ne $oem.Strings.Count) {
        throw "The $systemProductName SMBIOS type 11 count is ${declaredCount}, but $($oem.Strings.Count) strings were parsed."
    }
    if ($declaredCount -lt $highestRequiredOemString) {
        throw "The $systemProductName SMBIOS type 11 structure contains only ${declaredCount} OEM strings; the highest required gain index is ${highestRequiredOemString}."
    }

    $identity = [pscustomobject][ordered]@{
        SystemManufacturer = $systemManufacturer
        SystemProductName = $systemProductName
        SystemFamily = $systemFamily
        BaseBoardManufacturer = $baseBoardManufacturer
        BaseBoardProduct = $baseBoardProduct
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $mapping) {
        $gainText = [string]$oem.Strings[$entry.OemStringIndex - 1]
        $factoryGain = ConvertFrom-DeckLuxInvariantPositiveDouble `
            -Text $gainText `
            -OemStringIndex $entry.OemStringIndex
        $conversionScale = $factoryGain * $script:DeckLuxFactoryScaleFactor
        if ([double]::IsNaN($conversionScale) -or
            [double]::IsInfinity($conversionScale) -or
            $conversionScale -lt $script:DeckLuxMinimumConversionScale -or
            $conversionScale -gt $script:DeckLuxMaximumConversionScale) {
            throw "SMBIOS type 11 OEM string $($entry.OemStringIndex) produces DeckLux scale $conversionScale, outside the supported [0.01, 100.0] range."
        }
        $scalePpm = [uint32][Math]::Round(
            $conversionScale * $script:DeckLuxCalibrationPpmDenominator,
            0,
            [MidpointRounding]::AwayFromZero)

        $provenance = [pscustomobject][ordered]@{
            Source = $Source
            SmbiosType = 11
            SmbiosHandle = $oem.Handle
            SmbiosStructureOffset = $oem.Offset
            OemStringIndex = $entry.OemStringIndex
            RawValue = $gainText
            Formula = 'FactoryGain * (16.0 / 9.0)'
        }

        $results.Add([pscustomobject][ordered]@{
                Role = $entry.Role
                BiosLeaf = $entry.BiosLeaf
                InstanceSuffix = $entry.InstanceSuffix
                OemStringIndex = $entry.OemStringIndex
                FactoryGain = $factoryGain
                ConversionScale = $conversionScale
                ScalePpm = $scalePpm
                Identity = $identity
                Provenance = $provenance
            })
    }

    return $results.ToArray()
}
