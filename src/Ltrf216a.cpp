// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
// Licensed under the Microsoft Public License (MS-PL).
//
// Register definitions and conversion behavior are independently implemented
// from the Lite-On LTR-F216A datasheet. No Linux driver source is incorporated.

#include "Device.h"

namespace
{
NTSTATUS ReadRegister(
    _In_ WDFIOTARGET IoTarget,
    _In_ BYTE Register,
    _Out_writes_bytes_(Length) BYTE* Buffer,
    _In_ ULONG Length)
{
    if (IoTarget == nullptr || Buffer == nullptr || Length == 0)
    {
        return STATUS_INVALID_PARAMETER;
    }

    return I2CSensorReadRegister(IoTarget, Register, Buffer, Length);
}

NTSTATUS WriteRegister(
    _In_ WDFIOTARGET IoTarget,
    _In_ BYTE Register,
    _In_reads_bytes_(Length) const BYTE* Buffer,
    _In_ ULONG Length)
{
    if (IoTarget == nullptr || Buffer == nullptr || Length == 0)
    {
        return STATUS_INVALID_PARAMETER;
    }

    return I2CSensorWriteRegister(
        IoTarget,
        Register,
        const_cast<BYTE*>(Buffer),
        Length);
}
}

NTSTATUS DlxLtrf216aProbe(_In_ WDFIOTARGET IoTarget, _Out_ BYTE* PartId)
{
    if (PartId == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *PartId = 0;
    NTSTATUS status = ReadRegister(
        IoTarget,
        DLX_LTRF216A_REG_PART_ID,
        PartId,
        sizeof(*PartId));

    if (!NT_SUCCESS(status))
    {
        return status;
    }

    // PART_ID identifies the common Lite-On register family, not the exact
    // optical variant. Platform firmware or explicit opt-in selects LTR-F216A.
    if (!DlxLtrf216aIsExpectedRegisterFamily(*PartId))
    {
        DLX_TRACE_ERROR("Unexpected PART_ID 0x%02X", *PartId);
        return STATUS_DEVICE_HARDWARE_ERROR;
    }

    return STATUS_SUCCESS;
}

NTSTATUS DlxLtrf216aConfigure(_In_ WDFIOTARGET IoTarget, _Out_opt_ BYTE* PartId)
{
    BYTE detectedPart = 0;
    NTSTATUS status = DlxLtrf216aProbe(IoTarget, &detectedPart);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    const BYTE reset = DLX_LTRF216A_MAIN_CTRL_RESET;
    const NTSTATUS resetStatus = WriteRegister(
        IoTarget,
        DLX_LTRF216A_REG_MAIN_CTRL,
        &reset,
        sizeof(reset));

    // Some controllers surface a NACK while the part enters reset. Recovery is
    // accepted only after the expected part ID can be read again.
    status = STATUS_IO_TIMEOUT;
    for (ULONG attempt = 0; attempt < 10; ++attempt)
    {
        Sleep(10);
        status = DlxLtrf216aProbe(IoTarget, &detectedPart);
        if (NT_SUCCESS(status))
        {
            break;
        }
    }

    if (!NT_SUCCESS(status))
    {
        DLX_TRACE_ERROR(
            "Sensor did not recover after reset (reset status 0x%08X, probe status 0x%08X)",
            static_cast<ULONG>(resetStatus),
            static_cast<ULONG>(status));
        return status;
    }

    const BYTE disabled = 0;
    status = WriteRegister(
        IoTarget,
        DLX_LTRF216A_REG_MAIN_CTRL,
        &disabled,
        sizeof(disabled));

    if (NT_SUCCESS(status))
    {
        const BYTE resolution = DLX_LTRF216A_MEAS_RES_18BIT_100MS;
        status = WriteRegister(
            IoTarget,
            DLX_LTRF216A_REG_MEAS_RES,
            &resolution,
            sizeof(resolution));
    }

    if (NT_SUCCESS(status))
    {
        const BYTE gain = DLX_LTRF216A_GAIN_3X;
        status = WriteRegister(
            IoTarget,
            DLX_LTRF216A_REG_GAIN,
            &gain,
            sizeof(gain));
    }

    BYTE resolutionReadback = 0;
    BYTE gainReadback = 0;
    if (NT_SUCCESS(status))
    {
        status = ReadRegister(
            IoTarget,
            DLX_LTRF216A_REG_MEAS_RES,
            &resolutionReadback,
            sizeof(resolutionReadback));
    }

    if (NT_SUCCESS(status))
    {
        status = ReadRegister(
            IoTarget,
            DLX_LTRF216A_REG_GAIN,
            &gainReadback,
            sizeof(gainReadback));
    }

    if (NT_SUCCESS(status) &&
        (resolutionReadback != DLX_LTRF216A_MEAS_RES_18BIT_100MS ||
         gainReadback != DLX_LTRF216A_GAIN_3X))
    {
        DLX_TRACE_ERROR(
            "Configuration readback failed: resolution 0x%02X, gain 0x%02X",
            resolutionReadback,
            gainReadback);
        status = STATUS_DEVICE_CONFIGURATION_ERROR;
    }

    // A reset or supply glitch sets MAIN_STATUS.PowerOn and reading the
    // register clears it. Clear the expected reset indication here so any
    // later observation represents a runtime reset that needs recovery.
    BYTE statusReadback = 0;
    if (NT_SUCCESS(status))
    {
        status = ReadRegister(
            IoTarget,
            DLX_LTRF216A_REG_MAIN_STATUS,
            &statusReadback,
            sizeof(statusReadback));
    }

    if (NT_SUCCESS(status) && PartId != nullptr)
    {
        *PartId = detectedPart;
    }

    return status;
}

NTSTATUS DlxLtrf216aSetEnabled(_In_ WDFIOTARGET IoTarget, _In_ bool Enabled)
{
    const BYTE value = Enabled ? DLX_LTRF216A_MAIN_CTRL_ENABLE : 0;
    return WriteRegister(
        IoTarget,
        DLX_LTRF216A_REG_MAIN_CTRL,
        &value,
        sizeof(value));
}

NTSTATUS DlxLtrf216aReadSample(
    _In_ WDFIOTARGET IoTarget,
    _Out_ ULONG* Raw,
    _Out_ bool* DataReady,
    _Out_ bool* PowerOnReset)
{
    if (Raw == nullptr || DataReady == nullptr || PowerOnReset == nullptr)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *Raw = 0;
    *DataReady = false;
    *PowerOnReset = false;

    BYTE statusRegister = 0;
    NTSTATUS status = ReadRegister(
        IoTarget,
        DLX_LTRF216A_REG_MAIN_STATUS,
        &statusRegister,
        sizeof(statusRegister));

    if (!NT_SUCCESS(status))
    {
        return status;
    }

    *PowerOnReset = DlxLtrf216aStatusIndicatesPowerOn(statusRegister);
    if (*PowerOnReset)
    {
        // Configuration and ALS_ENABLE may have returned to their power-on
        // defaults. Do not publish a possibly stale sample from this cycle.
        return STATUS_SUCCESS;
    }

    if (!DlxLtrf216aStatusHasData(statusRegister))
    {
        return STATUS_SUCCESS;
    }

    BYTE data[3] = {};
    status = ReadRegister(
        IoTarget,
        DLX_LTRF216A_REG_ALS_DATA,
        data,
        ARRAYSIZE(data));

    if (NT_SUCCESS(status))
    {
        *Raw = DlxLtrf216aDecodeRaw(data);
        *DataReady = true;
    }

    return status;
}
