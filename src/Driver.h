// Copyright (c) Microsoft Corporation.
// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
// Licensed under the Microsoft Public License (MS-PL).
//
// Derived in part from the Microsoft Windows Driver Samples SensorCx examples.

#pragma once

#include <wdf.h>

WDF_EXTERN_C_START

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_UNLOAD DlxEvtDriverUnload;

WDF_EXTERN_C_END
