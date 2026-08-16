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

    const float oneFusionSample[DLX_FUSION_WINDOW_SIZE] = { 12.0f, 0.0f, 0.0f };
    Check(
        NearlyEqual(DlxFusionMedian(oneFusionSample, 1), 12.0f),
        "one-sample fusion window");
    const float twoFusionSamples[DLX_FUSION_WINDOW_SIZE] = { 10.0f, 14.0f, 0.0f };
    Check(
        NearlyEqual(DlxFusionMedian(twoFusionSamples, 2), 12.0f),
        "two-sample fusion window average");
    const float threeFusionSamples[DLX_FUSION_WINDOW_SIZE] = { 200.0f, 12.0f, 14.0f };
    Check(
        NearlyEqual(DlxFusionMedian(threeFusionSamples, 3), 14.0f),
        "three-sample fusion window rejects spike");
    Check(
        DlxFusionSampleIsFresh(2000, 1000),
        "fusion sample accepted at age limit");
    Check(
        !DlxFusionSampleIsFresh(2001, 1000),
        "fusion sample rejected beyond age limit");
    Check(
        !DlxFusionSampleIsFresh(999, 1000),
        "future fusion sample rejected");

    float seededWindow[DLX_FUSION_WINDOW_SIZE] = {};
    std::uint64_t seededTimes[DLX_FUSION_WINDOW_SIZE] = {};
    std::uint32_t seededCount = 0;
    std::uint32_t seededNext = 0;
    Check(
        DlxFusionPushSample(
            seededWindow,
            seededTimes,
            &seededCount,
            &seededNext,
            10.0f,
            1000) &&
            seededCount == DLX_FUSION_WINDOW_SIZE &&
            seededNext == 0 &&
            NearlyEqual(DlxFusionMedian(seededWindow, seededCount), 10.0f),
        "first fusion sample seeds complete median window");
    Check(
        DlxFusionPushSample(
            seededWindow,
            seededTimes,
            &seededCount,
            &seededNext,
            1000.0f,
            1100) &&
            seededNext == 1 &&
            NearlyEqual(DlxFusionMedian(seededWindow, seededCount), 10.0f),
        "seeded median rejects second-sample spike");
    Check(
        DlxFusionPushSample(
            seededWindow,
            seededTimes,
            &seededCount,
            &seededNext,
            12.0f,
            1200) &&
        DlxFusionPushSample(
            seededWindow,
            seededTimes,
            &seededCount,
            &seededNext,
            14.0f,
            1300) &&
            seededNext == 0 &&
            NearlyEqual(DlxFusionMedian(seededWindow, seededCount), 14.0f),
        "fusion window rotates across all three slots");
    Check(
        !DlxFusionPushSample(
            seededWindow,
            seededTimes,
            &seededCount,
            &seededNext,
            std::numeric_limits<float>::infinity(),
            1400),
        "fusion window rejects non-finite sample");

    const float expirySamples[DLX_FUSION_WINDOW_SIZE] =
        { 10.0f, 10.0f, 100.0f };
    const std::uint64_t expiryTimes[DLX_FUSION_WINDOW_SIZE] =
        { 1000, 1000, 6000 };
    float freshMedian = 0.0f;
    Check(
        DlxFusionFreshMedian(
            expirySamples,
            expiryTimes,
            DLX_FUSION_WINDOW_SIZE,
            6000,
            &freshMedian) &&
            NearlyEqual(freshMedian, 100.0f),
        "fusion median excludes individually expired samples");
    Check(
        !DlxFusionFreshMedian(
            expirySamples,
            expiryTimes,
            DLX_FUSION_WINDOW_SIZE,
            7001,
            &freshMedian),
        "fusion median rejects a fully expired channel");
    Check(
        DlxFusionMaximumScalePpm(23000000, false, 31000000) == 23000000 &&
        DlxFusionMaximumScalePpm(23000000, true, 21000000) == 23000000 &&
        DlxFusionMaximumScalePpm(23000000, true, 31000000) == 31000000,
        "fused range uses only registered channel calibrations");
    Check(
        NearlyEqual(
            DlxFusionResolution(23000000, false, 31000000),
            DlxLtrf216aResolution(23000000) * 0.5f) &&
        NearlyEqual(
            DlxFusionResolution(23000000, true, 21000000),
            DlxLtrf216aResolution(21000000) * 0.5f) &&
        NearlyEqual(
            DlxFusionResolution(23000000, true, 0),
            DlxLtrf216aResolution(23000000) * 0.5f),
        "fused resolution reflects registered channels and temporal midpoint");
    Check(
        DlxFusionSamplingInterval(true, true, 5000, 250) == 250 &&
            DlxFusionSamplingInterval(true, true, 100, 250) == 100 &&
            DlxFusionSamplingInterval(true, false, 100, 250) == 250 &&
            DlxFusionSamplingInterval(false, false, 5000, 250) == 5000,
        "background acquisition cadence follows active client state");
    Check(
        DlxFusionClientReportIsDue(1000, 0, 5000) &&
            !DlxFusionClientReportIsDue(5999, 1000, 5000) &&
            DlxFusionClientReportIsDue(6000, 1000, 5000) &&
            !DlxFusionClientReportIsDue(999, 1000, 5000),
        "diagnostic report cadence honors client interval");
    Check(
        DlxFusionRecoveryTimerDelay(2000, 250) == 250 &&
            DlxFusionRecoveryTimerDelay(120, 250) == 120,
        "fallback reporting preserves recovery backoff boundary");

    float fusedLux = -1.0f;
    Check(
        DlxFuseAmbientLux(true, 40.0f, true, 5.0f, &fusedLux) &&
            NearlyEqual(fusedLux, 40.0f),
        "fusion rejects lower occluded channel");
    Check(
        DlxFuseAmbientLux(true, 5.0f, true, 40.0f, &fusedLux) &&
            NearlyEqual(fusedLux, 40.0f),
        "fusion uses brighter alternate channel");
    Check(
        DlxFuseAmbientLux(false, 0.0f, true, 25.0f, &fusedLux) &&
            NearlyEqual(fusedLux, 25.0f),
        "fusion falls back to healthy secondary");
    Check(
        DlxFuseAmbientLux(true, 25.0f, false, 0.0f, &fusedLux) &&
            NearlyEqual(fusedLux, 25.0f),
        "fusion falls back to healthy primary");
    Check(
        !DlxFuseAmbientLux(false, 0.0f, false, 0.0f, &fusedLux),
        "fusion rejects two invalid channels");
    Check(
        !DlxFuseAmbientLux(
            true,
            std::numeric_limits<float>::quiet_NaN(),
            false,
            0.0f,
            &fusedLux),
        "fusion rejects non-finite input");
    Check(
        DlxFuseAmbientLux(
            true,
            std::numeric_limits<float>::infinity(),
            true,
            18.0f,
            &fusedLux) && NearlyEqual(fusedLux, 18.0f),
        "fusion ignores non-finite channel when peer is valid");
    Check(
        DlxFuseAmbientLux(
            true,
            -1.0f,
            true,
            18.0f,
            &fusedLux) && NearlyEqual(fusedLux, 18.0f),
        "fusion ignores negative channel when peer is valid");
    Check(
        !DlxFuseAmbientLux(true, 18.0f, true, 20.0f, nullptr),
        "fusion requires output storage");

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
