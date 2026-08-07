// Copyright (c) Microsoft Corporation.
// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
// Licensed under the Microsoft Public License (MS-PL).
//
// Derived in part from the Microsoft Windows Driver Samples ADXL345 SensorCx
// sample.

#include <initguid.h>
#include "Device.h"

// The conservative installer sets this property on each exact devnode selected
// by the operator. Requiring it even for known Deck ACPI names prevents a
// manually applied generic PRP0001 INF from authorizing unrelated hardware.
// The driver still probes PART_ID before its first hardware write.
DEFINE_DEVPROPKEY(
    DEVPKEY_DeckLux_OptIn,
    0x91b118a2, 0x7b5d, 0x4689, 0xa5, 0xe7, 0xc4, 0x3e, 0x33, 0x2b, 0x49, 0x66,
    2);

// Optional UINT32 parts-per-million multiplier applied to the datasheet lux
// value for this exact devnode. Integer persistence avoids locale and binary
// float serialization ambiguity in the installer journal.
DEFINE_DEVPROPKEY(
    DEVPKEY_DeckLux_CalibrationScalePpm,
    0x91b118a2, 0x7b5d, 0x4689, 0xa5, 0xe7, 0xc4, 0x3e, 0x33, 0x2b, 0x49, 0x66,
    3);

namespace
{
NTSTATUS QueryBiosNameFromDeviceInit(
    _In_ PWDFDEVICE_INIT DeviceInit,
    _Out_writes_(BiosNameCount) WCHAR* BiosName,
    _In_ size_t BiosNameCount)
{
    if (DeviceInit == nullptr || BiosName == nullptr || BiosNameCount == 0)
    {
        return STATUS_INVALID_PARAMETER;
    }

    BiosName[0] = L'\0';

    WDF_DEVICE_PROPERTY_DATA propertyData;
    WDF_DEVICE_PROPERTY_DATA_INIT(
        &propertyData,
        &DEVPKEY_Device_BiosDeviceName);

    WDFMEMORY propertyMemory = nullptr;
    DEVPROPTYPE propertyType = DEVPROP_TYPE_EMPTY;
    NTSTATUS status = WdfFdoInitAllocAndQueryPropertyEx(
        DeviceInit,
        &propertyData,
        PagedPool,
        WDF_NO_OBJECT_ATTRIBUTES,
        &propertyMemory,
        &propertyType);

    if (NT_SUCCESS(status))
    {
        size_t propertySize = 0;
        const WCHAR* propertyValue = static_cast<const WCHAR*>(
            WdfMemoryGetBuffer(propertyMemory, &propertySize));

        if (propertyType != DEVPROP_TYPE_STRING ||
            propertyValue == nullptr ||
            propertySize < sizeof(WCHAR))
        {
            status = STATUS_OBJECT_TYPE_MISMATCH;
        }
        else
        {
            status = StringCchCopyW(BiosName, BiosNameCount, propertyValue);
        }

        WdfObjectDelete(propertyMemory);
    }

    return status;
}

bool IsExplicitlyOptedIn(_In_ PWDFDEVICE_INIT DeviceInit)
{
    WDF_DEVICE_PROPERTY_DATA propertyData;
    WDF_DEVICE_PROPERTY_DATA_INIT(&propertyData, &DEVPKEY_DeckLux_OptIn);

    WDFMEMORY propertyMemory = nullptr;
    DEVPROPTYPE propertyType = DEVPROP_TYPE_EMPTY;
    const NTSTATUS status = WdfFdoInitAllocAndQueryPropertyEx(
        DeviceInit,
        &propertyData,
        PagedPool,
        WDF_NO_OBJECT_ATTRIBUTES,
        &propertyMemory,
        &propertyType);

    if (!NT_SUCCESS(status))
    {
        return false;
    }

    size_t propertySize = 0;
    const void* value = WdfMemoryGetBuffer(propertyMemory, &propertySize);
    bool optedIn = false;

    if (propertyType == DEVPROP_TYPE_BOOLEAN &&
        value != nullptr &&
        propertySize >= sizeof(DEVPROP_BOOLEAN))
    {
        optedIn = *static_cast<const DEVPROP_BOOLEAN*>(value) == DEVPROP_TRUE;
    }
    else if (propertyType == DEVPROP_TYPE_UINT32 &&
             value != nullptr &&
             propertySize >= sizeof(ULONG))
    {
        optedIn = *static_cast<const ULONG*>(value) != 0;
    }

    WdfObjectDelete(propertyMemory);
    return optedIn;
}

NTSTATUS GetContextFromDevice(
    _In_ WDFDEVICE Device,
    _Out_ PDLX_SENSOR_CONTEXT* Context)
{
    if (Context == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *Context = nullptr;
    ULONG sensorCount = 1;
    SENSOROBJECT sensorInstance = nullptr;
    NTSTATUS status = SensorsCxDeviceGetSensorList(
        Device,
        &sensorInstance,
        &sensorCount);

    if (!NT_SUCCESS(status) || sensorCount != 1 || sensorInstance == nullptr)
    {
        return NT_SUCCESS(status) ? STATUS_DEVICE_NOT_READY : status;
    }

    *Context = DlxGetSensorContext(sensorInstance);
    return *Context == nullptr ? STATUS_DEVICE_NOT_READY : STATUS_SUCCESS;
}
}

DLX_DEVICE_ROLE DlxRoleFromBiosName(_In_z_ const WCHAR* BiosName)
{
    if (BiosName == nullptr)
    {
        return DLX_DEVICE_ROLE::Standalone;
    }

    const WCHAR* leaf = wcsrchr(BiosName, L'.');
    leaf = leaf == nullptr ? BiosName : leaf + 1;

    if (_wcsicmp(leaf, L"LTRF") == 0)
    {
        return DLX_DEVICE_ROLE::Primary;
    }

    if (_wcsicmp(leaf, L"LTRS") == 0)
    {
        return DLX_DEVICE_ROLE::Secondary;
    }

    return DLX_DEVICE_ROLE::Standalone;
}

bool DlxIsKnownAcpiName(_In_z_ const WCHAR* BiosName)
{
    if (BiosName == nullptr)
    {
        return false;
    }

    const WCHAR* leaf = wcsrchr(BiosName, L'.');
    leaf = leaf == nullptr ? BiosName : leaf + 1;
    return _wcsicmp(leaf, L"LTRF") == 0 || _wcsicmp(leaf, L"LTRS") == 0;
}

NTSTATUS DlxQueryBiosName(
    _In_ WDFDEVICE Device,
    _Out_writes_(BiosNameCount) WCHAR* BiosName,
    _In_ size_t BiosNameCount)
{
    if (Device == nullptr || BiosName == nullptr || BiosNameCount == 0)
    {
        return STATUS_INVALID_PARAMETER;
    }

    BiosName[0] = L'\0';

    WDF_DEVICE_PROPERTY_DATA propertyData;
    WDF_DEVICE_PROPERTY_DATA_INIT(
        &propertyData,
        &DEVPKEY_Device_BiosDeviceName);

    WDF_OBJECT_ATTRIBUTES memoryAttributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&memoryAttributes);
    memoryAttributes.ParentObject = Device;

    WDFMEMORY propertyMemory = nullptr;
    DEVPROPTYPE propertyType = DEVPROP_TYPE_EMPTY;
    NTSTATUS status = WdfDeviceAllocAndQueryPropertyEx(
        Device,
        &propertyData,
        PagedPool,
        &memoryAttributes,
        &propertyMemory,
        &propertyType);

    if (!NT_SUCCESS(status))
    {
        return status;
    }

    size_t propertySize = 0;
    const WCHAR* propertyValue = static_cast<const WCHAR*>(
        WdfMemoryGetBuffer(propertyMemory, &propertySize));

    if (propertyType != DEVPROP_TYPE_STRING ||
        propertyValue == nullptr ||
        propertySize < sizeof(WCHAR))
    {
        status = STATUS_OBJECT_TYPE_MISMATCH;
    }
    else
    {
        status = StringCchCopyW(BiosName, BiosNameCount, propertyValue);
    }

    WdfObjectDelete(propertyMemory);
    return status;
}

NTSTATUS DlxQueryCalibrationScale(
    _In_ WDFDEVICE Device,
    _Out_ ULONG* CalibrationScalePpm)
{
    if (Device == nullptr || CalibrationScalePpm == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *CalibrationScalePpm = DLX_CALIBRATION_SCALE_PPM_DEFAULT;

    WDF_DEVICE_PROPERTY_DATA propertyData;
    WDF_DEVICE_PROPERTY_DATA_INIT(
        &propertyData,
        &DEVPKEY_DeckLux_CalibrationScalePpm);

    WDF_OBJECT_ATTRIBUTES memoryAttributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&memoryAttributes);
    memoryAttributes.ParentObject = Device;

    WDFMEMORY propertyMemory = nullptr;
    DEVPROPTYPE propertyType = DEVPROP_TYPE_EMPTY;
    NTSTATUS status = WdfDeviceAllocAndQueryPropertyEx(
        Device,
        &propertyData,
        PagedPool,
        &memoryAttributes,
        &propertyMemory,
        &propertyType);

    if (!NT_SUCCESS(status))
    {
        return status;
    }

    size_t propertySize = 0;
    const ULONG* propertyValue = static_cast<const ULONG*>(
        WdfMemoryGetBuffer(propertyMemory, &propertySize));

    if (propertyType != DEVPROP_TYPE_UINT32 ||
        propertyValue == nullptr ||
        propertySize != sizeof(ULONG))
    {
        status = STATUS_OBJECT_TYPE_MISMATCH;
    }
    else if (!DlxIsCalibrationScalePpmValid(*propertyValue))
    {
        status = STATUS_INVALID_PARAMETER;
    }
    else
    {
        *CalibrationScalePpm = *propertyValue;
    }

    WdfObjectDelete(propertyMemory);
    return status;
}

NTSTATUS DlxEvtDeviceAdd(
    _In_ WDFDRIVER Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit)
{
    UNREFERENCED_PARAMETER(Driver);

    WCHAR biosName[96] = {};
    const NTSTATUS nameStatus = QueryBiosNameFromDeviceInit(
        DeviceInit,
        biosName,
        ARRAYSIZE(biosName));

    if (!IsExplicitlyOptedIn(DeviceInit))
    {
        DLX_TRACE_WARNING(
            "Refusing unauthorized generic PRP0001 device (BIOS name status 0x%08X)",
            static_cast<ULONG>(nameStatus));
        return STATUS_NOT_SUPPORTED;
    }

    if (!NT_SUCCESS(nameStatus) || !DlxIsKnownAcpiName(biosName))
    {
        DLX_TRACE_WARNING(
            "Using explicitly authorized compatible sensor (BIOS name status 0x%08X)",
            static_cast<ULONG>(nameStatus));
    }

    WdfDeviceInitSetPowerPolicyOwnership(DeviceInit, TRUE);

    WDF_OBJECT_ATTRIBUTES deviceAttributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&deviceAttributes);

    NTSTATUS status = SensorsCxDeviceInitConfig(
        DeviceInit,
        &deviceAttributes,
        0);

    if (!NT_SUCCESS(status))
    {
        DLX_TRACE_ERROR(
            "SensorsCxDeviceInitConfig failed: 0x%08X",
            static_cast<ULONG>(status));
        return status;
    }

    WDF_PNPPOWER_EVENT_CALLBACKS pnpCallbacks;
    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnpCallbacks);
    pnpCallbacks.EvtDevicePrepareHardware = DlxEvtPrepareHardware;
    pnpCallbacks.EvtDeviceReleaseHardware = DlxEvtReleaseHardware;
    pnpCallbacks.EvtDeviceD0Entry = DlxEvtD0Entry;
    pnpCallbacks.EvtDeviceD0Exit = DlxEvtD0Exit;
    WdfDeviceInitSetPnpPowerEventCallbacks(DeviceInit, &pnpCallbacks);

    WDFDEVICE device = nullptr;
    status = WdfDeviceCreate(
        &DeviceInit,
        &deviceAttributes,
        &device);

    if (!NT_SUCCESS(status))
    {
        DLX_TRACE_ERROR("WdfDeviceCreate failed: 0x%08X", static_cast<ULONG>(status));
        return status;
    }

    SENSOR_CONTROLLER_CONFIG sensorConfig;
    SENSOR_CONTROLLER_CONFIG_INIT(&sensorConfig);
    sensorConfig.DriverIsPowerPolicyOwner = WdfUseDefault;
    sensorConfig.EvtSensorStart = DlxEvtSensorStart;
    sensorConfig.EvtSensorStop = DlxEvtSensorStop;
    sensorConfig.EvtSensorGetSupportedDataFields = DlxEvtSensorGetSupportedDataFields;
    sensorConfig.EvtSensorGetDataInterval = DlxEvtSensorGetDataInterval;
    sensorConfig.EvtSensorSetDataInterval = DlxEvtSensorSetDataInterval;
    sensorConfig.EvtSensorGetDataFieldProperties = DlxEvtSensorGetDataFieldProperties;
    sensorConfig.EvtSensorGetDataThresholds = DlxEvtSensorGetDataThresholds;
    sensorConfig.EvtSensorSetDataThresholds = DlxEvtSensorSetDataThresholds;
    sensorConfig.EvtSensorGetProperties = DlxEvtSensorGetProperties;
    sensorConfig.EvtSensorDeviceIoControl = DlxEvtSensorIoControl;

    status = SensorsCxDeviceInitialize(device, &sensorConfig);
    if (!NT_SUCCESS(status))
    {
        DLX_TRACE_ERROR(
            "SensorsCxDeviceInitialize failed: 0x%08X",
            static_cast<ULONG>(status));
        return status;
    }

    WDF_DEVICE_STATE deviceState;
    WDF_DEVICE_STATE_INIT(&deviceState);
    deviceState.NotDisableable = WdfFalse;
    WdfDeviceSetDeviceState(device, &deviceState);

    DLX_TRACE_INFO("Added device at %ls", biosName);
    return STATUS_SUCCESS;
}

NTSTATUS DlxEvtPrepareHardware(
    _In_ WDFDEVICE Device,
    _In_ WDFCMRESLIST ResourcesRaw,
    _In_ WDFCMRESLIST ResourcesTranslated)
{
    UNREFERENCED_PARAMETER(ResourcesRaw);

    WDF_OBJECT_ATTRIBUTES sensorAttributes;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(
        &sensorAttributes,
        DLX_SENSOR_CONTEXT);

    SENSOROBJECT sensorInstance = nullptr;
    NTSTATUS status = SensorsCxSensorCreate(
        Device,
        &sensorAttributes,
        &sensorInstance);

    if (!NT_SUCCESS(status))
    {
        DLX_TRACE_ERROR(
            "SensorsCxSensorCreate failed: 0x%08X",
            static_cast<ULONG>(status));
        return status;
    }

    PDLX_SENSOR_CONTEXT context = DlxGetSensorContext(sensorInstance);
    if (context == nullptr)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    status = DlxInitializeSensorContext(Device, sensorInstance, context);
    if (NT_SUCCESS(status))
    {
        status = DlxConfigureSpbTarget(context, ResourcesTranslated);
    }

    // Probe is deliberately the first I2C operation. No register is written
    // until the device identifies as an LTR-F216A family part.
    if (NT_SUCCESS(status))
    {
        WdfWaitLockAcquire(context->Lock, nullptr);
        status = DlxLtrf216aProbe(context->SpbIoTarget, &context->PartId);
        context->HardwareValidated = NT_SUCCESS(status);
        WdfWaitLockRelease(context->Lock);
    }

    if (NT_SUCCESS(status))
    {
        SENSOR_CONFIG sensorConfig;
        SENSOR_CONFIG_INIT(&sensorConfig);
        sensorConfig.pEnumerationList = context->EnumerationProperties;
        status = SensorsCxSensorInitialize(sensorInstance, &sensorConfig);
    }

    if (!NT_SUCCESS(status))
    {
        DLX_TRACE_ERROR(
            "PrepareHardware failed for %ls: 0x%08X",
            context->BiosName,
            static_cast<ULONG>(status));
    }

    return status;
}

NTSTATUS DlxEvtReleaseHardware(
    _In_ WDFDEVICE Device,
    _In_ WDFCMRESLIST ResourcesTranslated)
{
    UNREFERENCED_PARAMETER(ResourcesTranslated);

    PDLX_SENSOR_CONTEXT context = nullptr;
    NTSTATUS status = GetContextFromDevice(Device, &context);
    if (!NT_SUCCESS(status) || context == nullptr)
    {
        return STATUS_SUCCESS;
    }

    // WDF resources are no longer accessible in ReleaseHardware. D0Exit is
    // the only teardown callback allowed to disable the chip; here we only
    // quiesce software state before closing and deleting the SPB target.
    (void)DlxStopSensor(context, false, false, true);

    if (context->SpbIoTarget != nullptr)
    {
        WdfIoTargetClose(context->SpbIoTarget);
        WdfObjectDelete(context->SpbIoTarget);
        context->SpbIoTarget = nullptr;
    }

    SENSOROBJECT sensorInstance = context->SensorInstance;
    context->SensorInstance = nullptr;
    if (sensorInstance != nullptr)
    {
        WdfObjectDelete(sensorInstance);
    }

    return STATUS_SUCCESS;
}

NTSTATUS DlxEvtD0Entry(
    _In_ WDFDEVICE Device,
    _In_ WDF_POWER_DEVICE_STATE PreviousState)
{
    UNREFERENCED_PARAMETER(PreviousState);

    PDLX_SENSOR_CONTEXT context = nullptr;
    NTSTATUS status = GetContextFromDevice(Device, &context);
    if (NT_SUCCESS(status))
    {
        status = DlxPowerOn(context);
    }

    return status;
}

NTSTATUS DlxEvtD0Exit(
    _In_ WDFDEVICE Device,
    _In_ WDF_POWER_DEVICE_STATE TargetState)
{
    PDLX_SENSOR_CONTEXT context = nullptr;
    NTSTATUS status = GetContextFromDevice(Device, &context);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    // WDF requires the device to remain powered while the hibernation image
    // is prepared. Stop our software timer, but leave the sensor untouched.
    if (TargetState == WdfPowerDevicePrepareForHibernation)
    {
        return DlxStopSensor(context, true, false, false);
    }

    // D3Final can represent removal or shutdown. Do not issue synchronous
    // SPB traffic when the target may already have disappeared. ReleaseHardware
    // sees PoweredOn == false and therefore will not attempt a second write.
    const bool safeToWrite = TargetState != WdfPowerDeviceD3Final;
    return DlxStopSensor(context, true, safeToWrite, true);
}

NTSTATUS DlxConfigureSpbTarget(
    _Inout_ PDLX_SENSOR_CONTEXT Context,
    _In_ WDFCMRESLIST ResourcesTranslated)
{
    if (Context == nullptr || ResourcesTranslated == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    LARGE_INTEGER connectionId = {};
    ULONG connectionCount = 0;
    const ULONG resourceCount = WdfCmResourceListGetCount(ResourcesTranslated);

    for (ULONG index = 0; index < resourceCount; ++index)
    {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR descriptor =
            WdfCmResourceListGetDescriptor(ResourcesTranslated, index);

        if (descriptor != nullptr &&
            descriptor->Type == CmResourceTypeConnection &&
            descriptor->u.Connection.Class == CM_RESOURCE_CONNECTION_CLASS_SERIAL &&
            descriptor->u.Connection.Type == CM_RESOURCE_CONNECTION_TYPE_SERIAL_I2C)
        {
            connectionId.LowPart = descriptor->u.Connection.IdLowPart;
            connectionId.HighPart = descriptor->u.Connection.IdHighPart;
            ++connectionCount;
        }
    }

    if (connectionCount != 1)
    {
        DLX_TRACE_ERROR(
            "Expected exactly one I2C connection, found %lu",
            connectionCount);
        return STATUS_DEVICE_CONFIGURATION_ERROR;
    }

    WDFIOTARGET ioTarget = nullptr;
    NTSTATUS status = WdfIoTargetCreate(
        Context->Device,
        WDF_NO_OBJECT_ATTRIBUTES,
        &ioTarget);

    if (!NT_SUCCESS(status))
    {
        return status;
    }

    WCHAR resourcePath[256] = {};
    status = StringCbPrintfW(
        resourcePath,
        sizeof(resourcePath),
        L"%s\\%0*I64x",
        RESOURCE_HUB_DEVICE_NAME,
        static_cast<unsigned int>(sizeof(LARGE_INTEGER) * 2),
        connectionId.QuadPart);

    if (!NT_SUCCESS(status))
    {
        WdfObjectDelete(ioTarget);
        return status;
    }

    UNICODE_STRING targetName = {};
    targetName.Buffer = resourcePath;
    targetName.Length = static_cast<USHORT>(wcslen(resourcePath) * sizeof(WCHAR));
    targetName.MaximumLength = sizeof(resourcePath);

    WDF_IO_TARGET_OPEN_PARAMS openParams;
    WDF_IO_TARGET_OPEN_PARAMS_INIT_OPEN_BY_NAME(
        &openParams,
        &targetName,
        GENERIC_READ | GENERIC_WRITE);
    openParams.ShareAccess = 0;
    openParams.FileAttributes = FILE_ATTRIBUTE_NORMAL;

    status = WdfIoTargetOpen(ioTarget, &openParams);
    if (!NT_SUCCESS(status))
    {
        DLX_TRACE_ERROR(
            "WdfIoTargetOpen(%ls) failed: 0x%08X",
            resourcePath,
            static_cast<ULONG>(status));
        WdfObjectDelete(ioTarget);
        return status;
    }

    Context->SpbIoTarget = ioTarget;
    return STATUS_SUCCESS;
}

NTSTATUS DlxPowerOn(_Inout_ PDLX_SENSOR_CONTEXT Context)
{
    if (Context == nullptr ||
        Context->SpbIoTarget == nullptr ||
        Context->Lock == nullptr ||
        Context->LifecycleLock == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    // Match Start/Stop lock ordering so D-state changes cannot interleave
    // with a client lifecycle transition.
    WdfWaitLockAcquire(Context->LifecycleLock, nullptr);
    WdfWaitLockAcquire(Context->Lock, nullptr);
    NTSTATUS status = DlxLtrf216aConfigure(
        Context->SpbIoTarget,
        &Context->PartId);

    Context->Started = false;
    Context->ConsecutiveIoFailures = 0;
    Context->ConsecutiveNotReady = 0;
    Context->ConsecutiveNoSample = 0;
    Context->RecoveryAttempts = 0;

    if (NT_SUCCESS(status))
    {
        Context->PoweredOn = true;
        Context->HardwareValidated = true;
        Context->RecoveryPending = false;
        Context->PendingInvalidReport = false;

        if (Context->ClientRequestedStart)
        {
            status = DlxLtrf216aSetEnabled(Context->SpbIoTarget, true);
            Context->Started = true;
            Context->FirstSample = true;
            Context->InvalidSampleReported = false;
            Context->PendingInvalidReport = false;

            if (!NT_SUCCESS(status))
            {
                Context->RecoveryPending = true;
                Context->PendingInvalidReport = true;
                InitPropVariantFromUInt32(
                    SensorState_Error,
                    &Context->SensorProperties->List[DlxSensorState].Value);
            }
            else
            {
                InitPropVariantFromUInt32(
                    SensorState_Active,
                    &Context->SensorProperties->List[DlxSensorState].Value);
            }

            WdfTimerStart(
                Context->Timer,
                WDF_REL_TIMEOUT_IN_MS(DLX_LTRF216A_STARTUP_DELAY_MS));

            // SensorCx will not retry a failed start callback. Once identity
            // is known, transient enable failures are repaired by the timer.
            status = STATUS_SUCCESS;
        }
        else
        {
            InitPropVariantFromUInt32(
                SensorState_Idle,
                &Context->SensorProperties->List[DlxSensorState].Value);
        }
    }
    else if (Context->HardwareValidated)
    {
        // The read-only PrepareHardware probe already established identity.
        // Keep that immutable fact separate from current configuration health
        // and retry safely; each recovery probes again before its first write.
        Context->PoweredOn = true;
        Context->RecoveryPending = true;
        Context->Started = Context->ClientRequestedStart;
        InitPropVariantFromUInt32(
            SensorState_Error,
            &Context->SensorProperties->List[DlxSensorState].Value);

        if (Context->Started)
        {
            Context->FirstSample = true;
            Context->InvalidSampleReported = false;
            Context->PendingInvalidReport = true;
            WdfTimerStart(
                Context->Timer,
                WDF_REL_TIMEOUT_IN_MS(DLX_LTRF216A_STARTUP_DELAY_MS));
        }

        status = STATUS_SUCCESS;
    }
    else
    {
        Context->PoweredOn = false;
        Context->PendingInvalidReport = false;
    }

    WdfWaitLockRelease(Context->Lock);
    WdfWaitLockRelease(Context->LifecycleLock);
    return status;
}
