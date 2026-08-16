// Copyright (c) Microsoft Corporation.
// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
// Licensed under the Microsoft Public License (MS-PL).
//
// Derived in part from the Microsoft Windows Driver Samples ADXL345 and
// SensorsComboDriver SensorCx examples.

#pragma once

#include <windows.h>
#include <wdf.h>
#include <reshub.h>
#include <devpkey.h>
#include <propvarutil.h>
#include <sensorsdef.h>
#include <sensorscx.h>
#include <sensorsutils.h>
#include <SensorsDriversUtils.h>

#include "Ltrf216a.h"
#include "Trace.h"

constexpr ULONG DLX_POOL_TAG = 'xuLD';
constexpr ULONG DLX_MAX_COUNTER = static_cast<ULONG>(-1);
constexpr ULONG DLX_DEFAULT_INTERVAL_MS = 250;
constexpr ULONG DLX_MINIMUM_INTERVAL_MS = 100;
constexpr FLOAT DLX_DEFAULT_THRESHOLD_PERCENT = 0.25f;
constexpr FLOAT DLX_DEFAULT_THRESHOLD_ABSOLUTE = 1.0f;
constexpr FLOAT DLX_DEFAULT_SCALE = 1.0f;
constexpr FLOAT DLX_DEFAULT_OFFSET = 0.0f;

enum class DLX_DEVICE_ROLE : ULONG
{
    Standalone = 0,
    Primary = 1,
    Secondary = 2,
};

enum DLX_ENUMERATION_PROPERTY_INDEX
{
    DlxEnumerationType = 0,
    DlxEnumerationManufacturer,
    DlxEnumerationModel,
    DlxEnumerationConnectionType,
    DlxEnumerationPersistentId,
    DlxEnumerationCategory,
    DlxEnumerationIsPrimary,
    DlxEnumerationAutoBrightnessPreferred,
    DlxEnumerationColorCapable,
    DlxEnumerationPropertyCount,
};

enum DLX_SENSOR_PROPERTY_INDEX
{
    DlxSensorState = 0,
    DlxSensorMinimumInterval,
    DlxSensorMaximumDataFieldSize,
    DlxSensorType,
    DlxSensorResponseCurve,
    DlxSensorPropertyCount,
};

enum DLX_DATA_INDEX
{
    DlxDataTimestamp = 0,
    DlxDataLux,
    DlxDataIsValid,
    DlxDataCount,
};

enum DLX_FIELD_PROPERTY_INDEX
{
    DlxFieldResolution = 0,
    DlxFieldRangeMinimum,
    DlxFieldRangeMaximum,
    DlxFieldPropertyCount,
};

enum DLX_THRESHOLD_INDEX
{
    DlxThresholdPercent = 0,
    DlxThresholdAbsolute,
    DlxThresholdCount,
};

typedef struct _DLX_FUSION_CHANNEL_STATE
{
    FLOAT Samples[DLX_FUSION_WINDOW_SIZE];
    ULONGLONG SampleTimesMs[DLX_FUSION_WINDOW_SIZE];
    std::uint32_t SampleCount;
    std::uint32_t NextSampleIndex;
    WDFDEVICE OwnerDevice;
    ULONG CalibrationScalePpm;
    bool Valid;
} DLX_FUSION_CHANNEL_STATE, *PDLX_FUSION_CHANNEL_STATE;

typedef struct _DLX_DRIVER_CONTEXT
{
    WDFWAITLOCK FusionLock;
    DLX_FUSION_CHANNEL_STATE Primary;
    DLX_FUSION_CHANNEL_STATE Secondary;
    WCHAR FusionPairKey[96];
} DLX_DRIVER_CONTEXT, *PDLX_DRIVER_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DLX_DRIVER_CONTEXT, DlxGetDriverContext);

typedef struct _DLX_SENSOR_CONTEXT
{
    WDFDEVICE Device;
    SENSOROBJECT SensorInstance;
    WDFIOTARGET SpbIoTarget;
    WDFWAITLOCK Lock;
    WDFWAITLOCK LifecycleLock;
    WDFTIMER Timer;

    bool PoweredOn;
    bool Started;
    bool ClientRequestedStart;
    bool BackgroundSampling;
    bool FirstSample;
    bool LastSampleValid;
    bool HardwareValidated;
    bool IsPrimary;
    bool InvalidSampleReported;
    bool PendingInvalidReport;
    bool RecoveryPending;
    ULONGLONG NextRecoveryAttemptMs;
    ULONGLONG LastClientReportMs;

    DLX_DEVICE_ROLE Role;
    ULONG IntervalMs;
    ULONG ConsecutiveIoFailures;
    ULONG ConsecutiveNotReady;
    ULONG ConsecutiveNoSample;
    ULONG RecoveryAttempts;
    FLOAT ThresholdPercent;
    FLOAT ThresholdAbsolute;
    FLOAT LastLux;
    FLOAT CalibrationScale;
    FLOAT CalibrationOffset;
    ULONG CalibrationScalePpm;
    BYTE PartId;
    WCHAR BiosName[96];
    WCHAR InstanceId[128];

    PSENSOR_PROPERTY_LIST SupportedDataFields;
    PSENSOR_COLLECTION_LIST EnumerationProperties;
    PSENSOR_COLLECTION_LIST SensorProperties;
    PSENSOR_COLLECTION_LIST SensorData;
    PSENSOR_COLLECTION_LIST DataFieldProperties;
    PSENSOR_COLLECTION_LIST Thresholds;
} DLX_SENSOR_CONTEXT, *PDLX_SENSOR_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DLX_SENSOR_CONTEXT, DlxGetSensorContext);

EVT_WDF_DRIVER_DEVICE_ADD DlxEvtDeviceAdd;
EVT_WDF_DEVICE_PREPARE_HARDWARE DlxEvtPrepareHardware;
EVT_WDF_DEVICE_RELEASE_HARDWARE DlxEvtReleaseHardware;
EVT_WDF_DEVICE_D0_ENTRY DlxEvtD0Entry;
EVT_WDF_DEVICE_D0_EXIT DlxEvtD0Exit;
EVT_WDF_TIMER DlxEvtTimer;

EVT_SENSOR_DRIVER_START_SENSOR DlxEvtSensorStart;
EVT_SENSOR_DRIVER_STOP_SENSOR DlxEvtSensorStop;
EVT_SENSOR_DRIVER_GET_SUPPORTED_DATA_FIELDS DlxEvtSensorGetSupportedDataFields;
EVT_SENSOR_DRIVER_GET_PROPERTIES DlxEvtSensorGetProperties;
EVT_SENSOR_DRIVER_GET_DATA_FIELD_PROPERTIES DlxEvtSensorGetDataFieldProperties;
EVT_SENSOR_DRIVER_GET_DATA_INTERVAL DlxEvtSensorGetDataInterval;
EVT_SENSOR_DRIVER_SET_DATA_INTERVAL DlxEvtSensorSetDataInterval;
EVT_SENSOR_DRIVER_GET_DATA_THRESHOLDS DlxEvtSensorGetDataThresholds;
EVT_SENSOR_DRIVER_SET_DATA_THRESHOLDS DlxEvtSensorSetDataThresholds;
EVT_SENSOR_DRIVER_DEVICE_IO_CONTROL DlxEvtSensorIoControl;

NTSTATUS DlxInitializeSensorContext(
    _In_ WDFDEVICE Device,
    _In_ SENSOROBJECT SensorInstance,
    _Out_ PDLX_SENSOR_CONTEXT Context);

NTSTATUS DlxRegisterFusionChannel(_Inout_ PDLX_SENSOR_CONTEXT Context);
VOID DlxUnregisterFusionChannel(_Inout_ PDLX_SENSOR_CONTEXT Context);

NTSTATUS DlxConfigureSpbTarget(
    _Inout_ PDLX_SENSOR_CONTEXT Context,
    _In_ WDFCMRESLIST ResourcesTranslated);

NTSTATUS DlxPowerOn(_Inout_ PDLX_SENSOR_CONTEXT Context);
NTSTATUS DlxReadAndReportSample(
    _Inout_ PDLX_SENSOR_CONTEXT Context,
    _Out_ ULONG* NextDelayMs);
NTSTATUS DlxStopSensor(
    _Inout_ PDLX_SENSOR_CONTEXT Context,
    _In_ bool PreserveClientRequest = false,
    _In_ bool DisableHardware = true,
    _In_ bool PoweringOff = false);

NTSTATUS DlxQueryBiosName(
    _In_ WDFDEVICE Device,
    _Out_writes_(BiosNameCount) WCHAR* BiosName,
    _In_ size_t BiosNameCount);

NTSTATUS DlxQueryInstanceId(
    _In_ WDFDEVICE Device,
    _Out_writes_(InstanceIdCount) WCHAR* InstanceId,
    _In_ size_t InstanceIdCount);

NTSTATUS DlxQueryCalibrationScale(
    _In_ WDFDEVICE Device,
    _Out_ ULONG* CalibrationScalePpm);

DLX_DEVICE_ROLE DlxRoleFromBiosName(_In_z_ const WCHAR* BiosName);
bool DlxIsKnownAcpiName(_In_z_ const WCHAR* BiosName);
