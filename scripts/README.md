# DeckLux installation and support tools

Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.

DeckLux 1.0.0 is distributed as a test-signed Windows driver with a graphical
installer. The normal installer configures only the Steam Deck primary `LTRF`
ambient-light sensor.

The installer:

- Never enables or disables Windows Test Mode.
- Never changes Secure Boot, BitLocker, or BCD configuration.
- Never initiates a reboot.
- Never uses PnPUtil's all-matching `/install` mode.
- Authorizes and binds one exact device instance.
- Reads Valve factory calibration before making system changes.
- Preserves a machine-wide rollback journal under `%ProgramData%\DeckLux`.

## Windows preparation

DeckLux requires 64-bit Windows 11 build 22000 or newer. Its current release is
locally test-signed, so Secure Boot must be disabled and Windows must be booted
with Test Mode enabled.

Before changing boot configuration, store the BitLocker recovery key somewhere
other than the Deck and inspect protection status from an elevated terminal:

```powershell
manage-bde.exe -status $env:SystemDrive
bcdedit.exe /enum '{current}'
```

If BitLocker protection is active, suspend it for the BCD-changing reboot:

```powershell
manage-bde.exe -protectors -disable $env:SystemDrive -rc 1
```

Disable Secure Boot in firmware settings, enable Test Mode, and restart Windows:

```powershell
bcdedit.exe -set TESTSIGNING ON
Restart-Computer
```

Confirm that Test Mode is active and BitLocker protection has resumed before
running DeckLux Setup.

## Graphical installer

Run the release executable and approve its UAC prompt:

```text
DeckLux-1.0.0-Setup.exe
```

Setup verifies its embedded payload, copies immutable program files to
`%ProgramFiles%\DeckLux`, protects its state directory under
`%ProgramData%\DeckLux`, imports the exact package certificate, stages the
driver, applies per-device calibration, and binds only the primary `LTRF`
instance. It also registers DeckLux in Windows Installed apps.

The standard graphical installer has no secondary-sensor or generic-device
option.

## Package validation

Developers can validate a built driver package from the project root:

```powershell
.\scripts\Test-DeckLuxPackage.ps1 -RequireWdkTools
```

The release build performs package validation automatically and writes artifact
hashes to `artifacts\release\1.0.0\SHA256SUMS.txt`.

## Live readings

The setup window includes a **Test sensor** button. The same WinRT validation can
be run directly without Administrator access:

```powershell
& "$env:ProgramFiles\DeckLux\scripts\Test-DeckLuxSensor.ps1" `
    -DurationSeconds 15 `
    -SampleIntervalMs 500
```

The script reports the Windows default light sensor, timestamped lux readings,
report intervals, invalid samples, timestamp advancement, and reading range.
JSON and CSV output are available through `-OutputFormat`.

## Diagnostics

Collect DeckLux-focused diagnostics with:

```powershell
& "$env:ProgramFiles\DeckLux\scripts\Collect-DeckLuxDiagnostics.ps1"
```

The collector limits its output to DeckLux, `PRP0001`, SensorsCx, package
validation, and relevant Windows event data. Review the generated files before
sharing them.

## Uninstall

Remove DeckLux from **Settings > Apps > Installed apps**, or reopen the setup
executable and select **Uninstall**.

Uninstall uses `%ProgramData%\DeckLux\install-state.json` to restore only the
recorded device and properties, delete only the recorded driver package, and
remove test certificates only when DeckLux added them. The journal and setup log
remain available as an audit trail.

After DeckLux is removed, Test Mode can be disabled if no other test driver
requires it. Apply the same BitLocker precaution before the BCD-changing reboot:

```powershell
manage-bde.exe -protectors -disable $env:SystemDrive -rc 1
bcdedit.exe -set TESTSIGNING OFF
Restart-Computer
```

## Advanced command-line installation

The PowerShell transaction engine remains available for development and
diagnostics. Run it from 64-bit PowerShell as Administrator:

```powershell
.\scripts\Install-DeckLux.ps1
```

On Steam Deck OLED, the separate `LTRS` sensor can be installed only through an
explicit advanced command:

```powershell
.\scripts\Install-DeckLux.ps1 -IncludeSecondary
```

This exposes two independent Windows sensors. DeckLux does not combine their
readings or reproduce Valve's proprietary obstruction/fusion policy.

An independently verified LTR-F216A on other hardware requires both its exact
instance ID and the explicit compatible-device switch:

```powershell
.\scripts\Install-DeckLux.ps1 `
    -InstanceId 'ACPI\PRP0001\2' `
    -AllowCompatibleSensor
```

The generic `ACPI\PRP0001` identifier alone is not sufficient evidence that a
device is an LTR-F216A.
