# Third-party notices and source provenance

DeckLux is distributed under the Microsoft Public License (MS-PL). Third-party material remains subject to its own license and copyright terms. This file records sources that inform the project and defines how they may be used.

The original DeckLux project and implementation are copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>. The attribution notice in NOTICE.md is part of the software and must be retained under section 3(C) of the MS-PL.

## Microsoft Windows Driver Samples

- Project: Microsoft Windows Driver Samples
- Source: https://github.com/microsoft/Windows-driver-samples
- License: Microsoft Public License (MS-PL)
- Copyright: Microsoft Corporation and the respective contributors

The DeckLux architecture is informed by Microsoft's UMDF 2, SensorsCx, SPB, and sensor-driver examples. Source files adapted from Microsoft samples must retain all applicable copyright, patent, trademark, attribution, and license notices. Consult individual source-file headers and repository history for file-specific provenance.

The upstream license is available at:

https://github.com/microsoft/Windows-driver-samples/blob/main/LICENSE

## Linux LTR-F216A driver

- File: `drivers/iio/light/ltrf216a.c`
- Current source: https://github.com/torvalds/linux/blob/master/drivers/iio/light/ltrf216a.c
- Raw-value compatibility commit: https://github.com/torvalds/linux/commit/f5ffeca5086fef68765f3c1dbc9a12183833adf0
- Historical SteamOS downstream reference: https://gitlab.com/evlaV/linux-integration/-/blob/2aba90bba5c4c9ccbec5057d111c3e52a654e9a9/drivers/iio/light/ltrf216a.c
- License: GPL-2.0-only
- Copyright: 2022 Collabora, Ltd.; 2021 Lite-On Technology Corp. (Singapore), as stated in the upstream file

The Linux driver may be consulted to cross-check publicly observable hardware behavior. Its implementation, structure, functions, and expressive code must not be copied, translated, or adapted into the MS-PL DeckLux source without a separate licensing review and an explicit project decision to meet the applicable GPL requirements.

DeckLux register access and sensor calculations should instead be implemented independently from the device specification and Windows driver documentation. When behavior is cross-checked against Linux, review notes should identify the fact being checked without copying upstream code.

The compatibility commit documents two observable facts used by DeckLux:
Steam Deck userspace applies a firmware factory constant, and the historical
downstream and current upstream drivers use different lux-conversion bases. At
3x gain and 100 ms, the ratio between those published bases is derived
independently as `(8 / (3 * 1 * 10)) / (45 / (3 * 100)) = 16 / 9`. DeckLux
uses that arithmetic result to express the firmware constant on its
`0.15 lux/count` basis. No GPL implementation code is incorporated.

## SteamOS ambient-light calibration helper

- Component: Valve SteamOS Manager
- Official source: https://gitlab.steamos.cloud/holo/steamos-manager/-/blob/7de5caad5e4d4f3bd9f179ddd7acc94e1cb2d677/steamos-manager/src/manager/root.rs#L289-322
- Copyright and license: governed by the notices and metadata in the referenced source repository

The public SteamOS Manager is the authoritative mapping reference used by
DeckLux. It selects OEM string 2 for Jupiter, strings 2 and 4 for Galileo, and
maps those ordered gains to Jupiter `PRP0001:01` or Galileo `PRP0001:00` and
`:01`, respectively. DeckLux independently parses Windows raw SMBIOS data and
does not copy or incorporate SteamOS Manager source.

Historical package provenance is also available through:

- Component: `jupiter-hw-support`
- Helper: `usr/bin/steamos-polkit-helpers/jupiter-get-als-gain`
- Public source-package mirror: https://gitlab.com/evlaV/jupiter-hw-support/-/blob/ab6a3560feca037b1d67fc6869d462f269c13be3/usr/bin/steamos-polkit-helpers/jupiter-get-als-gain
- Commit adding selectable OEM-string slots: https://gitlab.com/evlaV/jupiter-hw-support/-/commit/09536c96a5cbb4892d5f2be1b305340dfbb9b524
- Copyright and license: governed by the notices and metadata in the referenced source package

The referenced helper is a public mirror of Valve-distributed SteamOS package
source, not a dependency or vendored component. It remains a historical
behavioral cross-check. The values are per sensor and are never summed. No
helper source, shell logic, or SteamOS fusion behavior is copied or incorporated
into DeckLux.

## Lite-On LTR-F216A documentation

- Component: Lite-On LTR-F216A ambient-light sensor
- Document: LTR-F216A datasheet
- Manufacturer source: https://optoelectronics.liteon.com/upload/download/DS86-2019-0016/LTR-F216A_Final_DS_V1.4.PDF
- Copyright: Lite-On Technology Corporation and/or its licensors

The datasheet is used as a hardware specification for register addresses, bit meanings, timing, gain, integration settings, and conversion behavior. The document is not included in this repository and is not licensed under MS-PL.

## Microsoft documentation and SDK/WDK interfaces

The project uses publicly documented Windows driver interfaces, including UMDF 2, SensorsCx, and SPB. Relevant documentation begins at:

- https://learn.microsoft.com/windows-hardware/drivers/sensors/
- https://learn.microsoft.com/windows-hardware/drivers/spb/
- https://learn.microsoft.com/windows-hardware/drivers/wdf/

Microsoft documentation, SDK headers, WDK headers, tools, and redistributable components remain governed by their respective Microsoft terms. The DeckLux license does not relicense them.

## Trademark notice

DeckLux is an independent community project. It is not affiliated with, sponsored by, or endorsed by Valve Corporation, Microsoft Corporation, or Lite-On Technology Corporation. Steam and Steam Deck are trademarks and/or registered trademarks of Valve Corporation. Other names and marks belong to their respective owners.
