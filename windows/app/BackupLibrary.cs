using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace PixelBackup
{
    internal sealed class TakeoutDuplicateGroup
    {
        public string Sha256 { get; private set; }
        public int FileCount { get; private set; }
        public IList<string> Paths { get; private set; }

        internal TakeoutDuplicateGroup(string sha256, int fileCount, List<string> paths)
        {
            Sha256 = sha256;
            FileCount = fileCount;
            Paths = paths.AsReadOnly();
        }
    }

    internal sealed class TakeoutImportResult
    {
        public int Files { get; private set; }
        public int Added { get; private set; }
        public int DuplicateGroups { get; private set; }
        public int DuplicatePaths { get; private set; }
        public IList<TakeoutDuplicateGroup> DuplicatePreview { get; private set; }

        internal TakeoutImportResult(int files, int added, int groups, int paths, List<TakeoutDuplicateGroup> preview)
        {
            Files = files;
            Added = added;
            DuplicateGroups = groups;
            DuplicatePaths = paths;
            DuplicatePreview = preview.AsReadOnly();
        }
    }

    // Use a separate state directory for each Google Photos account. A Takeout
    // record is historical evidence about exact bytes in an export.
    internal sealed class BackupLibrary
    {
        private const int ApplicationId = 0x50424731;
        private const int Version = 1;
        private const int PreviewGroups = 50;
        private const int PreviewPaths = 5;
        private const string DuplicateQuery =
            "SELECT sha, count(*) AS paths FROM takeout_path GROUP BY sha HAVING count(*) > 1";
        private static readonly HashSet<string> ExcludedSections = new HashSet<string>(
            new[] { "Trash", "Trashed", "Bin", "Failed Videos" }, StringComparer.OrdinalIgnoreCase);
        private readonly string catalogPath;

        public BackupLibrary(string stateDirectory)
        {
            var directory = Directory.CreateDirectory(stateDirectory);
            catalogPath = Path.Combine(directory.FullName, "backup-library.sqlite3");
            Initialize();
        }

        private void Initialize()
        {
            bool exists = File.Exists(catalogPath);
            using (var db = new CatalogDatabase(catalogPath, true))
            {
                db.Execute("BEGIN IMMEDIATE");
                long appId = db.Scalar("PRAGMA application_id");
                long version = db.Scalar("PRAGMA user_version");
                if (!exists && appId == 0 && version == 0 && db.Scalar("SELECT count(*) FROM sqlite_master") == 0)
                {
                    db.Execute("CREATE TABLE fingerprint (sha TEXT NOT NULL PRIMARY KEY CHECK(length(sha) = 64), " +
                        "takeout INTEGER NOT NULL CHECK(takeout IN (0, 1)), " +
                        "confirmed INTEGER NOT NULL CHECK(confirmed IN (0, 1)), CHECK(takeout + confirmed > 0)) WITHOUT ROWID");
                    db.Execute("CREATE TABLE takeout_path (source TEXT COLLATE NOCASE NOT NULL, " +
                        "archive INTEGER NOT NULL CHECK(archive IN (0, 1)), item TEXT NOT NULL, " +
                        "sha TEXT NOT NULL REFERENCES fingerprint(sha), bytes INTEGER NOT NULL CHECK(bytes > 0), " +
                        "PRIMARY KEY(source, archive, item)) WITHOUT ROWID");
                    db.Execute("CREATE INDEX takeout_digest ON takeout_path(sha)");
                    db.Execute("PRAGMA application_id = " + ApplicationId);
                    db.Execute("PRAGMA user_version = " + Version);
                }
                else if (appId != ApplicationId || version != Version)
                {
                    throw new InvalidDataException("The local backup catalog has an unrecognized format.");
                }
                using (var check = db.Prepare("PRAGMA quick_check(1)"))
                {
                    if (!check.Read() || check.GetText(0) != "ok")
                        throw new InvalidDataException("The local backup catalog failed an integrity check.");
                }
                db.Execute("COMMIT");
            }
        }

        public int Count
        {
            get
            {
                using (var db = new CatalogDatabase(catalogPath, false))
                    return checked((int)db.Scalar("SELECT count(*) FROM fingerprint"));
            }
        }

        public IDictionary<string, string> Snapshot()
        {
            var result = new Dictionary<string, string>(StringComparer.Ordinal);
            using (var db = new CatalogDatabase(catalogPath, false))
            using (var query = db.Prepare("SELECT sha, takeout, confirmed FROM fingerprint"))
            {
                while (query.Read())
                {
                    string sha = query.GetText(0);
                    if (!IsSha256(sha))
                        throw new InvalidDataException("The local backup catalog contains an invalid fingerprint.");
                    bool takeout = query.GetInteger(1) == 1;
                    bool confirmed = query.GetInteger(2) == 1;
                    string label = takeout ? "Google Takeout snapshot" : "Manually confirmed in Google Photos";
                    if (takeout && confirmed)
                        label += " and manually confirmed";
                    result.Add(sha, label);
                }
            }
            return result;
        }

        public int Confirm(IEnumerable<MediaEntry> entries)
        {
            if (entries == null) throw new ArgumentNullException("entries");
            using (var db = new CatalogDatabase(catalogPath, false))
            {
                db.Execute("BEGIN IMMEDIATE");
                int confirmed = 0;
                using (var insert = db.Prepare("INSERT OR IGNORE INTO fingerprint VALUES (?1, 0, 1)"))
                using (var update = db.Prepare("UPDATE fingerprint SET confirmed = 1 WHERE sha = ?1 AND confirmed = 0"))
                {
                    foreach (MediaEntry entry in entries)
                    {
                        if (entry == null || !IsSha256(entry.Sha256))
                            throw new ArgumentException("Confirming a session requires an exact SHA-256 for each item.", "entries");
                        insert.Bind(1, entry.Sha256);
                        insert.ExecuteAndReset();
                        confirmed += db.Changes;
                        update.Bind(1, entry.Sha256);
                        update.ExecuteAndReset();
                        confirmed += db.Changes;
                    }
                }
                db.Execute("COMMIT");
                return confirmed;
            }
        }

        public void Clear()
        {
            using (var db = new CatalogDatabase(catalogPath, false))
            {
                db.Execute("PRAGMA secure_delete = ON");
                db.Execute("BEGIN IMMEDIATE");
                db.Execute("DELETE FROM takeout_path");
                db.Execute("DELETE FROM fingerprint");
                db.Execute("COMMIT");
            }
        }

        public TakeoutImportResult ImportFolder(string extractedPhotosFolder, CancellationToken cancellationToken, IProgress<string> progress)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var root = ResolvePhotosDirectory(extractedPhotosFolder);
            using (var db = OpenImport())
            {
                var reader = new TakeoutReader(db, cancellationToken, progress);
                using (reader)
                    reader.ReadFolder(root);
                return CommitImport(db, root.FullName, false, reader.Files, cancellationToken);
            }
        }

        public TakeoutImportResult ImportZip(string zipPath, CancellationToken cancellationToken, IProgress<string> progress)
        {
            cancellationToken.ThrowIfCancellationRequested();
            string path = Path.GetFullPath(zipPath);
            using (var db = OpenImport())
            {
                var reader = new TakeoutReader(db, cancellationToken, progress);
                using (reader)
                    reader.ReadZip(path);
                return CommitImport(db, path, true, reader.Files, cancellationToken);
            }
        }

        public TakeoutImportResult ReadAudit()
        {
            using (var db = new CatalogDatabase(catalogPath, false))
            {
                db.Execute("BEGIN");
                int files = checked((int)db.Scalar("SELECT count(*) FROM takeout_path"));
                TakeoutImportResult result = SummarizeImport(db, files, 0, CancellationToken.None);
                db.Execute("COMMIT");
                return result;
            }
        }

        private CatalogDatabase OpenImport()
        {
            var db = new CatalogDatabase(catalogPath, false);
            try
            {
                // Accumulate streamed hashes in a private SQLite temp table.
                // Take the catalog write lock only for the final merge.
                db.Execute("PRAGMA temp_store = FILE");
                db.Execute("CREATE TEMP TABLE imported (item TEXT NOT NULL PRIMARY KEY, sha TEXT NOT NULL, bytes INTEGER NOT NULL) WITHOUT ROWID");
                return db;
            }
            catch
            {
                db.Dispose();
                throw;
            }
        }

        private static TakeoutImportResult CommitImport(CatalogDatabase db, string source, bool archive, int files, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            db.Execute("BEGIN IMMEDIATE");
            db.Execute("INSERT OR IGNORE INTO fingerprint SELECT DISTINCT sha, 1, 0 FROM temp.imported");
            int added = db.Changes;
            db.Execute("UPDATE fingerprint SET takeout = 1 WHERE takeout = 0 AND sha IN (SELECT sha FROM temp.imported)");
            using (var delete = db.Prepare("DELETE FROM takeout_path WHERE source = ?1 AND archive = ?2"))
            using (var insert = db.Prepare("INSERT INTO takeout_path SELECT ?1, ?2, item, sha, bytes FROM temp.imported"))
            {
                delete.Bind(1, source);
                delete.Bind(2, archive ? 1 : 0);
                delete.ExecuteAndReset();
                insert.Bind(1, source);
                insert.Bind(2, archive ? 1 : 0);
                insert.ExecuteAndReset();
            }
            TakeoutImportResult result = SummarizeImport(db, files, added, token);
            token.ThrowIfCancellationRequested();
            db.Execute("COMMIT");
            return result;
        }

        private static TakeoutImportResult SummarizeImport(CatalogDatabase db, int files, int added, CancellationToken token)
        {
            var preview = new List<TakeoutDuplicateGroup>();
            int groups;
            int paths;
            using (var totals = db.Prepare("SELECT count(*), coalesce(sum(paths), 0) FROM (" + DuplicateQuery + ")"))
            {
                if (!totals.Read()) throw new InvalidDataException("Duplicate totals are unavailable.");
                groups = checked((int)totals.GetInteger(0));
                paths = checked((int)totals.GetInteger(1));
            }
            using (var duplicates = db.Prepare(DuplicateQuery + " ORDER BY sha LIMIT ?1"))
            using (var examples = db.Prepare("SELECT source, archive, item FROM takeout_path " +
                "WHERE sha = ?1 ORDER BY source, archive, item LIMIT ?2"))
            {
                duplicates.Bind(1, PreviewGroups);
                while (duplicates.Read())
                {
                    token.ThrowIfCancellationRequested();
                    string sha = duplicates.GetText(0);
                    var samplePaths = new List<string>();
                    examples.Bind(1, sha);
                    examples.Bind(2, PreviewPaths);
                    while (examples.Read()) samplePaths.Add(ReadExportPath(examples));
                    examples.Reset();
                    preview.Add(new TakeoutDuplicateGroup(sha, checked((int)duplicates.GetInteger(1)), samplePaths));
                }
            }
            return new TakeoutImportResult(files, added, groups, paths, preview);
        }

        public void WriteDuplicateReport(TextWriter writer)
        {
            if (writer == null) throw new ArgumentNullException("writer");
            writer.WriteLine("Identical files in recorded Google Photos exports");
            writer.WriteLine("Multiple export paths can represent a single item in Google Photos.");
            using (var db = new CatalogDatabase(catalogPath, false))
            using (var query = db.Prepare("SELECT p.source, p.archive, p.item, d.sha, d.paths, p.bytes " +
                "FROM (" + DuplicateQuery + ") AS d JOIN takeout_path AS p ON p.sha = d.sha " +
                "ORDER BY d.sha, p.source, p.archive, p.item"))
            {
                string previous = null;
                while (query.Read())
                {
                    string sha = query.GetText(3);
                    if (sha != previous)
                    {
                        writer.WriteLine();
                        writer.WriteLine("SHA-256 {0} ({1} export paths, {2} bytes each)", sha, query.GetInteger(4), query.GetInteger(5));
                        previous = sha;
                    }
                    writer.WriteLine("  " + ReadExportPath(query));
                }
            }
        }

        private static string ReadExportPath(CatalogStatement query)
        {
            string source = query.GetText(0);
            string item = query.GetText(2);
            if (query.GetInteger(1) != 0)
                return source + " :: " + item.Replace("\r", "\\r").Replace("\n", "\\n");
            return Path.Combine(source, item.Replace('/', Path.DirectorySeparatorChar));
        }

        private static DirectoryInfo ResolvePhotosDirectory(string path)
        {
            var directory = new DirectoryInfo(path);
            if (!directory.Exists) throw new DirectoryNotFoundException("Select an extracted Google Photos folder or album.");
            if (IsReparsePoint(directory)) throw new IOException("Select the extracted folder directly, without a directory link.");
            if (ExcludedSections.Contains(directory.Name))
                throw new InvalidDataException("Choose a Google Photos export folder or album outside Trash and Failed Videos.");
            if (String.Equals(directory.Name, "Google Photos", StringComparison.OrdinalIgnoreCase)) return directory;

            var direct = new DirectoryInfo(Path.Combine(directory.FullName, "Google Photos"));
            if (direct.Exists && !IsReparsePoint(direct)) return direct;
            var takeout = new DirectoryInfo(Path.Combine(directory.FullName, "Takeout"));
            if (takeout.Exists && !IsReparsePoint(takeout))
            {
                var photos = new DirectoryInfo(Path.Combine(takeout.FullName, "Google Photos"));
                if (photos.Exists && !IsReparsePoint(photos)) return photos;
            }
            if (direct.Exists || takeout.Exists || String.Equals(directory.Name, "Takeout", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Select the extracted Google Photos folder inside this Takeout export.");
            return directory;
        }

        private static bool IsReparsePoint(FileSystemInfo item)
        {
            return (item.Attributes & FileAttributes.ReparsePoint) != 0;
        }

        private static bool IsSha256(string value)
        {
            if (value == null || value.Length != 64) return false;
            foreach (char ch in value)
            {
                if ((ch < '0' || ch > '9') && (ch < 'a' || ch > 'f')) return false;
            }
            return true;
        }

        private sealed class TakeoutReader : IDisposable
        {
            private readonly CatalogStatement insert;
            private readonly CancellationToken token;
            private readonly IProgress<string> progress;
            private readonly byte[] buffer = new byte[1024 * 1024];

            public int Files { get; private set; }

            public TakeoutReader(CatalogDatabase db, CancellationToken token, IProgress<string> progress)
            {
                this.token = token;
                this.progress = progress;
                insert = db.Prepare("INSERT INTO temp.imported VALUES (?1, ?2, ?3)");
            }

            public void ReadFolder(DirectoryInfo root)
            {
                var remaining = new Stack<DirectoryInfo>();
                remaining.Push(root);
                string prefix = root.FullName.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
                while (remaining.Count > 0)
                {
                    token.ThrowIfCancellationRequested();
                    var directory = remaining.Pop();
                    foreach (FileSystemInfo entry in directory.EnumerateFileSystemInfos())
                    {
                        token.ThrowIfCancellationRequested();
                        if (IsReparsePoint(entry)) continue;
                        var child = entry as DirectoryInfo;
                        if (child != null)
                        {
                            if (directory != root || !ExcludedSections.Contains(child.Name)) remaining.Push(child);
                            continue;
                        }
                        if (!MediaScanner.IsMediaFile(entry.Name)) continue;
                        string item = entry.FullName.Substring(prefix.Length).Replace(Path.DirectorySeparatorChar, '/');
                        using (var stream = OpenRead(entry.FullName))
                            if (stream.Length > 0) ReadMedia(stream, item, stream.Length);
                    }
                }
            }

            public void ReadZip(string path)
            {
                bool photosFound = false;
                using (var stream = OpenRead(path))
                using (var zip = new ZipArchive(stream, ZipArchiveMode.Read))
                {
                    foreach (ZipArchiveEntry entry in zip.Entries)
                    {
                        token.ThrowIfCancellationRequested();
                        string item = entry.FullName.Replace('\\', '/');
                        string photosPath = PhotosZipPath(item);
                        if (photosPath == null) continue;
                        photosFound = true;
                        if (photosPath.Length == 0 || photosPath.EndsWith("/", StringComparison.Ordinal)) continue;
                        string[] sections = photosPath.Split('/');
                        if (sections.Length > 1 && ExcludedSections.Contains(sections[0])) continue;
                        foreach (string section in sections)
                        {
                            if (section.Length == 0 || section == "." || section == ".." || section.IndexOf('\0') >= 0)
                                throw new InvalidDataException("A Google Photos ZIP entry has an invalid path.");
                        }
                        if (!MediaScanner.IsMediaFile(sections[sections.Length - 1]) || entry.Length == 0) continue;
                        using (Stream media = entry.Open())
                            ReadMedia(media, item, entry.Length);
                    }
                }
                if (!photosFound)
                    throw new InvalidDataException("This ZIP has no Google Photos folder. Select a Google Photos Takeout ZIP or import its extracted folder.");
            }

            private static string PhotosZipPath(string path)
            {
                const string wrapped = "Takeout/Google Photos/";
                const string direct = "Google Photos/";
                if (path.StartsWith(wrapped, StringComparison.OrdinalIgnoreCase)) return path.Substring(wrapped.Length);
                if (path.StartsWith(direct, StringComparison.OrdinalIgnoreCase)) return path.Substring(direct.Length);
                return null;
            }

            private static FileStream OpenRead(string path)
            {
                return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan);
            }

            private void ReadMedia(Stream stream, string item, long expectedBytes)
            {
                using (var sha = SHA256.Create())
                {
                    long length = 0;
                    while (true)
                    {
                        token.ThrowIfCancellationRequested();
                        int read = stream.Read(buffer, 0, buffer.Length);
                        if (read == 0) break;
                        length += read;
                        if (length > expectedBytes) throw new InvalidDataException("A Takeout file exceeds its declared size.");
                        sha.TransformBlock(buffer, 0, read, buffer, 0);
                    }
                    if (length != expectedBytes) throw new InvalidDataException("A Takeout file could not be read at its declared size.");
                    sha.TransformFinalBlock(buffer, 0, 0);
                    string fingerprint = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
                    insert.Bind(1, item);
                    insert.Bind(2, fingerprint);
                    insert.Bind(3, length);
                    insert.ExecuteAndReset();
                }
                Files++;
                if (progress != null && (Files == 1 || Files % 100 == 0))
                    progress.Report("Read " + Files + " media files from the Google Photos export.");
            }

            public void Dispose()
            {
                insert.Dispose();
            }
        }

        private sealed class CatalogDatabase : IDisposable
        {
            private IntPtr handle;

            public CatalogDatabase(string path, bool create)
            {
                const int readWrite = 2;
                const int createFlag = 4;
                try
                {
                    byte[] filename = Encoding.UTF8.GetBytes(path + "\0");
                    Check(Native.sqlite3_open_v2(filename, out handle, readWrite | (create ? createFlag : 0), IntPtr.Zero));
                    Check(Native.sqlite3_busy_timeout(handle, 5000));
                    Execute("PRAGMA foreign_keys = ON");
                }
                catch
                {
                    Dispose();
                    throw;
                }
            }

            public CatalogStatement Prepare(string sql)
            {
                IntPtr statement;
                Check(Native.sqlite3_prepare16_v2(handle, sql, -1, out statement, IntPtr.Zero));
                return new CatalogStatement(this, statement);
            }

            public void Execute(string sql)
            {
                using (var query = Prepare(sql)) query.ExecuteAndReset();
            }

            public long Scalar(string sql)
            {
                using (var query = Prepare(sql))
                {
                    if (query.Read()) return query.GetInteger(0);
                    throw new InvalidDataException("The local backup catalog did not return a value.");
                }
            }

            public int Changes { get { return Native.sqlite3_changes(handle); } }

            public void Check(int code)
            {
                if (code == 0) return;
                string message = handle == IntPtr.Zero ? "The storage engine could not allocate a connection." :
                    Marshal.PtrToStringUni(Native.sqlite3_errmsg16(handle));
                throw new IOException("Local backup catalog error " + code + ". " + message);
            }

            public void Dispose()
            {
                if (handle == IntPtr.Zero) return;
                // Finalizing statements and closing a connection also rolls back any open transaction.
                Native.sqlite3_close(handle);
                handle = IntPtr.Zero;
            }
        }

        private sealed class CatalogStatement : IDisposable
        {
            private IntPtr handle;
            private readonly CatalogDatabase database;

            public CatalogStatement(CatalogDatabase database, IntPtr handle)
            {
                this.database = database;
                this.handle = handle;
            }

            public void Bind(int position, string value)
            {
                // SQLITE_TRANSIENT copies the marshalled string into SQLite's own memory.
                database.Check(Native.sqlite3_bind_text16(handle, position, value, -1, new IntPtr(-1)));
            }

            public void Bind(int position, long value)
            {
                database.Check(Native.sqlite3_bind_int64(handle, position, value));
            }

            public bool Read()
            {
                const int row = 100;
                const int done = 101;
                int result = Native.sqlite3_step(handle);
                if (result == row) return true;
                if (result == done) return false;
                database.Check(result);
                return false;
            }

            public void ExecuteAndReset()
            {
                while (Read()) { }
                Reset();
            }

            public void Reset()
            {
                database.Check(Native.sqlite3_reset(handle));
            }

            public string GetText(int column) { return Marshal.PtrToStringUni(Native.sqlite3_column_text16(handle, column)); }
            public long GetInteger(int column) { return Native.sqlite3_column_int64(handle, column); }

            public void Dispose()
            {
                if (handle == IntPtr.Zero) return;
                Native.sqlite3_finalize(handle);
                handle = IntPtr.Zero;
            }
        }

        private static class Native
        {
            private const string Library = "winsqlite3.dll";
            private const CallingConvention Call = CallingConvention.Cdecl;
            private const DllImportSearchPath Search = DllImportSearchPath.System32;

            [DllImport(Library, CallingConvention = Call, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern int sqlite3_open_v2(byte[] path, out IntPtr database, int flags, IntPtr vfs);
            [DllImport(Library, CallingConvention = Call, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern int sqlite3_close(IntPtr database);
            [DllImport(Library, CallingConvention = Call, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern int sqlite3_busy_timeout(IntPtr database, int milliseconds);
            [DllImport(Library, CallingConvention = Call, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern IntPtr sqlite3_errmsg16(IntPtr database);
            [DllImport(Library, CallingConvention = Call, CharSet = CharSet.Unicode, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern int sqlite3_prepare16_v2(IntPtr database, string sql, int bytes, out IntPtr statement, IntPtr tail);
            [DllImport(Library, CallingConvention = Call, CharSet = CharSet.Unicode, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern int sqlite3_bind_text16(IntPtr statement, int index, string value, int bytes, IntPtr destructor);
            [DllImport(Library, CallingConvention = Call, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern int sqlite3_bind_int64(IntPtr statement, int index, long value);
            [DllImport(Library, CallingConvention = Call, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern int sqlite3_step(IntPtr statement);
            [DllImport(Library, CallingConvention = Call, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern int sqlite3_reset(IntPtr statement);
            [DllImport(Library, CallingConvention = Call, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern int sqlite3_finalize(IntPtr statement);
            [DllImport(Library, CallingConvention = Call, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern IntPtr sqlite3_column_text16(IntPtr statement, int index);
            [DllImport(Library, CallingConvention = Call, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern long sqlite3_column_int64(IntPtr statement, int index);
            [DllImport(Library, CallingConvention = Call, ExactSpelling = true), DefaultDllImportSearchPaths(Search)]
            public static extern int sqlite3_changes(IntPtr database);
        }
    }
}
