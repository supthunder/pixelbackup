using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace PixelBackup
{
    internal sealed class SessionStatus
    {
        public SessionStatus() { }

        public string State { get; set; }
        public string Message { get; set; }
        public bool PixelSeen { get; set; }
        public string ShareName { get; set; }
        public string PlanShareName { get; set; }
        public bool CleanupComplete { get; set; }
    }

    internal sealed class PlanSession : IDisposable
    {
        private const int MaximumPlanBytes = 32 * 1024 * 1024;
        private const int MaximumStatusBytes = 64 * 1024;
        private static readonly TimeSpan StartupLimit = TimeSpan.FromSeconds(60);
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        private static readonly byte[] EndOfHash = new byte[0];
        private static readonly char[] InvalidNameCharacters = Path.GetInvalidFileNameChars();

        private readonly object gate = new object();
        private readonly Stopwatch startup = new Stopwatch();
        private readonly SecurityIdentifier owner;
        private readonly string folder;
        private readonly string stagingDirectory;
        private readonly string planDirectory;
        private readonly string controlDirectory;

        private Process broker;
        private CancellationTokenRegistration cancellation;
        private SessionStatus lastStatus;
        private bool stagingCreated;
        private bool brokerStarted;
        private bool brokerCleanupConfirmed;
        private bool stopRequested;
        private bool startupTimedOut;
        private bool disposed;
        private string stopError;

        internal List<MediaEntry> Published { get; private set; }

        private PlanSession(string folder, string sessionsDirectory, List<MediaEntry> entries)
        {
            this.folder = folder;
            Published = entries;
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                owner = identity.User;
            stagingDirectory = Path.Combine(sessionsDirectory, "session-" + Guid.NewGuid().ToString("N"));
            planDirectory = Path.Combine(stagingDirectory, "plan");
            controlDirectory = Path.Combine(stagingDirectory, "control");
            lastStatus = Status("Starting", "Opening the read-only share.");
        }


        internal static PlanSession Start(
            string windowsDirectory, ScanResult scan,
            CancellationToken token, IProgress<string> progress)
        {
            string script = Path.GetFullPath(Path.Combine(windowsDirectory, "Share-PixelPlan.ps1"));
            FileAttributes attributes = File.GetAttributes(script);
            if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                throw new IOException("The Windows sharing script must be a regular local file.");

            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            PlanSession session = Prepare(scan, token, progress, localAppData);
            try
            {
                token.ThrowIfCancellationRequested();
                if (progress != null)
                    progress.Report("Opening the read-only share.");
                session.LaunchBroker(script);
                session.cancellation = token.Register(session.Stop);
                return session;
            }
            catch (Win32Exception error)
            {
                session.Dispose();
                if (error.NativeErrorCode == 1223)
                    throw new OperationCanceledException("Windows administrator approval was canceled.", error, token);
                throw;
            }
            catch
            {
                session.Dispose();
                throw;
            }
        }

        private static PlanSession Prepare(
            ScanResult scan, CancellationToken token, IProgress<string> progress,
            string localAppData)
        {
            token.ThrowIfCancellationRequested();
            if (scan == null)
                throw new ArgumentNullException("scan");
            string folder = MediaScanner.LocalPath(scan.Folder);
            EnsureDirectoryChain(folder);

            if (String.IsNullOrEmpty(localAppData))
                throw new IOException("Windows did not provide a local application data directory.");
            EnsureDirectoryChain(localAppData);
            if (!String.Equals(new DriveInfo(Path.GetPathRoot(localAppData)).DriveFormat, "NTFS",
                    StringComparison.OrdinalIgnoreCase))
                throw new IOException("The private session requires an NTFS local application data directory.");
            string appDirectory = Path.Combine(localAppData, "PixelBackup");
            string sessionsDirectory = Path.Combine(appDirectory, "sessions");
            if (IsWithin(folder, sessionsDirectory) || IsWithin(sessionsDirectory, folder))
                throw new IOException("Choose a media folder outside PixelBackup's private session directories.");

            var entries = new List<MediaEntry>();
            var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            int planBytes = 0;
            foreach (MediaEntry entry in scan.Items)
            {
                token.ThrowIfCancellationRequested();
                ValidateEntryPath(folder, entry);
                if (!paths.Add(entry.RelativePath))
                    throw new IOException("The scan contains the same Windows path more than once. Scan again.");
                int bytes = Utf8.GetByteCount(entry.RelativePath) + 1;
                if (bytes > MaximumPlanBytes - planBytes)
                    throw new IOException("The folder list exceeds the 32 MiB manifest limit. Select a smaller folder.");
                planBytes += bytes;
                entries.Add(entry);
            }
            if (entries.Count == 0)
                throw new InvalidOperationException("There are no media files selected for sharing.");
            if (entries[0].RelativePath[0] == '\uFEFF')
            {
                // A leading U+FEFF has the same bytes as a UTF-8 BOM. Only its
                // position at the start of the manifest is ambiguous.
                int first = entries.FindIndex(candidate => candidate.RelativePath[0] != '\uFEFF');
                if (first < 0)
                    throw new IOException("Every selected path starts with a Unicode byte order mark. Rename one of the files before sharing.");
                MediaEntry firstEntry = entries[first];
                entries.RemoveAt(first);
                entries.Insert(0, firstEntry);
            }

            var session = new PlanSession(folder, sessionsDirectory, entries);
            try
            {
                session.CreateStage(appDirectory, sessionsDirectory);
                session.WritePlan(token, progress);
                return session;
            }
            catch
            {
                session.Dispose();
                throw;
            }
        }

        private static void EnsureDirectoryChain(string path)
        {
            for (DirectoryInfo current = new DirectoryInfo(path); current != null; current = current.Parent)
            {
                FileAttributes attributes = File.GetAttributes(current.FullName);
                if ((attributes & FileAttributes.Directory) == 0 ||
                    (attributes & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("The folder or an ancestor is redirected. Select a regular local folder.");
            }
        }

        private static bool IsWithin(string root, string path)
        {
            string prefix = root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            return (path.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar)
                .StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
        }


        private static void ValidateEntryPath(string root, MediaEntry entry)
        {
            if (entry == null || String.IsNullOrEmpty(entry.RelativePath))
                throw new IOException("The scan contains an empty file path. Scan again.");
            string relative = entry.RelativePath;
            foreach (string component in relative.Split('/'))
            {
                if (component.Length == 0 || component == "." || component == ".." ||
                    component.EndsWith(".", StringComparison.Ordinal) ||
                    component.EndsWith(" ", StringComparison.Ordinal) ||
                    component.IndexOfAny(InvalidNameCharacters) >= 0)
                    throw new IOException("A selected file has a path that cannot be shared safely. Scan again.");
                foreach (char value in component)
                    if (Char.IsControl(value))
                        throw new IOException("A selected file contains a control character in its path.");
            }
            string local = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
            if (!IsWithin(root, local) ||
                !String.Equals(local, Path.GetFullPath(entry.FullPath), StringComparison.OrdinalIgnoreCase))
                throw new IOException("A selected file no longer belongs to this folder. Scan again.");
        }

        private DirectorySecurity PrivateDirectorySecurity()
        {
            var security = new DirectorySecurity();
            security.SetOwner(owner);
            security.SetAccessRuleProtection(true, false);
            var inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            security.AddAccessRule(new FileSystemAccessRule(owner, FileSystemRights.FullControl,
                inherit, PropagationFlags.None, AccessControlType.Allow));
            var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            security.AddAccessRule(new FileSystemAccessRule(system, FileSystemRights.FullControl,
                inherit, PropagationFlags.None, AccessControlType.Allow));
            return security;
        }

        private void CreateStage(string appDirectory, string sessionsDirectory)
        {
            DirectorySecurity security = PrivateDirectorySecurity();
            Directory.CreateDirectory(appDirectory, security);
            EnsureDirectoryChain(appDirectory);
            Directory.CreateDirectory(sessionsDirectory, security);
            EnsureDirectoryChain(sessionsDirectory);
            if (Directory.Exists(stagingDirectory) || File.Exists(stagingDirectory))
                throw new IOException("A private session directory already exists. Try again.");
            Directory.CreateDirectory(stagingDirectory, security);
            stagingCreated = true;
            Directory.CreateDirectory(planDirectory, security);
            Directory.CreateDirectory(controlDirectory, security);
        }

        private void WritePlan(CancellationToken token, IProgress<string> progress)
        {
            string listPath = Path.Combine(planDirectory, "files.txt");
            using (var output = new FileStream(listPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var digest = SHA256.Create())
            {
                int totalBytes = 0;
                foreach (MediaEntry entry in Published)
                {
                    token.ThrowIfCancellationRequested();
                    byte[] line = Utf8.GetBytes(entry.RelativePath + "\n");
                    if (line.Length > MaximumPlanBytes - totalBytes)
                        throw new IOException("The folder list exceeds the 32 MiB manifest limit.");
                    totalBytes += line.Length;
                    digest.TransformBlock(line, 0, line.Length, line, 0);
                    output.Write(line, 0, line.Length);
                }
                digest.TransformFinalBlock(EndOfHash, 0, 0);
                File.WriteAllText(Path.Combine(planDirectory, "files.sha256"),
                    LowerHex(digest.Hash) + "\n", Utf8);
            }
            // Reopen each source and check the scan's metadata immediately
            // before handing the finished manifest to the sharing broker.
            var reportInterval = Stopwatch.StartNew();
            for (int index = 0; index < Published.Count; index++)
            {
                token.ThrowIfCancellationRequested();
                if (progress != null && (index == 0 || reportInterval.ElapsedMilliseconds >= 400))
                {
                    progress.Report(String.Format(CultureInfo.CurrentCulture,
                        "Checking file {0:N0} of {1:N0}.", index + 1, Published.Count));
                    reportInterval.Restart();
                }
                MediaEntry entry = Published[index];
                if (!MediaScanner.IsCurrent(entry))
                    throw new IOException("A source file changed or became unavailable. Scan the folder again.\n" + entry.RelativePath);
            }
            token.ThrowIfCancellationRequested();
        }

        private static string LowerHex(byte[] bytes)
        {
            return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
        }

        private void LaunchBroker(string script)
        {
            int parentId;
            long parentStartTicks;
            using (Process parent = Process.GetCurrentProcess())
            {
                parentId = parent.Id;
                parentStartTicks = parent.StartTime.ToUniversalTime().Ticks;
            }

            bool elevate;
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                elevate = !new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            var info = new ProcessStartInfo
            {
                FileName = DesktopPlatform.PowerShell,
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File " +
                    DesktopPlatform.Quote(script) + " -Folder " + DesktopPlatform.Quote(folder) +
                    " -PlanDirectory " + DesktopPlatform.Quote(planDirectory) +
                    " -ControlDirectory " + DesktopPlatform.Quote(controlDirectory) +
                    " -ParentProcessId " + parentId.ToString(CultureInfo.InvariantCulture) +
                    " -ParentStartTicks " + parentStartTicks.ToString(CultureInfo.InvariantCulture),
                WorkingDirectory = Path.GetDirectoryName(script),
                UseShellExecute = elevate,
                Verb = elevate ? "runas" : "",
                CreateNoWindow = !elevate,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            broker = Process.Start(info);
            if (broker == null)
                throw new IOException("Windows did not start the sharing broker.");
            brokerStarted = true;
            startup.Start();
            broker.Exited += BrokerExited;
            try { broker.EnableRaisingEvents = true; }
            catch (Win32Exception error) { Trace.TraceWarning(error.Message); }
        }

        internal SessionStatus Poll()
        {
            lock (gate)
            {
                if (broker == null)
                    return lastStatus;

                SessionStatus status = ReadStatus();
                bool exited = HasExited(broker);
                if (status != null)
                    lastStatus = status;
                if (status != null && (status.State == "Error" || status.State == "Closed"))
                {
                    if (startupTimedOut && status.State == "Closed")
                        return new SessionStatus { State = "Error", CleanupComplete = status.CleanupComplete,
                            Message = "Windows did not open the shares before the startup limit." };
                    return status;
                }
                if (exited)
                    return Status("Error", "The Windows broker exited before it confirmed share cleanup. " +
                        "Check administrator approval and the sharing script permissions. The private session files remain in " +
                        stagingDirectory);
                if (lastStatus.State == "Starting" && !stopRequested && startup.Elapsed >= StartupLimit)
                {
                    startupTimedOut = true;
                    RequestStop();
                }
                if (stopError != null)
                    return Status("Error", stopError);
                if (startupTimedOut)
                    return Status("Error", "Sharing startup timed out. Windows was asked to close the session.");
                if (stopRequested)
                    return Status("Starting", "Closing the shares.");
                return lastStatus;
            }
        }


        private SessionStatus ReadStatus()
        {
            try
            {
                string path = Path.Combine(controlDirectory, "status.json");
                FileAttributes attributes = File.GetAttributes(path);
                if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                    return null;
                using (var input = new FileStream(path, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
                using (var reader = new StreamReader(input, Utf8, false))
                {
                    if (input.Length == 0 || input.Length > MaximumStatusBytes)
                        return null;
                    var json = new JavaScriptSerializer { MaxJsonLength = MaximumStatusBytes, RecursionLimit = 8 };
                    SessionStatus status = json.Deserialize<SessionStatus>(reader.ReadToEnd());
                    if (status != null && (status.State == "Ready" || status.State == "Closed" ||
                                           status.State == "Error"))
                        return status;
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
            return null;
        }

        private static SessionStatus Status(string state, string message)
        {
            return new SessionStatus { State = state, Message = message };
        }

        private static bool HasExited(Process process)
        {
            try { return process.HasExited; }
            catch (Win32Exception) { return false; }
        }

        internal void Stop()
        {
            lock (gate)
                RequestStop();
        }

        private void RequestStop()
        {
            if (broker == null || HasExited(broker) || (stopRequested && stopError == null))
                return;
            stopRequested = true;
            try
            {
                string path = Path.Combine(controlDirectory, "stop");
                if (!File.Exists(path))
                    using (new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read)) { }
                stopError = null;
            }
            catch (IOException error)
            {
                stopError = "Could not send the stop request. " + error.Message;
            }
            catch (UnauthorizedAccessException error)
            {
                stopError = "Could not send the stop request. " + error.Message;
            }
        }

        private void BrokerExited(object sender, EventArgs arguments)
        {
            // A call to HasExited can raise Exited inline while holding the gate.
            ThreadPool.QueueUserWorkItem(delegate
            {
                lock (gate)
                    if (disposed)
                        FinishDispose();
            });
        }

        public void Dispose()
        {
            cancellation.Dispose();
            lock (gate)
            {
                if (disposed)
                    return;
                disposed = true;
                RequestStop();
                FinishDispose();
            }
        }

        private void FinishDispose()
        {
            if (broker != null)
            {
                if (!HasExited(broker))
                    return;
                SessionStatus terminal = ReadStatus();
                broker.Exited -= BrokerExited;
                broker.Dispose();
                broker = null;
                brokerCleanupConfirmed = terminal != null && terminal.CleanupComplete &&
                    (terminal.State == "Closed" || terminal.State == "Error");
                if (brokerCleanupConfirmed)
                    lastStatus = terminal;
            }
            if (!stagingCreated || (brokerStarted && !brokerCleanupConfirmed))
                return;
            try
            {
                EnsureOwnedDirectory(stagingDirectory);
                RemoveStageDirectory(planDirectory, "files.txt", "files.sha256");
                RemoveStageDirectory(controlDirectory, "status.json", "stop");
                Directory.Delete(stagingDirectory);
                stagingCreated = false;
            }
            catch (IOException error)
            {
                Trace.TraceWarning("Could not remove private PixelBackup session files. " + error.Message);
            }
            catch (UnauthorizedAccessException error)
            {
                Trace.TraceWarning("Could not remove private PixelBackup session files. " + error.Message);
            }
        }

        private void EnsureOwnedDirectory(string path)
        {
            EnsureDirectoryChain(path);
            var directory = new DirectoryInfo(path);
            var security = directory.GetAccessControl(AccessControlSections.Owner);
            if (!owner.Equals(security.GetOwner(typeof(SecurityIdentifier))))
                throw new IOException("Private session directory ownership changed.");
        }

        private void RemoveStageDirectory(string directory, params string[] names)
        {
            if (!Directory.Exists(directory))
                return;
            EnsureOwnedDirectory(directory);
            foreach (string name in names)
            {
                string path = Path.Combine(directory, name);
                if (!File.Exists(path))
                    continue;
                FileAttributes attributes = File.GetAttributes(path);
                if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                    throw new IOException("A private session file changed type.");
                File.Delete(path);
            }
            Directory.Delete(directory);
        }
    }
}
