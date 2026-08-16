// Copyright (c) Microsoft Corporation.
// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
// Licensed under the Microsoft Public License (MS-PL).
//
// Derived in part from the Microsoft Windows Driver Samples ADXL345 and
// SensorsComboDriver SensorCx examples.

#include "Device.h"

#include <cmath>

namespace
{
VOID DlxEvtCollectionCleanup(_In_ WDFOBJECT Object)
{
    size_t bufferSize = 0;
    auto collection = static_cast<PSENSOR_COLLECTION_LIST>(
        WdfMemoryGetBuffer(reinterpret_cast<WDFMEMORY>(Object), &bufferSize));

    if (collection == nullptr ||
        bufferSize < SENSOR_COLLECTION_LIST_HEADER_SIZE)
    {
        return;
    }

    const ULONG capacity = static_cast<ULONG>(
        (bufferSize - SENSOR_COLLECTION_LIST_HEADER_SIZE) /
        sizeof(SENSOR_VALUE_PAIR));
    const ULONG count = collection->Count < capacity
        ? collection->Count
        : capacity;

    for (ULONG index = 0; index < count; ++index)
    {
        (void)PropVariantClear(&collection->List[index].Value);
    }
}

void CaptureInitializationFailure(
    _Inout_ NTSTATUS* Status,
    _In_ HRESULT Result)
{
    if (Status != nullptr && NT_SUCCESS(*Status) && FAILED(Result))
    {
        *Status = Result == E_OUTOFMEMORY
            ? STATUS_INSUFFICIENT_RESOURCES
            : STATUS_UNSUCCESSFUL;
    }
}

// Steam Deck LTRF (primary) persistent sensor ID:
// {E910DD11-A261-4B13-B038-1DA46313E0DF}
const GUID DlxPrimarySensorId =
{ 0xe910dd11, 0xa261, 0x4b13, { 0xb0, 0x38, 0x1d, 0xa4, 0x63, 0x13, 0xe0, 0xdf } };

// Steam Deck LTRS (secondary) persistent sensor ID:
// {6E9ED2B6-7536-4F0E-B62D-467FAC971A0B}
const GUID DlxSecondarySensorId =
{ 0x6e9ed2b6, 0x7536, 0x4f0e, { 0xb6, 0x2d, 0x46, 0x7f, 0xac, 0x97, 0x1a, 0x0b } };

// Explicitly opted-in standalone LTR-F216A persistent sensor ID:
// {A107114A-B796-4B8B-88AF-5A489987C4D4}
const GUID DlxStandaloneSensorId =
{ 0xa107114a, 0xb796, 0x4b8b, { 0x88, 0xaf, 0x5a, 0x48, 0x99, 0x87, 0xc4, 0xd4 } };

NTSTATUS AllocateCollection(
    _In_ ULONG Count,
    _In_ SENSOROBJECT Parent,
    _Out_ PSENSOR_COLLECTION_LIST* Collection)
{
    if (Parent == nullptr || Collection == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *Collection = nullptr;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    attributes.ParentObject = Parent;
    attributes.EvtCleanupCallback = DlxEvtCollectionCleanup;

    const ULONG size = SENSOR_COLLECTION_LIST_SIZE(Count);
    WDFMEMORY memory = nullptr;
    NTSTATUS status = WdfMemoryCreate(
        &attributes,
        PagedPool,
        DLX_POOL_TAG,
        size,
        &memory,
        reinterpret_cast<void**>(Collection));

    if (!NT_SUCCESS(status) || *Collection == nullptr)
    {
        return NT_SUCCESS(status) ? STATUS_INSUFFICIENT_RESOURCES : status;
    }

    SENSOR_COLLECTION_LIST_INIT(*Collection, size);
    (*Collection)->Count = Count;
    return STATUS_SUCCESS;
}

NTSTATUS AllocatePropertyList(
    _In_ ULONG Count,
    _In_ SENSOROBJECT Parent,
    _Out_ PSENSOR_PROPERTY_LIST* Properties)
{
    if (Parent == nullptr || Properties == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *Properties = nullptr;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    attributes.ParentObject = Parent;

    const ULONG size = SENSOR_PROPERTY_LIST_SIZE(Count);
    WDFMEMORY memory = nullptr;
    NTSTATUS status = WdfMemoryCreate(
        &attributes,
        PagedPool,
        DLX_POOL_TAG,
        size,
        &memory,
        reinterpret_cast<void**>(Properties));

    if (!NT_SUCCESS(status) || *Properties == nullptr)
    {
        return NT_SUCCESS(status) ? STATUS_INSUFFICIENT_RESOURCES : status;
    }

    SENSOR_PROPERTY_LIST_INIT(*Properties, size);
    (*Properties)->Count = Count;
    return STATUS_SUCCESS;
}

const GUID& PersistentIdForRole(_In_ DLX_DEVICE_ROLE Role)
{
    if (Role == DLX_DEVICE_ROLE::Primary)
    {
        return DlxPrimarySensorId;
    }

    if (Role == DLX_DEVICE_ROLE::Secondary)
    {
        return DlxSecondarySensorId;
    }

    return DlxStandaloneSensorId;
}

const WCHAR* ModelForRole(_In_ DLX_DEVICE_ROLE Role)
{
    if (Role == DLX_DEVICE_ROLE::Primary)
    {
        return L"LTR-F216A (preferred; fused when paired)";
    }

    if (Role == DLX_DEVICE_ROLE::Secondary)
    {
        return L"LTR-F216A (LTRS)";
    }

    return L"LTR-F216A";
}

NTSTATUS CopyPropertyList(
    _In_ PSENSOR_PROPERTY_LIST Source,
    _Inout_opt_ PSENSOR_PROPERTY_LIST Destination,
    _Out_ PULONG Size)
{
    if (Source == nullptr || Size == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *Size = Source->AllocatedSizeInBytes;
    if (Destination == nullptr)
    {
        return STATUS_SUCCESS;
    }

    if (Destination->AllocatedSizeInBytes < Source->AllocatedSizeInBytes)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    return PropertiesListCopy(Destination, Source);
}

NTSTATUS CopyCollection(
    _In_ PSENSOR_COLLECTION_LIST Source,
    _Inout_opt_ PSENSOR_COLLECTION_LIST Destination,
    _Out_ PULONG Size)
{
    if (Source == nullptr || Size == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    const ULONG marshalledSize = CollectionsListGetMarshalledSize(Source);
    *Size = marshalledSize;
    if (Destination == nullptr)
    {
        return STATUS_SUCCESS;
    }

    if (Destination->AllocatedSizeInBytes < marshalledSize)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    return CollectionsListCopyAndMarshall(Destination, Source);
}

PDLX_FUSION_CHANNEL_STATE FusionChannelForRole(
    _Inout_ PDLX_DRIVER_CONTEXT DriverContext,
    _In_ DLX_DEVICE_ROLE Role)
{
    if (DriverContext == nullptr)
    {
        return nullptr;
    }

    if (Role == DLX_DEVICE_ROLE::Primary)
    {
        return &DriverContext->Primary;
    }
    if (Role == DLX_DEVICE_ROLE::Secondary)
    {
        return &DriverContext->Secondary;
    }
    return nullptr;
}

PDLX_DRIVER_CONTEXT FusionContextForSensor(
    _In_ PDLX_SENSOR_CONTEXT Context)
{
    if (Context == nullptr || Context->Device == nullptr)
    {
        return nullptr;
    }

    WDFDRIVER driver = WdfDeviceGetDriver(Context->Device);
    return driver == nullptr ? nullptr : DlxGetDriverContext(driver);
}

ULONG EffectiveSamplingInterval(_In_ PDLX_SENSOR_CONTEXT Context)
{
    if (Context == nullptr)
    {
        return DLX_DEFAULT_INTERVAL_MS;
    }

    return DlxFusionSamplingInterval(
        Context->BackgroundSampling,
        Context->IntervalMs,
        DLX_DEFAULT_INTERVAL_MS);
}

bool ClientReportIsDue(_In_ PDLX_SENSOR_CONTEXT Context)
{
    if (Context == nullptr || !Context->ClientRequestedStart)
    {
        return false;
    }

    if (Context->FirstSample ||
        !Context->LastSampleValid ||
        Context->LastClientReportMs == 0)
    {
        return true;
    }

    return DlxFusionClientReportIsDue(
        GetTickCount64(),
        Context->LastClientReportMs,
        Context->IntervalMs);
}

void PublishFusionSample(
    _Inout_ PDLX_SENSOR_CONTEXT Context,
    _In_ FLOAT Lux)
{
    PDLX_DRIVER_CONTEXT driverContext = FusionContextForSensor(Context);
    if (driverContext == nullptr || driverContext->FusionLock == nullptr)
    {
        return;
    }

    WdfWaitLockAcquire(driverContext->FusionLock, nullptr);
    PDLX_FUSION_CHANNEL_STATE channel = FusionChannelForRole(
        driverContext,
        Context->Role);
    if (channel != nullptr &&
        DlxFusionPushSample(
            channel->Samples,
            &channel->SampleCount,
            &channel->NextSampleIndex,
            Lux))
    {
        channel->UpdatedAtMs = GetTickCount64();
        channel->Valid = true;
    }
    WdfWaitLockRelease(driverContext->FusionLock);
}

void InvalidateFusionSample(_Inout_ PDLX_SENSOR_CONTEXT Context)
{
    PDLX_DRIVER_CONTEXT driverContext = FusionContextForSensor(Context);
    if (driverContext == nullptr || driverContext->FusionLock == nullptr)
    {
        return;
    }

    WdfWaitLockAcquire(driverContext->FusionLock, nullptr);
    PDLX_FUSION_CHANNEL_STATE channel = FusionChannelForRole(
        driverContext,
        Context->Role);
    if (channel != nullptr)
    {
        channel->SampleCount = 0;
        channel->NextSampleIndex = 0;
        channel->UpdatedAtMs = 0;
        channel->Valid = false;
    }
    WdfWaitLockRelease(driverContext->FusionLock);
}

bool TryGetFusedLux(
    _In_ PDLX_SENSOR_CONTEXT Context,
    _Out_ FLOAT* FusedLux)
{
    if (Context == nullptr ||
        Context->Role != DLX_DEVICE_ROLE::Primary ||
        FusedLux == nullptr)
    {
        return false;
    }

    PDLX_DRIVER_CONTEXT driverContext = FusionContextForSensor(Context);
    if (driverContext == nullptr || driverContext->FusionLock == nullptr)
    {
        return false;
    }

    const ULONGLONG nowMs = GetTickCount64();
    bool primaryValid = false;
    bool secondaryValid = false;
    FLOAT primaryLux = 0.0f;
    FLOAT secondaryLux = 0.0f;

    WdfWaitLockAcquire(driverContext->FusionLock, nullptr);
    if (driverContext->Primary.Valid &&
        DlxFusionSampleIsFresh(
            nowMs,
            driverContext->Primary.UpdatedAtMs) &&
        driverContext->Primary.SampleCount > 0)
    {
        primaryLux = DlxFusionMedian(
            driverContext->Primary.Samples,
            driverContext->Primary.SampleCount);
        primaryValid = true;
    }
    if (driverContext->Secondary.Valid &&
        DlxFusionSampleIsFresh(
            nowMs,
            driverContext->Secondary.UpdatedAtMs) &&
        driverContext->Secondary.SampleCount > 0)
    {
        secondaryLux = DlxFusionMedian(
            driverContext->Secondary.Samples,
            driverContext->Secondary.SampleCount);
        secondaryValid = true;
    }
    WdfWaitLockRelease(driverContext->FusionLock);

    return DlxFuseAmbientLux(
        primaryValid,
        primaryLux,
        secondaryValid,
        secondaryLux,
        FusedLux);
}

NTSTATUS ReportLux(
    _Inout_ PDLX_SENSOR_CONTEXT Context,
    _In_ FLOAT Lux)
{
    if (!DlxShouldReportLux(
            Context->FirstSample,
            Context->LastSampleValid,
            Context->LastLux,
            Lux,
            Context->ThresholdPercent,
            Context->ThresholdAbsolute))
    {
        return STATUS_DATA_NOT_ACCEPTED;
    }

    FILETIME timestamp = {};
    GetSystemTimePreciseAsFileTime(&timestamp);
    InitPropVariantFromFileTime(
        &timestamp,
        &Context->SensorData->List[DlxDataTimestamp].Value);
    InitPropVariantFromFloat(
        Lux,
        &Context->SensorData->List[DlxDataLux].Value);
    InitPropVariantFromBoolean(
        TRUE,
        &Context->SensorData->List[DlxDataIsValid].Value);

    SensorsCxSensorDataReady(Context->SensorInstance, Context->SensorData);
    Context->LastClientReportMs = GetTickCount64();
    Context->LastLux = Lux;
    Context->LastSampleValid = true;
    Context->InvalidSampleReported = false;
    Context->FirstSample = false;
    InitPropVariantFromUInt32(
        SensorState_Active,
        &Context->SensorProperties->List[DlxSensorState].Value);
    return STATUS_SUCCESS;
}

void ReportValidityTransition(
    _Inout_ PDLX_SENSOR_CONTEXT Context,
    _In_ bool IsValid)
{
    FILETIME timestamp = {};
    GetSystemTimePreciseAsFileTime(&timestamp);

    InitPropVariantFromFileTime(
        &timestamp,
        &Context->SensorData->List[DlxDataTimestamp].Value);
    InitPropVariantFromFloat(
        Context->LastLux,
        &Context->SensorData->List[DlxDataLux].Value);
    InitPropVariantFromBoolean(
        IsValid ? TRUE : FALSE,
        &Context->SensorData->List[DlxDataIsValid].Value);

    SensorsCxSensorDataReady(Context->SensorInstance, Context->SensorData);
    Context->LastSampleValid = IsValid;
    Context->InvalidSampleReported = !IsValid;

    if (Context->SensorProperties != nullptr)
    {
        InitPropVariantFromUInt32(
            IsValid ? SensorState_Active : SensorState_Error,
            &Context->SensorProperties->List[DlxSensorState].Value);
    }
}

void ReportInvalidOnce(_Inout_ PDLX_SENSOR_CONTEXT Context)
{
    InvalidateFusionSample(Context);

    if (Context->Role == DLX_DEVICE_ROLE::Primary)
    {
        FLOAT fallbackLux = 0.0f;
        if (TryGetFusedLux(Context, &fallbackLux))
        {
            if (ClientReportIsDue(Context))
            {
                if (!Context->LastSampleValid)
                {
                    Context->FirstSample = true;
                }
                (void)ReportLux(Context, fallbackLux);
            }
            Context->PendingInvalidReport = false;
            return;
        }
    }

    if (Context->BackgroundSampling && !Context->ClientRequestedStart)
    {
        Context->LastSampleValid = false;
        Context->InvalidSampleReported = true;
        Context->PendingInvalidReport = false;
        return;
    }

    if (Context->LastSampleValid || !Context->InvalidSampleReported)
    {
        ReportValidityTransition(Context, false);
    }
    Context->PendingInvalidReport = false;
}

NTSTATUS RecoverSensorAfterReset(
    _Inout_ PDLX_SENSOR_CONTEXT Context,
    _Out_ ULONG* NextDelayMs)
{
    if (Context == nullptr ||
        Context->SpbIoTarget == nullptr ||
        NextDelayMs == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    Context->RecoveryPending = true;
    if (Context->RecoveryAttempts != DLX_MAX_COUNTER)
    {
        ++Context->RecoveryAttempts;
    }
    *NextDelayMs = DlxLtrf216aRecoveryDelay(Context->RecoveryAttempts);

    NTSTATUS status = DlxLtrf216aConfigure(
        Context->SpbIoTarget,
        &Context->PartId);

    if (NT_SUCCESS(status))
    {
        status = DlxLtrf216aSetEnabled(Context->SpbIoTarget, true);
    }

    if (NT_SUCCESS(status))
    {
        Context->RecoveryPending = false;
        Context->NextRecoveryAttemptMs = 0;
        Context->HardwareValidated = true;
        Context->FirstSample = true;
        Context->ConsecutiveIoFailures = 0;
        Context->ConsecutiveNotReady = 0;
        Context->ConsecutiveNoSample = 0;
        Context->RecoveryAttempts = 0;
        *NextDelayMs = DLX_LTRF216A_STARTUP_DELAY_MS;
        DLX_TRACE_INFO("Recovered sensor after reset for %ls", Context->BiosName);
    }
    else
    {
        Context->NextRecoveryAttemptMs =
            GetTickCount64() + *NextDelayMs;
        DLX_TRACE_ERROR(
            "Sensor reset recovery failed for %ls: 0x%08X",
            Context->BiosName,
            static_cast<ULONG>(status));
    }

    return status;
}

ULONG RemainingRecoveryDelay(
    _In_ PDLX_SENSOR_CONTEXT Context,
    _In_ ULONGLONG NowMs)
{
    if (Context == nullptr || Context->NextRecoveryAttemptMs <= NowMs)
    {
        return 1;
    }

    const ULONGLONG remaining = Context->NextRecoveryAttemptMs - NowMs;
    return remaining > DLX_MAX_COUNTER
        ? DLX_MAX_COUNTER
        : static_cast<ULONG>(remaining);
}

NTSTATUS ServiceRecoveryAndFallback(
    _Inout_ PDLX_SENSOR_CONTEXT Context,
    _Out_ ULONG* NextDelayMs)
{
    const ULONGLONG nowMs = GetTickCount64();
    const bool recoveryDue =
        Context->NextRecoveryAttemptMs == 0 ||
        nowMs >= Context->NextRecoveryAttemptMs;
    NTSTATUS recoveryStatus = STATUS_NO_DATA_DETECTED;

    if (recoveryDue)
    {
        recoveryStatus = RecoverSensorAfterReset(Context, NextDelayMs);
    }
    else
    {
        *NextDelayMs = RemainingRecoveryDelay(Context, nowMs);
    }

    if (Context->Role == DLX_DEVICE_ROLE::Primary)
    {
        FLOAT fallbackLux = 0.0f;
        const bool fallbackValid = TryGetFusedLux(Context, &fallbackLux);
        if (fallbackValid && ClientReportIsDue(Context))
        {
            (void)ReportLux(Context, fallbackLux);
        }
        else if (!fallbackValid &&
                 (Context->LastSampleValid ||
                  !Context->InvalidSampleReported))
        {
            // The primary is unavailable and the alternate has now failed or
            // aged out. Do not leave the preferred reading valid forever.
            ReportValidityTransition(Context, false);
        }

        // Continue forwarding a healthy alternate at the primary client's
        // cadence without defeating the bounded hardware-recovery backoff.
        if (Context->RecoveryPending)
        {
            const ULONG recoveryDelay = RemainingRecoveryDelay(
                Context,
                GetTickCount64());
            const ULONG samplingDelay = EffectiveSamplingInterval(Context);
            *NextDelayMs = DlxFusionRecoveryTimerDelay(
                recoveryDelay,
                samplingDelay);
        }
    }

    return recoveryDue && !NT_SUCCESS(recoveryStatus)
        ? recoveryStatus
        : STATUS_NO_DATA_DETECTED;
}
}

NTSTATUS DlxInitializeSensorContext(
    _In_ WDFDEVICE Device,
    _In_ SENSOROBJECT SensorInstance,
    _Out_ PDLX_SENSOR_CONTEXT Context)
{
    if (Device == nullptr || SensorInstance == nullptr || Context == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    Context->Device = Device;
    Context->SensorInstance = SensorInstance;
    Context->SpbIoTarget = nullptr;
    Context->Lock = nullptr;
    Context->LifecycleLock = nullptr;
    Context->Timer = nullptr;
    Context->PoweredOn = false;
    Context->Started = false;
    Context->ClientRequestedStart = false;
    Context->BackgroundSampling = false;
    Context->FirstSample = true;
    Context->LastSampleValid = false;
    Context->HardwareValidated = false;
    Context->InvalidSampleReported = false;
    Context->PendingInvalidReport = false;
    Context->RecoveryPending = false;
    Context->NextRecoveryAttemptMs = 0;
    Context->LastClientReportMs = 0;
    Context->IntervalMs = DLX_DEFAULT_INTERVAL_MS;
    Context->ConsecutiveIoFailures = 0;
    Context->ConsecutiveNotReady = 0;
    Context->ConsecutiveNoSample = 0;
    Context->RecoveryAttempts = 0;
    Context->ThresholdPercent = DLX_DEFAULT_THRESHOLD_PERCENT;
    Context->ThresholdAbsolute = DLX_DEFAULT_THRESHOLD_ABSOLUTE;
    Context->LastLux = 0.0f;
    Context->CalibrationScale = DLX_DEFAULT_SCALE;
    Context->CalibrationOffset = DLX_DEFAULT_OFFSET;
    Context->CalibrationScalePpm = DLX_CALIBRATION_SCALE_PPM_DEFAULT;
    Context->PartId = 0;
    Context->BiosName[0] = L'\0';

    NTSTATUS status = DlxQueryBiosName(
        Device,
        Context->BiosName,
        ARRAYSIZE(Context->BiosName));

    if (!NT_SUCCESS(status))
    {
        (void)StringCchCopyW(
            Context->BiosName,
            ARRAYSIZE(Context->BiosName),
            L"Explicitly opted-in LTR-F216A");
    }

    Context->Role = DlxRoleFromBiosName(Context->BiosName);
    Context->IsPrimary = Context->Role != DLX_DEVICE_ROLE::Secondary;
    Context->BackgroundSampling =
        Context->Role == DLX_DEVICE_ROLE::Secondary;

    ULONG configuredScalePpm = DLX_CALIBRATION_SCALE_PPM_DEFAULT;
    const NTSTATUS calibrationStatus = DlxQueryCalibrationScale(
        Device,
        &configuredScalePpm);
    if (NT_SUCCESS(calibrationStatus))
    {
        Context->CalibrationScalePpm = configuredScalePpm;
        Context->CalibrationScale = DlxCalibrationScaleFromPpm(
            configuredScalePpm);
        DLX_TRACE_INFO(
            "Using calibration scale %.6f (%lu ppm) for %ls",
            static_cast<double>(Context->CalibrationScale),
            Context->CalibrationScalePpm,
            Context->BiosName);
    }
    else
    {
        DLX_TRACE_INFO(
            "Using default calibration scale for %ls (property status 0x%08X)",
            Context->BiosName,
            static_cast<ULONG>(calibrationStatus));
    }

    WDF_OBJECT_ATTRIBUTES lockAttributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&lockAttributes);
    lockAttributes.ParentObject = SensorInstance;
    status = WdfWaitLockCreate(&lockAttributes, &Context->Lock);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    WDF_OBJECT_ATTRIBUTES lifecycleLockAttributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&lifecycleLockAttributes);
    lifecycleLockAttributes.ParentObject = SensorInstance;
    status = WdfWaitLockCreate(
        &lifecycleLockAttributes,
        &Context->LifecycleLock);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    WDF_TIMER_CONFIG timerConfig;
    WDF_TIMER_CONFIG_INIT(&timerConfig, DlxEvtTimer);

    WDF_OBJECT_ATTRIBUTES timerAttributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&timerAttributes);
    timerAttributes.ParentObject = SensorInstance;
    timerAttributes.ExecutionLevel = WdfExecutionLevelPassive;
    status = WdfTimerCreate(
        &timerConfig,
        &timerAttributes,
        &Context->Timer);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    status = AllocateCollection(
        DlxEnumerationPropertyCount,
        SensorInstance,
        &Context->EnumerationProperties);

    if (NT_SUCCESS(status))
    {
        auto list = Context->EnumerationProperties;

        list->List[DlxEnumerationType].Key = DEVPKEY_Sensor_Type;
        CaptureInitializationFailure(
            &status,
            InitPropVariantFromCLSID(
                GUID_SensorType_AmbientLight,
                &list->List[DlxEnumerationType].Value));

        list->List[DlxEnumerationManufacturer].Key = DEVPKEY_Sensor_Manufacturer;
        CaptureInitializationFailure(
            &status,
            InitPropVariantFromString(
                L"Lite-On",
                &list->List[DlxEnumerationManufacturer].Value));

        list->List[DlxEnumerationModel].Key = DEVPKEY_Sensor_Model;
        CaptureInitializationFailure(
            &status,
            InitPropVariantFromString(
                ModelForRole(Context->Role),
                &list->List[DlxEnumerationModel].Value));

        list->List[DlxEnumerationConnectionType].Key =
            DEVPKEY_Sensor_ConnectionType;
        InitPropVariantFromUInt32(
            static_cast<ULONG>(SensorConnectionType_Integrated),
            &list->List[DlxEnumerationConnectionType].Value);

        list->List[DlxEnumerationPersistentId].Key =
            DEVPKEY_Sensor_PersistentUniqueId;
        CaptureInitializationFailure(
            &status,
            InitPropVariantFromCLSID(
                PersistentIdForRole(Context->Role),
                &list->List[DlxEnumerationPersistentId].Value));

        list->List[DlxEnumerationCategory].Key = DEVPKEY_Sensor_Category;
        CaptureInitializationFailure(
            &status,
            InitPropVariantFromCLSID(
                GUID_SensorCategory_Light,
                &list->List[DlxEnumerationCategory].Value));

        list->List[DlxEnumerationIsPrimary].Key = DEVPKEY_Sensor_IsPrimary;
        InitPropVariantFromBoolean(
            Context->IsPrimary ? TRUE : FALSE,
            &list->List[DlxEnumerationIsPrimary].Value);

        list->List[DlxEnumerationAutoBrightnessPreferred].Key =
            DEVPKEY_LightSensor_AutoBrightnessPreferred;
        InitPropVariantFromBoolean(
            Context->IsPrimary ? TRUE : FALSE,
            &list->List[DlxEnumerationAutoBrightnessPreferred].Value);

        list->List[DlxEnumerationColorCapable].Key =
            DEVPKEY_LightSensor_ColorCapable;
        InitPropVariantFromBoolean(
            FALSE,
            &list->List[DlxEnumerationColorCapable].Value);
    }

    if (NT_SUCCESS(status))
    {
        status = AllocatePropertyList(
            DlxDataCount,
            SensorInstance,
            &Context->SupportedDataFields);
    }

    if (NT_SUCCESS(status))
    {
        Context->SupportedDataFields->List[DlxDataTimestamp] =
            PKEY_SensorData_Timestamp;
        Context->SupportedDataFields->List[DlxDataLux] =
            PKEY_SensorData_LightLevel_Lux;
        Context->SupportedDataFields->List[DlxDataIsValid] =
            PKEY_SensorData_IsValid;
    }

    if (NT_SUCCESS(status))
    {
        status = AllocateCollection(
            DlxDataCount,
            SensorInstance,
            &Context->SensorData);
    }

    if (NT_SUCCESS(status))
    {
        FILETIME timestamp = {};
        GetSystemTimePreciseAsFileTime(&timestamp);

        Context->SensorData->List[DlxDataTimestamp].Key =
            PKEY_SensorData_Timestamp;
        InitPropVariantFromFileTime(
            &timestamp,
            &Context->SensorData->List[DlxDataTimestamp].Value);

        Context->SensorData->List[DlxDataLux].Key =
            PKEY_SensorData_LightLevel_Lux;
        InitPropVariantFromFloat(
            0.0f,
            &Context->SensorData->List[DlxDataLux].Value);

        Context->SensorData->List[DlxDataIsValid].Key =
            PKEY_SensorData_IsValid;
        InitPropVariantFromBoolean(
            FALSE,
            &Context->SensorData->List[DlxDataIsValid].Value);
    }

    if (NT_SUCCESS(status))
    {
        status = AllocateCollection(
            DlxSensorPropertyCount,
            SensorInstance,
            &Context->SensorProperties);
    }

    if (NT_SUCCESS(status))
    {
        auto list = Context->SensorProperties;

        list->List[DlxSensorState].Key = PKEY_Sensor_State;
        InitPropVariantFromUInt32(
            SensorState_Initializing,
            &list->List[DlxSensorState].Value);

        list->List[DlxSensorMinimumInterval].Key =
            PKEY_Sensor_MinimumDataInterval_Ms;
        InitPropVariantFromUInt32(
            DLX_MINIMUM_INTERVAL_MS,
            &list->List[DlxSensorMinimumInterval].Value);

        list->List[DlxSensorMaximumDataFieldSize].Key =
            PKEY_Sensor_MaximumDataFieldSize_Bytes;
        InitPropVariantFromUInt32(
            CollectionsListGetMarshalledSize(Context->SensorData),
            &list->List[DlxSensorMaximumDataFieldSize].Value);

        list->List[DlxSensorType].Key = PKEY_Sensor_Type;
        CaptureInitializationFailure(
            &status,
            InitPropVariantFromCLSID(
                GUID_SensorType_AmbientLight,
                &list->List[DlxSensorType].Value));

        const ULONG responseCurve[] =
        {
            0, 10,
            10, 40,
            40, 100,
            68, 400,
            90, 1000,
        };

        list->List[DlxSensorResponseCurve].Key = PKEY_LightSensor_ResponseCurve;
        CaptureInitializationFailure(
            &status,
            InitPropVariantFromUInt32Vector(
                responseCurve,
                ARRAYSIZE(responseCurve),
                &list->List[DlxSensorResponseCurve].Value));
    }

    if (NT_SUCCESS(status))
    {
        status = AllocateCollection(
            DlxFieldPropertyCount,
            SensorInstance,
            &Context->DataFieldProperties);
    }

    if (NT_SUCCESS(status))
    {
        auto list = Context->DataFieldProperties;

        list->List[DlxFieldResolution].Key =
            PKEY_SensorDataField_Resolution;
        InitPropVariantFromFloat(
            DlxLtrf216aResolution(Context->CalibrationScalePpm),
            &list->List[DlxFieldResolution].Value);

        list->List[DlxFieldRangeMinimum].Key =
            PKEY_SensorDataField_RangeMinimum;
        InitPropVariantFromFloat(
            0.0f,
            &list->List[DlxFieldRangeMinimum].Value);

        list->List[DlxFieldRangeMaximum].Key =
            PKEY_SensorDataField_RangeMaximum;
        InitPropVariantFromFloat(
            DlxLtrf216aMaximumLux(
                Context->Role == DLX_DEVICE_ROLE::Primary
                    ? DLX_CALIBRATION_SCALE_PPM_MAXIMUM
                    : Context->CalibrationScalePpm),
            &list->List[DlxFieldRangeMaximum].Value);
    }

    if (NT_SUCCESS(status))
    {
        status = AllocateCollection(
            DlxThresholdCount,
            SensorInstance,
            &Context->Thresholds);
    }

    if (NT_SUCCESS(status))
    {
        Context->Thresholds->List[DlxThresholdPercent].Key =
            PKEY_SensorData_LightLevel_Lux;
        InitPropVariantFromFloat(
            Context->ThresholdPercent,
            &Context->Thresholds->List[DlxThresholdPercent].Value);

        Context->Thresholds->List[DlxThresholdAbsolute].Key =
            PKEY_SensorData_LightLevel_Lux_Threshold_AbsoluteDifference;
        InitPropVariantFromFloat(
            Context->ThresholdAbsolute,
            &Context->Thresholds->List[DlxThresholdAbsolute].Value);
    }

    return status;
}

VOID DlxEvtTimer(_In_ WDFTIMER Timer)
{
    SENSOROBJECT sensorInstance = WdfTimerGetParentObject(Timer);
    PDLX_SENSOR_CONTEXT context = DlxGetSensorContext(sensorInstance);
    if (context == nullptr || context->Lock == nullptr)
    {
        return;
    }

    ULONG nextDelayMs = DLX_DEFAULT_INTERVAL_MS;
    WdfWaitLockAcquire(context->Lock, nullptr);
    nextDelayMs = EffectiveSamplingInterval(context);
    if (context->Started && context->PoweredOn)
    {
        const NTSTATUS status = DlxReadAndReportSample(context, &nextDelayMs);
        if (!NT_SUCCESS(status) &&
            status != STATUS_DATA_NOT_ACCEPTED &&
            status != STATUS_NO_DATA_DETECTED)
        {
            DLX_TRACE_WARNING(
                "Sample failed for %ls: 0x%08X",
                context->BiosName,
                static_cast<ULONG>(status));
        }
    }

    if (context->Started && context->PoweredOn)
    {
        WdfTimerStart(Timer, WDF_REL_TIMEOUT_IN_MS(nextDelayMs));
    }
    WdfWaitLockRelease(context->Lock);
}

NTSTATUS DlxReadAndReportSample(
    _Inout_ PDLX_SENSOR_CONTEXT Context,
    _Out_ ULONG* NextDelayMs)
{
    if (Context == nullptr ||
        Context->SpbIoTarget == nullptr ||
        Context->SensorInstance == nullptr ||
        NextDelayMs == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *NextDelayMs = EffectiveSamplingInterval(Context);

    if (Context->PendingInvalidReport)
    {
        // Lifecycle callbacks only mark this transition. Reporting from the
        // polling timer guarantees EvtSensorStart/D0Entry has returned and
        // SensorsCx is ready to accept data.
        ReportInvalidOnce(Context);
    }

    if (Context->RecoveryPending)
    {
        return ServiceRecoveryAndFallback(Context, NextDelayMs);
    }

    ULONG raw = 0;
    bool dataReady = false;
    bool powerOnReset = false;
    NTSTATUS status = DlxLtrf216aReadSample(
        Context->SpbIoTarget,
        &raw,
        &dataReady,
        &powerOnReset);

    if (!NT_SUCCESS(status))
    {
        if (Context->ConsecutiveIoFailures != DLX_MAX_COUNTER)
        {
            ++Context->ConsecutiveIoFailures;
        }
        if (Context->ConsecutiveNoSample != DLX_MAX_COUNTER)
        {
            ++Context->ConsecutiveNoSample;
        }

        if (Context->ConsecutiveIoFailures >= 3)
        {
            ReportInvalidOnce(Context);
        }

        if (DlxLtrf216aShouldRetryAcquisition(
                Context->ConsecutiveNoSample))
        {
            *NextDelayMs = DLX_LTRF216A_ACQUISITION_RETRY_MS;
            return status;
        }

        DLX_TRACE_WARNING(
            "Sensor produced no sample for %ls; reinitializing after I/O failures",
            Context->BiosName);
        ReportInvalidOnce(Context);
        Context->RecoveryPending = true;
        Context->NextRecoveryAttemptMs = 0;
        return ServiceRecoveryAndFallback(Context, NextDelayMs);
    }

    if (powerOnReset)
    {
        DLX_TRACE_WARNING(
            "Power-on/reset status detected for %ls; reinitializing sensor",
            Context->BiosName);
        ReportInvalidOnce(Context);
        Context->RecoveryPending = true;
        Context->NextRecoveryAttemptMs = 0;
        return ServiceRecoveryAndFallback(Context, NextDelayMs);
    }

    if (!dataReady)
    {
        if (Context->ConsecutiveNotReady != DLX_MAX_COUNTER)
        {
            ++Context->ConsecutiveNotReady;
        }
        if (Context->ConsecutiveNoSample != DLX_MAX_COUNTER)
        {
            ++Context->ConsecutiveNoSample;
        }

        if (DlxLtrf216aShouldRetryAcquisition(
                Context->ConsecutiveNoSample))
        {
            *NextDelayMs = DLX_LTRF216A_ACQUISITION_RETRY_MS;
            return STATUS_NO_DATA_DETECTED;
        }

        DLX_TRACE_WARNING(
            "Sensor produced no sample for %ls; reinitializing after not-ready status",
            Context->BiosName);
        ReportInvalidOnce(Context);
        Context->RecoveryPending = true;
        Context->NextRecoveryAttemptMs = 0;
        return ServiceRecoveryAndFallback(Context, NextDelayMs);
    }

    Context->ConsecutiveIoFailures = 0;
    Context->ConsecutiveNotReady = 0;
    Context->ConsecutiveNoSample = 0;
    Context->RecoveryAttempts = 0;

    const FLOAT lux = DlxLtrf216aRawToLux(
        raw,
        Context->CalibrationScale,
        Context->CalibrationOffset);

    PublishFusionSample(Context, lux);

    if (Context->Role == DLX_DEVICE_ROLE::Primary)
    {
        FLOAT fusedLux = lux;
        (void)TryGetFusedLux(Context, &fusedLux);
        return ClientReportIsDue(Context)
            ? ReportLux(Context, fusedLux)
            : STATUS_DATA_NOT_ACCEPTED;
    }

    if (Context->BackgroundSampling && !ClientReportIsDue(Context))
    {
        if (!Context->ClientRequestedStart)
        {
            // A healthy background sample clears the private failure marker;
            // a client opening later should receive the fresh valid reading,
            // not a stale invalid transition that it never observed.
            Context->InvalidSampleReported = false;
            Context->PendingInvalidReport = false;
        }
        return STATUS_DATA_NOT_ACCEPTED;
    }
    return ReportLux(Context, lux);
}

NTSTATUS DlxEvtSensorStart(_In_ SENSOROBJECT SensorInstance)
{
    PDLX_SENSOR_CONTEXT context = DlxGetSensorContext(SensorInstance);
    if (context == nullptr || context->LifecycleLock == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    WdfWaitLockAcquire(context->LifecycleLock, nullptr);
    WdfWaitLockAcquire(context->Lock, nullptr);
    if (!context->PoweredOn || !context->HardwareValidated)
    {
        WdfWaitLockRelease(context->Lock);
        WdfWaitLockRelease(context->LifecycleLock);
        return STATUS_DEVICE_NOT_READY;
    }

    context->ClientRequestedStart = true;
    context->LastClientReportMs = 0;
    if (context->Started)
    {
        context->FirstSample = true;
        if (context->RecoveryPending || context->InvalidSampleReported)
        {
            // The prior invalid state may have been suppressed because no
            // diagnostic client existed. Force exactly one transition for the
            // newly opened client before recovery/fresh data continues.
            context->InvalidSampleReported = false;
            context->PendingInvalidReport = true;
            InitPropVariantFromUInt32(
                SensorState_Error,
                &context->SensorProperties->List[DlxSensorState].Value);
            WdfTimerStart(context->Timer, WDF_REL_TIMEOUT_IN_MS(1));
        }
        else
        {
            InitPropVariantFromUInt32(
                SensorState_Active,
                &context->SensorProperties->List[DlxSensorState].Value);
        }
        WdfWaitLockRelease(context->Lock);
        WdfWaitLockRelease(context->LifecycleLock);
        return STATUS_SUCCESS;
    }

    context->ConsecutiveIoFailures = 0;
    context->ConsecutiveNotReady = 0;
    context->ConsecutiveNoSample = 0;
    context->RecoveryAttempts = 0;

    ULONG firstDelayMs = DLX_LTRF216A_STARTUP_DELAY_MS;
    NTSTATUS status = context->RecoveryPending
        ? RecoverSensorAfterReset(context, &firstDelayMs)
        : DlxLtrf216aSetEnabled(context->SpbIoTarget, true);

    context->Started = true;
    context->FirstSample = true;
    context->InvalidSampleReported = false;
    context->PendingInvalidReport = false;

    if (!NT_SUCCESS(status))
    {
        // SensorCx does not retry a failed EvtSensorStart. Keep the client
        // request active and let the bounded timer recovery path repair a
        // transient bus/configuration failure.
        context->RecoveryPending = true;
        context->PendingInvalidReport = true;
        InitPropVariantFromUInt32(
            SensorState_Error,
            &context->SensorProperties->List[DlxSensorState].Value);
        firstDelayMs = DlxLtrf216aRecoveryDelay(
            context->RecoveryAttempts == 0 ? 1 : context->RecoveryAttempts);
    }
    else
    {
        InitPropVariantFromUInt32(
            SensorState_Active,
            &context->SensorProperties->List[DlxSensorState].Value);
    }

    WdfTimerStart(
        context->Timer,
        WDF_REL_TIMEOUT_IN_MS(firstDelayMs));

    WdfWaitLockRelease(context->Lock);
    WdfWaitLockRelease(context->LifecycleLock);

    return STATUS_SUCCESS;
}

NTSTATUS DlxStopSensor(
    _Inout_ PDLX_SENSOR_CONTEXT Context,
    _In_ bool PreserveClientRequest,
    _In_ bool DisableHardware,
    _In_ bool PoweringOff)
{
    if (Context == nullptr ||
        Context->Lock == nullptr ||
        Context->LifecycleLock == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    // Serialize Start, Stop, and power transitions across the deliberate
    // lock release required by WdfTimerStop(TRUE).
    WdfWaitLockAcquire(Context->LifecycleLock, nullptr);
    WdfWaitLockAcquire(Context->Lock, nullptr);
    if (!PreserveClientRequest)
    {
        Context->ClientRequestedStart = false;
        Context->LastClientReportMs = 0;
    }

    if (Context->BackgroundSampling &&
        !PreserveClientRequest &&
        !PoweringOff)
    {
        Context->FirstSample = true;
        if (Context->SensorProperties != nullptr)
        {
            InitPropVariantFromUInt32(
                SensorState_Active,
                &Context->SensorProperties->List[DlxSensorState].Value);
        }
        WdfWaitLockRelease(Context->Lock);
        WdfWaitLockRelease(Context->LifecycleLock);
        return STATUS_SUCCESS;
    }

    Context->Started = false;
    WdfWaitLockRelease(Context->Lock);

    if (Context->Timer != nullptr)
    {
        (void)WdfTimerStop(Context->Timer, TRUE);
    }

    WdfWaitLockAcquire(Context->Lock, nullptr);
    NTSTATUS status = STATUS_SUCCESS;
    if (DisableHardware &&
        Context->PoweredOn &&
        Context->SpbIoTarget != nullptr)
    {
        status = DlxLtrf216aSetEnabled(
            Context->SpbIoTarget,
            false);
    }

    if (PoweringOff)
    {
        Context->PoweredOn = false;
    }

    Context->FirstSample = true;
    Context->ConsecutiveIoFailures = 0;
    Context->ConsecutiveNotReady = 0;
    Context->ConsecutiveNoSample = 0;
    Context->RecoveryAttempts = 0;
    Context->NextRecoveryAttemptMs = 0;
    Context->LastClientReportMs = 0;
    Context->InvalidSampleReported = false;
    Context->PendingInvalidReport = false;
    InvalidateFusionSample(Context);
    if (Context->SensorProperties != nullptr)
    {
        InitPropVariantFromUInt32(
            SensorState_Idle,
            &Context->SensorProperties->List[DlxSensorState].Value);
    }

    WdfWaitLockRelease(Context->Lock);
    WdfWaitLockRelease(Context->LifecycleLock);
    return status;
}

NTSTATUS DlxEvtSensorStop(_In_ SENSOROBJECT SensorInstance)
{
    PDLX_SENSOR_CONTEXT context = DlxGetSensorContext(SensorInstance);
    return context == nullptr
        ? STATUS_INVALID_PARAMETER
        : DlxStopSensor(context);
}

NTSTATUS DlxEvtSensorGetSupportedDataFields(
    _In_ SENSOROBJECT SensorInstance,
    _Inout_opt_ PSENSOR_PROPERTY_LIST Fields,
    _Out_ PULONG Size)
{
    PDLX_SENSOR_CONTEXT context = DlxGetSensorContext(SensorInstance);
    return context == nullptr
        ? STATUS_INVALID_PARAMETER
        : CopyPropertyList(context->SupportedDataFields, Fields, Size);
}

NTSTATUS DlxEvtSensorGetProperties(
    _In_ SENSOROBJECT SensorInstance,
    _Inout_opt_ PSENSOR_COLLECTION_LIST Properties,
    _Out_ PULONG Size)
{
    PDLX_SENSOR_CONTEXT context = DlxGetSensorContext(SensorInstance);
    if (context == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    WdfWaitLockAcquire(context->Lock, nullptr);
    const NTSTATUS status = CopyCollection(
        context->SensorProperties,
        Properties,
        Size);
    WdfWaitLockRelease(context->Lock);
    return status;
}

NTSTATUS DlxEvtSensorGetDataFieldProperties(
    _In_ SENSOROBJECT SensorInstance,
    _In_ const PROPERTYKEY* DataField,
    _Inout_opt_ PSENSOR_COLLECTION_LIST Properties,
    _Out_ PULONG Size)
{
    PDLX_SENSOR_CONTEXT context = DlxGetSensorContext(SensorInstance);
    if (context == nullptr || DataField == nullptr || Size == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    if (!IsEqualPropertyKey(*DataField, PKEY_SensorData_LightLevel_Lux))
    {
        *Size = 0;
        return STATUS_NOT_SUPPORTED;
    }

    return CopyCollection(context->DataFieldProperties, Properties, Size);
}

NTSTATUS DlxEvtSensorGetDataInterval(
    _In_ SENSOROBJECT SensorInstance,
    _Out_ PULONG DataRateMs)
{
    PDLX_SENSOR_CONTEXT context = DlxGetSensorContext(SensorInstance);
    if (context == nullptr || DataRateMs == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    WdfWaitLockAcquire(context->Lock, nullptr);
    *DataRateMs = context->IntervalMs;
    WdfWaitLockRelease(context->Lock);
    return STATUS_SUCCESS;
}

NTSTATUS DlxEvtSensorSetDataInterval(
    _In_ SENSOROBJECT SensorInstance,
    _In_ ULONG DataRateMs)
{
    PDLX_SENSOR_CONTEXT context = DlxGetSensorContext(SensorInstance);
    if (context == nullptr || DataRateMs < DLX_MINIMUM_INTERVAL_MS)
    {
        return STATUS_INVALID_PARAMETER;
    }

    WdfWaitLockAcquire(context->Lock, nullptr);
    context->IntervalMs = DataRateMs;
    if (context->Started && context->PoweredOn)
    {
        // Applying a new active interval should take effect immediately,
        // rather than waiting for the previously scheduled due time.
        WdfTimerStart(
            context->Timer,
            WDF_REL_TIMEOUT_IN_MS(EffectiveSamplingInterval(context)));
    }
    WdfWaitLockRelease(context->Lock);
    return STATUS_SUCCESS;
}

NTSTATUS DlxEvtSensorGetDataThresholds(
    _In_ SENSOROBJECT SensorInstance,
    _Inout_opt_ PSENSOR_COLLECTION_LIST Thresholds,
    _Out_ PULONG Size)
{
    PDLX_SENSOR_CONTEXT context = DlxGetSensorContext(SensorInstance);
    if (context == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    WdfWaitLockAcquire(context->Lock, nullptr);
    const NTSTATUS status = CopyCollection(
        context->Thresholds,
        Thresholds,
        Size);
    WdfWaitLockRelease(context->Lock);
    return status;
}

NTSTATUS DlxEvtSensorSetDataThresholds(
    _In_ SENSOROBJECT SensorInstance,
    _In_ PSENSOR_COLLECTION_LIST Thresholds)
{
    PDLX_SENSOR_CONTEXT context = DlxGetSensorContext(SensorInstance);
    if (context == nullptr || Thresholds == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    WdfWaitLockAcquire(context->Lock, nullptr);
    FLOAT percentage = context->ThresholdPercent;
    FLOAT absolute = context->ThresholdAbsolute;
    NTSTATUS status = STATUS_SUCCESS;

    for (ULONG index = 0; index < Thresholds->Count; ++index)
    {
        const SENSOR_VALUE_PAIR& entry = Thresholds->List[index];
        if (entry.Value.vt != VT_R4 ||
            !std::isfinite(entry.Value.fltVal) ||
            entry.Value.fltVal < 0.0f)
        {
            status = STATUS_INVALID_PARAMETER;
            break;
        }

        if (IsEqualPropertyKey(
                entry.Key,
                PKEY_SensorData_LightLevel_Lux))
        {
            percentage = entry.Value.fltVal;
        }
        else if (IsEqualPropertyKey(
                     entry.Key,
                     PKEY_SensorData_LightLevel_Lux_Threshold_AbsoluteDifference))
        {
            absolute = entry.Value.fltVal;
        }
        else
        {
            status = STATUS_NOT_SUPPORTED;
            break;
        }
    }

    if (NT_SUCCESS(status))
    {
        context->ThresholdPercent = percentage;
        context->ThresholdAbsolute = absolute;
        InitPropVariantFromFloat(
            percentage,
            &context->Thresholds->List[DlxThresholdPercent].Value);
        InitPropVariantFromFloat(
            absolute,
            &context->Thresholds->List[DlxThresholdAbsolute].Value);
    }

    WdfWaitLockRelease(context->Lock);
    return status;
}

NTSTATUS DlxEvtSensorIoControl(
    _In_ SENSOROBJECT SensorInstance,
    _In_ WDFREQUEST Request,
    _In_ size_t OutputBufferLength,
    _In_ size_t InputBufferLength,
    _In_ ULONG IoControlCode)
{
    UNREFERENCED_PARAMETER(SensorInstance);
    UNREFERENCED_PARAMETER(Request);
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);
    UNREFERENCED_PARAMETER(IoControlCode);
    return STATUS_NOT_SUPPORTED;
}
