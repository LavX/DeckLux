// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
// Licensed under the Microsoft Public License (MS-PL).
//
// Platform-light LTR-F216A decoding, conversion, and ALS threshold logic.

#pragma once

#include <cmath>
#include <cstdint>

constexpr std::uint8_t DLX_LTRF216A_REG_MAIN_CTRL = 0x00;
constexpr std::uint8_t DLX_LTRF216A_REG_MEAS_RES = 0x04;
constexpr std::uint8_t DLX_LTRF216A_REG_GAIN = 0x05;
constexpr std::uint8_t DLX_LTRF216A_REG_PART_ID = 0x06;
constexpr std::uint8_t DLX_LTRF216A_REG_MAIN_STATUS = 0x07;
constexpr std::uint8_t DLX_LTRF216A_REG_ALS_DATA = 0x0D;

constexpr std::uint8_t DLX_LTRF216A_MAIN_CTRL_ENABLE = 0x02;
constexpr std::uint8_t DLX_LTRF216A_MAIN_CTRL_RESET = 0x10;
constexpr std::uint8_t DLX_LTRF216A_STATUS_DATA_READY = 0x08;
constexpr std::uint8_t DLX_LTRF216A_STATUS_POWER_ON = 0x20;
constexpr std::uint8_t DLX_LTRF216A_PART_ID_MASK = 0xF0;
constexpr std::uint8_t DLX_LTRF216A_PART_ID_VALUE = 0xB0;

constexpr std::uint8_t DLX_LTRF216A_MEAS_RES_18BIT_100MS = 0x22;
constexpr std::uint8_t DLX_LTRF216A_GAIN_3X = 0x01;
constexpr std::uint32_t DLX_LTRF216A_INTEGRATION_MS = 100;
constexpr std::uint32_t DLX_LTRF216A_STARTUP_DELAY_MS = 120;
constexpr std::uint32_t DLX_LTRF216A_ACQUISITION_RETRY_MS = 10;
constexpr std::uint32_t DLX_LTRF216A_MAX_NO_SAMPLE_RETRIES = 12;
constexpr std::uint32_t DLX_LTRF216A_MAX_FAST_RECOVERIES = 3;
constexpr std::uint32_t DLX_LTRF216A_RECOVERY_BACKOFF_MS = 2000;
constexpr float DLX_LTRF216A_LUX_PER_COUNT = 0.15f;
constexpr std::uint32_t DLX_LTRF216A_MAX_RAW_18BIT = 0x3FFFF;

// Calibration scales are persisted as unsigned parts-per-million so the
// package does not depend on locale-specific floating-point serialization.
constexpr std::uint32_t DLX_CALIBRATION_SCALE_PPM_DENOMINATOR = 1000000;
constexpr std::uint32_t DLX_CALIBRATION_SCALE_PPM_DEFAULT =
    DLX_CALIBRATION_SCALE_PPM_DENOMINATOR;
constexpr std::uint32_t DLX_CALIBRATION_SCALE_PPM_MINIMUM = 10000;     // 0.01x
constexpr std::uint32_t DLX_CALIBRATION_SCALE_PPM_MAXIMUM = 100000000; // 100x

// Valve's legacy downstream conversion produced 16/9 as many lux per count
// as the corrected conversion used by DeckLux. Firmware gains made for that
// output therefore need this ratio exactly once.
constexpr std::uint32_t DLX_LTRF216A_FACTORY_LEGACY_SCALE_NUMERATOR = 16;
constexpr std::uint32_t DLX_LTRF216A_FACTORY_LEGACY_SCALE_DENOMINATOR = 9;

inline bool DlxIsCalibrationScalePpmValid(std::uint32_t ScalePpm)
{
    return ScalePpm >= DLX_CALIBRATION_SCALE_PPM_MINIMUM &&
           ScalePpm <= DLX_CALIBRATION_SCALE_PPM_MAXIMUM;
}

inline float DlxCalibrationScaleFromPpm(std::uint32_t ScalePpm)
{
    const std::uint32_t boundedScalePpm =
        DlxIsCalibrationScalePpmValid(ScalePpm)
        ? ScalePpm
        : DLX_CALIBRATION_SCALE_PPM_DEFAULT;

    return static_cast<float>(boundedScalePpm) /
           static_cast<float>(DLX_CALIBRATION_SCALE_PPM_DENOMINATOR);
}

inline std::uint32_t DlxLtrf216aLegacyFactoryGainToScalePpm(
    double LegacyFactoryGain)
{
    if (!std::isfinite(LegacyFactoryGain) || LegacyFactoryGain <= 0.0)
    {
        return 0;
    }

    const double scalePpm =
        LegacyFactoryGain *
        static_cast<double>(DLX_LTRF216A_FACTORY_LEGACY_SCALE_NUMERATOR) *
        static_cast<double>(DLX_CALIBRATION_SCALE_PPM_DENOMINATOR) /
        static_cast<double>(DLX_LTRF216A_FACTORY_LEGACY_SCALE_DENOMINATOR);

    if (scalePpm < static_cast<double>(DLX_CALIBRATION_SCALE_PPM_MINIMUM) ||
        scalePpm > static_cast<double>(DLX_CALIBRATION_SCALE_PPM_MAXIMUM))
    {
        return 0;
    }

    return static_cast<std::uint32_t>(scalePpm + 0.5);
}

inline bool DlxLtrf216aIsExpectedRegisterFamily(std::uint8_t PartId)
{
    return (PartId & DLX_LTRF216A_PART_ID_MASK) == DLX_LTRF216A_PART_ID_VALUE;
}

inline bool DlxLtrf216aStatusIndicatesPowerOn(std::uint8_t Status)
{
    return (Status & DLX_LTRF216A_STATUS_POWER_ON) != 0;
}

inline bool DlxLtrf216aStatusHasData(std::uint8_t Status)
{
    return (Status & DLX_LTRF216A_STATUS_DATA_READY) != 0;
}

inline bool DlxLtrf216aShouldRetryAcquisition(std::uint32_t NoSampleCount)
{
    return NoSampleCount <= DLX_LTRF216A_MAX_NO_SAMPLE_RETRIES;
}

inline std::uint32_t DlxLtrf216aRecoveryDelay(std::uint32_t RecoveryAttempt)
{
    return RecoveryAttempt <= DLX_LTRF216A_MAX_FAST_RECOVERIES
        ? DLX_LTRF216A_STARTUP_DELAY_MS
        : DLX_LTRF216A_RECOVERY_BACKOFF_MS;
}

inline std::uint32_t DlxLtrf216aDecodeRaw(const std::uint8_t Data[3])
{
    if (Data == nullptr)
    {
        return 0;
    }

    const std::uint32_t value =
        static_cast<std::uint32_t>(Data[0]) |
        (static_cast<std::uint32_t>(Data[1]) << 8) |
        (static_cast<std::uint32_t>(Data[2]) << 16);

    return value & DLX_LTRF216A_MAX_RAW_18BIT;
}

inline float DlxLtrf216aRawToLux(
    std::uint32_t Raw,
    float Scale,
    float Offset)
{
    float lux =
        (static_cast<float>(Raw & DLX_LTRF216A_MAX_RAW_18BIT) *
            DLX_LTRF216A_LUX_PER_COUNT * Scale) +
        Offset;

    return lux < 0.0f ? 0.0f : lux;
}

inline float DlxLtrf216aResolution(std::uint32_t ScalePpm)
{
    return DLX_LTRF216A_LUX_PER_COUNT *
           DlxCalibrationScaleFromPpm(ScalePpm);
}

inline float DlxLtrf216aMaximumLux(std::uint32_t ScalePpm)
{
    return static_cast<float>(DLX_LTRF216A_MAX_RAW_18BIT) *
           DlxLtrf216aResolution(ScalePpm);
}

inline bool DlxShouldReportLux(
    bool FirstSample,
    bool LastSampleValid,
    float LastLux,
    float Lux,
    float ThresholdPercent,
    float ThresholdAbsolute)
{
    if (FirstSample || !LastSampleValid)
    {
        return true;
    }

    if (ThresholdPercent == 0.0f && ThresholdAbsolute == 0.0f)
    {
        return true;
    }

    const float difference = std::fabs(Lux - LastLux);
    const float percentageDifference =
        std::fabs(LastLux) * ThresholdPercent;

    return difference >= percentageDifference &&
           difference >= ThresholdAbsolute;
}
