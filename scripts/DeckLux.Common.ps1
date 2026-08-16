# Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
# Licensed under the Microsoft Public License (MS-PL).

Set-StrictMode -Version Latest

$script:DeckLuxExpectedProvider = 'DeckLux Project'
$script:DeckLuxExpectedInfName = 'DeckLuxSensor.inf'
$script:DeckLuxProductVersion = '1.1.0'
$script:DeckLuxHardwareId = 'ACPI\PRP0001'
$script:DeckLuxOptInPropertyGuid = [Guid]'91b118a2-7b5d-4689-a5e7-c43e332b4966'
$script:DeckLuxOptInPropertyPid = 2
$script:DeckLuxCalibrationPropertyGuid = [Guid]'91b118a2-7b5d-4689-a5e7-c43e332b4966'
$script:DeckLuxCalibrationScalePropertyPid = 3
$script:DeckLuxCalibrationScalePpmDenominator = 1000000
$script:DeckLuxCalibrationScalePpmMinimum = 10000
$script:DeckLuxCalibrationScalePpmMaximum = 100000000
$script:DeckLuxCalibrationTransform = 'valve-legacy-lux-to-datasheet-lux-v1'

function Get-DeckLuxProjectRoot {
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Get-DeckLuxDefaultPackagePath {
    $root = Get-DeckLuxProjectRoot
    $candidates = @(
        (Join-Path $root 'driver\DeckLux.Sensor'),
        (Join-Path $root 'src\x64\Release\DeckLux.Sensor'),
        (Join-Path $root 'src\x64\Debug\DeckLux.Sensor'))
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    return [IO.Path]::GetFullPath($candidates[0])
}

function Get-DeckLuxDefaultStatePath {
    return [IO.Path]::GetFullPath((Join-Path `
        ([Environment]::GetFolderPath('CommonApplicationData')) `
        'DeckLux\install-state.json'))
}

function Test-DeckLuxAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-DeckLuxAdministrator {
    if (-not (Test-DeckLuxAdministrator)) {
        throw 'This operation requires a 64-bit PowerShell window opened with Run as administrator.'
    }
}

function Assert-DeckLux64Bit {
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'DeckLux supports only 64-bit Windows.'
    }

    if (-not [Environment]::Is64BitProcess) {
        throw 'Run this script from 64-bit PowerShell, not a 32-bit host.'
    }
}

function Resolve-DeckLuxPlatformProduct {
    param(
        [AllowEmptyString()][string]$SystemManufacturer,
        [AllowEmptyString()][string]$SystemProductName,
        [AllowEmptyString()][string]$BaseBoardManufacturer,
        [AllowEmptyString()][string]$BaseBoardProduct
    )

    $knownProducts = @('Jupiter', 'Galileo')
    $isKnownSystem = $SystemManufacturer -ieq 'Valve' -and
        $knownProducts -icontains $SystemProductName
    $isKnownBoard = $BaseBoardManufacturer -ieq 'Valve' -and
        $knownProducts -icontains $BaseBoardProduct

    if ($isKnownSystem -and $isKnownBoard -and
        $SystemProductName -ine $BaseBoardProduct) {
        throw ("DeckLux found conflicting Valve platform identities: system " +
            "'$SystemProductName', baseboard '$BaseBoardProduct'.")
    }

    if ($isKnownSystem) {
        return $SystemProductName
    }
    if ($isKnownBoard) {
        return $BaseBoardProduct
    }
    return $null
}

function Get-DeckLuxPlatformSnapshot {
    $biosPath = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
    try {
        $bios = Get-ItemProperty -LiteralPath $biosPath -ErrorAction Stop
    }
    catch {
        throw "DeckLux could not read the Windows firmware identity at '${biosPath}': $($_.Exception.Message)"
    }

    $readText = {
        param([string]$Name)
        $property = $bios.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) {
            return ''
        }
        return [string]$property.Value
    }

    $systemManufacturer = & $readText 'SystemManufacturer'
    $systemProductName = & $readText 'SystemProductName'
    $baseBoardManufacturer = & $readText 'BaseBoardManufacturer'
    $baseBoardProduct = & $readText 'BaseBoardProduct'
    $deckProduct = Resolve-DeckLuxPlatformProduct `
        -SystemManufacturer $systemManufacturer `
        -SystemProductName $systemProductName `
        -BaseBoardManufacturer $baseBoardManufacturer `
        -BaseBoardProduct $baseBoardProduct

    return [pscustomobject][ordered]@{
        SystemManufacturer = $systemManufacturer
        SystemProductName = $systemProductName
        SystemFamily = & $readText 'SystemFamily'
        BaseBoardManufacturer = $baseBoardManufacturer
        BaseBoardProduct = $baseBoardProduct
        BiosVersion = & $readText 'BIOSVersion'
        DeckProduct = $deckProduct
        IsKnownSteamDeck = $null -ne $deckProduct
    }
}

function Import-DeckLuxNativeMethods {
    if ('DeckLux.NativeMethods' -as [type]) {
        return
    }

    $nativeSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace DeckLux
{
    public sealed class DevicePropertyValue
    {
        public bool Present { get; set; }
        public UInt32 PropertyType { get; set; }
        public byte[] Data { get; set; }
    }

    public static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct SP_DEVINFO_DATA
        {
            public UInt32 cbSize;
            public Guid ClassGuid;
            public UInt32 DevInst;
            public UIntPtr Reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DEVPROPKEY
        {
            public Guid fmtid;
            public UInt32 pid;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SYSTEM_CODEINTEGRITY_INFORMATION
        {
            public UInt32 Length;
            public UInt32 CodeIntegrityOptions;
        }

        private const UInt32 DIIDFLAG_INSTALLNULLDRIVER = 0x00000004;
        private const UInt32 DEVPROP_TYPE_EMPTY = 0x00000000;
        private const UInt32 DEVPROP_TYPE_UINT32 = 0x00000007;
        private const UInt32 DEVPROP_TYPE_BOOLEAN = 0x00000011;
        private const byte DEVPROP_TRUE = 0xFF;
        private const int ERROR_INSUFFICIENT_BUFFER = 122;
        private const int ERROR_NOT_FOUND = 1168;
        private const int SystemCodeIntegrityInformation = 103;
        private const UInt32 CODEINTEGRITY_OPTION_TESTSIGN = 0x00000002;

        private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern IntPtr SetupDiCreateDeviceInfoList(
            IntPtr ClassGuid,
            IntPtr hwndParent);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetupDiOpenDeviceInfoW(
            IntPtr DeviceInfoSet,
            string DeviceInstanceId,
            IntPtr hwndParent,
            UInt32 OpenFlags,
            ref SP_DEVINFO_DATA DeviceInfoData);

        [DllImport("setupapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetupDiDestroyDeviceInfoList(
            IntPtr DeviceInfoSet);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetupDiSetDevicePropertyW(
            IntPtr DeviceInfoSet,
            ref SP_DEVINFO_DATA DeviceInfoData,
            ref DEVPROPKEY PropertyKey,
            UInt32 PropertyType,
            byte[] PropertyBuffer,
            UInt32 PropertyBufferSize,
            UInt32 Flags);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetupDiGetDevicePropertyW(
            IntPtr DeviceInfoSet,
            ref SP_DEVINFO_DATA DeviceInfoData,
            ref DEVPROPKEY PropertyKey,
            out UInt32 PropertyType,
            byte[] PropertyBuffer,
            UInt32 PropertyBufferSize,
            out UInt32 RequiredSize,
            UInt32 Flags);

        [DllImport("newdev.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DiInstallDevice(
            IntPtr hwndParent,
            IntPtr DeviceInfoSet,
            ref SP_DEVINFO_DATA DeviceInfoData,
            IntPtr DriverInfoData,
            UInt32 Flags,
            [MarshalAs(UnmanagedType.Bool)] out bool NeedReboot);

        [DllImport("ntdll.dll")]
        private static extern int NtQuerySystemInformation(
            int SystemInformationClass,
            ref SYSTEM_CODEINTEGRITY_INFORMATION SystemInformation,
            UInt32 SystemInformationLength,
            out UInt32 ReturnLength);

        private static IntPtr OpenDevice(string instanceId, out SP_DEVINFO_DATA data)
        {
            IntPtr set = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
            if (set == InvalidHandleValue)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "SetupDiCreateDeviceInfoList failed");
            }

            data = new SP_DEVINFO_DATA();
            data.cbSize = (UInt32)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            if (!SetupDiOpenDeviceInfoW(set, instanceId, IntPtr.Zero, 0, ref data))
            {
                int error = Marshal.GetLastWin32Error();
                SetupDiDestroyDeviceInfoList(set);
                throw new Win32Exception(error,
                    "SetupDiOpenDeviceInfo failed for " + instanceId);
            }

            return set;
        }

        public static bool InstallDevice(string instanceId, bool installNullDriver)
        {
            SP_DEVINFO_DATA data;
            IntPtr set = OpenDevice(instanceId, out data);
            try
            {
                bool needReboot;
                UInt32 flags = installNullDriver ? DIIDFLAG_INSTALLNULLDRIVER : 0;
                if (!DiInstallDevice(
                    IntPtr.Zero,
                    set,
                    ref data,
                    IntPtr.Zero,
                    flags,
                    out needReboot))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "DiInstallDevice failed for " + instanceId);
                }

                return needReboot;
            }
            finally
            {
                SetupDiDestroyDeviceInfoList(set);
            }
        }

        public static void SetOptInProperty(string instanceId, Guid propertyGuid, UInt32 propertyPid, bool enabled)
        {
            SP_DEVINFO_DATA data;
            IntPtr set = OpenDevice(instanceId, out data);
            try
            {
                DEVPROPKEY key = new DEVPROPKEY();
                key.fmtid = propertyGuid;
                key.pid = propertyPid;
                byte[] value = enabled ? new byte[] { DEVPROP_TRUE } : null;
                UInt32 propertyType = enabled ? DEVPROP_TYPE_BOOLEAN : DEVPROP_TYPE_EMPTY;
                UInt32 valueLength = enabled ? 1U : 0U;

                if (!SetupDiSetDevicePropertyW(
                    set,
                    ref data,
                    ref key,
                    propertyType,
                    value,
                    valueLength,
                    0))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "SetupDiSetDeviceProperty failed for " + instanceId);
                }
            }
            finally
            {
                SetupDiDestroyDeviceInfoList(set);
            }
        }

        public static int GetBooleanProperty(string instanceId, Guid propertyGuid, UInt32 propertyPid)
        {
            SP_DEVINFO_DATA data;
            IntPtr set = OpenDevice(instanceId, out data);
            try
            {
                DEVPROPKEY key = new DEVPROPKEY();
                key.fmtid = propertyGuid;
                key.pid = propertyPid;
                byte[] value = new byte[1];
                UInt32 propertyType;
                UInt32 requiredSize;
                if (!SetupDiGetDevicePropertyW(
                    set,
                    ref data,
                    ref key,
                    out propertyType,
                    value,
                    1,
                    out requiredSize,
                    0))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error == ERROR_NOT_FOUND)
                    {
                        return -1;
                    }
                    throw new Win32Exception(error,
                        "SetupDiGetDeviceProperty failed for " + instanceId);
                }

                if (propertyType != DEVPROP_TYPE_BOOLEAN || requiredSize != 1)
                {
                    throw new InvalidOperationException(
                        "The DeckLux opt-in property has an unexpected type or size on " + instanceId);
                }

                return value[0] == 0 ? 0 : 1;
            }
            finally
            {
                SetupDiDestroyDeviceInfoList(set);
            }
        }

        public static DevicePropertyValue GetDeviceProperty(
            string instanceId,
            Guid propertyGuid,
            UInt32 propertyPid)
        {
            SP_DEVINFO_DATA data;
            IntPtr set = OpenDevice(instanceId, out data);
            try
            {
                DEVPROPKEY key = new DEVPROPKEY();
                key.fmtid = propertyGuid;
                key.pid = propertyPid;
                UInt32 propertyType;
                UInt32 requiredSize;

                if (!SetupDiGetDevicePropertyW(
                    set,
                    ref data,
                    ref key,
                    out propertyType,
                    null,
                    0,
                    out requiredSize,
                    0))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error == ERROR_NOT_FOUND)
                    {
                        return new DevicePropertyValue
                        {
                            Present = false,
                            PropertyType = DEVPROP_TYPE_EMPTY,
                            Data = new byte[0]
                        };
                    }

                    if (error != ERROR_INSUFFICIENT_BUFFER)
                    {
                        throw new Win32Exception(error,
                            "SetupDiGetDeviceProperty size query failed for " + instanceId);
                    }
                }

                byte[] value = requiredSize == 0
                    ? new byte[0]
                    : new byte[requiredSize];
                if (requiredSize != 0 && !SetupDiGetDevicePropertyW(
                    set,
                    ref data,
                    ref key,
                    out propertyType,
                    value,
                    (UInt32)value.Length,
                    out requiredSize,
                    0))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "SetupDiGetDeviceProperty failed for " + instanceId);
                }

                if (requiredSize < value.Length)
                {
                    Array.Resize(ref value, (int)requiredSize);
                }

                return new DevicePropertyValue
                {
                    Present = true,
                    PropertyType = propertyType,
                    Data = value
                };
            }
            finally
            {
                SetupDiDestroyDeviceInfoList(set);
            }
        }

        public static void SetDeviceProperty(
            string instanceId,
            Guid propertyGuid,
            UInt32 propertyPid,
            UInt32 propertyType,
            byte[] value)
        {
            SP_DEVINFO_DATA data;
            IntPtr set = OpenDevice(instanceId, out data);
            try
            {
                DEVPROPKEY key = new DEVPROPKEY();
                key.fmtid = propertyGuid;
                key.pid = propertyPid;
                byte[] actualValue = value ?? new byte[0];

                if (!SetupDiSetDevicePropertyW(
                    set,
                    ref data,
                    ref key,
                    propertyType,
                    actualValue.Length == 0 ? null : actualValue,
                    (UInt32)actualValue.Length,
                    0))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "SetupDiSetDeviceProperty failed for " + instanceId);
                }
            }
            finally
            {
                SetupDiDestroyDeviceInfoList(set);
            }
        }

        public static void SetUInt32Property(
            string instanceId,
            Guid propertyGuid,
            UInt32 propertyPid,
            UInt32 value)
        {
            SetDeviceProperty(
                instanceId,
                propertyGuid,
                propertyPid,
                DEVPROP_TYPE_UINT32,
                BitConverter.GetBytes(value));
        }

        public static Int64 GetUInt32Property(
            string instanceId,
            Guid propertyGuid,
            UInt32 propertyPid)
        {
            DevicePropertyValue property = GetDeviceProperty(
                instanceId,
                propertyGuid,
                propertyPid);
            if (!property.Present)
            {
                return -1;
            }
            if (property.PropertyType != DEVPROP_TYPE_UINT32 ||
                property.Data == null ||
                property.Data.Length != 4)
            {
                throw new InvalidOperationException(
                    "The DeckLux calibration property has an unexpected type or size on " + instanceId);
            }
            return (Int64)BitConverter.ToUInt32(property.Data, 0);
        }

        public static void DeleteProperty(
            string instanceId,
            Guid propertyGuid,
            UInt32 propertyPid)
        {
            SetDeviceProperty(
                instanceId,
                propertyGuid,
                propertyPid,
                DEVPROP_TYPE_EMPTY,
                null);
        }

        public static bool IsTestSigningEnabled()
        {
            SYSTEM_CODEINTEGRITY_INFORMATION information =
                new SYSTEM_CODEINTEGRITY_INFORMATION();
            information.Length = (UInt32)Marshal.SizeOf(
                typeof(SYSTEM_CODEINTEGRITY_INFORMATION));
            UInt32 returnLength;
            int status = NtQuerySystemInformation(
                SystemCodeIntegrityInformation,
                ref information,
                information.Length,
                out returnLength);

            if (status != 0)
            {
                throw new InvalidOperationException(
                    "NtQuerySystemInformation(SystemCodeIntegrityInformation) failed with NTSTATUS 0x" +
                    status.ToString("X8"));
            }

            return (information.CodeIntegrityOptions & CODEINTEGRITY_OPTION_TESTSIGN) != 0;
        }
    }
}
'@

    Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
}

function Test-DeckLuxTestSigningEnabled {
    Import-DeckLuxNativeMethods
    return [DeckLux.NativeMethods]::IsTestSigningEnabled()
}

function Test-DeckLuxCalibrationScalePpm {
    param([Parameter(Mandatory = $true)][long]$ScalePpm)

    return $ScalePpm -ge $script:DeckLuxCalibrationScalePpmMinimum -and
        $ScalePpm -le $script:DeckLuxCalibrationScalePpmMaximum
}

function Resolve-DeckLuxBindingTransition {
    param(
        [Parameter(Mandatory = $true)][bool]$WasAlreadyBoundToPackage,
        [Parameter(Mandatory = $true)][bool]$WasOwnedByInstaller
    )

    return [pscustomobject][ordered]@{
        BoundByInstaller = if ($WasAlreadyBoundToPackage) {
            $WasOwnedByInstaller
        }
        else {
            $true
        }
        ChangedThisRun = -not $WasAlreadyBoundToPackage
    }
}

function Get-DeckLuxCalibrationPropertySnapshot {
    param([Parameter(Mandatory = $true)][string]$InstanceId)

    Import-DeckLuxNativeMethods
    $property = [DeckLux.NativeMethods]::GetDeviceProperty(
        $InstanceId,
        $script:DeckLuxCalibrationPropertyGuid,
        $script:DeckLuxCalibrationScalePropertyPid)
    $data = [byte[]]@($property.Data)
    $scalePpm = $null
    $valid = $false
    $validationError = $null

    if (-not $property.Present) {
        $validationError = 'Property is absent.'
    }
    elseif ([uint32]$property.PropertyType -ne 0x00000007) {
        $validationError = "Expected DEVPROP_TYPE_UINT32 (0x7), found 0x$(([uint32]$property.PropertyType).ToString('X'))."
    }
    elseif ($data.Length -ne 4) {
        $validationError = "Expected a four-byte UINT32, found $($data.Length) bytes."
    }
    else {
        $scalePpm = [BitConverter]::ToUInt32($data, 0)
        $valid = Test-DeckLuxCalibrationScalePpm -ScalePpm ([long]$scalePpm)
        if (-not $valid) {
            $validationError = "Calibration '$scalePpm' ppm is outside the supported range."
        }
    }

    return [pscustomobject][ordered]@{
        Present = [bool]$property.Present
        PropertyType = [uint32]$property.PropertyType
        DataBase64 = [Convert]::ToBase64String($data)
        ScalePpm = $scalePpm
        Valid = [bool]$valid
        ValidationError = $validationError
    }
}

function Set-DeckLuxCalibrationScaleProperty {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][uint32]$ScalePpm
    )

    if (-not (Test-DeckLuxCalibrationScalePpm -ScalePpm ([long]$ScalePpm))) {
        throw "DeckLux calibration '$ScalePpm' ppm is outside the supported range."
    }
    Import-DeckLuxNativeMethods
    [DeckLux.NativeMethods]::SetUInt32Property(
        $InstanceId,
        $script:DeckLuxCalibrationPropertyGuid,
        $script:DeckLuxCalibrationScalePropertyPid,
        $ScalePpm)
}

function Test-DeckLuxCalibrationPropertyMatches {
    param(
        [Parameter(Mandatory = $true)][psobject]$Snapshot,
        [Parameter(Mandatory = $true)][uint32]$ScalePpm
    )

    $expectedBase64 = [Convert]::ToBase64String(
        [BitConverter]::GetBytes($ScalePpm))
    return $Snapshot.Present -and
        [uint32]$Snapshot.PropertyType -eq 0x00000007 -and
        [string]$Snapshot.DataBase64 -ceq $expectedBase64
}

function Restore-DeckLuxCalibrationProperty {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][psobject]$CalibrationState
    )

    Import-DeckLuxNativeMethods
    if ([bool]$CalibrationState.PreviousPresent) {
        $previousData = [Convert]::FromBase64String(
            [string]$CalibrationState.PreviousDataBase64)
        [DeckLux.NativeMethods]::SetDeviceProperty(
            $InstanceId,
            $script:DeckLuxCalibrationPropertyGuid,
            $script:DeckLuxCalibrationScalePropertyPid,
            [uint32]$CalibrationState.PreviousPropertyType,
            $previousData)
    }
    else {
        [DeckLux.NativeMethods]::DeleteProperty(
            $InstanceId,
            $script:DeckLuxCalibrationPropertyGuid,
            $script:DeckLuxCalibrationScalePropertyPid)
    }

    $restored = Get-DeckLuxCalibrationPropertySnapshot -InstanceId $InstanceId
    if ([bool]$CalibrationState.PreviousPresent) {
        if (-not $restored.Present -or
            [uint32]$restored.PropertyType -ne [uint32]$CalibrationState.PreviousPropertyType -or
            [string]$restored.DataBase64 -cne [string]$CalibrationState.PreviousDataBase64) {
            throw "DeckLux could not verify restoration of the prior calibration property on '$InstanceId'."
        }
    }
    elseif ($restored.Present) {
        throw "DeckLux could not verify removal of its calibration property on '$InstanceId'."
    }
}

function Invoke-DeckLuxPnpUtil {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    $pnpUtil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $pnpUtil @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "PnPUtil failed with exit code $exitCode.`n$($output -join [Environment]::NewLine)"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function ConvertFrom-DeckLuxPnpCsv {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines,

        [Parameter(Mandatory = $true)]
        [string]$FirstColumn
    )

    $headerIndex = -1
    for ($index = 0; $index -lt $Lines.Count; ++$index) {
        if ($Lines[$index] -match ('^' + [regex]::Escape($FirstColumn) + ',')) {
            $headerIndex = $index
            break
        }
    }

    if ($headerIndex -lt 0) {
        return @()
    }

    $csvLines = @($Lines[$headerIndex..($Lines.Count - 1)] |
        Where-Object { $_ -match ',' })
    if ($csvLines.Count -lt 1) {
        return @()
    }

    return @($csvLines | ConvertFrom-Csv)
}

function Get-DeckLuxMatchingInstanceIds {
    $result = Invoke-DeckLuxPnpUtil -Arguments @(
        '/enum-devices',
        '/deviceid',
        $script:DeckLuxHardwareId,
        '/format',
        'csv')

    $rows = ConvertFrom-DeckLuxPnpCsv -Lines $result.Output -FirstColumn 'InstanceId'
    return @($rows |
        Where-Object { $_.InstanceId -like 'ACPI\PRP0001\*' } |
        ForEach-Object { [string]$_.InstanceId } |
        Sort-Object -Unique)
}

function Get-DeckLuxDevicePropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId,

        [Parameter(Mandatory = $true)]
        [string]$KeyName
    )

    try {
        $property = Get-PnpDeviceProperty `
            -InstanceId $InstanceId `
            -KeyName $KeyName `
            -ErrorAction Stop
        return $property.Data
    }
    catch {
        return $null
    }
}

function Get-DeckLuxRoleFromBiosName {
    param([AllowNull()][string]$BiosDeviceName)

    if ([string]::IsNullOrWhiteSpace($BiosDeviceName)) {
        return 'Unknown'
    }

    $leaf = ($BiosDeviceName -split '\.')[-1]
    if ($leaf -ieq 'LTRF') {
        return 'Primary'
    }

    if ($leaf -ieq 'LTRS') {
        return 'Secondary'
    }

    return 'CompatibleOptIn'
}

function Get-DeckLuxDeviceSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId
    )

    $device = $null
    try {
        $device = Get-PnpDevice -InstanceId $InstanceId -ErrorAction Stop
    }
    catch {
        throw "Device '$InstanceId' is not present or cannot be queried: $($_.Exception.Message)"
    }

    $biosName = Get-DeckLuxDevicePropertyValue `
        -InstanceId $InstanceId `
        -KeyName 'DEVPKEY_Device_BiosDeviceName'
    $hardwareIds = @(Get-DeckLuxDevicePropertyValue `
        -InstanceId $InstanceId `
        -KeyName 'DEVPKEY_Device_HardwareIds')
    $problemCode = Get-DeckLuxDevicePropertyValue `
        -InstanceId $InstanceId `
        -KeyName 'DEVPKEY_Device_ProblemCode'
    $driverInf = Get-DeckLuxDevicePropertyValue `
        -InstanceId $InstanceId `
        -KeyName 'DEVPKEY_Device_DriverInfPath'
    $driverVersion = Get-DeckLuxDevicePropertyValue `
        -InstanceId $InstanceId `
        -KeyName 'DEVPKEY_Device_DriverVersion'
    $service = Get-DeckLuxDevicePropertyValue `
        -InstanceId $InstanceId `
        -KeyName 'DEVPKEY_Device_Service'
    $isPresent = Get-DeckLuxDevicePropertyValue `
        -InstanceId $InstanceId `
        -KeyName 'DEVPKEY_Device_IsPresent'
    $calibrationProperty = $null
    $calibrationPropertyError = $null
    try {
        $calibrationProperty = Get-DeckLuxCalibrationPropertySnapshot `
            -InstanceId $InstanceId
    }
    catch {
        $calibrationPropertyError = $_.Exception.Message
    }

    return [pscustomobject][ordered]@{
        InstanceId = [string]$device.InstanceId
        BiosDeviceName = [string]$biosName
        Role = Get-DeckLuxRoleFromBiosName -BiosDeviceName ([string]$biosName)
        Present = if ($null -eq $isPresent) { $true } else { [bool]$isPresent }
        Status = [string]$device.Status
        Class = [string]$device.Class
        FriendlyName = [string]$device.FriendlyName
        ProblemCode = if ($null -eq $problemCode) { $null } else { [uint32]$problemCode }
        DriverInfPath = [string]$driverInf
        DriverVersion = [string]$driverVersion
        Service = [string]$service
        HardwareIds = @($hardwareIds | ForEach-Object { [string]$_ })
        CalibrationScalePpm = if ($null -ne $calibrationProperty -and
            $calibrationProperty.Valid) {
            [uint32]$calibrationProperty.ScalePpm
        }
        else {
            $null
        }
        CalibrationPropertyPresent = if ($null -eq $calibrationProperty) {
            $null
        }
        else {
            [bool]$calibrationProperty.Present
        }
        CalibrationPropertyType = if ($null -eq $calibrationProperty) {
            $null
        }
        else {
            [uint32]$calibrationProperty.PropertyType
        }
        CalibrationPropertyDataBase64 = if ($null -eq $calibrationProperty) {
            $null
        }
        else {
            [string]$calibrationProperty.DataBase64
        }
        CalibrationPropertyError = $calibrationPropertyError
    }
}

function Assert-DeckLuxTargetSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Snapshot,

        [switch]$AllowCompatibleSensor
    )

    if (-not $Snapshot.Present) {
        throw "Device '$($Snapshot.InstanceId)' is not presently connected."
    }

    if ($Snapshot.InstanceId -notlike 'ACPI\PRP0001\*' -or
        $Snapshot.HardwareIds -notcontains $script:DeckLuxHardwareId) {
        throw "Device '$($Snapshot.InstanceId)' does not expose the required ACPI\PRP0001 hardware ID."
    }

    if ($Snapshot.Role -eq 'CompatibleOptIn' -and -not $AllowCompatibleSensor) {
        throw "Device '$($Snapshot.InstanceId)' has BIOS name '$($Snapshot.BiosDeviceName)'. Use -AllowCompatibleSensor only after confirming it is an LTR-F216A."
    }

    if ($Snapshot.Role -eq 'Unknown') {
        throw "Device '$($Snapshot.InstanceId)' has no readable BIOS device name; refusing installation."
    }
}

function Get-DeckLuxPublishedDrivers {
    $result = Invoke-DeckLuxPnpUtil -Arguments @(
        '/enum-drivers',
        '/class',
        'Sensor',
        '/format',
        'csv')
    return @(ConvertFrom-DeckLuxPnpCsv -Lines $result.Output -FirstColumn 'DriverName')
}

function Get-DeckLuxPublishedDriver {
    param(
        [AllowNull()][string]$DriverVersion,
        [AllowNull()][string[]]$PreferNewDriverNames
    )

    $matches = @(Get-DeckLuxPublishedDrivers | Where-Object {
        $_.OriginalName -ieq $script:DeckLuxExpectedInfName -and
        $_.ProviderName -ieq $script:DeckLuxExpectedProvider
    })

    if ($matches.Count -eq 0) {
        return $null
    }

    if ($PreferNewDriverNames) {
        $newMatches = @($matches | Where-Object {
            $PreferNewDriverNames -contains [string]$_.DriverName
        })
        if ($newMatches.Count -eq 1) {
            return $newMatches[0]
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DriverVersion)) {
        $versionMatches = @($matches | Where-Object {
            ([string]$_.DriverVersion).Trim().EndsWith($DriverVersion)
        })
        if ($versionMatches.Count -eq 1) {
            return $versionMatches[0]
        }
    }

    if ($matches.Count -eq 1) {
        return $matches[0]
    }

    throw "More than one published DeckLux package matches; remove obsolete packages or specify a clean test environment. Found: $($matches.DriverName -join ', ')"
}

function Find-DeckLuxWdkTool {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('signtool.exe', 'infverif.exe')]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        return [string]$command.Source
    }

    $relativePattern = if ($Name -ieq 'infverif.exe') {
        'Program Files\Windows Kits\10\Tools\*\x64\infverif.exe'
    }
    else {
        'Program Files\Windows Kits\10\bin\*\x64\signtool.exe'
    }

    $candidatePatterns = New-Object System.Collections.Generic.List[string]
    if (${env:ProgramFiles(x86)}) {
        $kitRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
        if ($Name -ieq 'infverif.exe') {
            $candidatePatterns.Add((Join-Path $kitRoot 'Tools\*\x64\infverif.exe'))
        }
        else {
            $candidatePatterns.Add((Join-Path $kitRoot 'bin\*\x64\signtool.exe'))
        }
    }

    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($drive.Root) {
            $candidatePatterns.Add((Join-Path $drive.Root $relativePattern))
        }
    }

    $candidates = @($candidatePatterns | ForEach-Object {
        Get-ChildItem -Path $_ -File -ErrorAction SilentlyContinue
    } | Sort-Object FullName -Descending)

    if ($candidates.Count -gt 0) {
        return [string]$candidates[0].FullName
    }

    return $null
}

function Resolve-DeckLuxPackageFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackagePath,

        [AllowNull()][string]$CertificatePath
    )

    $resolvedPackage = [IO.Path]::GetFullPath($PackagePath)
    if (-not (Test-Path -LiteralPath $resolvedPackage -PathType Container)) {
        throw "Driver package directory not found: $resolvedPackage"
    }

    $inf = Join-Path $resolvedPackage 'DeckLuxSensor.inf'
    $catalog = Join-Path $resolvedPackage 'deckluxsensor.cat'
    $dll = Join-Path $resolvedPackage 'DeckLuxSensor.dll'
    foreach ($requiredFile in @($inf, $catalog, $dll)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required driver package file not found: $requiredFile"
        }
    }

    if ([string]::IsNullOrWhiteSpace($CertificatePath)) {
        $certificateCandidates = @(
            (Join-Path $resolvedPackage 'DeckLuxSensor.cer'),
            (Join-Path (Split-Path $resolvedPackage -Parent) 'DeckLuxSensor.cer'))
        $CertificatePath = $certificateCandidates |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
    }

    if ([string]::IsNullOrWhiteSpace($CertificatePath) -or
        -not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
        throw 'DeckLuxSensor.cer was not found in the package directory or its parent. Supply -CertificatePath explicitly.'
    }

    return [pscustomobject]@{
        PackagePath = $resolvedPackage
        InfPath = [IO.Path]::GetFullPath($inf)
        CatalogPath = [IO.Path]::GetFullPath($catalog)
        DllPath = [IO.Path]::GetFullPath($dll)
        CertificatePath = [IO.Path]::GetFullPath($CertificatePath)
    }
}

function Get-DeckLuxPeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            throw "File is not a PE image: $Path"
        }

        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 6)) {
            throw "File has an invalid PE header offset: $Path"
        }

        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "File has no PE signature: $Path"
        }

        return $reader.ReadUInt16()
    }
    finally {
        $stream.Dispose()
    }
}

function Invoke-DeckLuxExternalTool {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Path @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function Test-DeckLuxPackageInternal {
    param(
        [Parameter(Mandatory = $true)][string]$PackagePath,
        [AllowNull()][string]$CertificatePath,
        [AllowNull()][string]$InfVerifPath,
        [AllowNull()][string]$SignToolPath,
        [switch]$RequireTrustedSignature,
        [switch]$RequireWdkTools
    )

    $files = Resolve-DeckLuxPackageFiles `
        -PackagePath $PackagePath `
        -CertificatePath $CertificatePath
    $warnings = New-Object System.Collections.Generic.List[string]
    $infText = [IO.File]::ReadAllText($files.InfPath)

    $requiredPatterns = [ordered]@{
        'Sensor setup class' = '(?im)^\s*Class\s*=\s*Sensor\s*$'
        'Sensor class GUID' = '(?im)^\s*ClassGuid\s*=\s*\{5175D334-C371-4806-B3BA-71FD53C9258D\}\s*$'
        'DeckLux catalog name' = '(?im)^\s*CatalogFile\s*=\s*DeckLuxSensor\.cat\s*$'
        'generic ACPI model ID' = '(?im)^\s*[^;\r\n]+\s*=\s*[^,]+,\s*ACPI\\PRP0001\s*$'
        'Driver Store destination' = '(?im)^\s*(DefaultDestDir|DeckLux_CopyFiles)\s*=\s*13\s*$'
        'Driver Store UMDF binary' = '(?im)^\s*ServiceBinary\s*=\s*%13%\\DeckLuxSensor\.dll\s*$'
        'SensorsCx extension' = '(?im)^\s*UmdfExtensions\s*=\s*SensorsCx0102\s*$'
        'PnP lockdown' = '(?im)^\s*PnpLockdown\s*=\s*1\s*$'
        'manual-selection exclusion' = '(?im)^\s*ExcludeFromSelect\s*=\s*\*\s*$'
        'dedicated pooled UMDF host' = '(?im)^\s*UmdfHostProcessSharing\s*=\s*ProcessSharingEnabled\s*$'
        'fusion device-group directive' = '(?im)^\s*AddReg\s*=\s*DeckLux_Install\.NT\.HW\.AddReg\s*$'
        'fusion device-group identity' = '(?im)^\s*HKR\s*,\s*"WUDF"\s*,\s*"DeviceGroupId"\s*,\s*0x00000000\s*,\s*"DeckLux\.Sensor\.Fusion"\s*$'
        'direct hardware access declaration' = '(?im)^\s*UmdfDirectHardwareAccess\s*=\s*AllowDirectHardwareAccess\s*$'
        'DeckLux provider string' = '(?im)^\s*ProviderName\s*=\s*"DeckLux Project"\s*$'
        'DeckLux manufacturer string' = '(?im)^\s*ManufacturerName\s*=\s*"DeckLux Project"\s*$'
    }

    foreach ($entry in $requiredPatterns.GetEnumerator()) {
        if ($infText -notmatch $entry.Value) {
            throw "INF validation failed: missing or invalid $($entry.Key)."
        }
    }

    if ($infText -match '(?i)%12%|DefaultDestDir\s*=\s*12') {
        throw 'INF validation failed: package still references legacy DIRID 12.'
    }

    $addRegDirectives = [regex]::Matches(
        $infText,
        '(?im)^\s*AddReg\s*=.*$')
    if ($addRegDirectives.Count -ne 1 -or
        $addRegDirectives[0].Value -notmatch
            '(?i)^\s*AddReg\s*=\s*DeckLux_Install\.NT\.HW\.AddReg\s*$') {
        throw 'INF validation failed: the dedicated fusion device group must be the only AddReg directive.'
    }

    $hkrEntries = [regex]::Matches($infText, '(?im)^\s*HKR\s*,.*$')
    if ($hkrEntries.Count -ne 1 -or
        $hkrEntries[0].Value -notmatch
            '(?i)^\s*HKR\s*,\s*"WUDF"\s*,\s*"DeviceGroupId"\s*,\s*0x00000000\s*,\s*"DeckLux\.Sensor\.Fusion"\s*$') {
        throw 'INF validation failed: the fusion DeviceGroupId must be the only HKR registry entry.'
    }

    if ($infText -match '(?im)^\s*(DelReg|CopyINF|CoInstallers32|UpperFilters|LowerFilters|RunPreSetupCommands)\s*=') {
        throw 'INF validation failed: package contains an unexpected registry, filter, co-installer, or chained-INF directive.'
    }

    $modelSection = [regex]::Match(
        $infText,
        '(?ims)^\s*\[DeckLux_Devices\.NTamd64\.10\.0\.\.\.22000\]\s*(.*?)(?=^\s*\[|\z)')
    if (-not $modelSection.Success) {
        throw 'INF validation failed: the expected AMD64 DeckLux model section was not found.'
    }
    $modelLines = @($modelSection.Groups[1].Value -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith(';') })
    if ($modelLines.Count -ne 1 -or
        $modelLines[0] -notmatch '(?i)^%DeckLux_DevDesc%\s*=\s*DeckLux_Install\s*,\s*ACPI\\PRP0001$') {
        throw 'INF validation failed: the model section must contain only the DeckLux ACPI\PRP0001 mapping.'
    }

    $driverVersionMatch = [regex]::Match(
        $infText,
        '(?im)^\s*DriverVer\s*=\s*[^,]+,\s*([^\s;]+)')
    if (-not $driverVersionMatch.Success) {
        throw 'INF validation failed: DriverVer was not found.'
    }
    $driverVersion = $driverVersionMatch.Groups[1].Value

    $peMachine = Get-DeckLuxPeMachine -Path $files.DllPath
    if ($peMachine -ne 0x8664) {
        throw ('DeckLuxSensor.dll is not AMD64. PE machine value: 0x{0:X4}' -f $peMachine)
    }

    $certificate = New-Object `
        System.Security.Cryptography.X509Certificates.X509Certificate2 `
        -ArgumentList $files.CertificatePath
    $thumbprint = $certificate.Thumbprint.ToUpperInvariant()
    $now = [DateTime]::UtcNow
    if ($now -lt $certificate.NotBefore.ToUniversalTime() -or
        $now -gt $certificate.NotAfter.ToUniversalTime()) {
        throw 'DeckLuxSensor.cer is not currently within its validity period.'
    }

    $catalogSignature = Get-AuthenticodeSignature -LiteralPath $files.CatalogPath
    $dllSignature = Get-AuthenticodeSignature -LiteralPath $files.DllPath
    foreach ($signatureEntry in @(
        [pscustomobject]@{ Name = 'catalog'; Signature = $catalogSignature },
        [pscustomobject]@{ Name = 'DLL'; Signature = $dllSignature })) {
        if ($null -eq $signatureEntry.Signature.SignerCertificate) {
            throw "The $($signatureEntry.Name) has no Authenticode signer certificate."
        }

        if ($signatureEntry.Signature.SignerCertificate.Thumbprint -ine $thumbprint) {
            throw "The $($signatureEntry.Name) signer does not match DeckLuxSensor.cer."
        }

        $untrustedTestSignature = $signatureEntry.Signature.Status -eq 'NotTrusted' -or
            ($signatureEntry.Signature.Status -eq 'UnknownError' -and
             $signatureEntry.Signature.StatusMessage -match '(?i)(not trusted|untrusted root)')
        if ($signatureEntry.Signature.Status -ne 'Valid' -and
            -not $untrustedTestSignature) {
            throw "The $($signatureEntry.Name) signature is invalid: $($signatureEntry.Signature.StatusMessage)"
        }

        if ($RequireTrustedSignature -and $signatureEntry.Signature.Status -ne 'Valid') {
            throw "The $($signatureEntry.Name) signature is not trusted: $($signatureEntry.Signature.StatusMessage)"
        }

        if ($signatureEntry.Signature.Status -ne 'Valid') {
            $warnings.Add(
                "The $($signatureEntry.Name) signature is present but not currently trusted: $($signatureEntry.Signature.Status)")
        }
    }

    if ([string]::IsNullOrWhiteSpace($InfVerifPath)) {
        $InfVerifPath = Find-DeckLuxWdkTool -Name 'infverif.exe'
    }
    if ([string]::IsNullOrWhiteSpace($SignToolPath)) {
        $SignToolPath = Find-DeckLuxWdkTool -Name 'signtool.exe'
    }

    if ([string]::IsNullOrWhiteSpace($InfVerifPath)) {
        if ($RequireWdkTools) {
            throw 'InfVerif.exe was not found.'
        }
        $warnings.Add('InfVerif.exe was not found; WDK INF verification was skipped.')
    }
    else {
        foreach ($mode in @('/w', '/u', '/h')) {
            $verification = Invoke-DeckLuxExternalTool `
                -Path $InfVerifPath `
                -Arguments @($mode, '/v', $files.InfPath)
            if ($verification.ExitCode -ne 0) {
                throw "InfVerif $mode failed.`n$($verification.Output -join [Environment]::NewLine)"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($SignToolPath)) {
        if ($RequireWdkTools) {
            throw 'SignTool.exe was not found.'
        }
        $warnings.Add('SignTool.exe was not found; catalog membership verification was skipped.')
    }
    else {
        foreach ($member in @($files.InfPath, $files.DllPath)) {
            $verification = Invoke-DeckLuxExternalTool `
                -Path $SignToolPath `
                -Arguments @('verify', '/v', '/pa', '/c', $files.CatalogPath, $member)
            if ($verification.ExitCode -ne 0) {
                $membershipText = $verification.Output -join [Environment]::NewLine
                if ($membershipText -notmatch '(?i)File is signed in catalog') {
                    throw "Catalog membership verification failed for '$member'.`n$membershipText"
                }

                if ($RequireTrustedSignature) {
                    throw "Trusted catalog verification failed for '$member'.`n$membershipText"
                }

                $warnings.Add(
                    "Catalog membership is present for '$(Split-Path $member -Leaf)', but trust validation did not pass yet.")
            }
        }
    }

    $hashes = [ordered]@{}
    foreach ($file in @($files.InfPath, $files.CatalogPath, $files.DllPath, $files.CertificatePath)) {
        $hashes[(Split-Path $file -Leaf)] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    }

    return [pscustomobject][ordered]@{
        Valid = $true
        PackagePath = $files.PackagePath
        InfPath = $files.InfPath
        CatalogPath = $files.CatalogPath
        DllPath = $files.DllPath
        CertificatePath = $files.CertificatePath
        CertificateThumbprint = $thumbprint
        CertificateSubject = $certificate.Subject
        CertificateNotAfter = $certificate.NotAfter.ToUniversalTime().ToString('o')
        DriverVersion = $driverVersion
        PeMachine = 'AMD64 (0x8664)'
        CatalogSignatureStatus = [string]$catalogSignature.Status
        DllSignatureStatus = [string]$dllSignature.Status
        InfVerifPath = [string]$InfVerifPath
        SignToolPath = [string]$SignToolPath
        Hashes = [pscustomobject]$hashes
        Warnings = @($warnings)
    }
}

function Write-DeckLuxState {
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = "$fullPath.$PID.tmp"
    try {
        $State | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Read-DeckLuxState {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "DeckLux rollback state was not found: $fullPath"
    }

    $state = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json
    if ($state.SchemaVersion -notin @(1, 2, 3) -or $state.Project -ne 'DeckLux') {
        throw "Rollback state '$fullPath' is not a supported DeckLux state file."
    }

    return $state
}

function Test-DeckLuxCertificateInStore {
    param(
        [Parameter(Mandatory = $true)][string]$Store,
        [Parameter(Mandatory = $true)][string]$Thumbprint
    )

    return Test-Path -LiteralPath "Cert:\LocalMachine\$Store\$Thumbprint"
}

function Remove-DeckLuxCertificateFromStore {
    param(
        [Parameter(Mandatory = $true)][string]$Store,
        [Parameter(Mandatory = $true)][string]$Thumbprint
    )

    $path = "Cert:\LocalMachine\$Store\$Thumbprint"
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    }
}
