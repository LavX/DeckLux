// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
// Licensed under the Microsoft Public License (MS-PL).

#include "Core.h"

#include <cmath>
#include <cstdio>
#include <limits>

namespace
{
int failures = 0;

void Check(bool Condition, const char* Name)
{
    if (!Condition)
    {
        std::fprintf(stderr, "FAIL: %s\n", Name);
        ++failures;
    }
}

bool NearlyEqual(float Left, float Right, float Tolerance = 0.001f)
{
    return std::fabs(Left - Right) <= Tolerance;
}
}

int main()
{
    Check(DlxLtrf216aIsExpectedRegisterFamily(0xB0), "PART_ID B0 family accepted");
    Check(DlxLtrf216aIsExpectedRegisterFamily(0xB1), "PART_ID B1 family accepted");
    Check(DlxLtrf216aIsExpectedRegisterFamily(0xBF), "PART_ID BF revision accepted");
    Check(!DlxLtrf216aIsExpectedRegisterFamily(0xA1), "PART_ID A1 rejected");
    Check(!DlxLtrf216aIsExpectedRegisterFamily(0xC1), "PART_ID C1 rejected");

    Check(
        DlxLtrf216aStatusIndicatesPowerOn(DLX_LTRF216A_STATUS_POWER_ON),
        "power-on status detected");
    Check(
        !DlxLtrf216aStatusIndicatesPowerOn(DLX_LTRF216A_STATUS_DATA_READY),
        "data-ready is not power-on status");
    Check(
        DlxLtrf216aStatusHasData(DLX_LTRF216A_STATUS_DATA_READY),
        "data-ready status detected");
    Check(
        DLX_LTRF216A_STARTUP_DELAY_MS == 120,
        "startup and recovery delay");
    Check(
        DlxLtrf216aShouldRetryAcquisition(1),
        "first no-sample retry allowed");
    Check(
        DlxLtrf216aShouldRetryAcquisition(DLX_LTRF216A_MAX_NO_SAMPLE_RETRIES),
        "last bounded no-sample retry allowed");
    Check(
        !DlxLtrf216aShouldRetryAcquisition(DLX_LTRF216A_MAX_NO_SAMPLE_RETRIES + 1),
        "no-sample retry bound enforced");
    Check(
        DlxLtrf216aRecoveryDelay(DLX_LTRF216A_MAX_FAST_RECOVERIES) ==
            DLX_LTRF216A_STARTUP_DELAY_MS,
        "last fast recovery uses startup delay");
    Check(
        DlxLtrf216aRecoveryDelay(DLX_LTRF216A_MAX_FAST_RECOVERIES + 1) ==
            DLX_LTRF216A_RECOVERY_BACKOFF_MS,
        "repeated recovery uses slow backoff");

    const std::uint8_t littleEndian[] = { 0x56, 0x34, 0x02 };
    Check(
        DlxLtrf216aDecodeRaw(littleEndian) == 0x23456,
        "24-bit little-endian decode");

    const std::uint8_t highBits[] = { 0xFF, 0xFF, 0xFF };
    Check(
        DlxLtrf216aDecodeRaw(highBits) == DLX_LTRF216A_MAX_RAW_18BIT,
        "18-bit result mask");

    Check(
        NearlyEqual(DlxLtrf216aRawToLux(100, 1.0f, 0.0f), 15.0f),
        "datasheet lux conversion");
    Check(
        NearlyEqual(DlxLtrf216aRawToLux(100, 2.0f, 1.0f), 31.0f),
        "calibration scale and offset");
    Check(
        NearlyEqual(DlxLtrf216aRawToLux(0, 1.0f, -2.0f), 0.0f),
        "negative calibrated lux clamp");
    Check(
        NearlyEqual(
            DlxLtrf216aRawToLux(DLX_LTRF216A_MAX_RAW_18BIT, 1.0f, 0.0f),
            39321.45f,
            0.01f),
        "18-bit maximum lux");

    Check(
        !DlxIsCalibrationScalePpmValid(
            DLX_CALIBRATION_SCALE_PPM_MINIMUM - 1),
        "calibration scale below minimum rejected");
    Check(
        DlxIsCalibrationScalePpmValid(DLX_CALIBRATION_SCALE_PPM_MINIMUM),
        "minimum calibration scale accepted");
    Check(
        DlxIsCalibrationScalePpmValid(DLX_CALIBRATION_SCALE_PPM_DEFAULT),
        "nominal calibration scale accepted");
    Check(
        DlxIsCalibrationScalePpmValid(DLX_CALIBRATION_SCALE_PPM_MAXIMUM),
        "maximum calibration scale accepted");
    Check(
        !DlxIsCalibrationScalePpmValid(
            DLX_CALIBRATION_SCALE_PPM_MAXIMUM + 1),
        "calibration scale above maximum rejected");
    Check(
        NearlyEqual(
            DlxCalibrationScaleFromPpm(DLX_CALIBRATION_SCALE_PPM_MINIMUM),
            0.01f),
        "minimum ppm scale conversion");
    Check(
        NearlyEqual(
            DlxCalibrationScaleFromPpm(DLX_CALIBRATION_SCALE_PPM_MAXIMUM),
            100.0f),
        "maximum ppm scale conversion");
    Check(
        NearlyEqual(DlxCalibrationScaleFromPpm(0), 1.0f),
        "invalid ppm scale uses nominal fallback");

    constexpr double syntheticLegacyFactoryGain = 12.5;
    constexpr std::uint32_t syntheticScalePpm = 22222222;
    Check(
        DlxLtrf216aLegacyFactoryGainToScalePpm(
            syntheticLegacyFactoryGain) == syntheticScalePpm,
        "synthetic legacy factory gain rounds to exact ppm scale");
    Check(
        DlxLtrf216aLegacyFactoryGainToScalePpm(0.0) == 0,
        "zero legacy factory gain rejected");
    Check(
        DlxLtrf216aLegacyFactoryGainToScalePpm(100.0) == 0,
        "out-of-range legacy factory gain rejected");
    Check(
        NearlyEqual(
            DlxCalibrationScaleFromPpm(syntheticScalePpm),
            22.222221f,
            0.000002f),
        "synthetic ppm scale conversion");
    Check(
        NearlyEqual(
            DlxLtrf216aRawToLux(
                100,
                DlxCalibrationScaleFromPpm(syntheticScalePpm),
                0.0f),
            333.3333f,
            0.0001f),
        "per-device scale applied to lux sample");
    Check(
        NearlyEqual(
            DlxLtrf216aResolution(syntheticScalePpm),
            3.3333333f,
            0.00001f),
        "calibrated sensor resolution");
    Check(
        NearlyEqual(
            DlxLtrf216aMaximumLux(syntheticScalePpm),
            873809.94f,
            0.25f),
        "calibrated 18-bit maximum lux");
    Check(
        NearlyEqual(
            DlxLtrf216aMaximumLux(0),
            DlxLtrf216aMaximumLux(DLX_CALIBRATION_SCALE_PPM_DEFAULT),
            0.01f),
        "invalid calibration range uses nominal fallback");

    Check(
        DlxShouldReportLux(true, true, 100.0f, 100.0f, 0.25f, 1.0f),
        "first sample always reports");
    Check(
        DlxShouldReportLux(false, false, 100.0f, 100.0f, 0.25f, 1.0f),
        "validity recovery always reports");
    Check(
        DlxShouldReportLux(false, true, 4.0f, 3.0f, 0.25f, 1.0f),
        "Windows threshold example 4 to 3");
    Check(
        !DlxShouldReportLux(false, true, 1.0f, 0.5f, 0.25f, 1.0f),
        "Windows threshold example 1 to 0.5");
    Check(
        !DlxShouldReportLux(false, true, 100.0f, 90.0f, 0.25f, 1.0f),
        "Windows threshold example 100 to 90");
    Check(
        DlxShouldReportLux(false, true, 0.0f, 1.0f, 0.25f, 1.0f),
        "zero-lux prior sample");
    Check(
        DlxShouldReportLux(false, true, 50.0f, 50.0f, 0.0f, 0.0f),
        "zero thresholds stream");

    if (failures != 0)
    {
        std::fprintf(stderr, "%d DeckLux core test(s) failed.\n", failures);
        return 1;
    }

    std::puts("All DeckLux core tests passed.");
    return 0;
}
