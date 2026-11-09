using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Xml.Linq;

namespace ZeroOne.Windows;

internal static class CodexDiscovery
{
    private const string PackageFamily = "OpenAI.Codex_2p2nqsd0c76g0";
    private const int InsufficientBuffer = 122;
    public static string Preference => Path.Combine(AppContext.BaseDirectory, "codex-path.txt");

    public static string? Resolve(string? manual)
    {
        if (manual is not null)
        {
            string path = Path.GetFullPath(manual);
            return File.Exists(path) && Path.GetExtension(path).Equals(".exe", StringComparison.OrdinalIgnoreCase)
                ? path : throw new FileNotFoundException("指定的 Codex 可执行文件不存在", path);
        }
        if (File.Exists(Preference))
        {
            string saved = File.ReadAllText(Preference).Trim();
            if (File.Exists(saved))
                return saved;
        }
        foreach (string name in Packages().OrderByDescending(name =>
                 Version.TryParse(name.Split('_').ElementAtOrDefault(1), out var version) ? version : new Version()))
        {
            uint length = 0;
            if (GetPackagePathByFullName(name, ref length, null) != InsufficientBuffer)
                continue;
            var path = new StringBuilder((int)length);
            if (GetPackagePathByFullName(name, ref length, path) != 0)
                continue;
            string root = path.ToString();
            var manifest = XDocument.Load(Path.Combine(root, "AppxManifest.xml"));
            var entry = manifest.Descendants().FirstOrDefault(node =>
                node.Name.LocalName == "Application" && (string?)node.Attribute("Id") == "App");
            if (entry?.Attribute("Executable") is not XAttribute executable)
                continue;
            string candidate = Path.Combine(root, executable.Value);
            if (File.Exists(candidate))
                return candidate;
        }
        return null;
    }

    private static string[] Packages()
    {
        uint count = 0, length = 0;
        int status = GetPackagesByPackageFamily(PackageFamily, ref count, IntPtr.Zero, ref length, IntPtr.Zero);
        if (status == 0 && count == 0)
            return [];
        if (status != InsufficientBuffer)
            throw new Win32Exception(status, $"GetPackagesByPackageFamily: {status}");

        IntPtr names = Marshal.AllocHGlobal(checked((int)count * IntPtr.Size));
        IntPtr buffer = IntPtr.Zero;
        try
        {
            buffer = Marshal.AllocHGlobal(checked((int)length * sizeof(char)));
            status = GetPackagesByPackageFamily(PackageFamily, ref count, names, ref length, buffer);
            if (status != 0)
                throw new Win32Exception(status, $"GetPackagesByPackageFamily: {status}");
            return Enumerable.Range(0, (int)count)
                .Select(i => Marshal.PtrToStringUni(Marshal.ReadIntPtr(names, i * IntPtr.Size))!).ToArray();
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
            Marshal.FreeHGlobal(names);
        }
    }

    public static int? Running(string? executable)
    {
        string image = executable is null ? "ChatGPT" : Path.GetFileNameWithoutExtension(executable);
        Process[] processes = Process.GetProcessesByName(image);
        try
        {
            int? fallback = null;
            foreach (var process in processes)
            {
                try
                {
                    string? path = process.MainModule?.FileName;
                    bool match = string.Equals(path, executable, StringComparison.OrdinalIgnoreCase) ||
                        (path is not null && path.Contains(@"\WindowsApps\OpenAI.Codex_", StringComparison.OrdinalIgnoreCase));
                    if (!match || process.HasExited)
                        continue;
                    if (process.MainWindowHandle != IntPtr.Zero)
                        return process.Id;
                    fallback ??= process.Id;
                }
                catch (InvalidOperationException) { }
                catch (Win32Exception)
                {
                    // A same-name executable we cannot inspect could own an existing single-instance session.
                    fallback ??= process.Id;
                }
            }
            return fallback;
        }
        finally
        {
            foreach (var process in processes)
                process.Dispose();
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetPackagesByPackageFamily(string family, ref uint count,
        IntPtr names, ref uint length, IntPtr buffer);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetPackagePathByFullName(string package, ref uint length, StringBuilder? path);
}

internal sealed class WindowGuard : IDisposable
{
    private readonly int pid;
    private readonly HashSet<IntPtr> hidden = [];
    private readonly WinEvent callback;
    private readonly IntPtr showHook, foregroundHook;
    private bool guarding = true;
    private IntPtr revealed;

    public WindowGuard(int pid, Action<string> log)
    {
        this.pid = pid;
        callback = OnWindowEvent;
        showHook = SetWinEventHook(0x8002, 0x8002, IntPtr.Zero, callback, (uint)pid, 0, 0);
        foregroundHook = SetWinEventHook(3, 3, IntPtr.Zero, callback, (uint)pid, 0, 0);
        if (showHook == IntPtr.Zero || foregroundHook == IntPtr.Zero)
            log("window hook unavailable; using EnumWindows fallback");
        HideVisible();
    }

    private void OnWindowEvent(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time)
    {
        if (guarding && window != IntPtr.Zero && objectId == 0 && childId == 0)
            HideVisible();
    }

    public void HideVisible()
    {
        if (!guarding)
            return;
        foreach (IntPtr window in Windows(pid))
            if (IsWindowVisible(window))
            {
                hidden.Add(window);
                ShowWindowAsync(window, 0);
            }
    }

    public void Reveal()
    {
        StopHooks();
        foreach (IntPtr window in hidden)
            if (OwnedBy(window, pid))
                ShowWindowAsync(window, 4); // SW_SHOWNOACTIVATE
        revealed = Activate(pid, hidden);
        hidden.Clear();
    }

    public void ReassertForeground()
    {
        if (OwnedBy(revealed, pid))
            SetForegroundWindow(revealed);
        else
            Activate(pid);
    }

    public static IntPtr Activate(int pid, IReadOnlySet<IntPtr>? justShown = null)
    {
        IntPtr best = Windows(pid).Where(w => IsWindowVisible(w) || justShown?.Contains(w) == true)
            .Where(w => GetWindow(w, 4) == IntPtr.Zero)
            .OrderByDescending(w => GetWindowRect(w, out var rect)
                ? Math.Max(0L, rect.Right - rect.Left) * Math.Max(0L, rect.Bottom - rect.Top) : 0)
            .FirstOrDefault();
        if (best != IntPtr.Zero)
        {
            ShowWindowAsync(best, IsIconic(best) ? 9 : 5);
            SetForegroundWindow(best);
        }
        return best;
    }

    public static void RequestClose(int pid)
    {
        foreach (IntPtr window in Windows(pid))
            if (IsWindowVisible(window) && GetWindow(window, 4) == IntPtr.Zero)
                PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero);
    }

    public static bool ForegroundBelongsTo(int pid) => OwnedBy(GetForegroundWindow(), pid);

    private static List<IntPtr> Windows(int pid)
    {
        var result = new List<IntPtr>();
        EnumWindows((window, _) =>
        {
            if (OwnedBy(window, pid))
                result.Add(window);
            return true;
        }, IntPtr.Zero);
        return result;
    }

    private static bool OwnedBy(IntPtr window, int pid) =>
        window != IntPtr.Zero && GetWindowThreadProcessId(window, out uint owner) != 0 && owner == pid;

    private void StopHooks()
    {
        if (!guarding)
            return;
        guarding = false;
        if (showHook != IntPtr.Zero)
            UnhookWinEvent(showHook);
        if (foregroundHook != IntPtr.Zero)
            UnhookWinEvent(foregroundHook);
    }

    public void Dispose() => Reveal();

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
    private delegate void WinEvent(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time);
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", EntryPoint = "PostMessageW")]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEvent callback, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")]
    private static extern bool UnhookWinEvent(IntPtr hook);
}
