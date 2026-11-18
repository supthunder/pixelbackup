using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security;
using System.Security.Cryptography;
using System.Threading;

namespace PixelBackup
{
    public sealed class MediaEntry
    {
        private static readonly string[] SizeUnits = { "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };

        public string RelativePath { get; set; }
        public string FullPath { get; set; }
        public long Bytes { get; set; }
        public string SizeText
        {
            get
            {
                double size = Bytes;
                int unit = 0;
                while (size >= 1024 && unit < SizeUnits.Length - 1)
                {
                    size /= 1024;
                    unit++;
                }
                return size.ToString("0.#", CultureInfo.CurrentCulture) + " " + SizeUnits[unit];
            }
        }
        public long LastWriteUtcTicks { get; set; }
        public string Sha256 { get; set; }
        public string Decision { get; set; }
        public string Match { get; set; }
    }

    public sealed class ScanResult
    {
        public string Folder { get; private set; }
        public List<MediaEntry> Items { get; private set; }
        public List<string> Warnings { get; private set; }
        // A skipped directory counts as one entry regardless of its contents.
        public int SkippedCount { get; internal set; }

        public ScanResult(string folder)
        {
            Folder = folder;
            Items = new List<MediaEntry>();
            Warnings = new List<string>();
        }

        internal void Skip(string path, string reason)
        {
            SkippedCount++;
            Warnings.Add(path + " — " + reason);
        }
    }

    public static class MediaScanner
    {
        private static readonly HashSet<string> ImageExtensions = new HashSet<string>(
            (".jpg .jpeg .jpe .heic .heif .png .webp .gif .avif " +
             ".dng .cr2 .cr3 .crw .nef .nrw .arw .srf .sr2 .raf .orf .rw2 .raw " +
             ".pef .rwl .3fr .fff .iiq .x3f").Split(' '), StringComparer.OrdinalIgnoreCase);
        private static readonly HashSet<string> VideoExtensions = new HashSet<string>(
            (".mpg .mpeg .mod .mmv .tod .wmv .asf .avi .divx .mov .m4v .3gp .3gpp " +
             ".3g2 .3gpp2 .mp4 .m2t .m2ts .mts .mkv").Split(' '), StringComparer.OrdinalIgnoreCase);
        private static readonly char[] InvalidNameChars = Path.GetInvalidFileNameChars();
        private static readonly byte[] Empty = new byte[0];
        private const long PhotoLimit = 200L * 1024 * 1024;
        private const long VideoLimit = 10L * 1024 * 1024 * 1024;

        // This predicate also accepts names from a Takeout ZIP. Camera models,
        // pixel dimensions and codecs are ultimately checked by Google Photos.
        public static bool IsMediaFile(string path)
        {
            if (string.IsNullOrEmpty(path)) return false;
            int start = Math.Max(path.LastIndexOf('/'), path.LastIndexOf('\\')) + 1;
            string name = path.Substring(start);
            if (!IsPlainName(name) || name[0] == '.') return false;
            string ext = Path.GetExtension(name);
            return ImageExtensions.Contains(ext) || VideoExtensions.Contains(ext);
        }

        public static ScanResult Scan(string folder, IDictionary<string, string> known,
            CancellationToken token, IProgress<string> progress)
        {
            token.ThrowIfCancellationRequested();
            string root = LocalPath(folder);
            if ((CheckPath(root) & FileAttributes.Directory) == 0)
                throw new IOException("Select a folder on this PC.");
            var result = new ScanResult(root);
            var pending = new Stack<string>();
            pending.Push(root);
            string prefix = root.TrimEnd('\\') + "\\";
            var buffer = new byte[256 * 1024];
            var clock = Stopwatch.StartNew();
            if (progress != null) progress.Report("Scanning " + root);

            while (pending.Count != 0)
            {
                token.ThrowIfCancellationRequested();
                string path = pending.Pop();
                string relative = path == root ? "." : path.Substring(prefix.Length).Replace('\\', '/');
                try
                {
                    CheckPath(path);
                    if (HasNoMedia(path))
                    {
                        result.Skip(relative, "Skipped this folder and its contents because it contains .nomedia.");
                        continue;
                    }
                    foreach (string file in Directory.EnumerateFileSystemEntries(path))
                    {
                        token.ThrowIfCancellationRequested();
                        string child = file.Substring(prefix.Length).Replace('\\', '/');
                        try
                        {
                            string name = Path.GetFileName(file);
                            if (!IsPlainName(name))
                            {
                                result.Skip(child, "Unsupported characters or reserved name.");
                                continue;
                            }
                            var attributes = File.GetAttributes(file);
                            if ((attributes & FileAttributes.ReparsePoint) != 0)
                            {
                                result.Skip(child, "Skipped a reparse point or cloud placeholder.");
                                continue;
                            }
                            if (name[0] == '.')
                            {
                                result.SkippedCount++;
                                continue;
                            }
                            if ((attributes & FileAttributes.Directory) != 0)
                            {
                                pending.Push(file);
                                continue;
                            }
                            if (!IsMediaFile(name))
                            {
                                result.SkippedCount++;
                                continue;
                            }
                            result.Items.Add(HashFile(file, child, buffer, token, progress, clock));
                        }
                        catch (Exception ex)
                        {
                            if (!IsFileError(ex)) throw;
                            result.Skip(child, ex.Message);
                        }
                    }
                }
                catch (Exception ex)
                {
                    if (!IsFileError(ex)) throw;
                    result.Skip(relative, "Could not finish reading this folder. " + ex.Message);
                }
            }

            token.ThrowIfCancellationRequested();
            result.Items.Sort((a, b) => StringComparer.Ordinal.Compare(a.RelativePath, b.RelativePath));
            var first = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (MediaEntry entry in result.Items)
            {
                token.ThrowIfCancellationRequested();
                string match;
                if (known != null && known.TryGetValue(entry.Sha256, out match))
                {
                    entry.Decision = "Known copy";
                    entry.Match = string.IsNullOrEmpty(match) ? "Known library" : match;
                }
                else if (first.TryGetValue(entry.Sha256, out match))
                {
                    entry.Decision = "Folder copy";
                    entry.Match = match;
                }
                else
                {
                    first.Add(entry.Sha256, entry.RelativePath);
                    entry.Decision = "Ready";
                    entry.Match = "";
                }
            }
            token.ThrowIfCancellationRequested();
            if (progress != null) progress.Report("Scanned " + result.Items.Count + " media files.");
            return result;
        }

        private static MediaEntry HashFile(string path, string relative, byte[] buffer,
            CancellationToken token, IProgress<string> progress, Stopwatch clock)
        {
            CheckPath(path);
            using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
                                              64 * 1024, FileOptions.SequentialScan))
            using (var hash = SHA256.Create())
            {
                long length = file.Length;
                if (length == 0) throw new IOException("The media file is empty.");
                if (ImageExtensions.Contains(Path.GetExtension(path)) ? length > PhotoLimit : length > VideoLimit)
                    throw new IOException("The file exceeds the Google Photos size limit for this media type.");
                long stamp = File.GetLastWriteTimeUtc(path).Ticks;
                long total = 0;
                int read;
                while ((read = file.Read(buffer, 0, buffer.Length)) != 0)
                {
                    token.ThrowIfCancellationRequested();
                    hash.TransformBlock(buffer, 0, read, buffer, 0);
                    total += read;
                    if (progress != null && clock.ElapsedMilliseconds >= 250)
                    {
                        progress.Report(string.Format(CultureInfo.CurrentCulture,
                            "Reading {0} ({1:P0})", relative, (double)total / length));
                        clock.Restart();
                    }
                }
                token.ThrowIfCancellationRequested();
                hash.TransformFinalBlock(Empty, 0, 0);
                CheckPath(path);
                if (total != length || File.GetLastWriteTimeUtc(path).Ticks != stamp)
                    throw new IOException("The file changed while it was being read. Scan it again.");
                return new MediaEntry
                {
                    FullPath = path, RelativePath = relative, Bytes = total, LastWriteUtcTicks = stamp,
                    Sha256 = BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant()
                };
            }
        }

        // A quick metadata check. The publisher rehashes before opening a session.
        public static bool IsCurrent(MediaEntry entry)
        {
            if (entry == null || string.IsNullOrEmpty(entry.RelativePath)) return false;
            try
            {
                string path = LocalPath(entry.FullPath);
                string suffix = "\\" + entry.RelativePath.Replace('/', '\\');
                if (!path.EndsWith(suffix, StringComparison.Ordinal) || !IsMediaFile(path)) return false;
                CheckPath(path);
                var file = new FileInfo(path);
                if (!file.Exists || file.Length != entry.Bytes || file.LastWriteTimeUtc.Ticks != entry.LastWriteUtcTicks)
                    return false;
                // Check .nomedia up to the root originally selected. The phone
                // never sees Windows directories above that selection.
                int rootLength = path.Length - suffix.Length;
                for (var parent = file.Directory; parent != null && parent.FullName.Length >= rootLength; parent = parent.Parent)
                    if (HasNoMedia(parent.FullName)) return false;
                return true;
            }
            catch (Exception ex)
            {
                if (!IsFileError(ex)) throw;
                return false;
            }
        }

        internal static string LocalPath(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) throw new ArgumentException("Select a local Windows folder.");
            path = path.Replace('/', '\\');
            if (path.Length < 3 || path[1] != ':' || path[2] != '\\' ||
                !((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')))
                throw new ArgumentException("Select an absolute path on a local drive.");
            foreach (string component in path.Substring(3).Split(new[] { '\\' }, StringSplitOptions.RemoveEmptyEntries))
                if (!IsPlainName(component)) throw new ArgumentException("Unsupported Windows path component: " + component);
            var drive = new DriveInfo(path.Substring(0, 3));
            if (drive.DriveType != DriveType.Fixed && drive.DriveType != DriveType.Removable)
                throw new IOException("Select a folder on a local fixed or removable drive.");
            string full = Path.GetFullPath(path);
            return full.Length == 3 ? full : full.TrimEnd('\\');
        }

        private static bool IsPlainName(string name)
        {
            if (name.Length == 0 || name.IndexOfAny(InvalidNameChars) >= 0 ||
                name.EndsWith(".", StringComparison.Ordinal) || name.EndsWith(" ", StringComparison.Ordinal))
                return false;
            foreach (char c in name)
                if (char.IsControl(c)) return false;
            string device = name.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
            if (device == "CON" || device == "PRN" || device == "AUX" || device == "NUL" ||
                device == "CONIN$" || device == "CONOUT$") return false;
            return !(device.Length == 4 && (device.StartsWith("LPT", StringComparison.Ordinal) ||
                device.StartsWith("COM", StringComparison.Ordinal)) && "123456789¹²³".IndexOf(device[3]) >= 0);
        }

        private static FileAttributes CheckPath(string path)
        {
            // Check ancestors from the drive down before asking Windows for
            // attributes of anything underneath a possible junction.
            int end = Path.GetPathRoot(path).Length;
            while (true)
            {
                string current = path.Substring(0, end);
                FileAttributes attributes = File.GetAttributes(current);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("A reparse point is outside the supported source tree: " + current);
                if (end == path.Length) return attributes;
                int separator = path.IndexOf('\\', end + 1);
                end = separator < 0 ? path.Length : separator;
            }
        }

        private static bool HasNoMedia(string directory)
        {
            try { File.GetAttributes(Path.Combine(directory, ".nomedia")); return true; }
            catch (FileNotFoundException) { return false; }
        }

        private static bool IsFileError(Exception ex)
        {
            return ex is IOException || ex is UnauthorizedAccessException || ex is SecurityException ||
                   ex is ArgumentException || ex is NotSupportedException;
        }
    }
}
