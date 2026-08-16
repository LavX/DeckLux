// Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>
// Licensed under the Microsoft Public License (MS-PL).

using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("DeckLux Setup")]
[assembly: AssemblyDescription("Installer for the DeckLux Steam Deck ambient-light sensor driver")]
[assembly: AssemblyCompany("Laszlo Toth")]
[assembly: AssemblyProduct("DeckLux")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Laszlo Toth <lavx@lavx.hu>")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]
[assembly: AssemblyInformationalVersion("1.1.0")]
[assembly: ComVisible(false)]

namespace DeckLux.Setup
{
    internal static class Product
    {
        internal const string Name = "DeckLux";
        internal const string Version = "1.1.0";
        internal const string DriverVersion = "1.1.0.0";
        internal const string PayloadResource = "DeckLux.Payload.zip";
        internal const string PayloadHashResource = "DeckLux.Payload.sha256";
        internal const string UninstallKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DeckLux";
        internal const string SetupMutexName = @"Global\DeckLux.Setup.Transaction";

        internal static readonly string InstallRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "DeckLux");
        internal static readonly string DataRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "DeckLux");
        internal static readonly string StatePath = Path.Combine(DataRoot, "install-state.json");
        internal static readonly string LogPath = Path.Combine(DataRoot, "DeckLux.Setup.log");
        internal static readonly string InstalledSetupPath = Path.Combine(InstallRoot, "DeckLux.Setup.exe");
    }

    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length > 0 && string.Equals(args[0], "/cleanup", StringComparison.OrdinalIgnoreCase))
            {
                return InstallerEngine.Cleanup(args);
            }

            bool quietInstall = HasArgument(args, "/quiet-install");
            bool quietUninstall = HasArgument(args, "/quiet-uninstall");
            bool startInstall = HasArgument(args, "/install");
            bool startUninstall = HasArgument(args, "/uninstall");

            using (Mutex setupMutex = new Mutex(false, Product.SetupMutexName))
            {
                bool lockTaken = false;
                try
                {
                    try
                    {
                        lockTaken = setupMutex.WaitOne(0, false);
                    }
                    catch (AbandonedMutexException)
                    {
                        lockTaken = true;
                    }
                    if (!lockTaken)
                    {
                        if (!quietInstall && !quietUninstall)
                        {
                            MessageBox.Show("Another DeckLux setup operation is already running.",
                                Product.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
                        }
                        return 1618;
                    }

                    if (quietInstall || quietUninstall)
                    {
                        try
                        {
                            Action<string> log = delegate(string message)
                            {
                                InstallerEngine.AppendPersistentLog(message);
                            };
                            if (quietInstall)
                            {
                                InstallerEngine.Install(log);
                            }
                            else
                            {
                                InstallerEngine.Uninstall(log);
                            }
                            return 0;
                        }
                        catch (Exception exception)
                        {
                            InstallerEngine.AppendPersistentLog("ERROR: " + exception);
                            return 1;
                        }
                    }

                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    using (SetupForm form = new SetupForm(startInstall, startUninstall))
                    {
                        Application.Run(form);
                        return form.ExitCode;
                    }
                }
                finally
                {
                    if (lockTaken)
                    {
                        setupMutex.ReleaseMutex();
                    }
                }
            }
        }

        private static bool HasArgument(string[] args, string expected)
        {
            foreach (string argument in args)
            {
                if (string.Equals(argument, expected, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
            return false;
        }
    }

    internal sealed class SetupForm : Form
    {
        private readonly Button installButton;
        private readonly Button uninstallButton;
        private readonly Button testButton;
        private readonly Button logButton;
        private readonly Button closeButton;
        private readonly Label statusLabel;
        private readonly TextBox logBox;
        private readonly ProgressBar progress;
        private readonly bool startInstall;
        private readonly bool startUninstall;
        private bool busy;

        internal int ExitCode { get; private set; }

        internal SetupForm(bool startInstallValue, bool startUninstallValue)
        {
            startInstall = startInstallValue;
            startUninstall = startUninstallValue;
            Text = "DeckLux " + Product.Version + " Setup";
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(700, 500);
            ClientSize = new Size(760, 560);
            Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            MaximizeBox = false;

            TableLayoutPanel root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.Padding = new Padding(22);
            root.ColumnCount = 1;
            root.RowCount = 7;
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            Controls.Add(root);

            Label title = new Label();
            title.AutoSize = true;
            title.Font = new Font("Segoe UI Semibold", 22F, FontStyle.Bold, GraphicsUnit.Point);
            title.Text = "DeckLux";
            root.Controls.Add(title, 0, 0);

            Label description = new Label();
            description.AutoSize = true;
            description.MaximumSize = new Size(700, 0);
            description.Margin = new Padding(0, 4, 0, 12);
            description.Text = "Steam Deck ambient-light sensor support for Windows. " +
                "Setup configures both sensors on Steam Deck OLED and the single sensor on Steam Deck LCD.";
            root.Controls.Add(description, 0, 1);

            Label requirements = new Label();
            requirements.AutoSize = true;
            requirements.MaximumSize = new Size(700, 0);
            requirements.Padding = new Padding(10);
            requirements.BackColor = Color.FromArgb(255, 245, 204);
            requirements.Text = "Test-signed release: Windows Test Mode must already be enabled and " +
                "Secure Boot disabled. Setup never changes BCD, BitLocker, Secure Boot, or reboot settings.";
            root.Controls.Add(requirements, 0, 2);

            statusLabel = new Label();
            statusLabel.AutoSize = true;
            statusLabel.Font = new Font("Segoe UI Semibold", 10F, FontStyle.Bold, GraphicsUnit.Point);
            statusLabel.Margin = new Padding(0, 14, 0, 8);
            root.Controls.Add(statusLabel, 0, 3);

            logBox = new TextBox();
            logBox.Dock = DockStyle.Fill;
            logBox.Multiline = true;
            logBox.ReadOnly = true;
            logBox.ScrollBars = ScrollBars.Both;
            logBox.WordWrap = false;
            logBox.Font = new Font("Consolas", 8.5F, FontStyle.Regular, GraphicsUnit.Point);
            logBox.BackColor = Color.White;
            root.Controls.Add(logBox, 0, 4);

            progress = new ProgressBar();
            progress.Dock = DockStyle.Fill;
            progress.Style = ProgressBarStyle.Marquee;
            progress.MarqueeAnimationSpeed = 0;
            progress.Height = 8;
            progress.Margin = new Padding(0, 10, 0, 8);
            root.Controls.Add(progress, 0, 5);

            FlowLayoutPanel buttons = new FlowLayoutPanel();
            buttons.AutoSize = true;
            buttons.Dock = DockStyle.Fill;
            buttons.FlowDirection = FlowDirection.LeftToRight;
            buttons.WrapContents = false;
            root.Controls.Add(buttons, 0, 6);

            installButton = NewButton("Install / Repair", 122);
            uninstallButton = NewButton("Uninstall", 100);
            testButton = NewButton("Test sensor", 100);
            logButton = NewButton("Open log", 90);
            closeButton = NewButton("Close", 90);
            installButton.Click += delegate { BeginInstall(); };
            uninstallButton.Click += delegate { BeginUninstall(true); };
            testButton.Click += delegate { BeginSensorTest(); };
            logButton.Click += delegate { OpenLog(); };
            closeButton.Click += delegate { Close(); };
            buttons.Controls.Add(installButton);
            buttons.Controls.Add(uninstallButton);
            buttons.Controls.Add(testButton);
            buttons.Controls.Add(logButton);
            buttons.Controls.Add(closeButton);

            FormClosing += OnFormClosing;
            Shown += OnShown;
            RefreshStatus();
        }

        private static Button NewButton(string text, int width)
        {
            Button button = new Button();
            button.Text = text;
            button.Width = width;
            button.Height = 32;
            button.Margin = new Padding(0, 0, 8, 0);
            return button;
        }

        private void OnShown(object sender, EventArgs eventArgs)
        {
            if (startInstall)
            {
                BeginInvoke(new MethodInvoker(BeginInstall));
            }
            else if (startUninstall)
            {
                BeginInvoke(new MethodInvoker(delegate { BeginUninstall(true); }));
            }
        }

        private void OnFormClosing(object sender, FormClosingEventArgs eventArgs)
        {
            if (busy)
            {
                eventArgs.Cancel = true;
                MessageBox.Show(this, "Wait for the current operation to finish.", Product.Name,
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }

        private void RefreshStatus()
        {
            InstallState state = InstallerEngine.ReadInstallState();
            if (state.Active)
            {
                statusLabel.Text = "Installed driver: " + state.DriverVersion;
                bool sameVersion = string.Equals(state.DriverVersion,
                    Product.DriverVersion, StringComparison.OrdinalIgnoreCase);
                installButton.Text = sameVersion ? "Repair" : "Uninstall first";
                installButton.Enabled = sameVersion;
                uninstallButton.Enabled = true;
                testButton.Enabled = true;
            }
            else
            {
                statusLabel.Text = "DeckLux is not installed by this setup.";
                installButton.Text = "Install";
                uninstallButton.Enabled = false;
                testButton.Enabled = false;
            }
            logButton.Enabled = File.Exists(Product.LogPath);
        }

        private void BeginInstall()
        {
            RunOperation("Installing DeckLux", false, delegate
            {
                InstallerEngine.Install(AppendLog);
                return "DeckLux " + Product.Version + " was installed successfully.";
            });
        }

        private void BeginUninstall(bool confirm)
        {
            if (confirm && MessageBox.Show(this,
                "Remove the DeckLux driver and restore its recorded device state?",
                "Uninstall DeckLux", MessageBoxButtons.YesNo,
                MessageBoxIcon.Question) != DialogResult.Yes)
            {
                return;
            }
            RunOperation("Uninstalling DeckLux", true, delegate
            {
                InstallerEngine.Uninstall(AppendLog);
                return "DeckLux was uninstalled successfully.";
            });
        }

        private void BeginSensorTest()
        {
            RunOperation("Testing the ambient-light sensor", false, delegate
            {
                InstallerEngine.TestSensor(AppendLog);
                return "The Windows light-sensor test completed.";
            });
        }

        private void RunOperation(string heading, bool closeAfterSuccess, Func<string> operation)
        {
            if (busy)
            {
                return;
            }
            busy = true;
            ExitCode = 0;
            SetButtonsEnabled(false);
            progress.MarqueeAnimationSpeed = 30;
            AppendLog(heading + "...");

            Thread worker = new Thread(delegate()
            {
                string successMessage = null;
                Exception failure = null;
                try
                {
                    successMessage = operation();
                }
                catch (Exception exception)
                {
                    failure = exception;
                    InstallerEngine.AppendPersistentLog("ERROR: " + exception);
                }

                BeginInvoke(new MethodInvoker(delegate
                {
                    busy = false;
                    progress.MarqueeAnimationSpeed = 0;
                    SetButtonsEnabled(true);
                    RefreshStatus();
                    if (failure == null)
                    {
                        AppendLog(successMessage);
                        MessageBox.Show(this, successMessage, Product.Name,
                            MessageBoxButtons.OK, MessageBoxIcon.Information);
                        if (closeAfterSuccess)
                        {
                            Close();
                        }
                    }
                    else
                    {
                        ExitCode = 1;
                        AppendLog("ERROR: " + failure.Message);
                        MessageBox.Show(this, failure.Message + Environment.NewLine + Environment.NewLine +
                            "Details were written to:" + Environment.NewLine + Product.LogPath,
                            Product.Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }));
            });
            worker.IsBackground = true;
            worker.Name = "DeckLux setup worker";
            worker.Start();
        }

        private void SetButtonsEnabled(bool enabled)
        {
            installButton.Enabled = enabled;
            uninstallButton.Enabled = enabled;
            testButton.Enabled = enabled;
            logButton.Enabled = enabled;
            closeButton.Enabled = enabled;
        }

        private void AppendLog(string message)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(AppendLog), message);
                return;
            }
            string line = DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + "  " + message;
            logBox.AppendText(line + Environment.NewLine);
            InstallerEngine.AppendPersistentLog(message);
        }

        private void OpenLog()
        {
            if (File.Exists(Product.LogPath))
            {
                Process.Start(new ProcessStartInfo(Product.LogPath) { UseShellExecute = true });
            }
        }
    }

    internal sealed class InstallState
    {
        internal bool Exists;
        internal bool Active;
        internal bool Completed;
        internal bool Uninstalled;
        internal string DriverVersion;
    }

    internal static class InstallerEngine
    {
        private const int MoveFileDelayUntilReboot = 0x4;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);

        internal static void Install(Action<string> log)
        {
            AssertEnvironment();
            EnsureProtectedDirectory(Product.InstallRoot, true);
            EnsureProtectedDirectory(Product.DataRoot, false);
            log("Preparing the protected installation directories.");

            InstallState existing = ReadInstallState();
            if (existing.Active && !string.Equals(existing.DriverVersion,
                Product.DriverVersion, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("DeckLux " + existing.DriverVersion +
                    " is installed. Uninstall that release before installing " +
                    Product.DriverVersion + ".");
            }

            log("Verifying and extracting the embedded release payload.");
            ExtractPayload(Product.InstallRoot);
            InstallSetupExecutable();
            HardenProtectedTree(Product.InstallRoot, true);

            bool hadActiveInstallation = existing.Active && existing.Completed;
            try
            {
                log("Installing the Steam Deck ambient-light sensor topology.");
                try
                {
                    RunPowerShell(Path.Combine(Product.InstallRoot, @"scripts\Install-DeckLux.ps1"),
                        "-PackagePath " + QuotePowerShell(Path.Combine(Product.InstallRoot, @"driver\DeckLux.Sensor")) +
                        " -CertificatePath " + QuotePowerShell(Path.Combine(Product.InstallRoot, @"driver\DeckLuxSensor.cer")) +
                        " -StatePath " + QuotePowerShell(Product.StatePath) + " -Confirm:$false -Verbose", log);
                }
                finally
                {
                    HardenProtectedTree(Product.DataRoot, false);
                }

                InstallState installed = ReadInstallState();
                if (!installed.Active || !installed.Completed ||
                    !string.Equals(installed.DriverVersion, Product.DriverVersion, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        "Installation finished without a verified DeckLux " + Product.DriverVersion + " state.");
                }
                ValidateInstalledDefaultState();
                WriteUninstallRegistration();
                HardenProtectedTree(Product.DataRoot, false);
                log("DeckLux " + Product.Version + " installation verified.");
            }
            catch (Exception installationFailure)
            {
                Exception rollbackFailure = null;
                if (!hadActiveInstallation)
                {
                    try
                    {
                        InstallState failedState = ReadInstallState();
                        if (failedState.Exists && !failedState.Uninstalled)
                        {
                            log("Installation failed; rolling back the recorded DeckLux changes.");
                            try
                            {
                                RunPowerShell(Path.Combine(Product.InstallRoot,
                                    @"scripts\Uninstall-DeckLux.ps1"),
                                    "-StatePath " + QuotePowerShell(Product.StatePath) +
                                    " -Confirm:$false -Verbose", log);
                            }
                            finally
                            {
                                HardenProtectedTree(Product.DataRoot, false);
                            }
                        }
                        RemoveUninstallRegistration();
                    }
                    catch (Exception exception)
                    {
                        rollbackFailure = exception;
                    }
                }
                if (rollbackFailure != null)
                {
                    throw new AggregateException(
                        "DeckLux installation failed and automatic rollback was incomplete.",
                        installationFailure, rollbackFailure);
                }
                throw;
            }
        }

        internal static void Uninstall(Action<string> log)
        {
            AssertEnvironment();
            ValidateProtectedDirectoryIfPresent(Product.InstallRoot, true);
            ValidateProtectedDirectoryIfPresent(Product.DataRoot, false);
            InstallState state = ReadInstallState();
            if (!state.Exists)
            {
                if (Directory.Exists(Product.InstallRoot) || IsUninstallRegistered())
                {
                    throw new InvalidOperationException(
                        "DeckLux program files or uninstall metadata exist, but the protected rollback journal is missing. Refusing to orphan the driver.");
                }
                log("No DeckLux installation state was found.");
                return;
            }
            if (state.Active)
            {
                ValidateSupportedState();
                string scriptPath = Path.Combine(Product.InstallRoot, @"scripts\Uninstall-DeckLux.ps1");
                if (!File.Exists(scriptPath))
                {
                    throw new FileNotFoundException("The installed DeckLux rollback script is missing.", scriptPath);
                }
                log("Restoring the recorded device, property, package, and certificate state.");
                try
                {
                    RunPowerShell(scriptPath,
                        "-StatePath " + QuotePowerShell(Product.StatePath) + " -Confirm:$false -Verbose", log);
                }
                finally
                {
                    HardenProtectedTree(Product.DataRoot, false);
                }
                state = ReadInstallState();
                if (!state.Uninstalled)
                {
                    throw new InvalidOperationException("DeckLux rollback did not reach a completed state.");
                }
            }
            else
            {
                log("No active DeckLux installation state was found.");
            }
            RemoveInstalledFiles(log);
        }

        internal static void TestSensor(Action<string> log)
        {
            string scriptPath = Path.Combine(Product.InstallRoot, @"scripts\Test-DeckLuxSensor.ps1");
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException("The DeckLux sensor test is missing.", scriptPath);
            }
            RunPowerShell(scriptPath, "-DurationSeconds 10 -SampleIntervalMs 500 -OutputFormat Object", log);
        }

        internal static InstallState ReadInstallState()
        {
            InstallState result = new InstallState();
            result.Exists = File.Exists(Product.StatePath);
            if (!result.Exists)
            {
                return result;
            }
            try
            {
                string json = File.ReadAllText(Product.StatePath, Encoding.UTF8);
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> root = serializer.Deserialize<Dictionary<string, object>>(json);
                if (!GetString(root, "Project").Equals("DeckLux", StringComparison.Ordinal))
                {
                    throw new InvalidDataException("The installation state does not identify DeckLux.");
                }
                result.Completed = GetBoolean(root, "Completed");
                result.Uninstalled = GetBoolean(root, "Uninstalled");
                Dictionary<string, object> package = GetDictionary(root, "Package");
                result.DriverVersion = GetString(package, "DriverVersion");
                result.Active = !result.Uninstalled;
                return result;
            }
            catch (Exception exception)
            {
                throw new InvalidDataException("DeckLux installation state is invalid or unreadable.", exception);
            }
        }

        internal static void AppendPersistentLog(string message)
        {
            try
            {
                if (!Directory.Exists(Product.DataRoot))
                {
                    return;
                }
                ValidateProtectedDirectoryIfPresent(Product.DataRoot, false);
                string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) +
                    "  " + message + Environment.NewLine;
                File.AppendAllText(Product.LogPath, line, Encoding.UTF8);
                ApplyFileSecurity(Product.LogPath, false);
            }
            catch
            {
            }
        }

        private static void AssertEnvironment()
        {
            if (!Environment.Is64BitOperatingSystem || !Environment.Is64BitProcess)
            {
                throw new PlatformNotSupportedException("DeckLux Setup requires 64-bit Windows.");
            }
            WindowsPrincipal principal = new WindowsPrincipal(WindowsIdentity.GetCurrent());
            if (!principal.IsInRole(WindowsBuiltInRole.Administrator))
            {
                throw new UnauthorizedAccessException("DeckLux Setup must run as Administrator.");
            }
            Version windows = Environment.OSVersion.Version;
            if (windows.Major < 10 || (windows.Major == 10 && windows.Build < 22000))
            {
                throw new PlatformNotSupportedException(
                    "DeckLux " + Product.Version + " requires Windows 11.");
            }
        }

        private static void EnsureProtectedDirectory(string path, bool allowUsersRead)
        {
            string fullPath = GetExpectedProtectedRoot(path, allowUsersRead);
            if (Directory.Exists(fullPath))
            {
                ValidateProtectedTree(fullPath, allowUsersRead);
                return;
            }
            Directory.CreateDirectory(fullPath);
            ApplyDirectorySecurity(fullPath, allowUsersRead);
        }

        private static void ValidateProtectedDirectoryIfPresent(string path, bool allowUsersRead)
        {
            string fullPath = GetExpectedProtectedRoot(path, allowUsersRead);
            if (Directory.Exists(fullPath))
            {
                ValidateProtectedTree(fullPath, allowUsersRead);
            }
        }

        private static string GetExpectedProtectedRoot(string path, bool allowUsersRead)
        {
            string fullPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
            string expectedRoot = Path.GetFullPath(allowUsersRead ?
                Product.InstallRoot : Product.DataRoot).TrimEnd(Path.DirectorySeparatorChar);
            if (!string.Equals(fullPath, expectedRoot, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Refusing an unexpected DeckLux directory: " + fullPath);
            }
            return fullPath;
        }

        private static List<string> GetSafeTreeEntries(string root)
        {
            List<string> entries = new List<string>();
            Stack<string> directories = new Stack<string>();
            directories.Push(root);
            while (directories.Count != 0)
            {
                string directory = directories.Pop();
                if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
                {
                    throw new InvalidOperationException(
                        "DeckLux directories must not be reparse points: " + directory);
                }
                foreach (string entry in Directory.GetFileSystemEntries(directory))
                {
                    FileAttributes attributes = File.GetAttributes(entry);
                    if ((attributes & FileAttributes.ReparsePoint) != 0)
                    {
                        throw new InvalidOperationException(
                            "DeckLux data must not contain reparse points: " + entry);
                    }
                    entries.Add(entry);
                    if ((attributes & FileAttributes.Directory) != 0)
                    {
                        directories.Push(entry);
                    }
                }
            }
            return entries;
        }

        private static void ValidateProtectedTree(string root, bool allowUsersRead)
        {
            ValidateFileSystemSecurity(Directory.GetAccessControl(root), root, allowUsersRead);
            foreach (string entry in GetSafeTreeEntries(root))
            {
                if ((File.GetAttributes(entry) & FileAttributes.Directory) != 0)
                {
                    ValidateFileSystemSecurity(Directory.GetAccessControl(entry), entry, allowUsersRead);
                }
                else
                {
                    ValidateFileSystemSecurity(File.GetAccessControl(entry), entry, allowUsersRead);
                }
            }
        }

        private static void ValidateFileSystemSecurity(
            FileSystemSecurity security, string path, bool allowUsersRead)
        {
            SecurityIdentifier system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            SecurityIdentifier administrators = new SecurityIdentifier(
                WellKnownSidType.BuiltinAdministratorsSid, null);
            SecurityIdentifier owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
            if (owner == null || (!owner.Equals(system) && !owner.Equals(administrators)))
            {
                throw new UnauthorizedAccessException(
                    "DeckLux refuses data not owned by SYSTEM or Administrators: " + path);
            }
            if (!security.AreAccessRulesProtected)
            {
                throw new UnauthorizedAccessException(
                    "DeckLux refuses data with an inherited or replaceable ACL: " + path);
            }
            AuthorizationRuleCollection rules = security.GetAccessRules(
                true, true, typeof(SecurityIdentifier));
            foreach (FileSystemAccessRule rule in rules)
            {
                SecurityIdentifier identity = rule.IdentityReference as SecurityIdentifier;
                if (rule.AccessControlType == AccessControlType.Allow &&
                    IncludesDangerousFileSystemRights(rule.FileSystemRights) &&
                    (identity == null || (!identity.Equals(system) && !identity.Equals(administrators))))
                {
                    throw new UnauthorizedAccessException(
                        "DeckLux refuses data writable by a non-administrator: " + path);
                }
            }
        }

        private static void ApplyDirectorySecurity(string path, bool allowUsersRead)
        {
            DirectorySecurity security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            InheritanceFlags inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            SecurityIdentifier system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            SecurityIdentifier administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            security.AddAccessRule(new FileSystemAccessRule(system, FileSystemRights.FullControl,
                inheritance, PropagationFlags.None, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(administrators, FileSystemRights.FullControl,
                inheritance, PropagationFlags.None, AccessControlType.Allow));
            if (allowUsersRead)
            {
                SecurityIdentifier users = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);
                security.AddAccessRule(new FileSystemAccessRule(users,
                    FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize,
                    inheritance, PropagationFlags.None, AccessControlType.Allow));
            }
            security.SetOwner(administrators);
            Directory.SetAccessControl(path, security);
        }

        private static void ApplyFileSecurity(string path, bool allowUsersRead)
        {
            FileSecurity security = new FileSecurity();
            security.SetAccessRuleProtection(true, false);
            SecurityIdentifier system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            SecurityIdentifier administrators = new SecurityIdentifier(
                WellKnownSidType.BuiltinAdministratorsSid, null);
            security.AddAccessRule(new FileSystemAccessRule(
                system, FileSystemRights.FullControl, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                administrators, FileSystemRights.FullControl, AccessControlType.Allow));
            if (allowUsersRead)
            {
                SecurityIdentifier users = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null);
                security.AddAccessRule(new FileSystemAccessRule(users,
                    FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize,
                    AccessControlType.Allow));
            }
            security.SetOwner(administrators);
            File.SetAccessControl(path, security);
        }

        private static void HardenProtectedTree(string root, bool allowUsersRead)
        {
            string fullPath = GetExpectedProtectedRoot(root, allowUsersRead);
            if (!Directory.Exists(fullPath))
            {
                return;
            }
            List<string> entries = GetSafeTreeEntries(fullPath);
            ApplyDirectorySecurity(fullPath, allowUsersRead);
            foreach (string entry in entries)
            {
                if ((File.GetAttributes(entry) & FileAttributes.Directory) != 0)
                {
                    ApplyDirectorySecurity(entry, allowUsersRead);
                }
                else
                {
                    ApplyFileSecurity(entry, allowUsersRead);
                }
            }
        }

        private static void ExtractPayload(string destinationRoot)
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            byte[] payload = ReadResource(assembly, Product.PayloadResource);
            string expectedHash = Encoding.ASCII.GetString(ReadResource(assembly,
                Product.PayloadHashResource)).Trim();
            string actualHash;
            using (SHA256 sha256 = SHA256.Create())
            {
                actualHash = BitConverter.ToString(sha256.ComputeHash(payload)).Replace("-", string.Empty);
            }
            if (!string.Equals(actualHash, expectedHash, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("The embedded DeckLux payload hash is invalid.");
            }

            string normalizedRoot = Path.GetFullPath(destinationRoot)
                .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            using (MemoryStream memory = new MemoryStream(payload, false))
            using (ZipArchive archive = new ZipArchive(memory, ZipArchiveMode.Read, false))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string relative = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                    string destination = Path.GetFullPath(Path.Combine(normalizedRoot, relative));
                    if (!destination.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidDataException("The embedded payload contains an unsafe path.");
                    }
                    if (entry.FullName.EndsWith("/", StringComparison.Ordinal))
                    {
                        Directory.CreateDirectory(destination);
                        continue;
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    string temporary = destination + ".new-" + Guid.NewGuid().ToString("N");
                    using (Stream input = entry.Open())
                    using (FileStream output = new FileStream(temporary, FileMode.CreateNew,
                        FileAccess.Write, FileShare.None))
                    {
                        input.CopyTo(output);
                        output.Flush(true);
                    }
                    if (File.Exists(destination))
                    {
                        File.Delete(destination);
                    }
                    File.Move(temporary, destination);
                }
            }
        }

        private static byte[] ReadResource(Assembly assembly, string name)
        {
            using (Stream stream = assembly.GetManifestResourceStream(name))
            {
                if (stream == null)
                {
                    throw new InvalidDataException("Required embedded resource is missing: " + name);
                }
                using (MemoryStream memory = new MemoryStream())
                {
                    stream.CopyTo(memory);
                    return memory.ToArray();
                }
            }
        }

        private static void InstallSetupExecutable()
        {
            string source = Path.GetFullPath(Application.ExecutablePath);
            string destination = Path.GetFullPath(Product.InstalledSetupPath);
            if (string.Equals(source, destination, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
            string temporary = destination + ".new";
            File.Copy(source, temporary, true);
            if (File.Exists(destination))
            {
                File.Delete(destination);
            }
            File.Move(temporary, destination);
        }

        private static void RunPowerShell(string scriptPath, string parameters, Action<string> log)
        {
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException("Required DeckLux script is missing.", scriptPath);
            }
            string script = "$ErrorActionPreference='Stop'; trap { Write-Error $_; exit 1 }; & " +
                QuotePowerShell(scriptPath) + " " + parameters + "; exit 0";
            string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            string powerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = powerShell;
            start.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + encoded;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            start.WorkingDirectory = Product.InstallRoot;
            using (Process process = new Process())
            {
                process.StartInfo = start;
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                {
                    if (!string.IsNullOrWhiteSpace(eventArgs.Data)) log(eventArgs.Data);
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                {
                    if (!string.IsNullOrWhiteSpace(eventArgs.Data)) log(eventArgs.Data);
                };
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    throw new InvalidOperationException("DeckLux installation command failed with exit code " +
                        process.ExitCode.ToString(CultureInfo.InvariantCulture) + ".");
                }
            }
        }

        private static string QuotePowerShell(string value)
        {
            return "'" + value.Replace("'", "''") + "'";
        }

        private static void ValidateSupportedState()
        {
            string json = File.ReadAllText(Product.StatePath, Encoding.UTF8);
            ValidateSupportedStateJson(json);
        }

        internal static void ValidateSupportedStateJson(string json)
        {
            Dictionary<string, object> root = DeserializeStateRoot(json);
            if (!string.Equals(GetStateString(root, "Project"), "DeckLux",
                StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "The installation state does not identify DeckLux.");
            }

            object schemaValue;
            if (!root.TryGetValue("SchemaVersion", out schemaValue) ||
                !(schemaValue is int))
            {
                throw new InvalidDataException(
                    "DeckLux state has no valid schema version.");
            }
            int schemaVersion = (int)schemaValue;
            if (schemaVersion < 1 || schemaVersion > 3)
            {
                throw new InvalidDataException(
                    "DeckLux state uses an unsupported schema version.");
            }

            object targetValue;
            IList targets;
            if (!root.TryGetValue("Targets", out targetValue) ||
                (targets = targetValue as IList) == null ||
                targets.Count < 1 || targets.Count > 2)
            {
                throw new InvalidDataException(
                    "DeckLux state must record one or two supported targets.");
            }

            object platformValue;
            bool hasPlatform = root.TryGetValue("Platform", out platformValue);
            Dictionary<string, object> platform = hasPlatform
                ? platformValue as Dictionary<string, object>
                : null;
            if (hasPlatform && platform == null)
            {
                throw new InvalidDataException(
                    "DeckLux state has an invalid platform record.");
            }
            if (schemaVersion == 3 && platform == null)
            {
                throw new InvalidDataException(
                    "DeckLux schema 3 state has no platform record.");
            }

            ValidateSupportedTargets(
                targets, schemaVersion, GetStateDeckProduct(platform, schemaVersion));
        }

        private static void ValidateInstalledDefaultState()
        {
            string json = File.ReadAllText(Product.StatePath, Encoding.UTF8);
            ValidateInstalledDefaultStateJson(json);
        }

        internal static void ValidateInstalledDefaultStateJson(string json)
        {
            // Keep the broader validator for uninstalling supported legacy states,
            // then enforce the current installer's exact completed topology.
            ValidateSupportedStateJson(json);
            Dictionary<string, object> root = DeserializeStateRoot(json);

            object schemaValue;
            if (!root.TryGetValue("SchemaVersion", out schemaValue) ||
                !(schemaValue is int) || (int)schemaValue != 3)
            {
                throw new InvalidDataException(
                    "A new DeckLux installation must record schema version 3.");
            }
            if (!GetRequiredStateBoolean(root, "Completed") ||
                GetRequiredStateBoolean(root, "Uninstalled"))
            {
                throw new InvalidDataException(
                    "A new DeckLux installation must record a completed, active transaction.");
            }

            Dictionary<string, object> platform = GetDictionary(root, "Platform");
            string deckProduct = GetStateDeckProduct(platform, 3);
            object targetValue;
            IList targets;
            if (!root.TryGetValue("Targets", out targetValue) ||
                (targets = targetValue as IList) == null)
            {
                throw new InvalidDataException(
                    "A new DeckLux installation has no valid target list.");
            }

            bool validDefaultTopology =
                (string.Equals(deckProduct, "Galileo", StringComparison.Ordinal) &&
                 targets.Count == 2 &&
                 IsSupportedSensorTarget(
                     targets[0] as Dictionary<string, object>,
                     "Primary", "LTRF", "ACPI\\PRP0001\\0") &&
                 IsSupportedSensorTarget(
                     targets[1] as Dictionary<string, object>,
                     "Secondary", "LTRS", "ACPI\\PRP0001\\1")) ||
                (string.Equals(deckProduct, "Jupiter", StringComparison.Ordinal) &&
                 targets.Count == 1 &&
                 IsSupportedSensorTarget(
                     targets[0] as Dictionary<string, object>,
                     "Primary", "LTRF", "ACPI\\PRP0001\\1"));
            if (!validDefaultTopology)
            {
                throw new InvalidDataException(
                    "A new DeckLux installation does not contain the default sensor topology for this Steam Deck.");
            }
        }

        private static Dictionary<string, object> DeserializeStateRoot(string json)
        {
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> root =
                    serializer.Deserialize<Dictionary<string, object>>(json);
                if (root == null)
                {
                    throw new InvalidDataException("DeckLux state JSON is null.");
                }
                return root;
            }
            catch (InvalidDataException)
            {
                throw;
            }
            catch (Exception exception)
            {
                throw new InvalidDataException(
                    "DeckLux state JSON is invalid.", exception);
            }
        }

        internal static bool IncludesDangerousFileSystemRights(
            FileSystemRights rights)
        {
            FileSystemRights dangerousRights =
                FileSystemRights.WriteData |
                FileSystemRights.AppendData |
                FileSystemRights.WriteExtendedAttributes |
                FileSystemRights.WriteAttributes |
                FileSystemRights.DeleteSubdirectoriesAndFiles |
                FileSystemRights.Delete |
                FileSystemRights.ChangePermissions |
                FileSystemRights.TakeOwnership;
            return (rights & dangerousRights) != 0;
        }

        private static string GetStateDeckProduct(
            Dictionary<string, object> platform,
            int schemaVersion)
        {
            if (platform == null)
            {
                return string.Empty;
            }

            string deckProduct = GetStateString(platform, "DeckProduct");
            string manufacturer = GetStateString(platform, "SystemManufacturer");
            string productName = GetStateString(platform, "SystemProductName");

            if (string.IsNullOrEmpty(deckProduct) && schemaVersion < 3 &&
                string.Equals(manufacturer, "Valve",
                    StringComparison.OrdinalIgnoreCase) &&
                (string.Equals(productName, "Jupiter",
                    StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(productName, "Galileo",
                    StringComparison.OrdinalIgnoreCase)))
            {
                deckProduct = productName;
            }

            if (string.IsNullOrEmpty(deckProduct))
            {
                if (schemaVersion == 3)
                {
                    throw new InvalidDataException(
                        "DeckLux schema 3 state has no supported product identity.");
                }
                return string.Empty;
            }

            if (!string.Equals(deckProduct, "Jupiter", StringComparison.Ordinal) &&
                !string.Equals(deckProduct, "Galileo", StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "DeckLux state identifies an unsupported product.");
            }
            if ((!string.IsNullOrEmpty(manufacturer) &&
                 !string.Equals(manufacturer, "Valve",
                     StringComparison.OrdinalIgnoreCase)) ||
                (!string.IsNullOrEmpty(productName) &&
                 !string.Equals(productName, deckProduct,
                     StringComparison.OrdinalIgnoreCase)))
            {
                throw new InvalidDataException(
                    "DeckLux state contains contradictory platform identity.");
            }
            return deckProduct;
        }

        private static void ValidateSupportedTargets(
            IList targets,
            int schemaVersion,
            string deckProduct)
        {
            Dictionary<string, object> primary =
                targets[0] as Dictionary<string, object>;
            if (targets.Count == 2)
            {
                Dictionary<string, object> secondary =
                    targets[1] as Dictionary<string, object>;
                if (schemaVersion != 3 ||
                    !string.Equals(deckProduct, "Galileo",
                        StringComparison.Ordinal) ||
                    !IsSupportedSensorTarget(primary, "Primary", "LTRF",
                        "ACPI\\PRP0001\\0") ||
                    !IsSupportedSensorTarget(secondary, "Secondary", "LTRS",
                        "ACPI\\PRP0001\\1"))
                {
                    throw new InvalidDataException(
                        "A two-sensor state must contain the canonical Galileo LTRF/LTRS pair.");
                }
                return;
            }

            bool validPrimary;
            if (string.Equals(deckProduct, "Jupiter", StringComparison.Ordinal))
            {
                validPrimary = IsSupportedSensorTarget(
                    primary, "Primary", "LTRF", "ACPI\\PRP0001\\1");
            }
            else if (string.Equals(deckProduct, "Galileo", StringComparison.Ordinal))
            {
                validPrimary = IsSupportedSensorTarget(
                    primary, "Primary", "LTRF", "ACPI\\PRP0001\\0");
            }
            else
            {
                validPrimary =
                    IsSupportedSensorTarget(
                        primary, "Primary", "LTRF", "ACPI\\PRP0001\\0") ||
                    IsSupportedSensorTarget(
                        primary, "Primary", "LTRF", "ACPI\\PRP0001\\1");
            }

            if (!validPrimary)
            {
                throw new InvalidDataException(
                    "DeckLux state does not contain a canonical primary sensor.");
            }
        }

        private static bool IsSupportedSensorTarget(
            Dictionary<string, object> target,
            string expectedRole,
            string expectedBiosLeaf,
            string expectedInstanceId)
        {
            return target != null &&
                string.Equals(GetStateString(target, "Role"), expectedRole,
                    StringComparison.Ordinal) &&
                HasBiosLeaf(GetStateString(target, "BiosDeviceName"),
                    expectedBiosLeaf) &&
                string.Equals(GetStateString(target, "InstanceId"),
                    expectedInstanceId, StringComparison.OrdinalIgnoreCase);
        }

        private static bool HasBiosLeaf(
            string biosDeviceName,
            string expectedLeaf)
        {
            return string.Equals(biosDeviceName, expectedLeaf,
                       StringComparison.OrdinalIgnoreCase) ||
                biosDeviceName.EndsWith("." + expectedLeaf,
                    StringComparison.OrdinalIgnoreCase);
        }

        private static string GetStateString(
            Dictionary<string, object> parent,
            string key)
        {
            object value;
            if (!parent.TryGetValue(key, out value) || value == null)
            {
                return string.Empty;
            }
            string text = value as string;
            if (text == null)
            {
                throw new InvalidDataException(
                    "DeckLux state field '" + key + "' must be a string.");
            }
            return text;
        }

        private static bool GetRequiredStateBoolean(
            Dictionary<string, object> parent,
            string key)
        {
            object value;
            if (!parent.TryGetValue(key, out value) || !(value is bool))
            {
                throw new InvalidDataException(
                    "DeckLux state field '" + key + "' must be a Boolean.");
            }
            return (bool)value;
        }

        private static void WriteUninstallRegistration()
        {
            using (RegistryKey baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
            using (RegistryKey key = baseKey.CreateSubKey(Product.UninstallKey, true))
            {
                if (key == null)
                {
                    throw new InvalidOperationException("Could not create the DeckLux uninstall registration.");
                }
                string quotedSetup = "\"" + Product.InstalledSetupPath + "\"";
                key.SetValue("DisplayName", "DeckLux", RegistryValueKind.String);
                key.SetValue("DisplayVersion", Product.Version, RegistryValueKind.String);
                key.SetValue("Publisher", "Laszlo Toth", RegistryValueKind.String);
                key.SetValue("InstallLocation", Product.InstallRoot, RegistryValueKind.String);
                key.SetValue("DisplayIcon", Product.InstalledSetupPath, RegistryValueKind.String);
                key.SetValue("UninstallString", quotedSetup + " /uninstall", RegistryValueKind.String);
                key.SetValue("QuietUninstallString", quotedSetup + " /quiet-uninstall", RegistryValueKind.String);
                key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd", CultureInfo.InvariantCulture),
                    RegistryValueKind.String);
                key.SetValue("EstimatedSize", EstimateInstalledSizeKilobytes(), RegistryValueKind.DWord);
            }
        }

        private static int EstimateInstalledSizeKilobytes()
        {
            long bytes = 0;
            if (Directory.Exists(Product.InstallRoot))
            {
                foreach (string file in Directory.GetFiles(Product.InstallRoot, "*", SearchOption.AllDirectories))
                {
                    bytes += new FileInfo(file).Length;
                }
            }
            return checked((int)Math.Max(1, (bytes + 1023) / 1024));
        }

        private static void RemoveUninstallRegistration()
        {
            using (RegistryKey baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
            {
                baseKey.DeleteSubKeyTree(Product.UninstallKey, false);
            }
        }

        private static bool IsUninstallRegistered()
        {
            using (RegistryKey baseKey = RegistryKey.OpenBaseKey(
                RegistryHive.LocalMachine, RegistryView.Registry64))
            using (RegistryKey key = baseKey.OpenSubKey(Product.UninstallKey, false))
            {
                return key != null;
            }
        }

        private static void RemoveInstalledFiles(Action<string> log)
        {
            if (!Directory.Exists(Product.InstallRoot))
            {
                RemoveUninstallRegistration();
                return;
            }
            string current = Path.GetFullPath(Application.ExecutablePath);
            string installed = Path.GetFullPath(Product.InstalledSetupPath);
            if (!string.Equals(current, installed, StringComparison.OrdinalIgnoreCase))
            {
                Directory.Delete(Product.InstallRoot, true);
                RemoveUninstallRegistration();
                log("Removed installed DeckLux program files.");
                return;
            }
            string temporary = Path.Combine(Path.GetTempPath(),
                "DeckLux.Setup.cleanup." + Guid.NewGuid().ToString("N") + ".exe");
            string tokenValue = Guid.NewGuid().ToString("N") + Guid.NewGuid().ToString("N");
            string tokenPath = Path.Combine(Product.DataRoot,
                "cleanup." + Guid.NewGuid().ToString("N") + ".token");
            File.WriteAllText(tokenPath, tokenValue, Encoding.ASCII);
            ApplyFileSecurity(tokenPath, false);
            File.Copy(current, temporary, true);
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = temporary;
            start.Arguments = "/cleanup " + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) +
                " \"" + Product.InstallRoot + "\" \"" + tokenPath + "\" " + tokenValue;
            start.UseShellExecute = true;
            try
            {
                Process worker = Process.Start(start);
                if (worker == null)
                {
                    throw new InvalidOperationException("Could not start the DeckLux cleanup worker.");
                }
            }
            catch
            {
                File.Delete(tokenPath);
                throw;
            }
            log("Scheduled installed DeckLux program-file cleanup.");
        }

        internal static int Cleanup(string[] args)
        {
            try
            {
                if (args.Length != 5) return 2;
                int parentId;
                if (!int.TryParse(args[1], NumberStyles.None, CultureInfo.InvariantCulture, out parentId)) return 2;
                string requested = Path.GetFullPath(args[2]).TrimEnd(Path.DirectorySeparatorChar);
                string expected = Path.GetFullPath(Product.InstallRoot).TrimEnd(Path.DirectorySeparatorChar);
                if (!string.Equals(requested, expected, StringComparison.OrdinalIgnoreCase)) return 2;
                string tokenPath = Path.GetFullPath(args[3]);
                string expectedTokenRoot = Path.GetFullPath(Product.DataRoot)
                    .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                if (!tokenPath.StartsWith(expectedTokenRoot, StringComparison.OrdinalIgnoreCase) ||
                    !Path.GetFileName(tokenPath).StartsWith("cleanup.", StringComparison.OrdinalIgnoreCase) ||
                    !Path.GetFileName(tokenPath).EndsWith(".token", StringComparison.OrdinalIgnoreCase) ||
                    args[4].Length != 64)
                {
                    return 2;
                }
                try
                {
                    using (Process parent = Process.GetProcessById(parentId)) { parent.WaitForExit(); }
                }
                catch (ArgumentException)
                {
                }

                using (Mutex setupMutex = new Mutex(false, Product.SetupMutexName))
                {
                    bool lockTaken = false;
                    try
                    {
                        try
                        {
                            setupMutex.WaitOne();
                            lockTaken = true;
                        }
                        catch (AbandonedMutexException)
                        {
                            lockTaken = true;
                        }
                        ValidateProtectedDirectoryIfPresent(Product.DataRoot, false);
                        if (!File.Exists(tokenPath) ||
                            !FixedTimeEquals(File.ReadAllText(tokenPath, Encoding.ASCII), args[4]))
                        {
                            return 2;
                        }
                        File.Delete(tokenPath);
                        ValidateProtectedDirectoryIfPresent(Product.InstallRoot, true);
                        if (Directory.Exists(expected)) Directory.Delete(expected, true);
                        RemoveUninstallRegistration();
                        MoveFileEx(Application.ExecutablePath, null, MoveFileDelayUntilReboot);
                        return 0;
                    }
                    finally
                    {
                        if (lockTaken)
                        {
                            setupMutex.ReleaseMutex();
                        }
                    }
                }
            }
            catch (Exception exception)
            {
                AppendPersistentLog("Cleanup error: " + exception);
                return 1;
            }
        }

        private static bool FixedTimeEquals(string left, string right)
        {
            byte[] leftBytes = Encoding.UTF8.GetBytes(left);
            byte[] rightBytes = Encoding.UTF8.GetBytes(right);
            int difference = leftBytes.Length ^ rightBytes.Length;
            int length = Math.Min(leftBytes.Length, rightBytes.Length);
            for (int index = 0; index < length; ++index)
            {
                difference |= leftBytes[index] ^ rightBytes[index];
            }
            return difference == 0;
        }

        private static Dictionary<string, object> GetDictionary(Dictionary<string, object> parent, string key)
        {
            object value;
            Dictionary<string, object> result;
            if (!parent.TryGetValue(key, out value) ||
                (result = value as Dictionary<string, object>) == null)
            {
                throw new InvalidDataException("DeckLux state is missing '" + key + "'.");
            }
            return result;
        }

        private static string GetString(Dictionary<string, object> parent, string key)
        {
            object value;
            if (!parent.TryGetValue(key, out value) || value == null) return string.Empty;
            return Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty;
        }

        private static bool GetBoolean(Dictionary<string, object> parent, string key)
        {
            object value;
            if (!parent.TryGetValue(key, out value) || value == null) return false;
            return Convert.ToBoolean(value, CultureInfo.InvariantCulture);
        }
    }
}
