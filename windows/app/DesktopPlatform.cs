using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Principal;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace PixelBackup
{
    internal static class DesktopPlatform
    {
        internal static string PowerShell
        {
            get { return Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"); }
        }

        // Win32 CreateProcess accepts a single string; quote every argument using the CRT rules.
        internal static string Quote(string value)
        {
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { result.Append('\\', 2 * slashes + 1).Append(c); }
                else { result.Append('\\', slashes).Append(c); }
                slashes = 0;
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }

        internal static void RunScript(string script, bool elevate, bool show, params string[] arguments)
        {
            if (!File.Exists(script)) throw new FileNotFoundException("Reinstall Pixel Backup. A Windows helper is missing.", script);
            var args = new List<string> { "-NoLogo", "-NoProfile", "-STA", "-ExecutionPolicy", "RemoteSigned", "-File", script };
            args.AddRange(arguments);
            var info = new ProcessStartInfo(PowerShell, string.Join(" ", args.Select(Quote)))
            {
                UseShellExecute = true,
                WorkingDirectory = Path.GetDirectoryName(script),
                WindowStyle = show ? ProcessWindowStyle.Normal : ProcessWindowStyle.Hidden
            };
            if (elevate && !new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) info.Verb = "runas";
            try
            {
                using (var process = Process.Start(info))
                {
                    if (process == null) throw new IOException("Windows could not start the setup helper.");
                    process.WaitForExit();
                    if (process.ExitCode != 0) throw new InvalidOperationException("Windows setup did not finish. Check the phone’s USB and root prompts, the PC address and folder permissions. The setup guide includes the troubleshooting commands.");
                }
            }
            catch (Win32Exception e)
            {
                if (e.NativeErrorCode == 1223) throw new OperationCanceledException("Windows approval was canceled.");
                throw;
            }
        }

        internal static string[] ReaderInfo()
        {
            const string cmd = @"$ErrorActionPreference = 'Stop'
$user = Get-LocalUser | Where-Object Name -eq 'PixelReader'
if (!$user) { 'Missing'; return }
if ($user.Description -cnotin @('Pixel Backup dedicated reader', 'Pixel Backup Gang dedicated reader')) { 'Other'; return }
if (!$user.Enabled) { 'Disabled'; return }
if ($user.PasswordExpires -and $user.PasswordExpires -le (Get-Date)) { 'Expired'; return }
'Ready'
if ($user.PasswordExpires) { $user.PasswordExpires.ToString('yyyy-MM-dd') } else { 'No expiry date' }";
            var info = new ProcessStartInfo(PowerShell, "-NoLogo -NoProfile -NonInteractive -Command " + Quote(cmd))
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
            };
            info.EnvironmentVariables.Remove("PSModulePath");
            using (var proc = Process.Start(info))
            {
                if (proc == null) return new string[0];
                var output = proc.StandardOutput.ReadToEndAsync();
                var errors = proc.StandardError.ReadToEndAsync();
                if (!proc.WaitForExit(10000)) { proc.Kill(); return new string[0]; }
                errors.GetAwaiter().GetResult();
                return proc.ExitCode == 0 ? output.GetAwaiter().GetResult().Split(new[] {'\r','\n'}, StringSplitOptions.RemoveEmptyEntries) : new string[0];
            }
        }

        internal static string PickFolder(Window owner, string title)
        {
            return DesktopFolderPicker.Show(owner, title);
        }

        internal static bool Elevated
        {
            get
            {
                using (var identity = WindowsIdentity.GetCurrent())
                    return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            }
        }

        // Pair-PixelDesktop requests elevation only when creating the Windows reader account.
        internal static void RunSetupScript(string script, params string[] arguments)
        {
            if (Elevated) throw new InvalidOperationException("Close Pixel Backup and reopen it from your desktop as a regular Windows app to set up USB.");
            if (!File.Exists(script)) throw new FileNotFoundException("Reinstall Pixel Backup. The Windows USB setup helper is missing.");
            var args = new List<string> { "-NoLogo", "-NoProfile", "-STA", "-ExecutionPolicy", "RemoteSigned", "-File", script };
            args.AddRange(arguments);
            var info = new ProcessStartInfo(PowerShell, string.Join(" ", args.Select(Quote)))
            {
                WorkingDirectory = Path.GetDirectoryName(script), UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            // Use the same local USB server as the preflight and PS 5.1's own module paths.
            foreach (string variable in new[] { "PSModulePath", "ADB_SERVER_SOCKET", "ANDROID_ADB_SERVER_ADDRESS", "ANDROID_ADB_SERVER_PORT" })
                info.EnvironmentVariables.Remove(variable);
            using (var process = Process.Start(info))
            {
                if (process == null) throw new IOException("Windows could not start the USB setup helper.");
                var output = process.StandardOutput.ReadToEndAsync();
                var errors = process.StandardError.ReadToEndAsync();
                process.WaitForExit();
                output.GetAwaiter().GetResult();
                string detail = errors.GetAwaiter().GetResult();
                if (process.ExitCode == 0) return;
                if (process.ExitCode == 1223) throw new OperationCanceledException("Setup canceled.");
                const string prefix = "PixelBackupError:";
                string safe = detail.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                    .FirstOrDefault(s => s.StartsWith(prefix, StringComparison.Ordinal) && s.Length > prefix.Length && s.Length < 1500);
                throw new InvalidOperationException(safe == null
                    ? "Keep one unlocked Pixel connected with a USB data cable. Allow USB debugging and the Magisk prompt on the phone, then try again."
                    : safe.Substring(prefix.Length).Trim());
            }
        }

        private sealed class LanAddress
        {
            internal string Address, Adapter;
            internal bool HasGateway;
            public override string ToString() { return Adapter + "  ·  " + Address; }
        }

        private static bool UsableAddress(string text)
        {
            IPAddress address;
            if (!IPAddress.TryParse(text, out address) || address.AddressFamily != AddressFamily.InterNetwork ||
                !string.Equals(address.ToString(), text, StringComparison.Ordinal)) return false;
            byte[] bytes = address.GetAddressBytes();
            return bytes[0] != 0 && bytes[0] != 127 && bytes[0] < 224;
        }

        private static LanAddress[] LanAddresses()
        {
            var addresses = new List<LanAddress>();
            try
            {
                foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (network.OperationalStatus != OperationalStatus.Up || network.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                        network.NetworkInterfaceType == NetworkInterfaceType.Tunnel || network.NetworkInterfaceType == NetworkInterfaceType.Ppp) continue;
                    try
                    {
                        var properties = network.GetIPProperties();
                        bool gateway = properties.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any));
                        foreach (var unicast in properties.UnicastAddresses)
                        {
                            if (unicast.Address.AddressFamily != AddressFamily.InterNetwork ||
                                unicast.DuplicateAddressDetectionState == DuplicateAddressDetectionState.Duplicate ||
                                unicast.DuplicateAddressDetectionState == DuplicateAddressDetectionState.Tentative ||
                                unicast.DuplicateAddressDetectionState == DuplicateAddressDetectionState.Invalid) continue;
                            string address = unicast.Address.ToString();
                            if (UsableAddress(address) && !address.StartsWith("169.254.", StringComparison.Ordinal))
                                addresses.Add(new LanAddress { Adapter = network.Name, Address = address, HasGateway = gateway });
                        }
                    }
                    catch (NetworkInformationException) { } // An adapter can disconnect during enumeration.
                }
            }
            catch (NetworkInformationException) { } // Manual entry remains available.
            return addresses.OrderByDescending(a => a.HasGateway).ThenBy(a => a.Adapter, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(a => a.Address, StringComparer.Ordinal).GroupBy(a => a.Address).Select(g => g.First()).ToArray();
        }

        private static TextBlock DialogText(string text)
        {
            return new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) };
        }

        private static bool ShowSetupDialog(Window owner, string title, StackPanel body, string action, Func<bool> approve)
        {
            var dialog = new Window { Title = "Pixel Backup", Owner = owner, Icon = owner.Icon, FontFamily = owner.FontFamily, FontSize = 14,
                Width = Math.Min(480, SystemParameters.WorkArea.Width), MaxHeight = SystemParameters.WorkArea.Height,
                SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                Background = owner.TryFindResource("Surface") as Brush ?? SystemColors.WindowBrush,
                Foreground = owner.TryFindResource("Ink") as Brush ?? SystemColors.WindowTextBrush };
            var panel = new StackPanel { Margin = new Thickness(24) };
            var heading = DialogText(title); heading.FontSize = 21; heading.FontWeight = FontWeights.SemiBold;
            panel.Children.Add(heading); panel.Children.Add(body);
            var buttons = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 4, 0, 0) };
            var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 68, Padding = new Thickness(12, 6, 12, 6), Style = owner.TryFindResource("ButtonBase") as Style };
            var ok = new Button { Content = action, MinWidth = 85, Padding = new Thickness(12, 6, 12, 6), Margin = new Thickness(8,0,0,0), Style = owner.TryFindResource("PrimaryButton") as Style };
            ok.Click += delegate { if (approve == null || approve()) dialog.DialogResult = true; };
            buttons.Children.Add(cancel); buttons.Children.Add(ok); panel.Children.Add(buttons);
            dialog.Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
            dialog.Loaded += delegate { cancel.Focus(); };
            return dialog.ShowDialog() == true;
        }

        internal static bool AcceptToolsDownload(Window owner)
        {
            var body = new StackPanel();
            body.Children.Add(DialogText("Pixel Backup uses Google's Android SDK Platform-Tools to connect to your Pixel over USB. " +
                "Version " + AndroidTools.Version + " for Windows is " + (AndroidTools.DownloadBytes / 1000000d).ToString("0.0") + " MB."));
            var terms = DialogText("");
            terms.Inlines.Add(new Run("Choosing Agree and download accepts Google's "));
            var link = new Hyperlink(new Run("Android SDK License Agreement")) { NavigateUri = new Uri(AndroidTools.LicenseUrl) };
            link.RequestNavigate += delegate(object sender, System.Windows.Navigation.RequestNavigateEventArgs e) {
                e.Handled = true;
                try { Process.Start(new ProcessStartInfo(AndroidTools.LicenseUrl) { UseShellExecute = true }); }
                catch (Exception) { terms.Inlines.Add(new Run("  " + AndroidTools.LicenseUrl)); }
            };
            terms.Inlines.Add(link); terms.Inlines.Add(new Run(".")); body.Children.Add(terms);
            return ShowSetupDialog(owner, "Download USB tools?", body, "Agree and download", null);
        }

        internal static string ConfirmPairing(Window owner, ref string folder)
        {
            string selectedFolder = folder;
            var body = new StackPanel();
            body.Children.Add(DialogText("Pair your unlocked Pixel over USB and give PixelReader read access to this photo folder for Wi-Fi backups. Windows asks for administrator approval if it needs to create that account."));
            var selected = DialogText(selectedFolder); selected.FontWeight = FontWeights.SemiBold; body.Children.Add(selected);
            var changeFolder = new Hyperlink(new Run("Choose another folder"));
            var folderLink = DialogText(""); folderLink.Inlines.Add(changeFolder); body.Children.Add(folderLink);
            changeFolder.Click += delegate {
                string choice = PickFolder(Window.GetWindow(selected), "Choose the photo folder your Pixel can read");
                if (choice != null) { selectedFolder = choice; selected.Text = choice; }
            };
            var addresses = LanAddresses();
            var choices = new ComboBox { MinHeight = 32, Margin = new Thickness(0,0,0,8) };
            foreach (var address in addresses) choices.Items.Add(address);
            choices.Items.Add("Enter a different IPv4 address…"); choices.SelectedIndex = 0;
            var input = new TextBox { MaxLength = 15, Padding = new Thickness(7), Margin = new Thickness(0,0,0,8) };
            System.Windows.Automation.AutomationProperties.SetName(choices, "PC network connection");
            System.Windows.Automation.AutomationProperties.SetName(input, "PC IPv4 address");
            var hint = DialogText("Use this PC's IPv4 address on the same network as your Pixel. Find it in Windows Settings under Network & internet, in the properties for Wi-Fi or Ethernet.");
            Action showManual = delegate {
                bool manual = choices.SelectedItem as LanAddress == null;
                input.Visibility = hint.Visibility = manual ? Visibility.Visible : Visibility.Collapsed;
            };
            if (addresses.Length == 1)
            {
                var line = DialogText("PC network address  ·  " + addresses[0]);
                var change = new Hyperlink(new Run("Change"));
                line.Inlines.Add(new Run("  ")); line.Inlines.Add(change); body.Children.Add(line);
                choices.Visibility = Visibility.Collapsed;
                change.Click += delegate { line.Visibility = Visibility.Collapsed; choices.Visibility = Visibility.Visible; choices.Focus(); };
            }
            else body.Children.Add(DialogText(addresses.Length > 0 ? "Choose the PC connection your Pixel can reach." : "Enter this PC’s IPv4 address."));
            if (addresses.Length == 0) choices.Visibility = Visibility.Collapsed;
            body.Children.Add(choices); body.Children.Add(hint); body.Children.Add(input);
            choices.SelectionChanged += delegate { showManual(); }; showManual();
            var validation = DialogText(""); validation.Visibility = Visibility.Collapsed; body.Children.Add(validation);
            string result = null;
            bool accepted = ShowSetupDialog(owner, "Pair your Pixel", body, "Pair Pixel", delegate {
                var choice = choices.SelectedItem as LanAddress;
                result = choice != null ? choice.Address : input.Text.Trim();
                if (UsableAddress(result)) return true;
                validation.Text = "Enter an IPv4 address such as 192.168.1.12."; validation.Visibility = Visibility.Visible; input.Focus(); return false;
            });
            if (!accepted) return null;
            folder = selectedFolder;
            return result;
        }

    }
}
