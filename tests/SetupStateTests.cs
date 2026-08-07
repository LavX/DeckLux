// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
// Licensed under the Microsoft Public License (MS-PL).

using System;
using System.IO;

namespace DeckLux.Setup.Tests
{
    internal static class Program
    {
        private static int Main()
        {
            const string valid = @"{""Targets"":[{""InstanceId"":""ACPI\\PRP0001\\0"",""BiosDeviceName"":""\\_SB.I2CA.LTRF"",""Role"":""Primary""}]}";
            InstallerEngine.ValidatePrimaryOnlyStateJson(valid);

            ExpectInvalid(@"{""Targets"":[{""InstanceId"":""ACPI\\PRP0001\\1"",""BiosDeviceName"":""\\_SB.I2CA.LTRS"",""Role"":""Secondary""}]}");
            ExpectInvalid(@"{""Targets"":[{""InstanceId"":""ACPI\\PRP0001\\0"",""BiosDeviceName"":""\\_SB.I2CA.LTRF"",""Role"":""Primary""},{""InstanceId"":""ACPI\\PRP0001\\1"",""BiosDeviceName"":""\\_SB.I2CA.LTRS"",""Role"":""Secondary""}]}");
            ExpectInvalid(@"{""Targets"":[{""InstanceId"":""ACPI\\OTHER\\0"",""BiosDeviceName"":""\\_SB.I2CA.LTRF"",""Role"":""Primary""}]}");

            Console.WriteLine("DeckLux setup-state tests passed.");
            return 0;
        }

        private static void ExpectInvalid(string json)
        {
            try
            {
                InstallerEngine.ValidatePrimaryOnlyStateJson(json);
            }
            catch (InvalidDataException)
            {
                return;
            }
            throw new InvalidOperationException("Setup accepted a non-primary DeckLux state.");
        }
    }
}
