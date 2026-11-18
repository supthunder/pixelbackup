using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace PixelBackup
{
    internal static class DesktopFolderPicker
    {
        private const int Cancelled = unchecked((int)0x800704C7);
        private const uint NoChangeDirectory = 0x8, PickFolders = 0x20, ForceFileSystem = 0x40, PathMustExist = 0x800;
        private const uint FileSystemPath = 0x80058000; // SIGDN_FILESYSPATH
        private static string previousFolder;

        internal static string Show(Window owner, string title)
        {
            if (owner == null) throw new ArgumentNullException("owner");
            IntPtr handle = new WindowInteropHelper(owner).EnsureHandle();
            var dialog = (IFileOpenDialog)new FileOpenDialog();
            IShellItem selection = null;
            try
            {
                uint options;
                dialog.GetOptions(out options);
                dialog.SetOptions(options | PickFolders | ForceFileSystem | PathMustExist | NoChangeDirectory);
                dialog.SetTitle(title);
                if (previousFolder != null)
                {
                    // A path typed into the name box can be selected without navigating there.
                    // If the previous selection has gone away, use Explorer's usual location.
                    Guid iid = typeof(IShellItem).GUID;
                    IShellItem previous;
                    if (SHCreateItemFromParsingName(previousFolder, IntPtr.Zero, ref iid, out previous) == 0)
                    {
                        try { dialog.SetFolder(previous); }
                        finally { Marshal.ReleaseComObject(previous); }
                    }
                }
                int result = dialog.Show(handle);
                if (result == Cancelled) return null;
                Marshal.ThrowExceptionForHR(result);
                dialog.GetResult(out selection);
                string path;
                selection.GetDisplayName(FileSystemPath, out path);
                previousFolder = path;
                return path;
            }
            finally
            {
                if (selection != null) Marshal.ReleaseComObject(selection);
                Marshal.ReleaseComObject(dialog);
            }
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int SHCreateItemFromParsingName(string path, IntPtr context, ref Guid id, out IShellItem item);

        [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
        private class FileOpenDialog { }

        // The .NET Framework WPF runtime predates OpenFolderDialog. Declare the
        // native shell interfaces in SDK vtable order through the methods we use.
        [ComImport, Guid("D57C7288-D4AD-4768-BE02-9D969532D960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IFileOpenDialog
        {
            [PreserveSig] int Show(IntPtr owner);
            void SetFileTypes(uint count, IntPtr filters);
            void SetFileTypeIndex(uint index);
            void GetFileTypeIndex(out uint index);
            void Advise(IntPtr events, out uint cookie);
            void Unadvise(uint cookie);
            void SetOptions(uint options);
            void GetOptions(out uint options);
            void SetDefaultFolder(IShellItem folder);
            [PreserveSig] int SetFolder(IShellItem folder);
            void GetFolder(out IShellItem folder);
            void GetCurrentSelection(out IShellItem item);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
            void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
            void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
            void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
            void GetResult(out IShellItem item);
        }

        [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItem
        {
            void BindToHandler(IntPtr context, ref Guid handler, ref Guid interfaceId, out IntPtr result);
            void GetParent(out IShellItem parent);
            void GetDisplayName(uint format, [MarshalAs(UnmanagedType.LPWStr)] out string name);
        }
    }
}
