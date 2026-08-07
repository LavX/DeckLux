// Copyright (c) Microsoft Corporation.
// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
// Licensed under the Microsoft Public License (MS-PL).
//
// Derived in part from the Microsoft Windows Driver Samples ADXL345 SensorCx
// sample.

#include "Device.h"
#include "Driver.h"

NTSTATUS DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath)
{
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, DlxEvtDeviceAdd);
    config.DriverPoolTag = DLX_POOL_TAG;
    config.EvtDriverUnload = DlxEvtDriverUnload;

    const NTSTATUS status = WdfDriverCreate(
        DriverObject,
        RegistryPath,
        WDF_NO_OBJECT_ATTRIBUTES,
        &config,
        WDF_NO_HANDLE);

    if (!NT_SUCCESS(status))
    {
        DLX_TRACE_ERROR("WdfDriverCreate failed: 0x%08X", static_cast<ULONG>(status));
    }

    return status;
}

VOID DlxEvtDriverUnload(_In_ WDFDRIVER Driver)
{
    UNREFERENCED_PARAMETER(Driver);
    DLX_TRACE_INFO("Driver unloaded");
}
