// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>.
// Licensed under the Microsoft Public License (MS-PL).

using System;
using System.Collections.Generic;
using System.IO;
using System.Security.AccessControl;
using System.Web.Script.Serialization;

namespace DeckLux.Setup.Tests
{
    internal static class Program
    {
        private static readonly JavaScriptSerializer Serializer =
            new JavaScriptSerializer();

        private static int Main()
        {
            Dictionary<string, object> primary0 =
                Target("Primary", "LTRF", @"ACPI\PRP0001\0");
            Dictionary<string, object> primary1 =
                Target("Primary", "LTRF", @"ACPI\PRP0001\1");
            Dictionary<string, object> secondary1 =
                Target("Secondary", "LTRS", @"ACPI\PRP0001\1");
            Dictionary<string, object> baseboardGalileo =
                BaseboardPlatform("Galileo");
            Dictionary<string, object> baseboardJupiter =
                BaseboardPlatform("Jupiter");
            Dictionary<string, object> conflictingGalileo =
                Platform("Galileo");
            conflictingGalileo.Add("BaseBoardManufacturer", "Valve");
            conflictingGalileo.Add("BaseBoardProduct", "Jupiter");

            ExpectValid(State(1, null, primary0));
            ExpectValid(State(2, null, primary1));
            ExpectValid(State(1, LegacyPlatform("Galileo"), primary0));
            ExpectValid(State(3, Platform("Jupiter"), primary1));
            ExpectValid(State(3, Platform("Galileo"), primary0));
            ExpectValid(State(3, Platform("Galileo"), primary0, secondary1));
            ExpectValid(State(
                3, baseboardJupiter, primary1));
            ExpectValid(State(
                3, baseboardGalileo, primary0, secondary1));

            ExpectInstalledValid(InstalledState(
                3, true, false, Platform("Jupiter"), primary1));
            ExpectInstalledValid(InstalledState(
                3, true, false, Platform("Galileo"), primary0, secondary1));
            ExpectInstalledValid(InstalledState(
                3, true, false, BaseboardPlatform("Galileo"),
                primary0, secondary1));

            ExpectInstalledInvalid(State(
                3, Platform("Galileo"), primary0, secondary1));
            ExpectInstalledInvalid(InstalledState(
                2, true, false, Platform("Galileo"), primary0, secondary1));
            ExpectInstalledInvalid(InstalledState(
                3, false, false, Platform("Galileo"), primary0, secondary1));
            ExpectInstalledInvalid(InstalledState(
                3, true, true, Platform("Galileo"), primary0, secondary1));
            ExpectInstalledInvalid(InstalledState(
                3, "true", false, Platform("Galileo"), primary0, secondary1));
            ExpectInstalledInvalid(InstalledState(
                3, true, false, Platform("Galileo"), primary0));
            ExpectInstalledInvalid(InstalledState(
                3, true, false, Platform("Galileo"), secondary1, primary0));
            ExpectInstalledInvalid(InstalledState(
                3, true, false, Platform("Jupiter"), primary1, secondary1));

            ExpectInvalid("not-json");
            ExpectInvalid("null");
            ExpectInvalid(Serializer.Serialize(new Dictionary<string, object>
            {
                { "SchemaVersion", 3 },
                { "Targets", new object[] { primary0 } }
            }));
            ExpectInvalid(State("3", Platform("Galileo"), primary0));
            ExpectInvalid(State(4, Platform("Galileo"), primary0));
            ExpectInvalid(State(3, null, primary0));
            ExpectInvalid(State(3, Platform("Neptune"), primary0));
            ExpectInvalid(State(
                3, conflictingGalileo, primary0, secondary1));
            ExpectInvalid(State(3, Platform("Jupiter"), primary0));
            ExpectInvalid(State(3, Platform("Galileo"), secondary1));
            ExpectInvalid(State(3, Platform("Galileo"), primary1));
            ExpectInvalid(State(3, Platform("Jupiter"), primary1, secondary1));
            ExpectInvalid(State(2, null, primary0, secondary1));
            ExpectInvalid(State(3, Platform("Galileo"), secondary1, primary0));
            ExpectInvalid(State(3, Platform("Galileo"), primary0, primary0));
            ExpectInvalid(State(3, Platform("Galileo"),
                Target("Primary", "LTRF", @"ACPI\PRP0001\0\EXTRA")));

            ExpectRights(false,
                FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize);
            ExpectRights(false, FileSystemRights.Read);
            ExpectRights(true, FileSystemRights.WriteData);
            ExpectRights(true, FileSystemRights.AppendData);
            ExpectRights(true, FileSystemRights.Modify);
            ExpectRights(true, FileSystemRights.FullControl);
            ExpectRights(true, FileSystemRights.Delete);
            ExpectRights(true, FileSystemRights.ChangePermissions);
            ExpectRights(true, FileSystemRights.TakeOwnership);

            Console.WriteLine("DeckLux setup-state tests passed.");
            return 0;
        }

        private static Dictionary<string, object> Target(
            string role,
            string biosLeaf,
            string instanceId)
        {
            return new Dictionary<string, object>
            {
                { "InstanceId", instanceId },
                { "BiosDeviceName", @"\_SB.I2CA." + biosLeaf },
                { "Role", role }
            };
        }

        private static Dictionary<string, object> Platform(string product)
        {
            return new Dictionary<string, object>
            {
                { "DeckProduct", product },
                { "SystemManufacturer", "Valve" },
                { "SystemProductName", product }
            };
        }

        private static Dictionary<string, object> LegacyPlatform(string product)
        {
            return new Dictionary<string, object>
            {
                { "SystemManufacturer", "Valve" },
                { "SystemProductName", product }
            };
        }

        private static Dictionary<string, object> BaseboardPlatform(string product)
        {
            return new Dictionary<string, object>
            {
                { "DeckProduct", product },
                { "SystemManufacturer", "Example" },
                { "SystemProductName", "ExampleProduct" },
                { "BaseBoardManufacturer", "Valve" },
                { "BaseBoardProduct", product }
            };
        }

        private static string State(
            object schema,
            Dictionary<string, object> platform,
            params Dictionary<string, object>[] targets)
        {
            Dictionary<string, object> root = new Dictionary<string, object>
            {
                { "SchemaVersion", schema },
                { "Project", "DeckLux" },
                { "Targets", targets }
            };
            if (platform != null)
            {
                root.Add("Platform", platform);
            }
            return Serializer.Serialize(root);
        }

        private static string InstalledState(
            object schema,
            object completed,
            object uninstalled,
            Dictionary<string, object> platform,
            params Dictionary<string, object>[] targets)
        {
            Dictionary<string, object> root = new Dictionary<string, object>
            {
                { "SchemaVersion", schema },
                { "Project", "DeckLux" },
                { "Completed", completed },
                { "Uninstalled", uninstalled },
                { "Targets", targets }
            };
            if (platform != null)
            {
                root.Add("Platform", platform);
            }
            return Serializer.Serialize(root);
        }

        private static void ExpectValid(string json)
        {
            InstallerEngine.ValidateSupportedStateJson(json);
        }

        private static void ExpectInvalid(string json)
        {
            try
            {
                InstallerEngine.ValidateSupportedStateJson(json);
            }
            catch (InvalidDataException)
            {
                return;
            }
            throw new InvalidOperationException(
                "Setup accepted an unsupported DeckLux state.");
        }

        private static void ExpectInstalledValid(string json)
        {
            InstallerEngine.ValidateInstalledDefaultStateJson(json);
        }

        private static void ExpectInstalledInvalid(string json)
        {
            try
            {
                InstallerEngine.ValidateInstalledDefaultStateJson(json);
            }
            catch (InvalidDataException)
            {
                return;
            }
            throw new InvalidOperationException(
                "Setup accepted an invalid post-install DeckLux state.");
        }

        private static void ExpectRights(
            bool expectedDangerous,
            FileSystemRights rights)
        {
            bool actual = InstallerEngine.IncludesDangerousFileSystemRights(rights);
            if (actual != expectedDangerous)
            {
                throw new InvalidOperationException(
                    "Setup ACL rights classification was incorrect for " + rights + ".");
            }
        }
    }
}
