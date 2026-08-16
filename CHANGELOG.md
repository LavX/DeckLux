# Changelog

## 1.1.0 - 2026-08-16

- Added dual-sensor installation by default on Steam Deck OLED while retaining
  the single-sensor topology on Steam Deck LCD.
- Added a preferred logical OLED sensor that median-filters each independently
  calibrated channel and selects the brighter fresh value, with one-channel
  fallback when a sensor is stale or unavailable.
- Kept the OLED secondary sensor available as a nonpreferred raw diagnostic
  channel and added timestamp-correlated fused-versus-raw comparison.
- Added verified restoration of temporary WinRT report intervals, latency, and
  lux thresholds used during sensor comparison.
- Added strict Setup validation and rollback support for each model's exact
  recorded default topology.
- Fixed Setup ACL validation so its own read-only Program Files permissions are
  accepted without allowing non-administrator write, delete, or ownership rights.
- Included the comparison tool in graphical and portable release payloads.
- Kept display-brightness curve policy in Windows and applications; DeckLux
  supplies calibrated, occlusion-resistant illuminance.

## 1.0.0 - 2026-08-07

- Added Windows ambient-light sensor support for the Steam Deck OLED primary
  LTR-F216A sensor.
- Added per-device Valve factory calibration from SMBIOS firmware data.
- Added exact-device authorization to prevent generic `ACPI\PRP0001` binding.
- Added recorded installation rollback and package ownership tracking.
- Added live WinRT sensor validation and focused diagnostics.
- Added a self-elevating graphical installer with an embedded driver payload.
