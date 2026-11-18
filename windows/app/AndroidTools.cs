using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace PixelBackup
{
    public static class AndroidTools
    {
        public const string Version = "37.0.1";
        public const string LicenseUrl = "https://developer.android.com/studio/terms";
        public const string DownloadUrl = "https://dl.google.com/android/repository/platform-tools_r37.0.1-win.zip";
        public const long DownloadBytes = 8044989;

        // Google's repository2-3.xml channel-0 metadata gives the archive size and SHA-1
        // e03e78b1d80b396f1c3358e31251cb31740e1110. These SHA-256 pins cover that archive.
        private const string ZipHash = "45f4d63113e895ebde0c90f194099a4676b6ac653bd28d54314a9e022bbc1a99";
        private sealed class Member
        {
            internal readonly string Name, Hash;
            internal readonly long Size;
            internal Member(string name, long size, string hash) { Name = name; Size = size; Hash = hash; }
        }
        private static readonly Member[] Package = {
            new Member("adb.exe", 8273560, "b4a6b455702684652cccf7b46258b29e653538904359a58fd4931cf3ef286b3f"),
            new Member("AdbWinApi.dll", 108184, "c1d653030b4bde65d3e07e4d0b0979e17be56df1436cdd15528630f27808050d"),
            new Member("AdbWinUsbApi.dll", 73368, "0710e894d9b40f71a670c13c694079d564c92c1279da382cfe4850983aaebe1b"),
            new Member("libwinpthread-1.dll", 243016, "f2044c755e39efc5d47f47c5a942178dd6d79dc8945bb182dc8753d10e2a4269"),
            new Member("etc1tool.exe", 451224, "ee9bb89bb770badcfeb12bb9a3c4095682fb2ea0105487f9f16e440c582064a3"),
            new Member("fastboot.exe", 2429080, "b2d9cbff4ce9ae7eb448cfc831bafc867935f50f5be38f8f81057fd7eb3b8d86"),
            new Member("hprof-conv.exe", 52888, "70cfef266dd9d94922679be159901cec3218561be946347e6e4a7577fc81dede"),
            new Member("make_f2fs.exe", 473752, "a1d8e18474636972e4ebaf2617ac17c880e76642fad7fa3e51ae5cd3c1fe5d17"),
            new Member("make_f2fs_casefold.exe", 473752, "9ac076516c2a1f620df24e148660becf3e7d4102b46ddda66970d35c59db2962"),
            new Member("mke2fs.conf", 1157, "ad58a58dcdd24d85055814ca9cac67db89d4e67c434e96774bdce0d0a007d067"),
            new Member("mke2fs.exe", 763544, "308304852b1f1a1449e9d9115332ab908b8a54b99f460ed1df5d109decef5be7"),
            new Member("NOTICE.txt", 1154131, "38ec8c6f5b7799c223ffeab1f9e81c2d5fc67b5e56d6424f649630ca1ee1a811"),
            new Member("source.properties", 38, "2dccd788c0234d8cf7f7457377e57f57527a86a629c6ed54feb8af0f549dac38"),
            new Member("sqlite3.exe", 3031704, "234d9e6c475c6e9ba07498a1ad96a6a32840fbfdc74e50277e1a94cbac48abdc")
        };
        // Also recognize an already-running official 37.0.3 kit. Install() uses stable channel only.
        private static readonly Member[] PreviewAdb = {
            new Member("adb.exe", 8659608, "28d23e79d4371ea5a6a11d3518469087eb453d1872433c5d10e65ee5310d8f1b"),
            new Member("AdbWinApi.dll", 108184, "5b10914959a3daabacb730a321e13c9deb06f3ef44d1d48b999d537fbf9e8d24"),
            new Member("AdbWinUsbApi.dll", 73368, "37441be63880f1ce3741ab890c9af9d77492ec690c989c72f430a2e4905ebf5d")
        };

        private static string LocalData { get { return Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData); } }
        private static string Cache(string local) { return Path.Combine(local, "PixelBackup", "tools", "platform-tools-" + Version); }
        private static string Preference(string local) { return Path.Combine(local, "PixelBackup", "Desktop", "android-tools-path.txt"); }
        private static bool Same(string a, string b) { return String.Equals(a, b, StringComparison.OrdinalIgnoreCase); }
        private static bool FileError(Exception e) { return e is IOException || e is UnauthorizedAccessException || e is SecurityException || e is ArgumentException || e is NotSupportedException; }

        // Only explicit drive-rooted local paths. Empty PATH entries and drive-relative paths use the current directory on Windows.
        private static string LocalPath(string value)
        {
            if (String.IsNullOrWhiteSpace(value)) return null;
            string path = value.Trim().Trim('"').Replace('/', '\\');
            if (path.Length < 3 || !Char.IsLetter(path[0]) || path[1] != ':' || path[2] != '\\') return null;
            try {
                path = Path.GetFullPath(path);
                return new DriveInfo(Path.GetPathRoot(path)).DriveType == DriveType.Network ? null : path;
            } catch (Exception e) { if (!FileError(e)) throw; return null; }
        }

        private static bool Linked(string path) { return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0; }
        private static bool PlainFile(string path)
        {
            var info = new FileInfo(path);
            return info.Exists && (info.Attributes & FileAttributes.ReparsePoint) == 0 && info.Length > 0;
        }
        private static string Digest(Stream stream)
        {
            using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }
        private static bool Matches(string path, long length, string hash)
        {
            if (!PlainFile(path) || new FileInfo(path).Length != length) return false;
            using (var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read)) return Digest(file) == hash;
        }
        private static bool SafeTree(string local, string directory)
        {
            for (var d = new DirectoryInfo(directory); d != null; d = d.Parent) {
                if (d.Exists && (d.Attributes & FileAttributes.ReparsePoint) != 0) return false;
                if (Same(d.FullName, new DirectoryInfo(local).FullName)) return true;
            }
            return false;
        }
        private static bool ValidCache(string local)
        {
            string dir = Cache(local);
            try {
                if (!Directory.Exists(dir) || !SafeTree(local, dir) || Directory.GetFileSystemEntries(dir).Length != Package.Length) return false;
                return Package.All(m => Matches(Path.Combine(dir, m.Name), m.Size, m.Hash));
            } catch (Exception e) { if (!FileError(e)) throw; return false; }
        }
        private static string Candidate(string path, string local)
        {
            path = LocalPath(path);
            if (path == null || !Same(Path.GetFileName(path), "adb.exe")) return null;
            try {
                string dir = Path.GetDirectoryName(path);
                if (Same(dir, Cache(local))) return ValidCache(local) ? path : null;
                if (!PlainFile(path) || Linked(dir) || !PlainFile(Path.Combine(dir, "AdbWinApi.dll")) ||
                    !PlainFile(Path.Combine(dir, "AdbWinUsbApi.dll"))) return null;
                return path;
            } catch (Exception e) { if (!FileError(e)) throw; return null; }
        }

        public static string Find()
        {
            return Find(LocalData, Environment.GetEnvironmentVariable("ANDROID_HOME"), Environment.GetEnvironmentVariable("ANDROID_SDK_ROOT"),
                Environment.GetEnvironmentVariable("PATH"), TrustedInstalledKit, FindRunningAdb);
        }
        internal static string Find(string localAppData, string androidHome, string sdkRoot, string searchPath)
        {
            return Find(localAppData, androidHome, sdkRoot, searchPath, TrustedInstalledKit, null);
        }
        internal static string Find(string localAppData, string androidHome, string sdkRoot, string searchPath, Func<string, bool> trustedInstalledKit)
        {
            return Find(localAppData, androidHome, sdkRoot, searchPath, trustedInstalledKit, null);
        }
        private static string Find(string local, string androidHome, string sdkRoot, string searchPath, Func<string, bool> trustedInstalledKit, Func<string> running)
        {
            string preference = Preference(local);
            try {
                if (SafeTree(local, Path.GetDirectoryName(preference)) && PlainFile(preference) && new FileInfo(preference).Length <= 8192) {
                    string saved = Candidate(File.ReadAllText(preference), local);
                    if (saved != null) return saved;
                }
            } catch (Exception e) { if (!FileError(e)) throw; }
            if (ValidCache(local)) return Path.Combine(Cache(local), "adb.exe");
            foreach (string root in new[] { androidHome, sdkRoot, Path.Combine(local, "Android", "Sdk") }) {
                string sdk = LocalPath(root);
                if (sdk == null) continue;
                string candidate = Candidate(Path.Combine(sdk, "platform-tools", "adb.exe"), local);
                if (candidate != null && trustedInstalledKit(candidate)) return candidate;
            }
            if (running != null) {
                try {
                    string active = running();
                    // Any managed installation reached here already failed its full validation.
                    if (active != null && !Same(Path.GetDirectoryName(active), Cache(local))) return active;
                } catch (Exception e) { if (!(e is Win32Exception) && !(e is InvalidOperationException) && !FileError(e)) throw; }
            }
            foreach (string part in (searchPath ?? "").Split(';')) {
                string dir = LocalPath(part);
                if (dir == null || Same(dir.TrimEnd('\\'), Environment.CurrentDirectory.TrimEnd('\\'))) continue;
                string candidate = Candidate(Path.Combine(dir, "adb.exe"), local);
                if (candidate != null && trustedInstalledKit(candidate)) return candidate;
            }
            return null;
        }

        private static bool TrustedInstalledKit(string adb)
        {
            try {
                string directory = Path.GetDirectoryName(adb);
                if (File.Exists(adb + ".local") || Directory.Exists(adb + ".local")) return false;
                // Only inspect the candidate's immediate DLL search directory. A broadly shared bin directory
                // containing unrelated libraries can still be chosen explicitly in Advanced settings.
                var dlls = Directory.EnumerateFiles(directory, "*.dll").Take(33).ToArray();
                if (dlls.Length > 32) return false;
                var files = new HashSet<string>(dlls, StringComparer.OrdinalIgnoreCase) {
                    adb, Path.Combine(directory, "AdbWinApi.dll"), Path.Combine(directory, "AdbWinUsbApi.dll")
                };
                foreach (string path in files) {
                    if (!PlainFile(path)) return false;
                    var known = Package.Concat(PreviewAdb).Where(m => Same(m.Name, Path.GetFileName(path)));
                    if (!known.Any(m => Matches(path, m.Size, m.Hash)) && !SignedByGoogle(path)) return false;
                }
                return true;
            } catch (Exception e) { if (!FileError(e) && !(e is CryptographicException) && !(e is Win32Exception)) throw; return false; }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct TrustFile { internal uint Size; [MarshalAs(UnmanagedType.LPWStr)] internal string Path; internal IntPtr Handle, Subject; }
        [StructLayout(LayoutKind.Sequential)]
        private struct TrustData {
            internal uint Size; internal IntPtr Policy, Client;
            internal uint UIChoice, RevocationChecks, UnionChoice; internal IntPtr File;
            internal uint StateAction; internal IntPtr State, Url; internal uint ProviderFlags, UIContext; internal IntPtr SignatureSettings;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct ProviderCertificate { internal uint Size; internal IntPtr Certificate; }

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32), DllImport("wintrust.dll", ExactSpelling = true)]
        private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32), DllImport("wintrust.dll", ExactSpelling = true)]
        private static extern IntPtr WTHelperProvDataFromStateData(IntPtr state);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32), DllImport("wintrust.dll", ExactSpelling = true)]
        private static extern IntPtr WTHelperGetProvSignerFromChain(IntPtr provider, uint index, bool countersigner, uint counterIndex);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32), DllImport("wintrust.dll", ExactSpelling = true)]
        private static extern IntPtr WTHelperGetProvCertFromChain(IntPtr signer, uint index);

        private static bool SignedByGoogle(string path)
        {
            Guid action = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE"); // WINTRUST_ACTION_GENERIC_VERIFY_V2
            using (var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                var file = new TrustFile { Size = (uint)Marshal.SizeOf(typeof(TrustFile)), Path = path, Handle = stream.SafeFileHandle.DangerousGetHandle() };
                var data = new TrustData {
                    Size = (uint)Marshal.SizeOf(typeof(TrustData)), UIChoice = 2, UnionChoice = 1, StateAction = 1,
                    ProviderFlags = 0x1000 | 0x2000, // Cache-only URL retrieval, disable MD2/MD4.
                    File = Marshal.AllocHGlobal((int)file.Size)
                };
                bool initialized = false;
                try {
                    Marshal.StructureToPtr(file, data.File, false);
                    initialized = true;
                    if (WinVerifyTrust(new IntPtr(-1), ref action, ref data) != 0) return false;
                    // Read the exact signer Windows verified, including its signature and certificate chain.
                    IntPtr provider = WTHelperProvDataFromStateData(data.State);
                    IntPtr signer = provider == IntPtr.Zero ? IntPtr.Zero : WTHelperGetProvSignerFromChain(provider, 0, false, 0);
                    IntPtr record = signer == IntPtr.Zero ? IntPtr.Zero : WTHelperGetProvCertFromChain(signer, 0);
                    if (record == IntPtr.Zero) return false;
                    IntPtr context = ((ProviderCertificate)Marshal.PtrToStructure(record, typeof(ProviderCertificate))).Certificate;
                    if (context == IntPtr.Zero) return false;
                    using (var cert = new X509Certificate2(context)) {
                        string name = cert.GetNameInfo(X509NameType.SimpleName, false);
                        return name == "Google LLC" || name == "Google Inc" || name == "Google Inc.";
                    }
                } finally {
                    if (data.State != IntPtr.Zero) { data.StateAction = 2; WinVerifyTrust(new IntPtr(-1), ref action, ref data); }
                    if (initialized) Marshal.DestroyStructure(data.File, typeof(TrustFile));
                    Marshal.FreeHGlobal(data.File);
                }
            }
        }

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out SafeAccessTokenHandle token);
        private static string FindRunningAdb()
        {
            using (var self = Process.GetCurrentProcess())
            using (var user = WindowsIdentity.GetCurrent()) {
                var processes = Process.GetProcessesByName("adb");
                try {
                    foreach (var process in processes) {
                        try {
                            if (process.SessionId != self.SessionId) continue;
                            SafeAccessTokenHandle token;
                            if (!OpenProcessToken(process.Handle, 8 /* TOKEN_QUERY */, out token)) continue;
                            using (token)
                            using (var owner = new WindowsIdentity(token.DangerousGetHandle())) {
                                if (!user.User.Equals(owner.User)) continue;
                            }
                            string path = LocalPath(process.MainModule.FileName);
                            if (path == null || !Same(Path.GetFileName(path), "adb.exe") || !PlainFile(path)) continue;
                            string dir = Path.GetDirectoryName(path);
                            if (Linked(dir)) continue;
                            var core = new FileInfo(path).Length == PreviewAdb[0].Size ? PreviewAdb : Package.Take(4).ToArray();
                            if (!core.All(m => Matches(Path.Combine(dir, m.Name), m.Size, m.Hash))) continue;
                            if (Directory.EnumerateFiles(dir, "*.dll").All(d => core.Any(m => Same(m.Name, Path.GetFileName(d))))) return path;
                        } catch (Exception e) { if (!(e is Win32Exception) && !(e is InvalidOperationException) && !FileError(e)) throw; }
                    }
                } finally { foreach (var process in processes) process.Dispose(); }
            }
            return null;
        }

        public static void Remember(string adbExe) { Remember(LocalData, adbExe); }
        internal static void Remember(string localAppData, string adbExe)
        {
            string pref = Preference(localAppData), directory = Path.GetDirectoryName(pref);
            if (!SafeTree(localAppData, directory) || (File.Exists(pref) && Linked(pref))) throw new IOException("The USB tool preference location is a link.");
            if (String.IsNullOrWhiteSpace(adbExe)) { if (File.Exists(pref)) File.Delete(pref); return; }
            string path = Candidate(adbExe, localAppData);
            if (path == null) throw new ArgumentException("Choose adb.exe from a complete local Android Platform Tools folder.", "adbExe");
            Directory.CreateDirectory(directory);
            string temp = Path.Combine(directory, ".adb-path-" + Guid.NewGuid().ToString("N"));
            try {
                File.WriteAllText(temp, path, new UTF8Encoding(false));
                if (File.Exists(pref)) File.Replace(temp, pref, null);
                else {
                    try { File.Move(temp, pref); }
                    catch (IOException) { if (!File.Exists(pref)) throw; File.Replace(temp, pref, null); }
                }
            } finally { if (File.Exists(temp)) File.Delete(temp); }
        }

        private static void Report(IProgress<string> progress, string message) { if (progress != null) progress.Report(message); }
        public static string Install(CancellationToken cancellation, IProgress<string> progress)
        {
            return Install(LocalData, cancellation, progress, Download);
        }
        internal static string Install(string localAppData, CancellationToken cancellation, IProgress<string> progress,
            Action<string, CancellationToken, IProgress<string>> download)
        {
            string local = LocalPath(localAppData);
            if (local == null) throw new IOException("Android Platform Tools need a local Windows cache directory.");
            string target = Cache(local), tools = Path.GetDirectoryName(target), exe = Path.Combine(target, "adb.exe");
            cancellation.ThrowIfCancellationRequested();
            string lockName;
            using (var bytes = new MemoryStream(Encoding.UTF8.GetBytes(target.ToUpperInvariant()))) lockName = "Local\\PixelBackup.Adb." + Digest(bytes);
            using (var mutex = new Mutex(false, lockName)) {
                bool held = false;
                try {
                    while (!held) {
                        cancellation.ThrowIfCancellationRequested();
                        try { held = mutex.WaitOne(200); } catch (AbandonedMutexException) { held = true; }
                    }
                    if (ValidCache(local)) return exe;
                    if (!SafeTree(local, target) || File.Exists(target)) throw new IOException("The Android tools cache location is occupied by a file or link.");
                    Directory.CreateDirectory(tools);
                    string work = Path.Combine(tools, ".adb-download-" + Guid.NewGuid().ToString("N"));
                    string staged = Path.Combine(work, "ready"), zip = Path.Combine(work, "platform-tools.zip");
                    Directory.CreateDirectory(staged);
                    try {
                        Report(progress, "Downloading Google Android Platform Tools " + Version + "…");
                        download(zip, cancellation, progress);
                        cancellation.ThrowIfCancellationRequested();
                        Report(progress, "Checking the Google download…");
                        if (!Matches(zip, DownloadBytes, ZipHash)) throw new InvalidDataException("The Google Platform Tools download did not match the expected size or SHA-256.");
                        Extract(zip, staged, cancellation);
                        cancellation.ThrowIfCancellationRequested();
                        string previous = null;
                        if (Directory.Exists(target)) {
                            previous = target + ".previous-" + Guid.NewGuid().ToString("N");
                            Directory.Move(target, previous);
                        }
                        try { Directory.Move(staged, target); }
                        catch { if (previous != null && !Directory.Exists(target)) Directory.Move(previous, target); throw; }
                        if (previous != null && !RemovePackage(previous)) Report(progress, "Previous tool files were preserved at " + previous);
                        return exe;
                    } finally {
                        if (Directory.Exists(work) && !Linked(work)) {
                            RemovePackage(staged);
                            if (File.Exists(zip) && !Linked(zip)) File.Delete(zip);
                            if (!Directory.EnumerateFileSystemEntries(work).Any()) Directory.Delete(work);
                        }
                    }
                } finally { if (held) mutex.ReleaseMutex(); }
            }
        }

        // A replaced cache may contain personal files. Remove only a tree consisting of named package files.
        private static bool RemovePackage(string dir)
        {
            try {
                if (!Directory.Exists(dir)) return true;
                if (Linked(dir)) return false;
                string[] entries = Directory.GetFileSystemEntries(dir);
                if (entries.Any(p => !File.Exists(p) || Linked(p) || !Package.Any(m => Same(m.Name, Path.GetFileName(p))))) return false;
                foreach (string file in entries) File.Delete(file);
                Directory.Delete(dir);
                return true;
            } catch (Exception e) { if (!FileError(e)) throw; return false; }
        }

        private static void Extract(string zip, string directory, CancellationToken cancellation)
        {
            var written = new HashSet<string>(StringComparer.Ordinal);
            using (var archive = ZipFile.OpenRead(zip)) {
                if (archive.Entries.Count != Package.Length + 1) throw new InvalidDataException("Unexpected files in the Google tools archive.");
                foreach (var entry in archive.Entries) {
                    cancellation.ThrowIfCancellationRequested();
                    if (entry.FullName == "platform-tools/" && entry.Length == 0) continue;
                    var expected = Package.SingleOrDefault(m => entry.FullName == "platform-tools/" + m.Name);
                    if (expected == null || entry.Length != expected.Size || !written.Add(expected.Name)) throw new InvalidDataException("Invalid file in the Google tools archive.");
                    string target = Path.Combine(directory, expected.Name);
                    using (var input = entry.Open())
                    using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                        CopyBounded(input, output, expected.Size, cancellation, null);
                    if (!Matches(target, expected.Size, expected.Hash)) throw new InvalidDataException("Verification failed for " + expected.Name + ".");
                }
            }
            if (written.Count != Package.Length) throw new InvalidDataException("The Google tools archive is incomplete.");
        }

        private static void CopyBounded(Stream input, Stream output, long expected, CancellationToken cancellation, IProgress<string> progress)
        {
            byte[] buffer = new byte[65536];
            long count = 0, lastUpdate = 0;
            int n;
            while ((n = input.Read(buffer, 0, buffer.Length)) > 0) {
                cancellation.ThrowIfCancellationRequested();
                count += n;
                if (count > expected) throw new InvalidDataException("The Google tools download exceeded its expected size.");
                output.Write(buffer, 0, n);
                if (progress != null && count - lastUpdate >= 524288) {
                    Report(progress, "Downloading Android Platform Tools… " + (count * 100 / expected) + "%");
                    lastUpdate = count;
                }
            }
            if (count != expected) throw new InvalidDataException("The Google tools download was incomplete.");
        }

        private static void Download(string zip, CancellationToken cancellation, IProgress<string> progress)
        {
            var request = (HttpWebRequest)WebRequest.Create(DownloadUrl);
            request.AllowAutoRedirect = false;
            request.Timeout = request.ReadWriteTimeout = 30000;
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation))
            using (deadline.Token.Register(request.Abort)) {
                deadline.CancelAfter(TimeSpan.FromMinutes(3));
                try {
                    using (var response = (HttpWebResponse)request.GetResponse()) {
                        if (response.StatusCode != HttpStatusCode.OK || (response.ContentLength >= 0 && response.ContentLength != DownloadBytes))
                            throw new InvalidDataException("Google returned an unexpected Platform Tools download.");
                        using (var input = response.GetResponseStream())
                        using (var output = new FileStream(zip, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                            CopyBounded(input, output, DownloadBytes, deadline.Token, progress);
                    }
                } catch {
                    cancellation.ThrowIfCancellationRequested();
                    if (deadline.IsCancellationRequested) throw new TimeoutException("The Google tools download timed out. Try again or select an existing installation.");
                    throw;
                }
            }
        }
    }
}
