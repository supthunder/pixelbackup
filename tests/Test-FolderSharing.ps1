#Requires -Version 5.1
<#
.SYNOPSIS
    Exercise folder scanning, the sharing manifest and the desktop start/stop flow.
.EXAMPLE
    powershell.exe -NoProfile -File .\tests\Test-FolderSharing.ps1
.NOTES
    Run in Windows PowerShell 5.1 on NTFS with .NET Framework 4.8.
    The test substitutes a local, unprivileged process for the Windows share broker.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$app = Join-Path $PSScriptRoot '..\windows\app'
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempName = 'PixelBackup-sharing-' + [guid]::NewGuid().ToString('N')
$testRoot = [IO.Path]::Combine($tempParent, $tempName)
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent().User,
    [Security.AccessControl.FileSystemRights]::FullControl,
    [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
    [Security.AccessControl.PropagationFlags]::None,
    [Security.AccessControl.AccessControlType]::Allow))
$null = [IO.Directory]::CreateDirectory($testRoot, $acl)
$junction = Join-Path $testRoot 'library\linked'

try {
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $junction))
    $outside = [IO.Directory]::CreateDirectory((Join-Path $testRoot 'outside')).FullName
    $null = New-Item -ItemType Junction -Path $junction -Target $outside

    $cases = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using PixelBackup;

internal static class FolderSharingTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly byte[] Sample = Encoding.UTF8.GetBytes("unchanged camera original");
    private static readonly string[] MediaPaths = {
        "A/caf\u00e9 #1 [wide].JPG", "B/caf\u00e9 #1 [wide].JPG", "B/renamed.NEF", "clip.MOV"
    };

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Expect<T>(Action action, string message) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new InvalidOperationException(message);
    }

    private static string Put(string root, string relative, byte[] contents)
    {
        string path = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        File.WriteAllBytes(path, contents);
        return path;
    }

    private static string Sha(byte[] bytes)
    {
        using (var hash = SHA256.Create())
            return BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
    }

    // A v1 catalog with the fixture's exact digest marked as confirmed.
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(byte[] path, out IntPtr db, int flags, IntPtr vfs);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_exec(IntPtr db, byte[] sql, IntPtr callback, IntPtr state, IntPtr error);
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);

    private static string SeedOldCatalog(string appData)
    {
        string profiles = Path.Combine(appData, "PixelBackup", "Desktop", "profiles");
        const string id = "5aa1a0c9339f4307b57a5c6e13124ce0";
        string profile = Directory.CreateDirectory(Path.Combine(profiles, id)).FullName;
        File.WriteAllText(Path.Combine(profiles, "current"), id);
        File.WriteAllText(Path.Combine(profile, "name.txt"), "Prior library");
        string catalog = Path.Combine(profile, "backup-library.sqlite3");
        string sql = "PRAGMA application_id=0x50424731; PRAGMA user_version=1;" +
            "CREATE TABLE fingerprint(sha TEXT PRIMARY KEY, takeout INTEGER, confirmed INTEGER) WITHOUT ROWID;" +
            "CREATE TABLE takeout_path(source TEXT COLLATE NOCASE,archive INTEGER,item TEXT,sha TEXT,bytes INTEGER," +
            "PRIMARY KEY(source,archive,item)) WITHOUT ROWID; CREATE INDEX takeout_digest ON takeout_path(sha);" +
            "INSERT INTO fingerprint VALUES('" + Sha(Sample) + "',0,1);";
        IntPtr db;
        Check(sqlite3_open_v2(Encoding.UTF8.GetBytes(catalog + "\0"), out db, 6, IntPtr.Zero) == 0,
            "Could not create the v1 catalog fixture.");
        try
        {
            Check(sqlite3_exec(db, Encoding.UTF8.GetBytes(sql + "\0"), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == 0,
                "Could not seed the v1 catalog.");
        }
        finally { sqlite3_close(db); }
        return catalog;
    }

    private static ScanResult Scan(string folder)
    {
        return MediaScanner.Scan(folder, None, null);
    }

    // Use the real staging and status protocol in an isolated local app data directory.
    private static PlanSession Prepare(ScanResult scan, string appData, CancellationToken token,
        IProgress<string> progress)
    {
        var method = typeof(PlanSession).GetMethod("Prepare", BindingFlags.NonPublic | BindingFlags.Static);
        try { return (PlanSession)method.Invoke(null, new object[] { scan, token, progress, appData }); }
        catch (TargetInvocationException error)
        {
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(error.InnerException).Throw();
            throw;
        }
    }

    private static FieldInfo SessionField(string name)
    {
        var field = typeof(PlanSession).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance);
        Check(field != null, "Missing session test seam: " + name);
        return field;
    }

    private static void NoStagedSession(string appData)
    {
        string path = Path.Combine(appData, "PixelBackup", "sessions");
        Check(!Directory.Exists(path) || !Directory.EnumerateFileSystemEntries(path).Any(),
            "A partial or closed share left staging files behind.");
    }

    private sealed class CancelOnProgress : IProgress<string>
    {
        private readonly CancellationTokenSource source;
        internal CancelOnProgress(CancellationTokenSource source) { this.source = source; }
        public void Report(string message) { source.Cancel(); }
    }

    private static void CheckFolder(string root, string folder, string appData)
    {
        foreach (string name in MediaPaths) Put(folder, name, Sample);
        Put(folder, "ignored/.nomedia", new byte[0]);
        Put(folder, "ignored/nested/hidden.jpg", Sample);
        Put(folder, ".cache/hidden.jpg", Sample);
        string hidden = Put(folder, "hidden.jpg", Sample);
        File.SetAttributes(hidden, File.GetAttributes(hidden) | FileAttributes.Hidden);
        Put(folder, "sidecar.json", Sample);
        Put(folder, "empty.jpg", new byte[0]);
        Put(Path.Combine(root, "outside"), "linked.jpg", Sample);

        string first = Path.Combine(folder, MediaPaths[0]);
        // Other handles may open this file and read its metadata. Any full content
        // read must hit its locked last byte. Neither scanning nor sharing needs it.
        using (var held = new FileStream(first, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            held.Lock(held.Length - 1, 1);
            try
            {
                using (var proof = File.OpenRead(first))
                {
                    proof.Position = proof.Length - 1;
                    Expect<IOException>(() => proof.ReadByte(), "The locked byte must be unreadable for this test.");
                }
                var scan = Scan(folder);
                Check(scan.Items.Select(i => i.RelativePath).SequenceEqual(MediaPaths),
                    "The folder scan must retain every media path, including equal basenames and identical files.");
                Check(scan.Items.All(i => i.Bytes == Sample.Length) &&
                    scan.Warnings.Any(w => w.IndexOf("linked", StringComparison.OrdinalIgnoreCase) >= 0),
                    "Expected original byte lengths and a warning for the junction.");
                using (var session = Prepare(scan, appData, None, null))
                {
                    string plan = (string)SessionField("planDirectory").GetValue(session);
                    byte[] manifest = File.ReadAllBytes(Path.Combine(plan, "files.txt"));
                    byte[] expected = Encoding.UTF8.GetBytes(String.Join("\n", MediaPaths) + "\n");
                    Check(manifest.SequenceEqual(expected), "The UTF-8 manifest lost or rewrote a media path.");
                    Check(File.ReadAllBytes(Path.Combine(plan, "files.sha256")).SequenceEqual(
                        Encoding.ASCII.GetBytes(Sha(expected) + "\n")), "The sidecar must hash the exact path manifest.");
                }
            }
            finally { held.Unlock(held.Length - 1, 1); }
        }
        NoStagedSession(appData);

        using (var canceled = new CancellationTokenSource())
        {
            canceled.Cancel();
            Expect<OperationCanceledException>(() => MediaScanner.Scan(folder, canceled.Token, null),
                "Canceled scanning succeeded.");
        }
        using (var canceled = new CancellationTokenSource())
        {
            ScanResult scan = Scan(folder);
            Expect<OperationCanceledException>(() =>
            {
                using (Prepare(scan, appData, canceled.Token, new CancelOnProgress(canceled))) { }
            }, "A canceled publication produced a session.");
        }
        NoStagedSession(appData);
    }

    private static void CheckChanges(string root, string appData)
    {
        string folder = Path.Combine(root, "changes");
        string path = Put(folder, "selected.jpg", Sample);
        ScanResult scan = Scan(folder);
        MediaEntry entry = scan.Items.Single();
        string marker = Put(folder, ".nomedia", new byte[0]);
        Expect<IOException>(() => { using (Prepare(scan, appData, None, null)) { } },
            "A folder excluded after scanning was exposed.");
        File.Delete(marker);
        File.AppendAllText(path, "larger");
        Expect<IOException>(() => { using (Prepare(scan, appData, None, null)) { } },
            "A size change after scanning was ignored.");
        byte[] newContents = (byte[])Sample.Clone();
        newContents[0] ^= 1;
        File.WriteAllBytes(path, newContents);
        File.SetLastWriteTimeUtc(path, new DateTime(entry.LastWriteUtcTicks, DateTimeKind.Utc).AddMinutes(2));
        Expect<IOException>(() => { using (Prepare(scan, appData, None, null)) { } },
            "A timestamp change after scanning was ignored.");
        File.SetLastWriteTimeUtc(path, new DateTime(entry.LastWriteUtcTicks, DateTimeKind.Utc));
        using (Prepare(scan, appData, None, null)) { }
        using (var locked = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
            Expect<IOException>(() => { using (Prepare(scan, appData, None, null)) { } },
                "An exclusively locked file was accepted for sharing.");
        File.Delete(path);
        Expect<IOException>(() => { using (Prepare(scan, appData, None, null)) { } },
            "A deleted source was accepted for sharing.");

        Put(folder, "selected.jpg", Sample);
        scan = Scan(folder);
        scan.Items.Add(scan.Items[0]);
        Expect<IOException>(() => { using (Prepare(scan, appData, None, null)) { } },
            "The same Windows path was accepted twice.");
        scan = Scan(folder);
        scan.Items[0].RelativePath = "../outside/linked.jpg";
        Expect<IOException>(() => { using (Prepare(scan, appData, None, null)) { } },
            "A path escaping the selected folder was accepted.");
        NoStagedSession(appData);
    }

    private static void MockStatus(string control, string state, bool closed)
    {
        var status = new SessionStatus {
            State = state, Message = "Synthetic broker", PixelSeen = true, CleanupComplete = closed,
            ShareName = "PixelBackupData-0123456789abcdef0123456789abcdef",
            PlanShareName = "PixelBackupPlan-0123456789abcdef0123456789abcdef"
        };
        string next = Path.Combine(control, "mock-status.tmp");
        string path = Path.Combine(control, "status.json");
        File.WriteAllText(next, new JavaScriptSerializer().Serialize(status), new UTF8Encoding(false));
        if (File.Exists(path)) File.Replace(next, path, null); else File.Move(next, path);
    }

    private static int RunMockBroker(string control, string stoppedReceipt)
    {
        MockStatus(control, "Ready", false);
        var elapsed = Stopwatch.StartNew();
        while (!File.Exists(Path.Combine(control, "stop")))
        {
            if (elapsed.Elapsed > TimeSpan.FromSeconds(15)) return 2;
            Thread.Sleep(20);
        }
        File.WriteAllText(stoppedReceipt, "Stop request received");
        MockStatus(control, "Closed", true);
        return 0;
    }

    private static void PumpUntil(Func<bool> done, string message)
    {
        var clock = Stopwatch.StartNew();
        while (!done())
        {
            Check(clock.Elapsed < TimeSpan.FromSeconds(10), message);
            var frame = new DispatcherFrame();
            Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => frame.Continue = false));
            Dispatcher.PushFrame(frame);
            Thread.Sleep(20);
        }
    }

    private static void CheckFirstRun(string root, string folder)
    {
        var window = Program.LoadWindow();
        var setup = (Expander)window.FindName("SetupExpander");
        // Keep the setup panel's device discovery offline when it expands in this test.
        setup.Expanded += (sender, args) => args.Handled = true;
        int starts = 0;
        var controller = new DesktopApp(window, root, (windowsDirectory, selection, token, progress) =>
        {
            Interlocked.Increment(ref starts);
            throw new InvalidOperationException("An unpaired reader reached the share broker.");
        }, () => new[] { "Missing" });
        var choose = (Button)window.FindName("ChooseFolder");
        var share = (Button)window.FindName("ShareButton");
        var pair = (Button)window.FindName("PairPhone");
        var files = (DataGrid)window.FindName("FileTable");
        controller.SelectFolder(folder);
        PumpUntil(() => setup.IsExpanded && choose.IsEnabled && files.Items.Count == MediaPaths.Length,
            "A first-time user must be able to choose a folder and see the inline setup.");
        Check(!share.IsEnabled && pair.IsEnabled && IsWithin(pair, setup),
            "The missing reader must leave pairing accessible and sharing disabled.");
        controller.StartShare();
        PumpUntil(() => choose.IsEnabled, "A first-run start request did not return to folder setup.");
        Check(starts == 0, "Starting before pairing opened a share.");
        window.Close();
    }

    private static void CheckDesktop(string root, string folder, string appData)
    {
        var window = Program.LoadWindow();
        var table = (DataGrid)window.FindName("FileTable");
        var choose = (Button)window.FindName("ChooseFolder");
        var share = (Button)window.FindName("ShareButton");
        var files = (Expander)window.FindName("FilesExpander");
        var setup = (Expander)window.FindName("SetupExpander");
        Check(table != null && choose != null && share != null && files != null && setup != null,
            "The desktop window is missing its folder-sharing controls.");
        var drop = (FrameworkElement)window.FindName("FolderDropSurface");
        Check(drop != null && drop.AllowDrop && window.FindName("FolderPath") != null &&
            window.FindName("PairPhone") != null && window.FindName("GetUsbTools") != null,
            "The single-page workflow must expose folder selection, drop and setup.");
        Check(IsWithin(table, files),
            "The file list must belong to the files expander.");

        int starts = 0;
        PlanSession active = null;
        string control = null;
        string stoppedReceipt = Path.Combine(root, "broker-stopped");
        try
        {
            var controller = new DesktopApp(window, root, (windowsDirectory, selection, token, progress) =>
            {
                var session = Prepare(selection, appData, token, progress);
                try
                {
                    control = (string)SessionField("controlDirectory").GetValue(session);
                    var info = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location,
                        "--mock-broker \"" + control + "\" \"" + stoppedReceipt + "\"") {
                        CreateNoWindow = true, UseShellExecute = false
                    };
                    var worker = Process.Start(info);
                    SessionField("broker").SetValue(session, worker);
                    SessionField("brokerStarted").SetValue(session, true);
                    var onExit = typeof(PlanSession).GetMethod("BrokerExited", BindingFlags.NonPublic | BindingFlags.Instance);
                    worker.Exited += (EventHandler)Delegate.CreateDelegate(typeof(EventHandler), session, onExit);
                    worker.EnableRaisingEvents = true;
                    active = session;
                    Interlocked.Increment(ref starts);
                    return session;
                }
                catch { session.Dispose(); throw; }
            }, () => new[] { "Ready", "No expiry date" });

            Check(choose.IsEnabled && !share.IsEnabled && share.Visibility == Visibility.Collapsed &&
                files.Visibility == Visibility.Collapsed && table.Items.Count == 0,
                "The empty screen must allow selection and keep sharing unavailable.");
            controller.StartShare();
            Check(starts == 0, "The controller opened a share before a folder was selected.");
            string empty = Directory.CreateDirectory(Path.Combine(root, "empty")).FullName;
            controller.SelectFolder(empty);
            PumpUntil(() => choose.IsEnabled && table.ItemsSource != null, "The empty-folder scan did not finish.");
            Check(!share.IsEnabled && table.Items.Count == 0, "An empty folder made sharing available.");
            controller.SelectFolder(folder);
            PumpUntil(() => share.IsEnabled && table.Items.Count == MediaPaths.Length,
                "Folder selection did not make all four files available to share.");
            Check(table.Items.Cast<MediaEntry>().Select(i => i.RelativePath).SequenceEqual(MediaPaths),
                "The UI dropped distinct paths or sorted them inconsistently.");
            Check(files.Visibility == Visibility.Visible && !files.IsExpanded &&
                ((TextBlock)window.FindName("FolderPath")).Text == folder,
                "The selected folder should display its path and let the user expand the file list.");
            object initialAction = share.Content;
            var connection = (FrameworkElement)window.FindName("ConnectionLine");
            share.RaiseEvent(new RoutedEventArgs(Button.ClickEvent, share));
            PumpUntil(() => starts == 1 && share.IsEnabled && !Object.Equals(initialAction, share.Content)
                && !choose.IsEnabled && Object.Equals(connection.Tag, "Reading"),
                "The desktop did not display the mock broker's ready status and stop action.");
            var headline = (TextBlock)window.FindName("StatusText");
            var detail = (TextBlock)window.FindName("StatusDetail");
            Check(headline != null && detail != null, "Sharing status is missing from the main screen.");
            controller.SelectFolder(empty);
            controller.StartShare();
            Check(((TextBlock)window.FindName("FolderPath")).Text == folder && starts == 1,
                "A second action replaced the active session.");
            share.RaiseEvent(new RoutedEventArgs(Button.ClickEvent, share));
            PumpUntil(() => choose.IsEnabled && share.IsEnabled && Object.Equals(initialAction, share.Content),
                "Stopping did not restore the selected folder and start action.");
            Check(File.ReadAllBytes(Path.Combine(folder, MediaPaths[0])).SequenceEqual(Sample),
                "Sharing changed an original file.");
            Check(starts == 1 && File.Exists(stoppedReceipt) && table.Items.Count == MediaPaths.Length &&
                !String.IsNullOrWhiteSpace(headline.Text),
                "The controller lost its selection or restarted the broker when stopping.");
            PumpUntil(() => !Directory.Exists(Path.GetDirectoryName(control)), "The stopped mock session was not cleaned up.");
            controller.StopShare();
            window.Close();
        }
        finally
        {
            if (active != null) active.Dispose();
        }
    }

    private static bool IsWithin(DependencyObject child, DependencyObject ancestor)
    {
        for (var current = child; current != null; current = LogicalTreeHelper.GetParent(current))
            if (Object.ReferenceEquals(current, ancestor)) return true;
        return false;
    }

    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            if (args.Length == 3 && args[0] == "--mock-broker") return RunMockBroker(args[1], args[2]);
            string root = args[0];
            string folder = Path.Combine(root, "library");
            string appData = Directory.CreateDirectory(Path.Combine(root, "app-data")).FullName;
            string catalog = SeedOldCatalog(appData);
            byte[] originalCatalog = File.ReadAllBytes(catalog);
            using (var held = File.Open(catalog, FileMode.Open, FileAccess.Read, FileShare.None))
            {
                CheckFolder(root, folder, appData);
                CheckChanges(root, appData);
                CheckFirstRun(root, folder);
                CheckDesktop(root, folder, appData);
            }
            Check(File.ReadAllBytes(catalog).SequenceEqual(originalCatalog), "The old catalog was modified.");
            NoStagedSession(appData);
            Console.WriteLine("Passed folder inventory, metadata-only planning, manifest validation and cleanup.");
            Console.WriteLine("Passed first-run pairing, one-page folder selection and mock-broker start/stop.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }
}
'@
    $harness = Join-Path $testRoot 'FolderSharingTests.cs'
    [IO.File]::WriteAllText($harness, $cases, [Text.UTF8Encoding]::new($false))
    $framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
    $compiler = Join-Path $framework 'csc.exe'
    $runner = Join-Path $testRoot 'FolderSharingTests.exe'
    $wpf = Join-Path $framework 'WPF'
    $arguments = @('/nologo', '/langversion:5', '/codepage:65001', '/platform:x64', '/target:exe',
        '/main:FolderSharingTests', "/out:$runner", "/lib:$wpf",
        "/resource:$app\MainWindow.xaml,PixelBackup.MainWindow.xaml", "/resource:$app\PixelBackup.ico,PixelBackup.PixelBackup.ico")
    $assemblies = @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml',
        'System.IO.Compression', 'System.IO.Compression.FileSystem', 'System.Web.Extensions')
    $references = $assemblies | ForEach-Object { "/reference:$_.dll" }
    $sources = @(Get-ChildItem -LiteralPath $app -Filter '*.cs' -File | ForEach-Object FullName)
    & $compiler @arguments @references @sources $harness
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the folder-sharing tests.' }

    $start = [Diagnostics.ProcessStartInfo]::new($runner, ('"' + $testRoot + '"'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $log = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(45000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'The folder-sharing test timed out. Check for an unexpected modal dialog.'
        }
        Write-Host $log.Result
        if ($process.ExitCode -ne 0) { throw $errors.Result }
    } finally { $process.Dispose() }
} finally {
    if ([IO.Directory]::Exists($testRoot)) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).ProviderPath
        if ([IO.Path]::GetFullPath($resolved) -ne [IO.Path]::Combine($tempParent, $tempName)) {
            throw "The temporary directory no longer resolves to the expected path: $testRoot"
        }
        if ([IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction) }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
