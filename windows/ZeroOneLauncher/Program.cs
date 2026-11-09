using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using ZeroOne.CodexPipeProbe;

namespace ZeroOne.Windows;

internal sealed record LaunchOptions(bool Windowed, string? SelfTest, string? E2E, string? CodexPath)
{
    public static LaunchOptions Parse(string[] args)
    {
        bool windowed = false;
        string? self = null, e2e = null, codex = null;
        for (int i = 0; i < args.Length; i++)
        {
            string current = args[i];
            switch (current)
            {
                case "--windowed": windowed = true; break;
                case "--selftest": self = Value(); break;
                case "--e2e-codex": e2e = Value(); break;
                case "--codex-path": codex = Value(); break;
                default: throw new ArgumentException($"未知参数 {current}");
            }
            string Value()
            {
                if (++i == args.Length || args[i].StartsWith("--", StringComparison.Ordinal))
                    throw new ArgumentException($"{current} 缺少路径参数");
                return Path.GetFullPath(args[i]);
            }
        }
        if (self is not null && (e2e is not null || codex is not null))
            throw new ArgumentException("--selftest 与 --e2e-codex / --codex-path 不能一起使用");
        return new LaunchOptions(windowed || self is not null, self, e2e, codex);
    }
}

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Startup += async (_, _) =>
        {
            BootRun? run = null;
            try
            {
                run = new BootRun(app, LaunchOptions.Parse(args));
                await run.StartAsync();
            }
            catch (Exception error)
            {
                if (run is null)
                {
                    MessageBox.Show(error.Message, "Zero-One AI Launcher", MessageBoxButton.OK, MessageBoxImage.Error);
                    app.Shutdown(2);
                }
                else
                    await run.FailAsync(error);
            }
        };
        return app.Run();
    }
}

internal sealed class BootRun(Application app, LaunchOptions options)
{
    private readonly RunLog log = new();
    private readonly FrameClock clock = new();
    private BootStage? stage;
    private AudioMixer? audio;
    private Assets assets = null!;
    private BootDirector boot = null!;
    private Window? window, reveal;
    private WindowGuard? guard;
    private CodexSession? session;
    private BootSelfTest? test;
    private Task<CodexSession?>? starting;
    private int? existing;
    private double? launchedAt, simulatedReady;
    private double nextHide;
    private bool closing, finishing, handedOff;
    private Exception? launchError;
    private bool IsSelfTest => options.SelfTest is not null;

    private string LogPath => IsSelfTest ? Path.Combine(options.SelfTest!, "selftest.log")
        : options.E2E is not null ? Path.ChangeExtension(options.E2E, ".log")
        : Path.Combine(AppContext.BaseDirectory, "last-run.log");

    public async Task StartAsync()
    {
        string? path = null;
        if (!IsSelfTest)
        {
            path = CodexDiscovery.Resolve(options.CodexPath);
            existing = CodexDiscovery.Running(path);
            if (options.E2E is not null && (existing is not null || path is null))
            {
                log.Write(existing is null ? "E2E refused: Codex executable not found" : $"E2E refused: Codex already running (PID {existing})");
                log.Save(LogPath);
                app.Shutdown(existing is null ? 2 : 3);
                return;
            }
            if (path is null && existing is null)
            {
                var picker = new OpenFileDialog
                {
                    Title = "未找到 Codex，请选择桌面版可执行程序",
                    Filter = "Windows 可执行程序 (*.exe)|*.exe",
                    CheckFileExists = true
                };
                if (picker.ShowDialog() == true)
                {
                    path = picker.FileName;
                    try { File.WriteAllText(CodexDiscovery.Preference, path); }
                    catch (IOException error) { log.Write("Could not save selected path: " + error.Message); }
                    catch (UnauthorizedAccessException error) { log.Write("Could not save selected path: " + error.Message); }
                    existing = CodexDiscovery.Running(path);
                }
            }
            if (existing is int pid)
                log.Write($"Using existing Codex PID {pid}; no CDP attach");
        }
        else
        {
            string? configured = Environment.GetEnvironmentVariable("ZEROONE_READY_AT");
            if (configured is not null &&
                (!double.TryParse(configured, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) ||
                 !double.IsFinite(parsed) || parsed < 0))
                throw new ArgumentException("ZEROONE_READY_AT 应为非负秒数");
            simulatedReady = configured is null ? 7 : double.Parse(configured, CultureInfo.InvariantCulture);
            test = new BootSelfTest(options.SelfTest!, simulatedReady.Value);
            launchedAt = 0;
            log.Write($"selftest ready_at={simulatedReady.Value.ToString("0.###", CultureInfo.InvariantCulture)}s");
        }

        var preloading = Stopwatch.StartNew();
        assets = await Task.Run(Assets.Load);
        log.Write($"assets predecoded in {preloading.ElapsedMilliseconds}ms");
        audio = new AudioMixer(assets.Clips, IsSelfTest, log.Write);
        boot = new BootDirector(audio, assets.Clips, log.Write)
        {
            Existing = existing is not null, Missing = !IsSelfTest && existing is null && path is null
        };
        stage = new BootStage(assets);
        window = MakeWindow(stage, transparent: false);
        reveal = MakeWindow(stage.RevealSurface, transparent: true);
        window.ContentRendered += (_, _) => CompositionTarget.Rendering += OnFrame;
        window.Show();
        reveal.WindowStartupLocation = WindowStartupLocation.Manual;
        reveal.Left = window.Left;
        reveal.Top = window.Top;
        reveal.Show();
        window.Activate();
        log.Write($"WPF render tier={RenderCapability.Tier >> 16}");

        if (path is not null && existing is null)
        {
            string executable = path;
            starting = Task.Run(() =>
            {
                string script = SkinScript.Build(Path.Combine(Assets.Root, "Skin"), Path.Combine(Assets.Root, "Images"));
                if (CodexDiscovery.Running(executable) is not null)
                    return null;
                return new CodexSession(executable, script, log.Write);
            });
        }
    }

    private Window MakeWindow(FrameworkElement content, bool transparent)
    {
        var result = new Window
        {
            Title = "Zero-One AI Launcher",
            AllowsTransparency = transparent,
            Background = transparent ? Brushes.Transparent : Brushes.Black,
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = options.Windowed ? WindowStartupLocation.CenterScreen : WindowStartupLocation.Manual,
            Left = 0,
            Top = 0,
            Width = options.Windowed ? Math.Min(1120, SystemParameters.WorkArea.Width * .9) : SystemParameters.PrimaryScreenWidth,
            Height = options.Windowed ? Math.Min(700, SystemParameters.WorkArea.Height * .9) : SystemParameters.PrimaryScreenHeight,
            Topmost = !options.Windowed || IsSelfTest,
            ShowInTaskbar = options.Windowed && !transparent,
            ShowActivated = !transparent,
            Cursor = IsSelfTest ? Cursors.Arrow : Cursors.None,
            Content = content
        };
        if (!IsSelfTest)
        {
            result.PreviewKeyDown += (_, e) =>
            {
                if (e.Key is Key.Escape or Key.Space or Key.Return)
                {
                    e.Handled = true;
                    if (!e.IsRepeat) boot.Skip();
                }
            };
            result.PreviewMouseDown += (_, e) => { e.Handled = true; boot.Skip(); };
        }
        result.Closing += (_, e) =>
        {
            if (closing) return;
            e.Cancel = true;
            if (!IsSelfTest) boot.Skip();
        };
        return result;
    }

    private async void OnFrame(object? sender, EventArgs args)
    {
        if (finishing || args is not RenderingEventArgs frame || clock.Advance(frame.RenderingTime) is not { } tick)
            return;
        long startUpdate = Stopwatch.GetTimestamp();
        try
        {
            if (starting is { IsCompleted: true } pending)
            {
                starting = null;
                try
                {
                    session = await pending;
                    if (session is null)
                    {
                        existing = CodexDiscovery.Running(CodexDiscovery.Resolve(options.CodexPath));
                        if (options.E2E is not null)
                            throw new InvalidOperationException("E2E: Codex 在启动前已运行");
                        boot.Existing = existing is not null;
                        boot.Missing = existing is null;
                    }
                    else
                    {
                        launchedAt = tick.Seconds;
                        if (!handedOff)
                            guard = new WindowGuard(session.Pid, log.Write);
                    }
                }
                catch (Exception error)
                {
                    launchError = error;
                    log.Write("Codex launch failed: " + error.Message);
                    boot.Missing = true;
                }
            }
            if (guard is not null && !handedOff && tick.Seconds >= nextHide)
            {
                guard.HideVisible();
                nextHide = tick.Seconds + .08;
            }
            boot.Frame(tick.Seconds, boot.Existing || boot.Missing || session is { Ready: true, Skinned: true },
                session?.Skinned == true, launchedAt, simulatedReady);
            stage!.Render(boot, IsSelfTest);
            if (boot.RevealTime >= 0 && !handedOff)
            {
                handedOff = true;
                if (guard is not null)
                    guard.Reveal();
                else if (existing is int pid)
                    WindowGuard.Activate(pid);
                window!.Hide();
            }
            clock.Count(boot.Phase, tick.Interval, tick.Dropped, Stopwatch.GetElapsedTime(startUpdate).TotalMilliseconds);
            test?.Capture(stage, boot);
            if (boot.Finished)
                await FinishAsync();
        }
        catch (Exception error) { await FailAsync(error); }
    }

    private async Task FinishAsync()
    {
        finishing = true;
        CompositionTarget.Rendering -= OnFrame;
        closing = true;
        reveal!.Close();
        reveal.Content = null;
        window!.Close();
        window.Content = null;
        stage = null;
        assets.Images.Clear();
        guard?.ReassertForeground();
        if (guard is null && existing is int pid)
            WindowGuard.Activate(pid);
        clock.Report(log);

        if (test is not null)
        {
            int code = test.Finish(boot, assets.Clips, log);
            await audio!.CloseAsync();
            app.Shutdown(code);
            return;
        }
        log.Save(LogPath);

        if (launchError is not null)
            throw new InvalidOperationException("Codex 启动失败：" + launchError.Message, launchError);

        if (starting is not null)
        {
            session = await starting;
            starting = null;
            if (session is not null)
                WindowGuard.Activate(session.Pid);
        }

        if (options.E2E is not null)
        {
            await CompleteE2EAsync();
            return;
        }

        // Allow the handoff effects and welcome reverb to drain before releasing audio.
        await Task.Delay(1500);
        await audio!.CloseAsync();
        audio = null;
        assets.Clips.Clear();
        if (session is not null)
        {
            await session.Completion;
            session.ReleaseProcessHandle();
            session = null;
        }
        log.Save(LogPath);
        app.Shutdown();
    }

    private async Task CompleteE2EAsync()
    {
        var owned = session ?? throw new InvalidOperationException("E2E 没有启动测试实例");
        string cleanup;
        try
        {
            if (!boot.Ready || boot.TimedOut || boot.Forced)
                throw new InvalidOperationException("E2E 未通过真实 Codex 就绪门槛");
            await Task.Delay(300);
            log.Write($"E2E foreground={WindowGuard.ForegroundBelongsTo(owned.Pid)}");
            byte[] png = await owned.CaptureAsync();
            Directory.CreateDirectory(Path.GetDirectoryName(options.E2E!)!);
            await File.WriteAllBytesAsync(options.E2E!, png);
            log.Write("E2E screenshot: " + options.E2E);
        }
        finally
        {
            cleanup = await owned.StopTestInstanceAsync();
            await owned.Completion;
            owned.ReleaseProcessHandle();
            session = null;
        }

        await audio!.CloseAsync();
        audio = null;
        log.Write($"E2E PASS (cleanup={cleanup})");
        log.Save(LogPath);
        app.Shutdown();
    }

    public async Task FailAsync(Exception error)
    {
        finishing = true;
        closing = true;
        CompositionTarget.Rendering -= OnFrame;
        log.Write($"{error.GetType().Name}: {error.Message}");
        reveal?.Close();
        window?.Close();
        guard?.Dispose();
        if (audio is not null)
        {
            await audio.CloseAsync();
            audio = null;
        }
        if (starting is not null)
        {
            try { session = await starting; }
            catch (Exception launchFailure) { log.Write("Codex launch failed: " + launchFailure.Message); }
            starting = null;
        }
        if (!IsSelfTest && options.E2E is null)
            MessageBox.Show(error.Message, "Zero-One AI Launcher", MessageBoxButton.OK, MessageBoxImage.Error);
        if (session is not null)
        {
            if (options.E2E is not null)
                await session.StopTestInstanceAsync();
            else
                WindowGuard.Activate(session.Pid);
            await session.Completion;
            session.ReleaseProcessHandle();
        }
        log.Write("RESULT: FAIL");
        try { log.Save(LogPath); }
        finally { app.Shutdown(1); }
    }
}
