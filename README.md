# DeckLux

Open ambient-light sensor support for Steam Deck on Windows.

DeckLux is a standalone UMDF 2 driver for the Lite-On LTR-F216A ambient-light
sensor used in Steam Deck hardware. It exposes illuminance through the standard
Windows sensor APIs with SensorsCx and SPB/I2C. It does not require a companion
application, background service, or another handheld project.

## Overview

DeckLux 1.0.0 supports the primary `LTRF` ambient-light sensor on Steam Deck
OLED (Galileo). It registers as a standard Windows light sensor and applies the
per-device factory calibration stored by Valve in system firmware.

The default installation binds only `LTRF`. The OLED `LTRS` device is treated as
a separate secondary sensor and requires an explicit installation option.

DeckLux is distributed as a locally test-signed driver. Windows Test Mode must
be enabled and Secure Boot must be disabled before it can load. DeckLux requires
64-bit Windows 11 build 22000 or newer.

## Download

Download DeckLux 1.0.0 from the
[GitHub release page](https://github.com/LavX/DeckLux/releases/tag/v1.0.0).
The setup executable is the normal primary-sensor installer. SHA-256 checksums
and a portable package are included with the release.

## Features

- Standard Windows ambient-light sensor interface through UMDF 2.15 and
  SensorsCx.
- Direct SPB/I2C access to the LTR-F216A register set.
- Read-only identity probe before the first hardware write.
- 18-bit, 100 ms acquisition at 3x gain.
- Bounded not-ready retries, reset recovery, configuration readback, and
  suspend/resume lifecycle handling.
- Valve per-device factory calibration read from SMBIOS.
- Report intervals, thresholds, timestamps, sensor state, and invalid-sample
  transitions expected by Windows sensor clients.
- Exact-device installation, recorded rollback, live WinRT testing, and focused
  diagnostics.

DeckLux reports illuminance. Windows and individual applications decide how
those readings affect display brightness.

## Hardware support

| Hardware | DeckLux behavior |
| --- | --- |
| Steam Deck OLED `LTRF` | Supported as the primary/default sensor |
| Steam Deck OLED `LTRS` | Separate explicit option; never installed by default |
| Steam Deck LCD with LTR-F216A | Jupiter firmware mapping is implemented |
| Steam Deck LCD with TI OPT3001 | Not compatible; this is a different sensor |
| Independently verified LTR-F216A | Supported only through exact-instance opt-in |

`ACPI\PRP0001` is a generic ACPI identifier, not proof that a device is an
LTR-F216A. DeckLux therefore requires an installer-created authorization
property on the exact device instance. Applying the INF manually to every
matching `PRP0001` device does not bypass that check.

The normal installer also requires a Valve `Jupiter` or `Galileo` firmware
identity. A compatible non-Deck sensor must be independently identified and
installed with both its exact instance ID and `-AllowCompatibleSensor`.

## Factory calibration

At 18-bit resolution, 100 ms integration, and 3x gain, DeckLux uses a base
conversion of `0.15 lux/count`. Valve's firmware calibration constants were
defined against the older SteamOS downstream basis of approximately
`0.2666667 lux/count`, so the installer converts them with the exact ratio:

```text
DeckLux scale = Valve OEM scale * 16 / 9
CalibrationScalePpm = round(DeckLux scale * 1,000,000)
```

The Valve SMBIOS Type 11 mapping is:

| Platform sensor | OEM-string slot | ACPI instance |
| --- | ---: | --- |
| Jupiter `LTRF` | 2 | `PRP0001:01` |
| Galileo `LTRF` | 2 | `PRP0001:00` |
| Galileo `LTRS` | 4 | `PRP0001:01` |

The four-byte `CalibrationScalePpm` device property belongs to one physical
sensor; `1,000,000` represents scale `1.0`. DeckLux never adds or averages the
`LTRF` and `LTRS` constants and does not claim to reproduce Valve's proprietary
dual-sensor fusion or obstruction policy.

The evidence, conversion derivation, property contract, and failure behavior
are documented in [docs/CALIBRATION.md](docs/CALIBRATION.md).

## Build

The reproducible release build uses an Enterprise WDK mounted as a drive. Pass
its root and the `Release` configuration to the build script:

```powershell
.\scripts\build-ewdk.cmd E: Release
```

The build performs a clean Release x64 compile, runs the core and calibration
tests, validates the Universal driver API surface, creates and signs the driver
package, compiles the graphical installer, and generates release archives and
SHA-256 manifests.

Release artifacts are placed under:

```text
artifacts\release\1.0.0\DeckLux-1.0.0-Setup.exe
artifacts\release\1.0.0\DeckLux-1.0.0-portable.zip
artifacts\release\1.0.0\DeckLux-1.0.0-source.zip
artifacts\release\1.0.0\SHA256SUMS.txt
```

Validate a built package with:

```powershell
.\scripts\Test-DeckLuxPackage.ps1 -RequireWdkTools
```

## Install

Read [scripts/README.md](scripts/README.md) before enabling Windows Test Mode. It
covers Secure Boot, BitLocker precautions, package validation, diagnostics, and
rollback.

Run the release installer and approve its Windows UAC prompt:

```text
DeckLux-1.0.0-Setup.exe
```

The installer verifies the Steam Deck firmware identity, resolves exactly one
`LTRF` instance, reads its matching factory calibration, validates the package,
trusts its exact test certificate, stages the INF, writes the device-specific
properties, and binds that instance. The installed payload and rollback state
are stored separately:

```text
%ProgramFiles%\DeckLux
%ProgramData%\DeckLux\install-state.json
```

DeckLux appears in Windows Installed apps after setup. The installer does not
alter BCD, Secure Boot, BitLocker, or Test Mode, and never initiates a reboot.

## Test live readings

The WinRT test uses the same public API available to Windows applications and
does not require Administrator access:

```powershell
& "$env:ProgramFiles\DeckLux\scripts\Test-DeckLuxSensor.ps1" `
    -DurationSeconds 15 `
    -SampleIntervalMs 500
```

JSON and CSV output are available for logging:

```powershell
& "$env:ProgramFiles\DeckLux\scripts\Test-DeckLuxSensor.ps1" -OutputFormat Json
& "$env:ProgramFiles\DeckLux\scripts\Test-DeckLuxSensor.ps1" -OutputFormat Csv
```

Focused diagnostic collection is also available:

```powershell
& "$env:ProgramFiles\DeckLux\scripts\Collect-DeckLuxDiagnostics.ps1"
```

## Uninstall and rollback

Remove DeckLux from **Settings > Apps > Installed apps**, or reopen
`DeckLux.Setup.exe` and select **Uninstall**.

It uses the recorded installation state to restore the exact device to its
previous binding, restore or remove only properties owned by DeckLux, delete
only the recorded driver package, and remove test certificates only when that
installation added them. It does not force package removal, disable Test Mode,
or initiate a reboot.

## Author and license

DeckLux was created and is maintained by **Laszlo Toth
<lavx@lavx.hu>**. Author information is also embedded in the source headers,
package notice, INF metadata, and binary version resources.

DeckLux is free and open-source software under the
[Microsoft Public License](LICENSE). When DeckLux source or compiled work is
distributed or incorporated into another project, the copyright, license, and
attribution notices included with the work must be retained. See
[AUTHORS.md](AUTHORS.md) and [NOTICE.md](NOTICE.md).

Third-party references and implementation provenance are recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The GPL-2.0-only Linux
LTR-F216A driver was used only as a behavioral reference; DeckLux's Windows
implementation is independent and MS-PL licensed.

## Independence and trademarks

DeckLux is not affiliated with, sponsored by, or endorsed by Valve Corporation,
Microsoft Corporation, or Lite-On Technology Corporation. Steam and Steam Deck
are trademarks or registered trademarks of Valve Corporation. Product names
are used only to describe compatibility.
