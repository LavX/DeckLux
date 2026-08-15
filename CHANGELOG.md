# Changelog

## 1.1.0 - 2026-08-16

- Added timestamp-correlated comparison of the independently calibrated left
  and right ambient-light sensors on Steam Deck OLED.
- Added verified restoration of temporary WinRT report intervals, latency, and
  lux thresholds used during sensor comparison.
- Added safe Setup validation and rollback support for the exact recorded
  Galileo `LTRF`/`LTRS` pair while retaining primary-only default setup.
- Fixed Setup ACL validation so its own read-only Program Files permissions are
  accepted without allowing non-administrator write, delete, or ownership rights.
- Included the comparison tool in graphical and portable release payloads.
- Kept sensor fusion and display-brightness policy outside the physical driver.

## 1.0.0 - 2026-08-07

- Added Windows ambient-light sensor support for the Steam Deck OLED primary
  LTR-F216A sensor.
- Added per-device Valve factory calibration from SMBIOS firmware data.
- Added exact-device authorization to prevent generic `ACPI\PRP0001` binding.
- Added recorded installation rollback and package ownership tracking.
- Added live WinRT sensor validation and focused diagnostics.
- Added a self-elevating graphical installer with an embedded driver payload.
