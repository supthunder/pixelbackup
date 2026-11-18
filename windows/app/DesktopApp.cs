using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace PixelBackup
{
    public sealed class DesktopApp
    {
        private readonly Window window;
        private readonly string windowsDirectory;
        private readonly Profiles profiles;
        private readonly DispatcherTimer timer;
        private BackupLibrary library;
        private int auditGroups;
        private int libraryRevision;
        private string folder;
        private ScanResult scan;
        private CancellationTokenSource work;
        private bool canCancel, stopping, reachedReady, closeRequested, closed;
        private PlanSession session;
        private List<MediaEntry> confirmation;
        private string lastReader = "";
        private string setupNotice;

        public DesktopApp(Window window, string windowsDirectory, string stateDirectory)
        {
            this.window = window;
            window.Dispatcher.VerifyAccess();
            if (!(SynchronizationContext.Current is DispatcherSynchronizationContext))
                SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(window.Dispatcher));
            this.windowsDirectory = Path.GetFullPath(windowsDirectory);
            profiles = new Profiles(Path.GetFullPath(stateDirectory));
            Wire("NavBackup", () => Navigate("Backup"));
            Wire("NavLibrary", () => Navigate("Library"));
            Wire("NavSetup", () => { Navigate("Setup"); RefreshReader(); });
            Wire("ChooseFolder", ChooseFolder);
            Wire("ScanButton", Rescan);
            Wire("ShareButton", StartShare);
            Wire("StopButton", StopShare);
            Wire("ConfirmButton", ConfirmBackup);
            Wire("CancelButton", CancelWork);
            if (window.FindName("CancelImport") != null) Wire("CancelImport", CancelWork);
            Wire("AccessButton", GiveAccess);
            Wire("ImportFolder", () => { string path = DesktopPlatform.PickFolder("Select your extracted Google Photos or Takeout folder"); if (path != null) ImportExport(path, false); });
            Wire("ImportZip", PickArchives);
            Wire("ExportReport", ExportAudit);
            Wire("NewProfile", NewProfile);
            Wire("ClearCatalog", ClearCatalog);
            Wire("OpenPhotos", () => OpenUrl("https://photos.google.com/"));
            Wire("OpenGuide", () => OpenUrl("https://github.com/supthunder/pixelbackup/blob/main/docs/PC_FOLDER.md"));
            Wire("PairPhone", () => SetupPhone(true));
            Wire("UpdateWatcher", () => SetupPhone(false));
            Wire("WarningsButton", ShowWarnings);
            RoutedEventHandler refreshSelection = delegate { UpdateCounts(); RefreshButtons(); if (scan != null && Idle) DescribeScan(); };
            Control<CheckBox>("SkipCopies").Checked += refreshSelection;
            Control<CheckBox>("SkipCopies").Unchecked += refreshSelection;
            BindProfiles();
            Control<ComboBox>("ProfileSelect").SelectionChanged += delegate
            {
                var selected = Control<ComboBox>("ProfileSelect").SelectedItem as LibraryProfile;
                if (selected != null && selected.Id != profiles.Active.Id && Idle)
                {
                    try { profiles.Select(selected); UseProfile(); }
                    catch (Exception ex) { Error("Could not switch libraries", ex); }
                }
            };
            UseProfile();
            Navigate("Backup");
            Text("ShareStatus", "Not sharing");
            RefreshReader();
            timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(650) };
            timer.Tick += delegate { Poll(); };
            timer.Start();
            window.Closing += OnClosing;
            window.Closed += delegate { closed = true; timer.Stop(); if (work != null && canCancel) work.Cancel(); };
        }

        private T Control<T>(string name) where T : FrameworkElement
        {
            var control = window.FindName(name) as T;
            if (control == null) throw new InvalidDataException("Missing app control: " + name);
            return control;
        }

        private void Wire(string name, Action action)
        {
            Control<Button>(name).Click += delegate { try { action(); } catch (Exception ex) { Error("Action unavailable", ex); } };
        }

        private bool Idle { get { return work == null && session == null; } }
        private bool Skip { get { return Control<CheckBox>("SkipCopies").IsChecked == true; } }
        private void Text(string name, string text) { Control<TextBlock>(name).Text = text; }
        private void Enabled(string name, bool value) { Control<FrameworkElement>(name).IsEnabled = value; }
        private void Status(string title, string detail) { Text("StatusText", title); Text("StatusDetail", detail ?? ""); }
        private void Error(string title, Exception error)
        {
            string message = error.GetBaseException().Message;
            Status(title, message);
            if (!closed && !closeRequested) MessageBox.Show(window, message, title, MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private void Navigate(string page)
        {
            foreach (string name in new[] { "Backup", "Library", "Setup" })
                Control<FrameworkElement>(name + "View").Visibility = name == page ? Visibility.Visible : Visibility.Collapsed;
        }

        private void BindProfiles()
        {
            var combo = Control<ComboBox>("ProfileSelect");
            combo.ItemsSource = profiles.All.ToArray();
            combo.SelectedItem = profiles.Active;
        }

        private void UseProfile()
        {
            libraryRevision++;
            library = new BackupLibrary(profiles.Active.DirectoryPath);
            confirmation = null;
            scan = null;
            Control<DataGrid>("FileTable").ItemsSource = null;
            Status(folder == null ? "Choose a photo folder" : "Ready to scan", "Check exact copies against “" + profiles.Active.Name + "” on this PC.");
            Text("ImportStatus", "Add a Google Photos export or confirm a completed batch to build this library.");
            Text("FolderPath", folder == null ? "No folder selected" : FolderLabel(folder));
            UpdateCounts(); RefreshButtons(); RefreshCatalog();
        }

        private static string FolderLabel(string fullPath)
        {
            var directory = new DirectoryInfo(fullPath);
            return directory.Parent == null ? directory.FullName : directory.Name;
        }

        private async void RefreshCatalog()
        {
            int version = ++libraryRevision;
            var current = library;
            try
            {
                var audit = await Task.Run(() => new { Count = current.Count, Report = current.ReadAudit() });
                if (closed || version != libraryRevision) return;
                Text("LibraryCount", audit.Count.ToString("N0"));
                auditGroups = audit.Report.DuplicateGroups;
                var lines = new List<string>();
                foreach (var group in audit.Report.DuplicatePreview)
                {
                    string paths = string.Join(Environment.NewLine, group.Paths.Select(PreviewPath));
                    lines.Add(group.FileCount.ToString("N0") + " matching export paths" + Environment.NewLine + paths);
                }
                if (lines.Count == 0) lines.Add("No repeated export paths recorded.");
                Control<ListBox>("AuditList").ItemsSource = lines;
                RefreshButtons();
            }
            catch (Exception ex)
            {
                if (!closed && version == libraryRevision) { Text("ImportStatus", ex.GetBaseException().Message); Text("LibraryCount", "—"); }
            }
        }

        private void RefreshButtons()
        {
            bool idle = Idle;
            bool hasFiles = scan != null && scan.Items.Any(x => !Skip || x.Decision == "Ready");
            foreach (string name in new[] { "ChooseFolder", "ImportFolder", "ImportZip", "NewProfile", "ClearCatalog", "ProfileSelect", "UpdateWatcher", "PairPhone" }) Enabled(name, idle);
            Enabled("ScanButton", idle && folder != null);
            Enabled("SkipCopies", idle);
            Enabled("ShareButton", idle && hasFiles);
            Enabled("StopButton", session != null && !stopping);
            Enabled("ConfirmButton", idle && confirmation != null && confirmation.Count > 0);
            Enabled("CancelButton", work != null && canCancel && !work.IsCancellationRequested);
            if (window.FindName("CancelImport") != null) Enabled("CancelImport", work != null && canCancel && !work.IsCancellationRequested);
            Enabled("AccessButton", idle && folder != null && CanGrant(folder));
            Enabled("WarningsButton", scan != null && scan.Warnings.Count > 0);
            Enabled("ExportReport", idle && auditGroups > 0);
            var bar = Control<ProgressBar>("ProgressBar");
            bar.IsIndeterminate = work != null;
            bar.Visibility = work != null ? Visibility.Visible : Visibility.Collapsed;
        }

        private static string PreviewPath(string value)
        {
            string normalized = value.Replace('\\', '/');
            int takeout = normalized.IndexOf("Takeout/Google Photos/", StringComparison.OrdinalIgnoreCase);
            if (takeout >= 0) return normalized.Substring(takeout + "Takeout/Google Photos/".Length);
            int photos = normalized.IndexOf("/Google Photos/", StringComparison.OrdinalIgnoreCase);
            return photos < 0 ? value : normalized.Substring(photos + "/Google Photos/".Length);
        }

        private static bool CanGrant(string path)
        {
            try { return new DirectoryInfo(path).Parent != null && string.Equals(new DriveInfo(Path.GetPathRoot(path)).DriveFormat, "NTFS", StringComparison.OrdinalIgnoreCase); }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }

        private void UpdateCounts()
        {
            int total = scan == null ? 0 : scan.Items.Count;
            int copies = scan == null ? 0 : scan.Items.Count(x => x.Decision != "Ready");
            Text("TotalCount", total.ToString("N0")); Text("CopyCount", copies.ToString("N0"));
            Text("ReadyCount", (Skip ? total - copies : total).ToString("N0"));
        }

        private void DescribeScan()
        {
            int available = scan.Items.Count(x => !Skip || x.Decision == "Ready");
            string detail = available == 0 ? "Choose another folder or review your copy settings." :
                (Skip ? "Only the ready files will appear on your Pixel." : "Every scanned file, including exact copies, will appear on your Pixel.");
            if (scan.SkippedCount > 0) detail += " " + scan.SkippedCount.ToString("N0") + " skipped. See scan notes.";
            Status(available == 0 ? "Nothing queued to share" : "Ready to share", detail + "  ·  " + profiles.Active.Name);
        }

        private CancellationTokenSource Begin(string title, string detail, bool cancellable)
        {
            work = new CancellationTokenSource(); canCancel = cancellable;
            Status(title, detail); RefreshButtons();
            return work;
        }

        private void End(CancellationTokenSource operation)
        {
            if (work != operation) return;
            work = null; canCancel = false; operation.Dispose();
            if (closed) return;
            RefreshButtons();
            if (closeRequested)
            {
                if (session == null) window.Dispatcher.BeginInvoke(new Action(() => window.Close()));
                else StopShare();
            }
        }

        private sealed class ThrottledProgress : IProgress<string>
        {
            private readonly object gate = new object();
            private readonly Dispatcher dispatcher;
            private readonly Action<string> show;
            private string latest;
            private bool queued;
            public ThrottledProgress(Dispatcher dispatcher, Action<string> show) { this.dispatcher = dispatcher; this.show = show; }
            public void Report(string value)
            {
                lock (gate)
                {
                    latest = value;
                    if (queued) return;
                    queued = true;
                }
                dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(delegate
                {
                    string message;
                    lock (gate) { message = latest; queued = false; }
                    show(message);
                }));
            }
        }

        private IProgress<string> Progress(CancellationTokenSource operation, string element)
        {
            return new ThrottledProgress(window.Dispatcher, s => { if (work == operation && !closed) Text(element, s); });
        }

        private void ChooseFolder()
        {
            string path = DesktopPlatform.PickFolder("Choose a local folder of photos and videos");
            if (path != null) SelectFolder(path);
        }

        private void CancelWork()
        {
            if (work == null || !canCancel) return;
            work.Cancel();
            Text("StatusDetail", "Canceling the current operation…");
            RefreshButtons();
        }

        public void SelectFolder(string absolutePath)
        {
            if (!Idle) return;
            folder = Path.GetFullPath(absolutePath);
            Control<TextBlock>("FolderPath").ToolTip = folder;
            Text("FolderPath", FolderLabel(folder));
            Navigate("Backup");
            Rescan();
        }

        private async void Rescan()
        {
            if (!Idle || folder == null) return;
            confirmation = null; scan = null; UpdateCounts();
            Control<DataGrid>("FileTable").ItemsSource = null;
            Text("ShareStatus", "Not sharing");
            var operation = Begin("Scanning folder", "Checking media fingerprints…", true);
            var progress = Progress(operation, "StatusDetail");
            var current = library;
            var selected = folder;
            try
            {
                scan = await Task.Run(() => MediaScanner.Scan(selected, current.Snapshot(), operation.Token, progress));
                operation.Token.ThrowIfCancellationRequested();
                Control<DataGrid>("FileTable").ItemsSource = scan.Items;
                UpdateCounts(); DescribeScan();
            }
            catch (OperationCanceledException) { scan = null; UpdateCounts(); Status("Scan canceled", "Choose Rescan when you’re ready."); }
            catch (Exception ex) { scan = null; Error("Could not scan folder", ex); }
            finally { End(operation); }
        }

        public async void StartShare()
        {
            if (!Idle || scan == null || !scan.Items.Any(x => !Skip || x.Decision == "Ready")) return;
            confirmation = null; stopping = false; reachedReady = false;
            var selected = scan; bool skip = Skip;
            var operation = Begin("Preparing to share", "Checking the selected files before opening Windows sharing.", true);
            var progress = Progress(operation, "StatusDetail");
            try
            {
                session = await Task.Run(() => PlanSession.Start(windowsDirectory, selected, skip, operation.Token, progress));
                Text("ShareStatus", "Starting");
                Status("Opening Windows share", "Keep this window open while your Pixel reads the folder.");
                Poll();
            }
            catch (OperationCanceledException) { Status("Sharing canceled", "Your reviewed selection is still available."); Text("ShareStatus", "Not sharing"); }
            catch (Exception ex) { Text("ShareStatus", "Not sharing"); Error("Could not start sharing", ex); }
            finally { End(operation); }
        }

        public void StopShare()
        {
            if (session == null || stopping) return;
            try { session.Stop(); stopping = true; Status("Stopping sharing", "Windows is closing this session."); RefreshButtons(); }
            catch (Exception ex) { Error("Could not request a stop", ex); }
        }

        private void Poll()
        {
            if (session == null) return;
            SessionStatus state;
            try { state = session.Poll(); }
            catch (Exception ex) { Status("Checking sharing status", ex.GetBaseException().Message); return; }
            if (state.State == "Starting") return;
            if (state.State == "Ready")
            {
                reachedReady = true;
                Text("ShareStatus", state.PixelSeen ? "Sharing · Pixel opened the plan" : "Sharing · waiting for Pixel");
                if (!stopping) Status(state.PixelSeen ? "Pixel is reading the selection" : "Waiting for the Pixel",
                    "Keep the PC awake. Check backup progress in Google Photos on your Pixel.");
                return;
            }
            if (state.State != "Closed" && state.State != "Error") return;
            var finished = session;
            session = null;
            bool complete = state.State == "Closed" && state.CleanupComplete && reachedReady;
            confirmation = complete ? new List<MediaEntry>(finished.Published) : null;
            try { finished.Dispose(); }
            catch (Exception ex) { state.Message = (state.Message + " " + ex.GetBaseException().Message).Trim(); }
            stopping = false;
            Text("ShareStatus", "Not sharing");
            Status(complete ? "Sharing stopped" : "Sharing ended",
                complete ? "After checking these items in Google Photos, choose Confirm backup to remember their fingerprints." : state.Message);
            RefreshButtons();
            if (closeRequested && work == null) window.Dispatcher.BeginInvoke(new Action(() => window.Close()));
        }

        private async void ConfirmBackup()
        {
            if (!Idle || confirmation == null) return;
            var batch = confirmation.ToArray();
            if (MessageBox.Show(window, "Have you verified that all " + batch.Length.ToString("N0") + " shared files are backed up in the Google Photos account for “" + profiles.Active.Name + "”?\n\nTheir exact fingerprints will be skipped in future scans for this library.", "Confirm backup", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
            var operation = Begin("Saving confirmation", profiles.Active.Name, false);
            try
            {
                var current = library;
                int saved = await Task.Run(() =>
                {
                    foreach (var entry in batch)
                        if (!MediaScanner.IsCurrent(entry)) throw new IOException("A shared file changed or disappeared. Rescan before recording this batch: " + entry.RelativePath);
                    return current.Confirm(batch);
                });
                confirmation = null;
                Text("ImportStatus", "You confirmed " + saved.ToString("N0") + " fingerprints for this library.");
                Status("Backup recorded", "Future scans will recognize the confirmed files.");
                RefreshCatalog();
            }
            catch (Exception ex) { Error("Could not save confirmation", ex); }
            finally { End(operation); }
            if (Idle && confirmation == null && !closeRequested) Rescan();
        }

        private void PickArchives()
        {
            var picker = new Microsoft.Win32.OpenFileDialog { Filter = "Takeout ZIP archives (*.zip)|*.zip", Multiselect = true, Title = "Choose Google Photos Takeout ZIP files" };
            if (picker.ShowDialog(window) == true) ImportFiles(picker.FileNames, true);
        }

        public void ImportExport(string path, bool zip) { ImportFiles(new[] { path }, zip); }

        private async void ImportFiles(string[] paths, bool zip)
        {
            if (!Idle || paths.Length == 0) return;
            Navigate("Library");
            var current = library; confirmation = null;
            var operation = Begin("Reading Takeout", "Hashing the media in your export.", true);
            var progress = Progress(operation, "ImportStatus");
            int processed = 0, added = 0;
            try
            {
                foreach (string path in paths)
                {
                    var result = await Task.Run(() => zip ? current.ImportZip(path, operation.Token, progress) : current.ImportFolder(path, operation.Token, progress));
                    processed++; added += result.Added;
                }
                Text("ImportStatus", "Import complete · " + added.ToString("N0") + (added == 1 ? " new fingerprint · " : " new fingerprints · ") + processed.ToString("N0") + (processed == 1 ? " export read." : " exports read."));
                Status("Takeout imported", "Review the repeated export paths in Library.");
            }
            catch (OperationCanceledException) { Text("ImportStatus", "Import canceled. Completed exports kept: " + processed + "."); }
            catch (Exception ex) { Text("ImportStatus", "Import stopped. Completed exports kept: " + processed + ". " + ex.GetBaseException().Message); }
            finally { RefreshCatalog(); End(operation); }
            if (processed > 0 && Idle && folder != null && !closeRequested) Rescan();
        }

        private void NewProfile()
        {
            string name = DesktopPlatform.Prompt(window, "New library", "Name the Google Photos account or library these fingerprints belong to.", "", null);
            if (name == null) return;
            var profile = profiles.Create(name); profiles.Select(profile); BindProfiles(); UseProfile();
        }

        private async void ClearCatalog()
        {
            if (!Idle || MessageBox.Show(window, "Clear all Takeout and manually confirmed fingerprints in “" + profiles.Active.Name + "”? Your photos stay in place.", "Clear local catalog", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
            var current = library;
            var operation = Begin("Clearing local catalog", profiles.Active.Name, false);
            try { await Task.Run(() => current.Clear()); UseProfile(); Text("ImportStatus", "Local fingerprints cleared."); }
            catch (Exception ex) { Error("Could not clear this library", ex); }
            finally { End(operation); }
            if (Idle && folder != null && !closeRequested) Rescan();
        }

        private async void ExportAudit()
        {
            if (!Idle) return;
            var dialog = new Microsoft.Win32.SaveFileDialog { Filter = "Text report (*.txt)|*.txt", FileName = "Pixel Backup duplicate report.txt", Title = "Save duplicate-path report" };
            if (dialog.ShowDialog(window) != true) return;
            var current = library;
            var operation = Begin("Saving report", profiles.Active.Name, false);
            string destination = dialog.FileName, temp = Path.Combine(Path.GetDirectoryName(destination), ".pixel-report-" + Guid.NewGuid().ToString("N"));
            try
            {
                await Task.Run(() =>
                {
                    using (var writer = new StreamWriter(temp, false, new UTF8Encoding(false))) current.WriteDuplicateReport(writer);
                    if (File.Exists(destination)) File.Replace(temp, destination, null); else File.Move(temp, destination);
                });
                Text("ImportStatus", "Saved " + Path.GetFileName(destination) + ".");
            }
            catch (Exception ex) { Error("Could not save report", ex); }
            finally { try { if (File.Exists(temp)) File.Delete(temp); } finally { End(operation); } }
        }

        private void ShowWarnings()
        {
            if (scan == null || scan.Warnings.Count == 0) return;
            var list = new ListBox { ItemsSource = scan.Warnings, Margin = new Thickness(14), FontSize = 14 };
            var w = new Window { Owner = window, Title = "Scan notes", Width = 700, Height = 400, WindowStartupLocation = WindowStartupLocation.CenterOwner, Content = list };
            w.ShowDialog();
        }

        private void OpenUrl(string url) { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }

        private async void RefreshReader()
        {
            try
            {
                string[] info = await Task.Run(() => DesktopPlatform.ReaderInfo());
                if (closed) return;
                lastReader = info.Length == 0 ? "" : info[0];
                Text("ReaderStatus", lastReader == "Ready" ? "PixelReader ready" : lastReader == "Missing" ? "Pair your PC" : lastReader == "Disabled" ? "Reader disabled" : "Status unavailable");
                Text("ExpiryStatus", info.Length > 1 ? (info[1] == "No expiry date" ? info[1] : "Password expires " + info[1]) : "Windows local account");
                Text("PairingStatus", lastReader == "Ready" ? (setupNotice ?? "The Windows reader is enabled. Existing installations can update their phone over USB for filtered sharing.") : "Pair your Pixel on this PC to enable read-only sharing.");
            }
            catch (Exception) { if (!closed) { Text("ReaderStatus", "Status unavailable"); Text("ExpiryStatus", "Open Setup to check pairing."); } }
        }

        private async void GiveAccess()
        {
            if (!Idle || folder == null) return;
            if (MessageBox.Show(window, "Grant PixelReader persistent NTFS read access to this folder and its inheriting files?\n\n" + folder, "Allow folder access", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
            var operation = Begin("Preparing folder access", "Windows may request administrator approval.", false);
            try
            {
                string selected = folder;
                await Task.Run(() => DesktopPlatform.RunScript(Path.Combine(windowsDirectory, "Initialize-PixelReader.ps1"), true, false, "-LibraryPath", selected, "-ExistingReaderOnly"));
                Status("Folder access ready", "PixelReader can read files that inherit this folder’s permissions.");
            }
            catch (OperationCanceledException) { Status("Folder access canceled", "Your selection is still available."); }
            catch (Exception ex) { Error("Could not grant access", ex); }
            finally { End(operation); }
        }

        private async void SetupPhone(bool firstPair)
        {
            if (!Idle) return;
            string adb = DesktopPlatform.FindAdb(window);
            if (adb == null) return;
            var args = new List<string> { "-Adb", adb };
            if (firstPair)
            {
                string path = DesktopPlatform.PickFolder("Choose the local photo folder PixelReader should be allowed to read");
                if (path == null) return;
                string[] addresses = DesktopPlatform.LanAddresses();
                if (addresses.Length == 0) { MessageBox.Show(window, "Connect your PC to the same network as the Pixel.", "Pair Pixel"); return; }
                string ip = DesktopPlatform.Prompt(window, "Pair Pixel", "Select this PC’s home-network address. Keep the Pixel unlocked and connected by USB.", null, addresses);
                if (ip == null) return;
                if (MessageBox.Show(window, "Pair this PC with your original Pixel and give the dedicated Windows reader read access to:\n\n" + path + "\n\nThe phone will use " + ip + " over Wi-Fi.", "Pair Pixel", MessageBoxButton.OKCancel, MessageBoxImage.Information, MessageBoxResult.Cancel) != MessageBoxResult.OK) return;
                args.AddRange(new[] { "-ComputerAddress", ip, "-LibraryPath", path });
            }
            var operation = Begin(firstPair ? "Pairing Pixel" : "Updating phone watcher", "Keep the Pixel connected and unlocked.", false);
            Text("PairingStatus", "Working over USB. Check the phone for debugging or root prompts.");
            try
            {
                string script = Path.Combine(windowsDirectory, firstPair ? "Pair-PixelDesktop.ps1" : "Update-PixelWatcher.ps1");
                await Task.Run(() => DesktopPlatform.RunScript(script, firstPair, true, args.ToArray()));
                setupNotice = firstPair ? "USB pairing completed. Your Pixel is ready for Wi-Fi sharing." : "The filtered watcher is installed on the Pixel.";
                RefreshReader();
                Text("PairingStatus", setupNotice);
                Status("Pixel ready", "Choose a folder to scan.");
            }
            catch (OperationCanceledException) { Text("PairingStatus", "Windows approval canceled."); }
            catch (Exception ex) { Text("PairingStatus", ex.GetBaseException().Message); Error("Pixel setup needs attention", ex); }
            finally { End(operation); }
        }

        private void OnClosing(object sender, CancelEventArgs e)
        {
            if (session == null && work == null) return;
            e.Cancel = true;
            if (closeRequested) return;
            string text = session != null ? "Stop sharing and close Pixel Backup?" : canCancel ? "Cancel this operation and close Pixel Backup?" : "Close Pixel Backup when the current operation finishes?";
            if (MessageBox.Show(window, text, "Close Pixel Backup", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
            closeRequested = true;
            if (session != null) StopShare();
            if (work != null && canCancel) work.Cancel();
        }
    }
}
