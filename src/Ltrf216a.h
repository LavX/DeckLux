// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
// Licensed under the Microsoft Public License (MS-PL).
//
// Register definitions and conversion behavior are independently implemented
// from the Lite-On LTR-F216A datasheet.

#pragma once

#include <windows.h>
#include <wdf.h>

#include "Core.h"

NTSTATUS DlxLtrf216aProbe(_In_ WDFIOTARGET IoTarget, _Out_ BYTE* PartId);
NTSTATUS DlxLtrf216aConfigure(_In_ WDFIOTARGET IoTarget, _Out_opt_ BYTE* PartId);
NTSTATUS DlxLtrf216aSetEnabled(_In_ WDFIOTARGET IoTarget, _In_ bool Enabled);
NTSTATUS DlxLtrf216aReadSample(
    _In_ WDFIOTARGET IoTarget,
    _Out_ ULONG* Raw,
    _Out_ bool* DataReady,
    _Out_ bool* PowerOnReset);
