using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Markup;
using System.Windows.Media.Imaging;

namespace PixelBackup
{
    public static class Program
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string id);

        public static Window LoadWindow()
        {
            Assembly assembly = typeof(Program).Assembly;
            using (Stream stream = assembly.GetManifestResourceStream("PixelBackup.MainWindow.xaml"))
            {
                if (stream == null) throw new InvalidDataException("The application layout is missing.");
                Window window = (Window)XamlReader.Load(stream);
                using (Stream icon = assembly.GetManifestResourceStream("PixelBackup.PixelBackup.ico"))
                {
                    if (icon != null)
                    {
                        var decoder = new IconBitmapDecoder(icon, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                        window.Icon = decoder.Frames[decoder.Frames.Count - 1];
                    }
                }
                return window;
            }
        }

        [STAThread]
        public static int Main()
        {
            SetCurrentProcessExplicitAppUserModelID("supthunder.PixelBackup");
            bool first;
            using (var mutex = new Mutex(true, @"Local\supthunder.PixelBackup.Desktop", out first))
            using (var signal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\supthunder.PixelBackup.Show"))
            {
                if (!first) { signal.Set(); return 0; }
                var app = new Application();
                try
                {
                    Window window = LoadWindow();
                    string install = AppDomain.CurrentDomain.BaseDirectory;
                    string state = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PixelBackup", "Desktop");
                    var controller = new DesktopApp(window, Path.Combine(install, "windows"), state);
                    var activate = ThreadPool.RegisterWaitForSingleObject(signal, delegate
                    {
                        window.Dispatcher.BeginInvoke(new Action(delegate
                        {
                            if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
                            window.Activate();
                        }));
                    }, null, Timeout.Infinite, false);
                    try { return app.Run(window); }
                    finally { activate.Unregister(null); GC.KeepAlive(controller); }
                }
                catch (Exception ex)
                {
                    MessageBox.Show(ex.GetBaseException().Message, "Pixel Backup", MessageBoxButton.OK, MessageBoxImage.Error);
                    return 1;
                }
                finally { mutex.ReleaseMutex(); }
            }
        }
    }
}
