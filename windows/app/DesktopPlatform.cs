using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Principal;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace PixelBackup
{
    internal sealed class LibraryProfile
    {
        public string Id, Name, DirectoryPath;
        public override string ToString() { return Name; }
    }

    internal sealed class Profiles
    {
        private readonly string root;
        internal readonly List<LibraryProfile> All = new List<LibraryProfile>();
        internal LibraryProfile Active { get; private set; }

        internal Profiles(string state)
        {
            root = Path.Combine(state, "profiles");
            Directory.CreateDirectory(root);
            foreach (string path in Directory.GetDirectories(root))
            {
                Guid id;
                if (!Guid.TryParseExact(Path.GetFileName(path), "N", out id) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) continue;
                string label = Path.Combine(path, "name.txt");
                if (!File.Exists(label)) continue;
                All.Add(new LibraryProfile { Id = id.ToString("N"), Name = File.ReadAllText(label, Encoding.UTF8).Trim(), DirectoryPath = path });
            }
            All.Sort((a, b) => StringComparer.CurrentCultureIgnoreCase.Compare(a.Name, b.Name));
            if (All.Count == 0) Create("My library");
            string current = Path.Combine(root, "current");
            string saved = File.Exists(current) ? File.ReadAllText(current).Trim() : "";
            Active = All.FirstOrDefault(x => x.Id == saved) ?? All[0];
        }

        internal LibraryProfile Create(string name)
        {
            name = (name ?? "").Trim();
            if (name.Length == 0 || name.Length > 60 || name.Any(char.IsControl))
                throw new ArgumentException("Choose a library name between 1 and 60 characters.");
            if (All.Any(x => string.Equals(x.Name, name, StringComparison.CurrentCultureIgnoreCase)))
                throw new ArgumentException("A library with that name already exists.");
            string id = Guid.NewGuid().ToString("N");
            string directory = Path.Combine(root, id);
            Directory.CreateDirectory(directory);
            var profile = new LibraryProfile { Id = id, Name = name, DirectoryPath = directory };
            File.WriteAllText(Path.Combine(directory, "name.txt"), name, new UTF8Encoding(false));
            All.Add(profile);
            return profile;
        }

        internal void Select(LibraryProfile selected)
        {
            string file = Path.Combine(root, "current");
            string temp = Path.Combine(root, Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                File.WriteAllText(temp, selected.Id, Encoding.ASCII);
                if (File.Exists(file)) File.Replace(temp, file, null);
                else File.Move(temp, file);
                Active = selected;
            }
            finally { if (File.Exists(temp)) File.Delete(temp); }
        }
    }

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
            const string cmd = "$ErrorActionPreference='Stop'; $u=Get-LocalUser | Where-Object Name -eq 'PixelReader'; if(!$u){'Missing'}elseif(!$u.Enabled){'Disabled'}else{'Ready';if($u.PasswordExpires){$u.PasswordExpires.ToString('yyyy-MM-dd')}else{'No expiry date'}}";
            var info = new ProcessStartInfo(PowerShell, "-NoLogo -NoProfile -NonInteractive -Command " + Quote(cmd))
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
            };
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

        internal static string PickFolder(string title)
        {
            using (var picker = new System.Windows.Forms.FolderBrowserDialog { Description = title, ShowNewFolderButton = false })
                return picker.ShowDialog() == System.Windows.Forms.DialogResult.OK ? picker.SelectedPath : null;
        }

        internal static string FindAdb(Window owner)
        {
            var paths = new List<string> { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Android\Sdk\platform-tools") };
            foreach (string name in new[] { "ANDROID_HOME", "ANDROID_SDK_ROOT" })
            {
                string sdk = Environment.GetEnvironmentVariable(name);
                if (!string.IsNullOrWhiteSpace(sdk)) paths.Add(Path.Combine(sdk, "platform-tools"));
            }
            paths.AddRange((Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'));
            foreach (string dir in paths)
            {
                if (string.IsNullOrWhiteSpace(dir)) continue;
                try
                {
                    var exe = Path.Combine(dir.Trim().Trim('"'), "adb.exe");
                    if (Path.IsPathRooted(exe) && File.Exists(exe)) return Path.GetFullPath(exe);
                }
                catch (ArgumentException) { }
            }
            var picker = new Microsoft.Win32.OpenFileDialog { Title = "Select adb.exe from Android Platform Tools", Filter = "Android Debug Bridge (adb.exe)|adb.exe", CheckFileExists = true };
            return picker.ShowDialog(owner) == true ? picker.FileName : null;
        }

        internal static string[] LanAddresses()
        {
            return NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up &&
                n.NetworkInterfaceType != NetworkInterfaceType.Loopback && n.NetworkInterfaceType != NetworkInterfaceType.Tunnel)
                .OrderByDescending(n => n.GetIPProperties().GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork))
                .SelectMany(n => n.GetIPProperties().UnicastAddresses).Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
                .Select(a => a.Address.ToString()).Distinct().ToArray();
        }

        internal static string Prompt(Window owner, string title, string caption, string value, string[] choices)
        {
            var dialog = new Window
            {
                Title = title, Owner = owner, SizeToContent = SizeToContent.Height, Width = 460, ResizeMode = ResizeMode.NoResize,
                WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
                Background = Brushes.White, FontFamily = owner.FontFamily, FontSize = 14
            };
            var panel = new StackPanel { Margin = new Thickness(24) };
            panel.Children.Add(new TextBlock { Text = caption, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 14) });
            var input = new TextBox { Text = value ?? "", MaxLength = 60, Padding = new Thickness(7), MinHeight = 32 };
            var list = new ComboBox { ItemsSource = choices, SelectedIndex = 0, MinHeight = 32 };
            panel.Children.Add(choices == null ? (UIElement)input : list);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
            var cancel = new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(12, 5, 12, 5) };
            var ok = new Button { Content = "Continue", IsDefault = true, Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(8, 0, 0, 0) };
            ok.Click += delegate { dialog.DialogResult = true; };
            buttons.Children.Add(cancel); buttons.Children.Add(ok); panel.Children.Add(buttons); dialog.Content = panel;
            dialog.Loaded += delegate { if (choices == null) { input.Focus(); input.SelectAll(); } else list.Focus(); };
            if (dialog.ShowDialog() != true) return null;
            return choices == null ? input.Text : list.SelectedItem as string;
        }
    }
}
