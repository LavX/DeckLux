<!-- Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>. Licensed under the MS-PL. -->

# Factory calibration design

DeckLux converts an LTR-F216A sample at its fixed 3x-gain, 100 ms setting as

```text
base_lux = raw_count * 0.15
reported_lux = max(0, base_lux * conversion_scale)
```

`conversion_scale` is per physical sensor. It is `1.0` when no trusted
calibration is available. An offset is not part of the factory-calibration
contract.

## Why the firmware value is not the conversion scale

Steam Deck factory gains were made for Valve's older downstream Linux
conversion. At the default sensor setting that path produced

```text
legacy_lux = raw_count * 8 / (3 * 1 * 10)
           = raw_count * 0.2666666667
```

The corrected upstream conversion produces

```text
base_lux = raw_count * 45 / (3 * 100)
         = raw_count * 0.15
```

The Linux patch that introduced the raw IIO attribute states that Steam Deck
userspace multiplied the old processed value by a factory constant stored in
BIOS. Therefore a firmware factory gain `G` must be converted for DeckLux as

```text
conversion_scale = G * (0.2666666667 / 0.15)
                 = G * 16 / 9
```

Apply this ratio exactly once. Multiplying corrected lux directly by `G`
under-reports by `9/16`; applying `16/9` twice over-reports. The Linux window
factor is `1`, so DeckLux must not add a second generic optical-window factor.

Factory gains vary by unit. As a synthetic example, gains of `12.5` and
`11.25` become scales of `22.22222222222222` and `20.0`. These numbers are
test data, not defaults or measurements from a physical Steam Deck.

## Authoritative sensor and OEM-string mapping

Valve's public SteamOS Manager returns the gains in sensor-index order and
maps that same index to the Linux ACPI/IIO path:

| Platform | DeckLux role | ACPI leaf | ACPI instance | Sensor index | SMBIOS Type 11 string |
| --- | --- | --- | --- | ---: | ---: |
| Jupiter (LCD) | Primary | `LTRF` | `PRP0001:01` | 0 | 2 |
| Galileo (OLED) | Primary | `LTRF` | `PRP0001:00` | 0 | 2 |
| Galileo (OLED) | Alternate/secondary | `LTRS` | `PRP0001:01` | 1 | 4 |

The important Jupiter exception is that its only sensor is index 0 but ACPI
instance `:01`. On Galileo, index and ACPI-instance suffix are both 0 or 1.
Never infer the OEM-string slot from the instance suffix alone.

"Primary" and "alternate" are enumeration labels, not a claim that one
physical sensor is optically superior. DeckLux installs only `LTRF` by default
and exposes `LTRS` only through the explicit OLED-secondary path.

## Driver property contract

The installer provisions the scale on the exact authorized devnode using:

```text
Property key: {91B118A2-7B5D-4689-A5E7-C43E332B4966}, PID 3
Name:         DEVPKEY_DeckLux_CalibrationScalePpm
Type:         DEVPROP_TYPE_UINT32
Range:        10,000 through 100,000,000, inclusive
Default:      absent (driver uses 1,000,000, meaning scale 1.0)
```

The value is the four-byte integer `round(conversion_scale * 1,000,000)`, not
the firmware factory gain. Missing, malformed, or out-of-range data does not
prevent the sensor from starting; the driver uses scale `1.0` and reports
uncalibrated values instead. Calibration is per devnode and must not leak from
one physical sensor to another.

## Provisioning rules

1. Identify Valve `Jupiter` or `Galileo` before interpreting OEM strings.
2. Read the raw SMBIOS Type 11 string set and select only the slots in the
   table above.
3. Parse with invariant-culture decimal rules and reject missing, empty,
   non-finite, non-positive, or trailing-data values.
4. Compute `round(G * 16 / 9 * 1,000,000)`, validate it against the driver
   range, and store it as `DEVPROP_TYPE_UINT32` on the matching exact devnode.
5. Record the prior property state so uninstall and failed installation can
   restore it exactly.

If any identity, table structure, mapping, parse, or range check fails, do not
guess and do not cross-assign another sensor's gain. Leave the property absent
and retain the uncalibrated `1.0` fallback.

For an explicitly authorized compatible non-Deck LTR-F216A, Valve's OEM slots
have no defined meaning. Such a device uses `1.0` unless the operator supplies
an independently established per-device scale through a future explicit
calibration workflow. Generic `ACPI\PRP0001` identity never authorizes either
binding or Valve-specific calibration.

## Dual-sensor behavior

DeckLux exposes Galileo's two physical sensors separately. It does not fuse,
average, median-filter, or choose between them. Valve's Steam client exposes
diagnostic fields named primary, alternate, and median, but its fusion
algorithm is proprietary and is not specified by the public SteamOS Manager or
Linux driver. Any future fusion belongs above the physical sensor driver and
must consume independently calibrated values.

When both Galileo sensors are explicitly installed,
`scripts/Compare-DeckLuxSensors.ps1` collects them in shared cycles and
correlates only valid readings whose sensor timestamps are within the selected
skew. It temporarily requests fresh per-interval reports from each WinRT client
and verifies restoration of every changed sampling property. Pair deltas and
ratios are diagnostics, not a fusion result or brightness recommendation.

## Source record

- Valve's official SteamOS Manager, pinned commit
  [`7de5caad`](https://gitlab.steamos.cloud/holo/steamos-manager/-/blob/7de5caad5e4d4f3bd9f179ddd7acc94e1cb2d677/steamos-manager/src/manager/root.rs#L289-322),
  selects OEM string 2 for Jupiter, strings 2 and 4 for Galileo, and maps
  Jupiter to `PRP0001:01` versus Galileo index-to-instance order.
- The upstream raw-attribute patch
  [explains the BIOS factory multiplier and records both formulas](https://lore.kernel.org/r/20220812100424.529425-1-shreeya.patel@collabora.com).
- Linux mainline at pinned revision
  [`2687c848`](https://github.com/torvalds/linux/blob/2687c848e578/drivers/iio/light/ltrf216a.c#L241-L289)
  implements the corrected calculation; its defaults are at
  [lines 494-496](https://github.com/torvalds/linux/blob/2687c848e578/drivers/iio/light/ltrf216a.c#L494-L496)
  and the LTR-F216A multiplier is at
  [lines 548-550](https://github.com/torvalds/linux/blob/2687c848e578/drivers/iio/light/ltrf216a.c#L548-L550).
- The archived Valve source-package mirror at pinned commit
  [`6d030343`](https://gitlab.com/evlaV/linux-integration/-/blob/6d030343b482bc42571b8686a7be37ff96da29c8/drivers/iio/light/ltrf216a.c#L198-208)
  preserves the old downstream formula and its
  [3x/100 ms defaults](https://gitlab.com/evlaV/linux-integration/-/blob/6d030343b482bc42571b8686a7be37ff96da29c8/drivers/iio/light/ltrf216a.c#L298-307).

The first three sources are authoritative for the firmware mapping and
conversion semantics. The archived mirror is a line-addressable historical
cross-check sourced from Valve's published SteamOS package.
