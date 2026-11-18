#Requires -Version 5.1
<#
.SYNOPSIS
    Exercise duplicate review, Takeout imports and saved evidence with synthetic media.
.EXAMPLE
    powershell.exe -NoProfile -File .\tests\Test-DuplicateReview.ps1
.NOTES
    Run in Windows PowerShell 5.1 with .NET Framework 4.8 and an NTFS temporary
    directory. The mock broker runs under the current user.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$app = Join-Path $PSScriptRoot '..\windows\app'
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempName = 'PixelBackup-regression-' + [guid]::NewGuid().ToString('N')
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
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using PixelBackup;

internal static class PixelBackupRegression
{
    private static readonly CancellationToken NoCancellation = CancellationToken.None;

    private static void Check(bool result, string expectation)
    {
        if (!result) throw new InvalidOperationException(expectation);
    }

    private static void ExpectCancellation(Action action)
    {
        try { action(); }
        catch (OperationCanceledException) { return; }
        throw new InvalidOperationException("A canceled operation returned success.");
    }

    private sealed class CancelAtFirstFile : IProgress<string>
    {
        private readonly CancellationTokenSource source;
        internal bool Reported;
        internal CancelAtFirstFile(CancellationTokenSource source) { this.source = source; }
        public void Report(string message) { Reported = true; source.Cancel(); }
    }

    private static byte[] Jpeg(Color color)
    {
        using (var image = new Bitmap(320, 320))
        using (var graphics = Graphics.FromImage(image))
        using (var bytes = new MemoryStream())
        {
            graphics.Clear(color);
            image.Save(bytes, ImageFormat.Jpeg);
            return bytes.ToArray();
        }
    }

    // Insert a valid EXIF TIFF ImageDescription after the JPEG's first APP0 segment.
    private static byte[] WithDescription(byte[] jpeg, string description)
    {
        byte[] value = Encoding.ASCII.GetBytes(description + "\0");
        using (var segment = new MemoryStream())
        using (var tiff = new BinaryWriter(segment))
        using (var result = new MemoryStream())
        {
            tiff.Write(Encoding.ASCII.GetBytes("Exif\0\0II"));
            tiff.Write((ushort)42);
            tiff.Write((uint)8);
            tiff.Write((ushort)1);
            tiff.Write((ushort)0x010e);
            tiff.Write((ushort)2);
            tiff.Write((uint)value.Length);
            tiff.Write((uint)26);
            tiff.Write((uint)0);
            tiff.Write(value);
            int split = 4 + (jpeg[4] << 8) + jpeg[5];
            int length = checked((int)segment.Length + 2);
            result.Write(jpeg, 0, split);
            result.Write(new byte[] {0xff, 0xe1, (byte)(length >> 8), (byte)length}, 0, 4);
            segment.Position = 0;
            segment.CopyTo(result);
            result.Write(jpeg, split, jpeg.Length - split);
            return result.ToArray();
        }
    }

    private static string Sha(byte[] bytes)
    {
        using (var sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
    }

    private static string Put(string parent, string relative, byte[] bytes)
    {
        string path = Path.Combine(parent, relative.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        File.WriteAllBytes(path, bytes);
        return path;
    }

    private static void Zip(string path, IDictionary<string, byte[]> entries)
    {
        using (var file = new FileStream(path, FileMode.Create, FileAccess.ReadWrite, FileShare.None))
        using (var archive = new ZipArchive(file, ZipArchiveMode.Create))
            foreach (var pair in entries)
                using (var output = archive.CreateEntry(pair.Key).Open())
                    output.Write(pair.Value, 0, pair.Value.Length);
    }

    private static string Report(BackupLibrary library)
    {
        using (var text = new StringWriter())
        {
            library.WriteDuplicateReport(text);
            return text.ToString();
        }
    }

    private static ScanResult Scan(string folder, BackupLibrary library)
    {
        return MediaScanner.Scan(folder, library.Snapshot(), NoCancellation, null);
    }

    private static void FolderAndMemory(string root, byte[] a, byte[] b, byte[] edited)
    {
        string folder = Path.Combine(root, "library");
        Put(folder, "A/photo.jpg", a);
        Put(folder, "B/photo.jpg", b);
        Put(folder, "C/renamed.jpeg", a);
        Put(folder, "D/metadata edit.jpg", edited);
        Put(folder, "Desktop.ini", b);
        Put(folder, "ignored/.nomedia", new byte[0]);
        Put(folder, "ignored/sub/deep.jpg", b);
        Put(folder, ".cache/hidden.jpg", b);
        Put(Path.Combine(root, "outside"), "linked.jpg", a);

        var profileRoot = Path.Combine(root, "local-profiles");
        var profiles = new Profiles(profileRoot);
        var primary = profiles.Active;
        var state = primary.DirectoryPath;
        var library = new BackupLibrary(state);
        var scan = Scan(folder, library);
        var rows = scan.Items.ToDictionary(i => i.RelativePath, StringComparer.Ordinal);
        Check(rows.Count == 4 && scan.Warnings.Any(w => w.IndexOf("linked", StringComparison.OrdinalIgnoreCase) >= 0),
              "Expected four eligible files and a warning for the junction.");
        Check(rows["A/photo.jpg"].Decision == "Ready" && rows["A/photo.jpg"].Sha256 == Sha(a),
              "The first exact copy should be ready and carry the SHA-256 of its complete contents.");
        Check(rows["C/renamed.jpeg"].Decision == "Folder copy" && rows["C/renamed.jpeg"].Match == "A/photo.jpg",
              "A renamed exact copy should identify its canonical relative path.");
        Check(rows["B/photo.jpg"].Decision == "Ready" && rows["B/photo.jpg"].Sha256 == Sha(b),
              "Equal basenames with different contents should both be ready.");
        Check(rows["D/metadata edit.jpg"].Decision == "Ready" && rows["D/metadata edit.jpg"].Sha256 == Sha(edited),
              "An EXIF-only edit should remain a different exact file.");
        Check(library.Count == 0 && new BackupLibrary(state).Count == 0, "Scanning wrote confirmation evidence.");

        var canonical = rows["A/photo.jpg"];
        Check(MediaScanner.IsCurrent(canonical), "A freshly scanned readable source should be current.");
        Check(library.Confirm(new[] {canonical, rows["C/renamed.jpeg"]}) == 1, "Confirmation should add one digest for exact copies.");
        var reopened = new BackupLibrary(state);
        Check(reopened.Count == 1 && reopened.Snapshot().ContainsKey(Sha(a)), "A reopened index lost the explicit confirmation.");
        Check(reopened.Confirm(new[] {canonical}) == 0, "Repeating the same confirmation added evidence twice.");
        rows = Scan(folder, reopened).Items.ToDictionary(i => i.RelativePath);
        Check(rows["A/photo.jpg"].Decision == "Known copy" && rows["C/renamed.jpeg"].Decision == "Known copy" &&
              rows["B/photo.jpg"].Decision == "Ready" && rows["D/metadata edit.jpg"].Decision == "Ready",
              "Stored evidence must match complete bytes across names and leave edited files ready.");
        profiles.Select(profiles.Create("Another library"));
        var restarted = new Profiles(profileRoot);
        Check(restarted.Active.Id == profiles.Active.Id && restarted.Active.Id != primary.Id, "The selected library profile was lost across a restart.");
        var other = new BackupLibrary(restarted.Active.DirectoryPath);
        Check(Scan(folder, other).Items.Single(i => i.RelativePath == "A/photo.jpg").Decision == "Ready",
              "Evidence from one library profile incorrectly skipped a file in another.");
        other.Confirm(new[] {rows["B/photo.jpg"]});
        restarted.Select(restarted.All.Single(p => p.Id == primary.Id));
        Check(new BackupLibrary(new Profiles(profileRoot).Active.DirectoryPath).Snapshot().ContainsKey(Sha(a)),
              "Switching back to the first profile lost its evidence.");
        string marker = Put(folder, "A/.nomedia", new byte[0]);
        Check(!MediaScanner.IsCurrent(canonical), "A folder excluded after the scan was still considered shareable.");
        File.Delete(marker);
        File.AppendAllText(canonical.FullPath, "changed");
        Check(!MediaScanner.IsCurrent(canonical), "A source whose size changed was treated as current.");
        File.Delete(canonical.FullPath);
        Check(!MediaScanner.IsCurrent(canonical), "A deleted source was treated as current.");
        Check(reopened.Snapshot().ContainsKey(Sha(a)), "Deleting a source erased surviving confirmation evidence.");
        using (var cancel = new CancellationTokenSource())
        {
            cancel.Cancel();
            ExpectCancellation(() => MediaScanner.Scan(folder, reopened.Snapshot(), cancel.Token, null));
        }
        reopened.Clear();
        Check(new BackupLibrary(state).Count == 0, "Clearing an index should survive reopening.");
        Check(other.Snapshot().ContainsKey(Sha(b)), "Clearing one profile also cleared a different profile.");
        Check(File.ReadAllBytes(rows["C/renamed.jpeg"].FullPath).SequenceEqual(a),
              "Clearing the local evidence index should leave the source media intact.");
    }

    private static void Takeout(string root, byte[] a, byte[] b, byte[] edited)
    {
        var state = Path.Combine(root, "takeout-index");
        var archiveRoot = Path.Combine(root, "extracted");
        var library = new BackupLibrary(state);
        var json = Encoding.UTF8.GetBytes("{\"title\":\"photo.jpg\"}");
        Put(archiveRoot, "Takeout/Google Photos/Trips/extracted.jpg", edited);
        Put(archiveRoot, "Takeout/Google Photos/Trips/extracted.jpg.supplemental-metadata.json", json);
        Put(archiveRoot, "Takeout/Drive/unrelated.jpg", a);
        Put(archiveRoot, "Takeout/Google Photos/Trash/discarded.jpg", a);
        var extracted = library.ImportFolder(archiveRoot, NoCancellation, null);
        Check(extracted.Files == 1 && library.Count == 1 && library.Snapshot().ContainsKey(Sha(edited)),
              "An extracted export must index real Google Photos media and ignore sidecars and other products.");

        string part1 = Path.Combine(root, "takeout-001.zip");
        string part2 = Path.Combine(root, "takeout-002.zip");
        Zip(part1, new Dictionary<string, byte[]> {
            {"Takeout/Google Photos/Photos from 2021/keep.jpg", a},
            {"Takeout/Google Photos/Photos from 2021/keep.jpg.json", json},
            {"Takeout/Google Photos/Failed Videos/unavailable.mp4", b},
            {"Takeout/Drive/other.jpg", b}
        });
        Zip(part2, new Dictionary<string, byte[]> {
            {"Takeout/Google Photos/Album/remote alias.jpg", a},
            {"Takeout/Google Photos/Album/different.jpg", b}
        });
        var first = library.ImportZip(part1, NoCancellation, null);
        var second = library.ImportZip(part2, NoCancellation, null);
        Check(first.Files == 1 && second.Files == 2 && library.Count == 3, "Split archives should add one known digest per distinct media file.");
        var aliases = second.DuplicatePreview.Single(g => g.Sha256 == Sha(a));
        Check(aliases.FileCount == 2 && aliases.Paths.Any(p => p.Contains("keep.jpg")) && aliases.Paths.Any(p => p.Contains("remote alias.jpg")),
              "Archive duplicate paths across split ZIPs were lost.");
        var same = library.ImportZip(part2, NoCancellation, null);
        Check(same.Added == 0 && same.DuplicatePreview.Single(g => g.Sha256 == Sha(a)).FileCount == 2,
              "Reimporting an identical archive inflated the duplicate group.");
        string before = Report(library);
        byte[] newlyExported = WithDescription(a, "new snapshot");
        Zip(part2, new Dictionary<string, byte[]> {
            {"Takeout/Google Photos/Album/new alias.jpg", a},
            {"Takeout/Google Photos/Album/new.jpg", newlyExported}
        });
        using (var cancel = new CancellationTokenSource())
        {
            var afterFile = new CancelAtFirstFile(cancel);
            ExpectCancellation(() => library.ImportZip(part2, cancel.Token, afterFile));
            Check(afterFile.Reported, "The cancellation test must process media before interruption.");
        }
        Check(library.Count == 3 && before == Report(library) && !library.Snapshot().ContainsKey(Sha(newlyExported)),
              "Cancellation partially replaced existing evidence.");
        library.ImportZip(part2, NoCancellation, null);
        var reopened = new BackupLibrary(state);
        string updated = Report(reopened);
        Check(updated.Contains("new alias.jpg") && !updated.Contains("remote alias.jpg") && updated.Contains("keep.jpg"),
              "Reimport should update paths for the replaced archive without dropping the other ZIP.");
        Check(reopened.Count == 4 && reopened.Snapshot().ContainsKey(Sha(newlyExported)) && reopened.Snapshot().ContainsKey(Sha(b)),
              "A new export should add changed media and retain historical evidence for files now absent.");
    }

    // Use the real manifest and status protocol. Replace only the elevated process
    // with a local worker so the test can run without UAC, SMB or a paired phone.
    private static PlanSession Prepare(ScanResult scan, bool skipCopies, string appData)
    {
        var method = typeof(PlanSession).GetMethod("Prepare", BindingFlags.NonPublic | BindingFlags.Static);
        Check(method != null, "Update the isolated PlanSession preparation fixture.");
        return (PlanSession)method.Invoke(null, new object[] {scan, skipCopies, NoCancellation, null, appData});
    }

    private static FieldInfo SessionField(string name)
    {
        var field = typeof(PlanSession).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance);
        Check(field != null, "Missing session test seam: " + name);
        return field;
    }

    private static void MockStatus(string control, string state, bool closed)
    {
        var status = new SessionStatus {
            State = state, Message = "Synthetic broker", PixelSeen = true, CleanupComplete = closed,
            ShareName = "PixelBackup-0123456789abcdef0123456789abcdef",
            PlanShareName = "PixelBackupPlan-0123456789abcdef0123456789abcdef"
        };
        string next = Path.Combine(control, "mock-status.tmp");
        string path = Path.Combine(control, "status.json");
        File.WriteAllText(next, new JavaScriptSerializer().Serialize(status), new UTF8Encoding(false));
        if (File.Exists(path)) File.Replace(next, path, null); else File.Move(next, path);
    }

    private static int RunMockBroker(string control)
    {
        MockStatus(control, "Ready", false);
        var elapsed = Stopwatch.StartNew();
        while (!File.Exists(Path.Combine(control, "stop")))
        {
            if (elapsed.Elapsed > TimeSpan.FromSeconds(20)) return 2;
            Thread.Sleep(20);
        }
        MockStatus(control, "Closed", true);
        return 0;
    }

    private static void ExerciseSession(PlanSession session, BackupLibrary library, string unknown)
    {
        string control = (string)SessionField("controlDirectory").GetValue(session);
        var info = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, "--mock-broker \"" + control + "\"") {
            CreateNoWindow = true, UseShellExecute = false
        };
        Process worker = Process.Start(info);
        SessionField("broker").SetValue(session, worker);
        try
        {
            var clock = Stopwatch.StartNew();
            SessionStatus status;
            do {
                status = session.Poll();
                if (status.State == "Ready" && status.PixelSeen) break;
                Check(!worker.HasExited && clock.Elapsed < TimeSpan.FromSeconds(10), "The mock broker did not become ready. " + status.Message);
                Thread.Sleep(20);
            } while (true);
            Check(!library.Snapshot().ContainsKey(unknown), "Publishing a share or seeing the phone incorrectly confirmed an upload.");
            session.Stop();
            Check(worker.WaitForExit(5000) && worker.ExitCode == 0, "Stopping the session did not signal the mock broker.");
            status = session.Poll();
            Check(status.State == "Closed" && status.CleanupComplete, "The session did not acknowledge the broker's completed cleanup.");
            Check(!library.Snapshot().ContainsKey(unknown), "Ending a sharing session incorrectly confirmed an upload.");
        }
        finally
        {
            if (!worker.HasExited)
            {
                session.Stop();
                if (!worker.WaitForExit(2500)) { worker.Kill(); worker.WaitForExit(); }
            }
        }
    }

    private static void Plans(string root, byte[] a, byte[] b)
    {
        string folder = Path.Combine(root, "to-share");
        string appData = Directory.CreateDirectory(Path.Combine(root, "mock-profile")).FullName;
        var library = new BackupLibrary(Path.Combine(root, "session-index"));
        byte[] oldVersion = WithDescription(a, "version one");
        byte[] newVersion = WithDescription(a, "version two");
        string chosen = "A/caf\u00e9 photo.jpg";
        string path = Put(folder, chosen, oldVersion);
        Put(folder, "B/same content.jpg", oldVersion);
        Put(folder, "C/already known.jpg", b);
        library.Confirm(new[] {Scan(folder, library).Items.Single(item => item.Sha256 == Sha(b))});
        ScanResult scan = Scan(folder, library);
        string stage;
        MediaEntry[] selected;
        using (var session = Prepare(scan, true, appData))
        {
            selected = session.Published.ToArray();
            Check(selected.Length == 1 && selected[0].RelativePath == chosen, "The plan must contain only the ready original when skipping copies.");
            string plan = (string)SessionField("planDirectory").GetValue(session);
            stage = Path.GetDirectoryName(plan);
            byte[] manifest = File.ReadAllBytes(Path.Combine(plan, "files.txt"));
            Check(manifest.SequenceEqual(Encoding.UTF8.GetBytes(chosen + "\n")), "The selected Unicode relative path must round-trip in the manifest.");
            Check(File.ReadAllBytes(Path.Combine(plan, "files.sha256")).SequenceEqual(Encoding.ASCII.GetBytes(Sha(manifest) + "\n")),
                  "The sidecar must identify the exact manifest bytes.");
            ExerciseSession(session, library, Sha(oldVersion));
        }
        Check(!Directory.Exists(stage), "A closed session left its private staging directory behind.");
        Check(File.ReadAllBytes(path).SequenceEqual(oldVersion), "Sharing changed the selected original.");
        Check(library.Confirm(selected) == 1 && library.Snapshot().ContainsKey(Sha(oldVersion)),
              "Only explicit confirmation should record the media actually selected for the session.");
        using (var all = Prepare(scan, false, appData))
            Check(all.Published.Count == 3, "Disabling duplicate skipping should include all three current source paths.");

        var original = scan.Items.Single(item => item.RelativePath == chosen);
        File.WriteAllBytes(path, newVersion);
        File.SetLastWriteTimeUtc(path, new DateTime(original.LastWriteUtcTicks, DateTimeKind.Utc));
        Check(newVersion.Length == original.Bytes && File.GetLastWriteTimeUtc(path).Ticks == original.LastWriteUtcTicks,
              "The stale-source fixture must preserve size and modification time.");
        try { using (Prepare(scan, true, appData)) { } }
        catch (TargetInvocationException error)
        {
            if (!(error.InnerException is IOException)) throw;
            Check(!Directory.EnumerateDirectories(Path.Combine(appData, "PixelBackup", "sessions")).Any(),
                  "A rejected changed source left a partially published session.");
            return;
        }
        throw new InvalidOperationException("A byte-changed source with the original size and timestamp was accepted for sharing.");
    }

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length == 2 && args[0] == "--mock-broker") return RunMockBroker(args[1]);
            Environment.SetEnvironmentVariable("TEMP", args[0]);
            Environment.SetEnvironmentVariable("TMP", args[0]);
            byte[] a = Jpeg(Color.Navy);
            byte[] b = Jpeg(Color.Gold);
            byte[] edited = WithDescription(a, "metadata edit");
            using (var originalImage = new Bitmap(new MemoryStream(a)))
            using (var editedImage = new Bitmap(new MemoryStream(edited)))
                Check(originalImage.GetPixel(100, 100) == editedImage.GetPixel(100, 100) &&
                      editedImage.GetPropertyItem(0x010e).Value.Length > 0 && Sha(a) != Sha(edited),
                      "The EXIF fixture must remain a decodable JPEG with the same pixels and changed bytes.");
            FolderAndMemory(args[0], a, b, edited);
            Console.WriteLine("Passed folder scanning, cancellation and confirmation persistence.");
            Takeout(args[0], a, b, edited);
            Console.WriteLine("Passed extracted and split Takeout archives, aliases and historical evidence.");
            Plans(args[0], a, b);
            Console.WriteLine("Passed filtered manifests, source revalidation and explicit confirmation after mock sharing.");
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
    $harness = Join-Path $testRoot 'PixelBackupRegression.cs'
    [IO.File]::WriteAllText($harness, $cases, [Text.UTF8Encoding]::new($false))
    $framework = if ([Environment]::Is64BitProcess) { 'Framework64' } else { 'Framework' }
    $compiler = Join-Path $env:WINDIR "Microsoft.NET\$framework\v4.0.30319\csc.exe"
    $sources = @('MediaScan.cs', 'BackupLibrary.cs', 'PlanSession.cs', 'DesktopPlatform.cs',
        'DesktopFolderPicker.cs', 'AndroidTools.cs') |
        ForEach-Object { Join-Path $app $_ }
    $runner = Join-Path $testRoot 'PixelBackupRegression.exe'
    $wpf = Join-Path (Split-Path -Parent $compiler) 'WPF'
    $arguments = @('/nologo', '/langversion:5', '/codepage:65001', '/target:exe',
        '/main:PixelBackupRegression', "/out:$runner", "/lib:$wpf")
    $assemblies = @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml',
        'System.Drawing', 'System.Windows.Forms', 'System.IO.Compression',
        'System.IO.Compression.FileSystem', 'System.Web.Extensions')
    $references = $assemblies | ForEach-Object { "/reference:$_.dll" }
    & $compiler @arguments @references @sources $harness
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the application and duplicate review tests.' }
    & $runner $testRoot
    if ($LASTEXITCODE -ne 0) { throw 'Duplicate review regression tests failed.' }
} finally {
    # Delete the test junction itself before removing its private fixtures.
    if ([IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction) }
    if ([IO.Directory]::Exists($testRoot)) {
        $resolved = (Resolve-Path -LiteralPath $testRoot).ProviderPath
        if ([IO.Path]::GetFullPath($resolved) -ne [IO.Path]::Combine($tempParent, $tempName)) {
            throw "The temporary directory no longer resolves to the expected path: $testRoot"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
