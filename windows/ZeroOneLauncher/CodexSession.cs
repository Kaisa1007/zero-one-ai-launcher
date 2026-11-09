using System.Diagnostics;
using System.IO;
using System.Text.Json;
using ZeroOne.CodexPipeProbe;

namespace ZeroOne.Windows;

internal sealed class CodexSession
{
    private sealed class Target(string session)
    {
        public string Session { get; } = session;
        public bool Dark, Registered, Skinned;
    }

    private readonly PipeChild child;
    private readonly string script;
    private readonly Action<string> log;
    private readonly Dictionary<string, Target> targets = [];
    private readonly TaskCompletionSource<byte[]> capture = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private volatile bool captureRequested, stoppingTest;
    private volatile bool ready, skinned;
    public int Pid => (int)child.Pid;
    public bool Ready => ready;
    public bool Skinned => skinned;
    public bool Exited => child.WaitForExit(0);
    public Task Completion { get; }

    public CodexSession(string path, string script, Action<string> log)
    {
        this.script = script;
        this.log = log;
        child = PipeChild.Start(path);
        log($"Codex PID {Pid}, private CDP pipe");
        Completion = Task.Run(RunAsync);
    }

    private async Task RunAsync()
    {
        using var cdp = new Cdp(child.Input, child.Output);
        try
        {
            using var handshake = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var version = await cdp.SendAsync("Browser.getVersion", handshake.Token);
            log("CDP connected: " + version.GetProperty("product").GetString());
            while (!Exited && !stoppingTest)
            {
                using var round = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                await PollAsync(cdp, round.Token);
                await Task.Delay(200);
            }
            if (stoppingTest && !Exited)
            {
                // Electron can close the pipe before replying to Browser.close.
                using var quit = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                log("E2E: requesting Browser.close on the owned Codex instance");
                try { await cdp.SendAsync("Browser.close", quit.Token); }
                catch (InvalidOperationException error) { log("E2E: Browser.close rejected: " + error.Message); }
                catch (OperationCanceledException) when (quit.IsCancellationRequested) { }
                catch (IOException) { }
            }
        }
        catch (Exception error)
        {
            if (!Exited && !stoppingTest)
                log("CDP stopped while Codex remains open: " + error.GetType().Name + " " + error.Message);
        }
        finally
        {
            capture.TrySetException(new IOException("Codex 的调试连接已结束"));
            // Closing an otherwise healthy pipe while Codex is open can close its window.
            while (!child.WaitForExit(0))
                await Task.Delay(250);
            child.Disconnect();
            log($"Codex exited ({child.ExitCode})");
        }
    }

    private async Task PollAsync(Cdp cdp, CancellationToken cancel)
    {
        var response = await cdp.SendAsync("Target.getTargets", cancel);
        var live = new HashSet<string>();
        foreach (var info in response.GetProperty("targetInfos").EnumerateArray())
        {
            string? kind = info.GetProperty("type").GetString();
            if (kind is not ("page" or "iframe" or "webview"))
                continue;

            string id = info.GetProperty("targetId").GetString()!;
            string url = info.GetProperty("url").GetString() ?? "";
            bool appPage = kind == "page" && Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == "app";
            bool mainPage = appPage && !url.Contains("avatar", StringComparison.OrdinalIgnoreCase);
            live.Add(id);
            try
            {
                if (!targets.TryGetValue(id, out var target))
                {
                    var attach = await cdp.SendAsync("Target.attachToTarget", cancel, new { targetId = id, flatten = true });
                    target = new Target(attach.GetProperty("sessionId").GetString()!);
                    targets.Add(id, target);
                }
                await ApplyAsync(cdp, cancel, target, appPage);
                if (!mainPage || (ready && skinned && !captureRequested))
                    continue;
                var state = await cdp.SendAsync("Runtime.evaluate", cancel,
                    new { expression = SkinScript.PageState, returnByValue = true }, target.Session);
                if (!state.GetProperty("result").TryGetProperty("value", out var values))
                    continue;
                bool composer = values.GetProperty("ready").GetBoolean();
                bool skin = values.GetProperty("skin").GetBoolean();
                target.Skinned = skin;
                if (composer && !ready)
                {
                    ready = true;
                    log("CDP main + composer ready");
                }
                if (composer && skin && !skinned)
                {
                    skinned = true;
                    log("CDP main skin visible");
                }
                if (composer && skin && captureRequested)
                {
                    var result = await cdp.SendAsync("Page.captureScreenshot", cancel, new { format = "png" }, target.Session);
                    capture.TrySetResult(result.GetProperty("data").GetBytesFromBase64());
                    captureRequested = false;
                }
            }
            catch (InvalidOperationException error)
            {
                // Targets may navigate or disappear between enumeration and attachment.
                if (targets.TryGetValue(id, out var current))
                    current.Skinned = false;
                if (error.Message.Contains("session", StringComparison.OrdinalIgnoreCase))
                    targets.Remove(id);
                if (!ready && !targets.ContainsKey(id))
                    log("CDP target retry: " + error.Message);
            }
        }
        foreach (string id in targets.Keys.Where(id => !live.Contains(id)).ToArray())
            targets.Remove(id);
    }

    private async Task ApplyAsync(Cdp cdp, CancellationToken cancel, Target target, bool appPage)
    {
        if (!target.Dark)
        {
            await cdp.SendAsync("Emulation.setEmulatedMedia", cancel, new
            {
                features = new[] { new { name = "prefers-color-scheme", value = "dark" } }
            }, target.Session);
            target.Dark = true;
        }
        if (!appPage)
        {
            target.Skinned = false;
            return;
        }

        if (!target.Registered)
        {
            await cdp.SendAsync("Page.enable", cancel, sessionId: target.Session);
            await cdp.SendAsync("Page.addScriptToEvaluateOnNewDocument", cancel, new { source = script }, target.Session);
            target.Registered = true;
        }
        if (target.Skinned)
            return;

        var response = await cdp.SendAsync("Runtime.evaluate", cancel,
            new { expression = script, returnByValue = true }, target.Session);
        if (response.GetProperty("result").TryGetProperty("value", out var value) && value.ValueKind == JsonValueKind.String &&
            value.GetString() is "on" or "updated")
        {
            target.Skinned = true;
            log("CDP app:// window skin applied");
        }
    }

    public async Task<byte[]> CaptureAsync()
    {
        captureRequested = true;
        return await capture.Task.WaitAsync(TimeSpan.FromSeconds(8));
    }

    public async Task<string> StopTestInstanceAsync()
    {
        stoppingTest = true;
        if (Exited)
            return "already-exited";
        using Process process = Process.GetProcessById(Pid);
        if (await WaitAsync(TimeSpan.FromSeconds(5)))
            return "browser-close";

        WindowGuard.RequestClose(Pid);
        if (await WaitAsync(TimeSpan.FromSeconds(2)))
            return "window-close";

        // In Electron a pipe disconnect requests an app quit. The screenshot is already saved.
        log("E2E: the process is still running; requesting quit via private pipe EOF");
        child.Disconnect();
        if (await WaitAsync(TimeSpan.FromSeconds(8)))
            return "pipe-quit";

        log("E2E: quit timed out; ending only the instance created by this test");
        if (!process.HasExited)
            process.Kill(entireProcessTree: true);
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
        return "forced";

        async Task<bool> WaitAsync(TimeSpan timeout)
        {
            using var deadline = new CancellationTokenSource(timeout);
            try
            {
                await process.WaitForExitAsync(deadline.Token);
                return true;
            }
            catch (OperationCanceledException) when (deadline.IsCancellationRequested)
            {
                return process.HasExited;
            }
        }
    }

    public void ReleaseProcessHandle() => child.Dispose();
}
