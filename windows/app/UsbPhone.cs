using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;

namespace PixelBackup
{
    internal static class UsbPhone
    {
        private const string ToolsUnavailable = "The USB tools could not start. Open Advanced options, choose Prepare USB tools and try again.";
        private const string Unresponsive = "The USB check timed out. Unlock the Pixel, reconnect the data cable and try again.";

        // The caller resolves and verifies adb.exe. Pairing repeats its own device checks.
        internal static string Check(string adb)
        {
            if (String.IsNullOrWhiteSpace(adb) || !File.Exists(adb) || Path.GetPathRoot(adb).Length < 3)
                return ToolsUnavailable;
            string state;
            string failure = Run(adb, "-d get-state", out state);
            if (failure != null) return failure;
            if (state != "device") return ConnectionProblem(state);

            string properties;
            failure = Run(adb, "-d shell -n -T \"getprop ro.product.device; getprop ro.build.version.sdk\"", out properties);
            if (failure != null) return failure;
            string[] values = properties.Split(new[] { '\n' }, StringSplitOptions.None);
            if (values.Length != 2 || String.IsNullOrWhiteSpace(values[0]) || String.IsNullOrWhiteSpace(values[1]))
                return "Android could not report the phone model and version. Unlock the Pixel and try again.";
            string device = values[0].Trim();
            if (device != "sailfish" && device != "marlin")
                return "Connect an original 2016 Pixel or Pixel XL to use this setup.";
            if (values[1].Trim() != "29")
                return "This setup needs Android 10. Check the Android version on your original Pixel.";
            return null;
        }

        private static string ConnectionProblem(string diagnostic)
        {
            string text = diagnostic.ToLowerInvariant();
            if (text.Contains("more than one") || text.Contains("multiple devices"))
                return "Disconnect the other USB Android devices, leave only your Pixel connected and try again.";
            if (text.Contains("unauthorized"))
                return "Unlock the Pixel and tap Allow on the USB debugging prompt, then try again.";
            if (text.Contains("offline"))
                return "The Pixel is offline. Unlock it, reconnect its USB data cable and try again.";
            if (text.Contains("timed out")) return Unresponsive;
            if (text.Contains("no device") || text.Contains("no usb device") || text == "unknown")
                return "Connect the Pixel with a USB data cable, enable USB debugging and try again.";
            if (text == "recovery" || text == "bootloader" || text == "sideload" || text == "rescue")
                return "Start the Pixel normally, unlock Android and try again.";
            return "USB communication failed. Reconnect the unlocked Pixel with a data cable and try again.";
        }

        private static string Run(string adb, string arguments, out string output)
        {
            output = null;
            var start = new ProcessStartInfo(adb, arguments)
            {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(adb),
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            // A USB phone reached through a remote adb server is not attached to this PC.
            start.EnvironmentVariables.Remove("ADB_SERVER_SOCKET");
            start.EnvironmentVariables.Remove("ANDROID_ADB_SERVER_ADDRESS");
            start.EnvironmentVariables.Remove("ANDROID_ADB_SERVER_PORT");
            const int timeout = 6000;
            try
            {
                using (var process = Process.Start(start))
                {
                    var timer = Stopwatch.StartNew();
                    var stdout = process.StandardOutput.ReadToEndAsync();
                    var stderr = process.StandardError.ReadToEndAsync();
                    if (!process.WaitForExit(timeout))
                    {
                        // End only this short-lived adb client. The shared server may have other users.
                        try { process.Kill(); } catch (InvalidOperationException) { }
                        return Unresponsive;
                    }
                    int remaining = Math.Max(0, timeout - (int)timer.ElapsedMilliseconds);
                    if (!Task.WaitAll(new Task[] { stdout, stderr }, remaining)) return Unresponsive;
                    output = stdout.Result.Trim();
                    return process.ExitCode == 0 ? null : ConnectionProblem(stderr.Result + "\n" + output);
                }
            }
            catch (Win32Exception) { return ToolsUnavailable; }
            catch (IOException) { return "USB communication was interrupted. Reconnect the Pixel and try again."; }
            catch (AggregateException) { return "USB communication was interrupted. Reconnect the Pixel and try again."; }
        }
    }
}
