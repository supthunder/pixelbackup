#Requires -Version 5.1
<#
.SYNOPSIS
    Exercise Android tool discovery and managed installation in an isolated profile.
.EXAMPLE
    powershell.exe -NoProfile -File .\tests\Test-AndroidTools.ps1
.EXAMPLE
    powershell.exe -NoProfile -File .\tests\Test-AndroidTools.ps1 -ArchivePath C:\fixtures\platform-tools_r37.0.1-win.zip
.NOTES
    An optional copy of the pinned Google archive enables the successful installation and repair cases.
    The test uses a local download stub and never starts adb.
#>
[CmdletBinding()]
param([string]$ArchivePath)

$ErrorActionPreference = 'Stop'
$app = Join-Path $PSScriptRoot '..\windows\app'
if ($ArchivePath) {
    $archive = Get-Item -LiteralPath $ArchivePath
    if ($archive -isnot [IO.FileInfo]) { throw 'ArchivePath must be a local ZIP file.' }
    $ArchivePath = $archive.FullName
}

$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$name = 'PixelBackup-android-tools-test-' + [guid]::NewGuid().ToString('N')
$root = Join-Path $parent $name
$security = [Security.AccessControl.DirectorySecurity]::new()
$security.SetAccessRuleProtection($true, $false)
$owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
$rule = [Security.AccessControl.FileSystemAccessRule]::new($owner, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$security.AddAccessRule($rule)
$null = [IO.Directory]::CreateDirectory($root, $security)

try {
    # Tool fixtures live only within this private root. Discovery must never run them.
    $cases = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using PixelBackup;

internal static class AndroidToolsRegression
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly string[] ToolFiles = { "adb.exe", "AdbWinApi.dll", "AdbWinUsbApi.dll" };

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static string Tool(string directory)
    {
        Directory.CreateDirectory(directory);
        foreach (string name in ToolFiles)
            File.WriteAllText(Path.Combine(directory, name), "Discovery fixture: " + name);
        return Path.Combine(directory, "adb.exe");
    }

    private static string SdkTool(string sdk)
    {
        return Tool(Path.Combine(sdk, "platform-tools"));
    }

    private static string Find(string profile)
    {
        return AndroidTools.Find(profile, null, null, null);
    }

    private static void Reject<T>(Action body, string message) where T : Exception
    {
        try { body(); }
        catch (T) { return; }
        throw new InvalidOperationException(message);
    }

    private static void Discovery(string root)
    {
        string profile = Path.Combine(root, "discovery profile");
        string home = Path.Combine(root, "home sdk");
        string sdk = Path.Combine(root, "root sdk");
        string path = Path.Combine(root, "path [with spaces]");
        string pathValue = " ;relative;" + "\"" + path + "\"";
        Check(String.IsNullOrEmpty(Find(profile)), "An isolated profile found an unexpected tool.");

        string pathAdb = Tool(path);
        string localAdb = SdkTool(Path.Combine(profile, "Android", "Sdk"));
        var trusted = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { pathAdb, localAdb };
        File.WriteAllBytes(Path.Combine(Path.GetDirectoryName(localAdb), "AdbWinUsbApi.dll"), new byte[0]);
        Check(AndroidTools.Find(profile, null, null, pathValue, trusted.Contains) == pathAdb,
            "Discovery did not skip an incomplete default SDK and use an absolute quoted PATH entry.");
        localAdb = SdkTool(Path.Combine(profile, "Android", "Sdk"));
        string sdkAdb = SdkTool(sdk);
        string homeAdb = SdkTool(home);
        trusted.Add(sdkAdb);
        trusted.Add(homeAdb);
        Check(AndroidTools.Find(profile, null, null, pathValue, trusted.Contains) == localAdb, "The default SDK must precede PATH.");
        Check(AndroidTools.Find(profile, null, sdk, pathValue, trusted.Contains) == sdkAdb, "ANDROID_SDK_ROOT was not considered.");
        Check(AndroidTools.Find(profile, home, sdk, pathValue, trusted.Contains) == homeAdb, "ANDROID_HOME must precede SDK_ROOT.");
        Check(String.IsNullOrEmpty(AndroidTools.Find(profile, home, sdk, pathValue)),
            "Automatic discovery trusted an unsigned SDK or PATH lookalike.");

        string manual = Tool(Path.Combine(root, "manual [chosen]"));
        AndroidTools.Remember(profile, manual);
        Check(AndroidTools.Find(profile, home, sdk, pathValue) == manual,
            "The manually selected custom installation was not persisted.");
        string second = Tool(Path.Combine(root, "manual replacement"));
        AndroidTools.Remember(profile, second);
        Check(AndroidTools.Find(profile, home, sdk, pathValue) == second, "Replacing the saved path did not take effect.");

        string missing = Path.Combine(root, "absent", "adb.exe");
        Reject<ArgumentException>(() => AndroidTools.Remember(profile, missing),
            "An incomplete manual tool selection was accepted.");
        Check(AndroidTools.Find(profile, home, sdk, pathValue) == second, "An invalid choice replaced a working override.");
        File.Delete(Path.Combine(Path.GetDirectoryName(second), "AdbWinApi.dll"));
        Check(AndroidTools.Find(profile, home, sdk, pathValue, trusted.Contains) == homeAdb,
            "A stale override masked a complete SDK.");
        AndroidTools.Remember(profile, manual);
        AndroidTools.Remember(profile, null);
        Check(AndroidTools.Find(profile, home, sdk, pathValue, trusted.Contains) == homeAdb,
            "Clearing the saved path did not restore discovery.");
        Console.WriteLine("Passed Android SDK discovery, publisher checks, incomplete tools and saved advanced paths.");
    }

    private static void FailedInstalls(string root)
    {
        string profile = Path.Combine(root, "failed install profile");
        Reject<InvalidDataException>(() => AndroidTools.Install(profile, None, null,
            (destination, token, progress) => File.WriteAllText(destination, "not the pinned Google ZIP")),
            "A corrupt archive was accepted.");
        Check(String.IsNullOrEmpty(Find(profile)), "A rejected archive left a discoverable managed tool.");

        using (var cancelled = new CancellationTokenSource())
        {
            cancelled.Cancel();
            bool entered = false;
            Reject<OperationCanceledException>(() => AndroidTools.Install(profile, cancelled.Token, null,
                (destination, token, progress) => { entered = true; }),
                "A pre-cancelled install was accepted.");
            Check(!entered, "An already cancelled install called the download transport.");
        }
        using (var cancelled = new CancellationTokenSource())
        {
            Reject<OperationCanceledException>(() => AndroidTools.Install(profile, cancelled.Token, null,
                (destination, token, progress) =>
                {
                    File.WriteAllText(destination, "partial download");
                    cancelled.Cancel();
                }),
                "Aborting a download did not cancel the installation.");
        }
        Check(String.IsNullOrEmpty(Find(profile)), "Cancellation leaked a discoverable managed tool.");

        // A damaged application-owned cache still needs pinned validation if it
        // was added to PATH alongside an independently installed SDK.
        string counterfeit = Tool(Path.Combine(profile, "PixelBackup", "tools", "platform-tools-" + AndroidTools.Version));
        string fallback = Tool(Path.Combine(root, "verified-path-fallback"));
        string searchPath = Path.GetDirectoryName(counterfeit) + ";" + Path.GetDirectoryName(fallback);
        Check(AndroidTools.Find(profile, null, null, searchPath, path => path == counterfeit || path == fallback) == fallback,
            "An invalid managed cache was rediscovered through PATH.");
        Console.WriteLine("Passed invalid archive and cancelled download checks.");
    }

    private static string Digest(Stream input)
    {
        using (var digest = SHA256.Create())
            return BitConverter.ToString(digest.ComputeHash(input)).Replace("-", "");
    }

    private static void CompareArchiveMembers(string archive, string directory)
    {
        using (ZipArchive zip = ZipFile.OpenRead(archive))
        {
            var entries = zip.Entries.Where(entry => entry.Name.Length != 0).ToArray();
            Check(entries.Select(entry => entry.Name).OrderBy(name => name, StringComparer.Ordinal)
                    .SequenceEqual(Directory.EnumerateFiles(directory).Select(Path.GetFileName)
                        .OrderBy(name => name, StringComparer.Ordinal)),
                "The managed directory differs from the pinned ZIP's file list.");
            foreach (ZipArchiveEntry entry in entries)
            {
                using (Stream source = entry.Open())
                using (Stream target = File.OpenRead(Path.Combine(directory, entry.Name)))
                    Check(Digest(source) == Digest(target), "The installed " + entry.Name + " differs from Google's ZIP.");
            }
        }
    }

    private static void Managed(string root, string archive)
    {
        string profile = Path.Combine(root, "managed profile");
        string expected = Path.Combine(profile, "PixelBackup", "tools", "platform-tools-" + AndroidTools.Version, "adb.exe");
        string managedDirectory = Path.GetDirectoryName(expected);
        string sdk = Path.Combine(root, "managed fallback sdk");
        int downloads = 0;
        Action<string, CancellationToken, IProgress<string>> copy = (destination, token, progress) =>
        {
            Interlocked.Increment(ref downloads);
            File.Copy(archive, destination, true);
        };

        using (var callers = new CountdownEvent(2))
        {
            Func<string> install = () =>
            {
                callers.Signal();
                return AndroidTools.Install(profile, None, null, (destination, token, progress) =>
                {
                    Check(callers.Wait(TimeSpan.FromSeconds(10)), "The second installer did not start while the first was downloading.");
                    copy(destination, token, progress);
                });
            };
            Task<string> first = Task.Run(install);
            Task<string> second = Task.Run(install);
            Check(Task.WaitAll(new Task[] { first, second }, TimeSpan.FromSeconds(30)),
                "Concurrent managed installation did not finish.");
            Check(first.Result == expected && second.Result == expected,
                "Concurrent installs disagreed on the managed tool.");
        }
        Check(downloads == 1, "The concurrent callers downloaded the same verified archive twice.");
        string sdkTools = Directory.CreateDirectory(Path.Combine(sdk, "platform-tools")).FullName;
        foreach (string member in Directory.GetFiles(managedDirectory))
            File.Copy(member, Path.Combine(sdkTools, Path.GetFileName(member)));
        string fallback = Path.Combine(sdkTools, "adb.exe");
        Check(AndroidTools.Find(Path.Combine(root, "official SDK profile"), sdk, null, null) == fallback,
            "A separate official Android SDK was rejected by real discovery.");
        Check(AndroidTools.Find(profile, sdk, null, null) == expected, "The verified managed tool did not precede the SDK.");
        CompareArchiveMembers(archive, managedDirectory);

        string custom = Tool(Path.Combine(root, "managed manual tool"));
        AndroidTools.Remember(profile, custom);
        Check(AndroidTools.Find(profile, sdk, null, null) == custom, "A saved custom tool did not precede managed Platform Tools.");
        File.Delete(Path.Combine(Path.GetDirectoryName(custom), "AdbWinApi.dll"));
        Check(AndroidTools.Find(profile, sdk, null, null) == expected, "A missing custom component hid the managed install.");

        DateTime stamp = File.GetLastWriteTimeUtc(expected);
        using (var modified = new FileStream(expected, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            modified.Position = 1024;
            int previous = modified.ReadByte();
            Check(previous >= 0, "The offline adb is unexpectedly short.");
            modified.Position--;
            modified.WriteByte((byte)(previous ^ 1));
        }
        File.SetLastWriteTimeUtc(expected, stamp);
        Check(AndroidTools.Find(profile, sdk, null, null) == fallback, "A modified managed binary was trusted by its timestamp and size.");
        Check(AndroidTools.Install(profile, None, null, copy) == expected, "The corrupt managed install could not be repaired.");
        File.Delete(Path.Combine(managedDirectory, "AdbWinUsbApi.dll"));
        Check(AndroidTools.Find(profile, sdk, null, null) == fallback, "An incomplete managed install was returned.");
        Check(AndroidTools.Install(profile, None, null, copy) == expected, "The incomplete managed install could not be repaired.");
        const string note = "Unexpected user file";
        const string noteName = "personal note.txt";
        File.WriteAllText(Path.Combine(managedDirectory, noteName), note);
        Check(AndroidTools.Find(profile, sdk, null, null) == fallback, "An unknown file did not invalidate the managed directory.");
        Check(AndroidTools.Install(profile, None, null, copy) == expected, "The managed cache with extra files was not repaired.");
        string saved = Directory.EnumerateDirectories(Path.GetDirectoryName(managedDirectory))
            .Select(directory => Path.Combine(directory, noteName)).Single(File.Exists);
        Check(File.ReadAllText(saved) == note, "Repair discarded an unexpected user file.");
        Check(downloads == 4, "Repair did not validate and reuse the expected cache.");
        CompareArchiveMembers(archive, managedDirectory);

        // A byte in the first ZIP local header's timestamp changes the
        // archive digest while leaving all extractable files identical.
        string altered = Path.Combine(root, "unverified package.zip");
        File.Copy(archive, altered);
        using (var zip = new FileStream(altered, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            zip.Position = 10;
            int previous = zip.ReadByte();
            Check(previous >= 0, "The archive fixture is unexpectedly short.");
            zip.Position--;
            zip.WriteByte((byte)(previous ^ 2));
        }
        CompareArchiveMembers(altered, managedDirectory);
        string alteredProfile = Path.Combine(root, "unverified package profile");
        Reject<InvalidDataException>(() => AndroidTools.Install(alteredProfile, None, null,
            (destination, token, progress) => File.Copy(altered, destination, true)),
            "A different archive with the same files and size bypassed the pinned ZIP digest.");
        Check(String.IsNullOrEmpty(Find(alteredProfile)), "A mismatched ZIP digest left a discoverable managed tool.");
        Console.WriteLine("Passed pinned package install, concurrent reuse, tamper detection and repair.");
    }

    public static int Main(string[] args)
    {
        try
        {
            Discovery(args[0]);
            FailedInstalls(args[0]);
            if (args.Length == 2) Managed(args[0], args[1]);
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

    $source = Join-Path $root 'AndroidToolsRegression.cs'
    [IO.File]::WriteAllText($source, $cases, [Text.UTF8Encoding]::new($false))
    $framework = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319'
    $compiler = Join-Path $framework 'csc.exe'
    $runner = Join-Path $root 'AndroidToolsRegression.exe'
    $references = @('System.IO.Compression','System.IO.Compression.FileSystem') |
        ForEach-Object { '/reference:' + (Join-Path $framework ($_ + '.dll')) }
    & $compiler /nologo /target:exe /platform:x64 /langversion:5 /codepage:65001 /warnaserror "/out:$runner" @references $source (Join-Path $app 'AndroidTools.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile Android tools tests.' }
    if ($ArchivePath) { & $runner $root $ArchivePath }
    else { & $runner $root }
    if ($LASTEXITCODE -ne 0) { throw 'Android tools regression tests failed.' }
} finally {
    if ([IO.Directory]::Exists($root)) {
        $item = Get-Item -LiteralPath $root -Force
        if ($item.FullName -ne [IO.Path]::Combine($parent, $name) -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'The private test folder no longer resolves to its original path.'
        }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
}
