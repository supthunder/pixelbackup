using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Threading;

namespace PixelBackup
{
    public sealed class DesktopApp
    {
        private readonly Window window;
        private readonly string windowsDirectory;
        private readonly Func<string, ScanResult, CancellationToken, IProgress<string>, PlanSession> startSession;
        private readonly Func<string[]> readerInfo;
        private readonly DispatcherTimer timer;
        private string folder;
        private ScanResult scan;
        private CancellationTokenSource work;
        private bool setupWork, canCancel, stopping, closeRequested, closed;
        private PlanSession session;
        private int usbToolsRevision, readerRevision;
        private bool readerChecked, needsSetup;

        public DesktopApp(Window window, string windowsDirectory)
            : this(window, windowsDirectory, PlanSession.Start) { }

        internal DesktopApp(Window window, string windowsDirectory,
            Func<string, ScanResult, CancellationToken, IProgress<string>, PlanSession> startSession,
            Func<string[]> readerInfo = null)
        {
            this.window = window;
            window.Dispatcher.VerifyAccess();
            if (!(SynchronizationContext.Current is DispatcherSynchronizationContext))
                SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(window.Dispatcher));
            this.windowsDirectory = Path.GetFullPath(windowsDirectory);
            this.startSession = startSession;
            this.readerInfo = readerInfo ?? DesktopPlatform.ReaderInfo;

            Wire("ChooseFolder", ChooseFolder);
            Wire("ShareButton", delegate { if (session == null) StartShare(); else StopShare(); });
            Wire("ScanButton", Rescan);
            Wire("CancelButton", CancelWork);
            Wire("CancelSetup", CancelWork);
            Wire("PairPhone", () => SetupUsb(UsbAction.Pair));
            Wire("UpdateWatcher", () => SetupUsb(UsbAction.Update));
            Wire("GetUsbTools", () => SetupUsb(UsbAction.Prepare));
            Wire("BrowseAdb", BrowseAdb);
            Wire("AccessButton", GiveAccess);
            Wire("OpenGuide", OpenSetupGuide);
            var drop = Control<Border>("FolderDropSurface");
            drop.PreviewDragOver += PreviewFolderDrop;
            drop.DragLeave += delegate { drop.Tag = null; };
            drop.PreviewDrop += DropFolder;
            Control<Expander>("SetupExpander").Expanded += (sender, e) =>
            {
                if (!ReferenceEquals(e.OriginalSource, sender)) return;
                if (readerChecked) RefreshReader();
                RefreshUsbTools();
            };

            RefreshButtons();
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
        private void Text(string name, string text, bool announce = true)
        {
            var label = Control<TextBlock>(name);
            if (label.Text == text) return;
            label.Text = text;
            if (announce && label.IsVisible && AutomationProperties.GetLiveSetting(label) != AutomationLiveSetting.Off &&
                AutomationPeer.ListenerExists(AutomationEvents.LiveRegionChanged))
            {
                var peer = UIElementAutomationPeer.CreatePeerForElement(label);
                if (peer != null) peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
            }
        }
        private void Status(string title, string detail)
        {
            Control<FrameworkElement>("StatusArea").Visibility = Visibility.Visible;
            Text("StatusText", title);
            Text("StatusDetail", detail ?? "");
        }

        private void Error(string title, Exception error) { Status(title, error.GetBaseException().Message); }

        private void RefreshButtons()
        {
            bool idle = Idle && !closeRequested;
            bool selected = folder != null;
            bool cancel = work != null && canCancel && !work.IsCancellationRequested;
            var choose = Control<Button>("ChooseFolder");
            choose.IsEnabled = idle;
            choose.Content = selected ? "Change folder…" : "Choose folder…";
            choose.Style = (Style)window.FindResource(selected ? "QuietButton" : "PrimaryButton");

            var share = Control<Button>("ShareButton");
            share.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
            share.IsEnabled = (session != null && !stopping && !closeRequested) || (idle && !needsSetup && scan != null && scan.Items.Count > 0);
            share.Content = session == null ? "Start sharing" : stopping ? "Stopping…" : "Stop sharing";
            share.ToolTip = needsSetup && session == null ? "Finish Pixel setup below to start sharing." : null;
            Control<FrameworkElement>("FilesExpander").Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
            Control<Button>("ScanButton").IsEnabled = idle && selected;
            Control<Button>("CancelButton").Visibility = cancel && !setupWork ? Visibility.Visible : Visibility.Collapsed;
            Control<Button>("CancelSetup").Visibility = cancel && setupWork ? Visibility.Visible : Visibility.Collapsed;
            var bar = Control<ProgressBar>("ProgressBar");
            bar.IsIndeterminate = work != null && !setupWork;
            bar.Visibility = bar.IsIndeterminate ? Visibility.Visible : Visibility.Collapsed;
            foreach (string name in new[] { "PairPhone", "UpdateWatcher", "BrowseAdb", "GetUsbTools" })
                Control<Button>(name).IsEnabled = idle;
            Control<Button>("AccessButton").IsEnabled = idle && selected && CanGrant(folder);
        }

        private static bool CanGrant(string path)
        {
            try { return new DirectoryInfo(path).Parent != null && string.Equals(new DriveInfo(Path.GetPathRoot(path)).DriveFormat, "NTFS", StringComparison.OrdinalIgnoreCase); }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }

        private CancellationTokenSource Begin(string title, string detail, bool cancellable, bool setup = false)
        {
            work = new CancellationTokenSource();
            canCancel = cancellable;
            setupWork = setup;
            if (setup) Text("SetupStatus", detail);
            else Status(title, detail);
            RefreshButtons();
            return work;
        }

        private void End(CancellationTokenSource operation)
        {
            if (work != operation) return;
            work = null; setupWork = false; canCancel = false; operation.Dispose();
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
            return new ThrottledProgress(window.Dispatcher, s => { if (work == operation && !closed) Text(element, s, false); });
        }

        private void ChooseFolder()
        {
            string path = DesktopPlatform.PickFolder(window, "Choose a folder of photos and videos");
            if (path != null) SelectFolder(path);
        }

        private static string DroppedFolder(IDataObject data)
        {
            if (!data.GetDataPresent(DataFormats.FileDrop, false)) return null;
            var paths = data.GetData(DataFormats.FileDrop, false) as string[];
            if (paths == null || paths.Length != 1 || string.IsNullOrEmpty(paths[0])) return null;
            string path = MediaScanner.LocalPath(paths[0]);
            return Directory.Exists(path) ? path : null;
        }

        private void PreviewFolderDrop(object sender, DragEventArgs e)
        {
            ((Border)sender).Tag = ReadFolderDrag(e) != null ? "Dragging" : null;
        }

        private void DropFolder(object sender, DragEventArgs e)
        {
            ((Border)sender).Tag = null;
            string path = ReadFolderDrag(e);
            if (path != null) SelectFolder(path);
        }

        private string ReadFolderDrag(DragEventArgs e)
        {
            e.Handled = true;
            e.Effects = DragDropEffects.None;
            var allowed = e.AllowedEffects & (DragDropEffects.Link | DragDropEffects.Copy);
            if (!Idle || allowed == DragDropEffects.None) return null;
            string path;
            try { path = DroppedFolder(e.Data); }
            catch (ArgumentException) { return null; }
            catch (System.Runtime.InteropServices.ExternalException) { return null; }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
            if (path != null) e.Effects = (allowed & DragDropEffects.Link) != 0 ? DragDropEffects.Link : DragDropEffects.Copy;
            return path;
        }

        private void CancelWork()
        {
            if (work == null || !canCancel) return;
            work.Cancel();
            Text(setupWork ? "SetupStatus" : "StatusDetail", "Canceling…");
            RefreshButtons();
        }

        public void SelectFolder(string absolutePath)
        {
            if (!Idle || closeRequested) return;
            folder = Path.GetFullPath(absolutePath);
            var directory = new DirectoryInfo(folder);
            Text("SourceName", directory.Parent == null ? directory.FullName : directory.Name);
            Text("FolderPath", folder);
            Control<TextBlock>("FolderPath").ToolTip = folder;
            Control<Expander>("FilesExpander").IsExpanded = false;
            Rescan();
        }

        private async void Rescan()
        {
            if (!Idle || folder == null) return;
            scan = null;
            Control<DataGrid>("FileTable").ItemsSource = null;
            Control<FrameworkElement>("NotesExpander").Visibility = Visibility.Collapsed;
            Text("FileSummary", "Reading folder…");
            var operation = Begin("Reading folder", "Looking for photos and videos.", true);
            var progress = Progress(operation, "StatusDetail");
            try
            {
                string selected = folder;
                var result = await Task.Run(() => MediaScanner.Scan(selected, operation.Token, progress));
                operation.Token.ThrowIfCancellationRequested();
                scan = result;
                Control<DataGrid>("FileTable").ItemsSource = result.Items;
                Control<ItemsControl>("NotesList").ItemsSource = result.Warnings;
                Control<FrameworkElement>("NotesExpander").Visibility = result.Warnings.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
                string size = MediaEntry.FormatSize(result.Items.Sum(item => (decimal)item.Bytes));
                string summary = result.Items.Count.ToString("N0") + (result.Items.Count == 1 ? " file" : " files") + "  ·  " + size;
                if (result.SkippedCount > 0) summary += "  ·  " + result.SkippedCount.ToString("N0") + " skipped";
                Text("FileSummary", summary);
                if (result.Items.Count == 0)
                    Status("No photos or videos to share", result.Warnings.Count > 0 ? "See the folder notes below or choose another folder." : "Choose a folder containing supported photos or videos.");
                else
                    Control<FrameworkElement>("StatusArea").Visibility = Visibility.Collapsed;
            }
            catch (OperationCanceledException) { scan = null; Text("FileSummary", "Canceled"); Status("Folder scan canceled", "Refresh the file list to try again."); }
            catch (Exception ex) { scan = null; Text("FileSummary", "Unavailable"); Error("Could not read this folder", ex); }
            finally { End(operation); }
        }

        public async void StartShare()
        {
            if (!Idle || closeRequested || needsSetup || scan == null || scan.Items.Count == 0) return;
            var selected = scan;
            var operation = Begin("Opening the share", "Windows may ask for permission to share this folder.", true);
            var progress = Progress(operation, "StatusDetail");
            try
            {
                session = await Task.Run(() => startSession(windowsDirectory, selected, operation.Token, progress));
                Status("Opening the share", "Keep this PC awake while the Pixel reads your files.");
                Poll();
            }
            catch (OperationCanceledException) { Status("Sharing canceled", "Your folder is still selected."); }
            catch (Exception ex) { Error("Could not start sharing", ex); }
            finally { End(operation); }
        }

        public void StopShare()
        {
            if (session == null || stopping) return;
            try
            {
                session.Stop();
                stopping = true;
                Status("Stopping sharing", "Disconnecting the folder from the Pixel.");
                RefreshButtons();
            }
            catch (Exception ex) { Error("Could not stop sharing", ex); }
        }

        private void Poll()
        {
            if (session == null) return;
            SessionStatus state;
            try { state = session.Poll(); }
            catch (Exception ex) { Status("Checking the share", ex.GetBaseException().Message); return; }
            if (state.State == "Starting") return;
            if (state.State == "Ready")
            {
                Control<FrameworkElement>("ConnectionLine").Tag = state.PixelSeen ? "Reading" : "Sharing";
                if (!stopping)
                {
                    if (state.PixelSeen) Status("Pixel opened the share", "Check Google Photos on the Pixel for backup progress.");
                    else Status("Waiting for the Pixel", "Keep this PC awake and the paired Pixel on the same network.");
                }
                return;
            }
            if (state.State != "Closed" && state.State != "Error") return;
            var finished = session;
            session = null;
            stopping = false;
            Control<FrameworkElement>("ConnectionLine").Tag = null;
            try { finished.Dispose(); }
            catch (Exception ex) { state.CleanupComplete = false; state.Message = (state.Message + " " + ex.GetBaseException().Message).Trim(); }
            if (state.State == "Closed" && state.CleanupComplete)
                Status("Sharing stopped", "You can share this folder again or choose another one.");
            else Status("Sharing ended", state.Message);
            RefreshButtons();
            if (closeRequested && work == null) window.Dispatcher.BeginInvoke(new Action(() => window.Close()));
        }

        private void OpenSetupGuide()
        {
            string guide = Path.GetFullPath(Path.Combine(windowsDirectory, @"..\docs\PC_FOLDER.md"));
            if (!File.Exists(guide)) throw new FileNotFoundException("The setup guide is missing from this installation.", guide);
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(guide) { UseShellExecute = true }); }
            catch (Win32Exception ex)
            {
                if (ex.NativeErrorCode != 1155) throw;
                System.Diagnostics.Process.Start(Path.Combine(Environment.SystemDirectory, "notepad.exe"), DesktopPlatform.Quote(guide));
            }
        }

        private async void RefreshReader()
        {
            int version = ++readerRevision;
            try
            {
                string[] info = await Task.Run(readerInfo);
                if (closed || version != readerRevision) return;
                string state = info.Length == 0 ? "" : info[0];
                bool saved = state == "Ready" && File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PixelBackup-Pairing", "PixelReader.clixml"));
                string summary;
                switch (state)
                {
                    case "Ready": summary = saved ? "Windows sharing is set up" : "Windows reader enabled"; break;
                    case "Missing": summary = "Pair your Pixel to get started"; break;
                    case "Disabled": summary = "Windows reader disabled"; break;
                    case "Expired": summary = "Windows reader password expired"; break;
                    case "Other": summary = "Check the dedicated Windows reader"; break;
                    default: summary = "Windows access unavailable"; break;
                }
                Text("SetupSummary", summary);
                Text("ExpiryStatus", info.Length > 1 && info[1] != "No expiry date" ? "Reader password expires " + info[1] : "");
                needsSetup = state == "Missing" || state == "Disabled" || state == "Expired" || state == "Other";
                if (!readerChecked)
                {
                    if (needsSetup) Control<Expander>("SetupExpander").IsExpanded = true;
                    readerChecked = true;
                }
                RefreshButtons();
            }
            catch (Exception) { if (!closed && version == readerRevision) Text("SetupSummary", "Windows access unavailable"); }
        }

        private async void GiveAccess()
        {
            if (!Idle || folder == null) return;
            if (MessageBox.Show(window, "Grant PixelReader persistent NTFS read access to this folder and its inheriting files?\n\n" + folder, "Allow folder access", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
            var operation = Begin("Preparing folder access", "Windows may request administrator approval.", false, true);
            try
            {
                string selected = folder;
                await Task.Run(() => DesktopPlatform.RunScript(Path.Combine(windowsDirectory, "Initialize-PixelReader.ps1"), true, false, "-LibraryPath", selected, "-ExistingReaderOnly"));
                Text("SetupStatus", "Folder access granted. The Pixel can read files that inherit its permissions.");
            }
            catch (OperationCanceledException) { Text("SetupStatus", "Folder access canceled."); }
            catch (Exception ex) { Text("SetupStatus", ex.GetBaseException().Message); }
            finally { End(operation); }
        }

        private enum UsbAction { Pair, Update, Prepare }

        private void UsbToolsFound(string path)
        {
            Text("UsbToolsStatus", path == null ? "Google USB tools are available to download." : "USB tools ready · " + path);
        }

        private async void RefreshUsbTools()
        {
            if (setupWork) return;
            int version = ++usbToolsRevision;
            try
            {
                string path = await Task.Run(() => AndroidTools.Find());
                if (closed || version != usbToolsRevision) return;
                UsbToolsFound(path);
                if (path == null || DesktopPlatform.Elevated)
                {
                    Text("UsbDeviceStatus", path == null ? "Set up USB tools to check the phone connection." : "Reopen Pixel Backup as a regular Windows app to check USB.");
                    return;
                }
                Text("UsbDeviceStatus", "Checking the USB connection…");
                string issue = await Task.Run(() => UsbPhone.Check(path));
                if (!closed && version == usbToolsRevision) Text("UsbDeviceStatus", issue ?? "Original Pixel connected by USB.");
            }
            catch (Exception ex) { if (!closed && version == usbToolsRevision) Text("UsbDeviceStatus", ex.GetBaseException().Message); }
        }

        private void BrowseAdb()
        {
            if (!Idle) return;
            try
            {
                var picker = new Microsoft.Win32.OpenFileDialog { Title = "Choose adb.exe from a Platform-Tools folder you trust", Filter = "Android Debug Bridge (adb.exe)|adb.exe", FileName = "adb.exe", CheckFileExists = true };
                if (picker.ShowDialog(window) != true) return;
                AndroidTools.Remember(picker.FileName);
                ++usbToolsRevision;
                UsbToolsFound(picker.FileName);
                Text("SetupStatus", "Saved these USB tools for pairing and updates.");
                RefreshUsbTools();
            }
            catch (Exception ex) { Text("SetupStatus", ex.GetBaseException().Message); }
        }

        private async void SetupUsb(UsbAction action)
        {
            if (!Idle) return;
            if (DesktopPlatform.Elevated)
            {
                Text("SetupStatus", "Close Pixel Backup and reopen it from your desktop as a regular Windows app to use USB setup.");
                return;
            }
            ++usbToolsRevision;
            var operation = Begin("Checking USB tools", "Looking for Android SDK Platform-Tools on this PC.", false, true);
            Text("SetupStatus", "Checking USB tools on this PC…");
            string pairedFolder = null;
            try
            {
                string adb = await Task.Run(() => AndroidTools.Find());
                operation.Token.ThrowIfCancellationRequested();
                if (closeRequested) return;
                if (adb == null)
                {
                    UsbToolsFound(null);
                    if (!DesktopPlatform.AcceptToolsDownload(window)) { Text("SetupStatus", "USB tools download canceled."); return; }
                    canCancel = true; RefreshButtons();
                    Text("SetupStatus", "Downloading Google's USB tools…");
                    var progress = new ThrottledProgress(window.Dispatcher, message => {
                        if (!closed && work == operation && canCancel && !operation.IsCancellationRequested) Text("SetupStatus", message, false);
                    });
                    adb = await Task.Run(() => AndroidTools.Install(operation.Token, progress));
                    operation.Token.ThrowIfCancellationRequested();
                    canCancel = false; RefreshButtons();
                }
                ++usbToolsRevision;
                UsbToolsFound(adb);
                if (closeRequested) return;
                if (action == UsbAction.Prepare)
                {
                    Text("SetupStatus", "USB tools ready. Connect your unlocked Pixel to pair or update its backup helper.");
                    return;
                }
                bool pair = action == UsbAction.Pair;
                Text("UsbDeviceStatus", "Checking the USB connection…");
                string issue = await Task.Run(() => UsbPhone.Check(adb));
                Text("UsbDeviceStatus", issue ?? "Original Pixel connected by USB.");
                if (closeRequested) return;
                if (issue != null)
                {
                    Text("SetupStatus", pair ? "When your Pixel is connected and unlocked, try pairing again." : "Choose Update backup helper when the connection is ready.");
                    return;
                }
                var args = new List<string> { "-Adb", adb };
                if (pair)
                {
                    string path = folder;
                    if (path == null || !Directory.Exists(path)) path = DesktopPlatform.PickFolder(window, "Choose the photo folder your Pixel can read");
                    if (path == null) { Text("SetupStatus", "Pairing canceled."); return; }
                    string ip = DesktopPlatform.ConfirmPairing(window, ref path);
                    if (ip == null) { Text("SetupStatus", "Pairing canceled."); return; }
                    args.AddRange(new[] { "-ComputerAddress", ip, "-LibraryPath", path });
                    pairedFolder = path;
                }
                Text("SetupStatus", pair ? "Pairing over USB. Keep the Pixel unlocked and allow its USB debugging and Magisk prompts." :
                    "Updating the backup helper over USB. Keep the Pixel unlocked and approve its Magisk prompt if asked.");
                string script = Path.Combine(windowsDirectory, pair ? "Pair-PixelDesktop.ps1" : "Update-PixelWatcher.ps1");
                await Task.Run(() => DesktopPlatform.RunSetupScript(script, args.ToArray()));
                Text("SetupStatus", pair ? "Pixel paired. You can start sharing your folder." : "Backup helper updated.");
                RefreshReader();
            }
            catch (OperationCanceledException) { if (!closed) Text("SetupStatus", "Setup canceled. You can try again here."); return; }
            catch (Exception ex) { if (!closed) Text("SetupStatus", ex.GetBaseException().Message); return; }
            finally { End(operation); }
            if (!closed && !closeRequested && pairedFolder != null && !string.Equals(folder, pairedFolder, StringComparison.OrdinalIgnoreCase))
                SelectFolder(pairedFolder);
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
