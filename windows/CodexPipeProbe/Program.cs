using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace ZeroOne.CodexPipeProbe;

internal static class Program
{
    // Keep probe output in one stream for PowerShell log capture.
    private static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        try
        {
            if (args.FirstOrDefault() == "--mock-child")
                return await MockChildAsync(args);
            if (args.SequenceEqual(["--selftest"]))
                return await SelfTestAsync();
            if (args is ["--codex-exe", var path, "--repo", var repo])
                return await ProbeAsync(Path.GetFullPath(path), Path.GetFullPath(repo));

            Console.WriteLine("Usage: CodexPipeProbe --codex-exe <path> --repo <directory> | --selftest");
            return 2;
        }
        catch (Exception error)
        {
            Console.WriteLine($"[failed] {error.GetType().Name}: {error.Message}");
            return 1;
        }
    }

    private static async Task<int> ProbeAsync(string executable, string repo)
    {
        if (!File.Exists(executable) || !executable.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            throw new FileNotFoundException("Codex executable is missing or is not an .exe", executable);

        string image = Path.GetFileNameWithoutExtension(executable);
        Console.WriteLine($"[discovery] exe={executable}");
        Console.WriteLine($"[discovery] image={image}.exe fileVersion={FileVersionInfo.GetVersionInfo(executable).FileVersion}");
        string skin = SkinScript.Build(Path.Combine(repo, "Skin"), Path.Combine(repo, "Resources", "Images"));

        var running = Process.GetProcessesByName(image);
        try
        {
            if (running.Length != 0)
            {
                Console.WriteLine($"[refused] {image}.exe is running (PID {string.Join(", ", running.Select(p => p.Id))}).");
                return 3;
            }
        }
        finally
        {
            foreach (Process process in running)
                process.Dispose();
        }

        Console.WriteLine("[launch] CreateProcessW, --remote-debugging-pipe, inherited read/write HANDLEs, no TCP");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        using var child = PipeChild.Start(executable);
        Console.WriteLine($"[launch] PID {child.Pid}");
        using var cdp = new Cdp(child.Input, child.Output);

        string step = "Browser.getVersion";
        bool attachedAndReady = false;
        try
        {
            var version = await cdp.SendAsync(step, deadline.Token);
            Console.WriteLine($"[pipe] OK product={version.GetProperty("product").GetString()} protocol={version.GetProperty("protocolVersion").GetString()}");

            step = "Target.getTargets (waiting for app:// page)";
            string targetId = await FindAppPageAsync(cdp, deadline.Token);
            step = "Target.attachToTarget";
            var attached = await cdp.SendAsync(step, deadline.Token, new { targetId, flatten = true });
            string session = attached.GetProperty("sessionId").GetString()!;
            Console.WriteLine("[target] OK attached to app:// page");

            step = "Page.enable";
            await cdp.SendAsync(step, deadline.Token, sessionId: session);
            step = "Emulation.setEmulatedMedia";
            await cdp.SendAsync(step, deadline.Token, new
            {
                features = new[] { new { name = "prefers-color-scheme", value = "dark" } }
            }, session);

            step = "Page.addScriptToEvaluateOnNewDocument";
            var registered = await cdp.SendAsync(step, deadline.Token, new { source = skin }, session);
            if (string.IsNullOrEmpty(registered.GetProperty("identifier").GetString()))
                throw new InvalidDataException("CDP returned an empty registration identifier");
            Console.WriteLine("[new-document] OK script registered");

            step = "Runtime.evaluate (skin and DOM readiness)";
            await WaitForSkinAndReadinessAsync(cdp, session, skin, deadline.Token);
            attachedAndReady = true;
        }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested)
        {
            Console.WriteLine($"[failed] {step}: 30-second deadline after launch");
        }
        catch (Exception error)
        {
            Console.WriteLine($"[failed] {step}: {error.GetType().Name}: {error.Message}");
        }

        string before = WindowState(child);
        Console.WriteLine($"[disconnect] before={before}");
        child.Disconnect();
        bool exited = child.WaitForExit(8000);
        string after = WindowState(child);
        Console.WriteLine($"[disconnect] after={after}, observation=8s max");
        bool survived = !exited && after == "alive/window-present";

        bool passed = attachedAndReady && survived;
        Console.WriteLine($"[result] {(passed ? "PASS" : "FAIL")} skin_and_ready={attachedAndReady} pipe_disconnect_survived={survived}");
        return passed ? 0 : 1;
    }

    private static async Task<string> FindAppPageAsync(Cdp cdp, CancellationToken cancellation)
    {
        // Prefer the main page and exclude the floating avatar.
        while (true)
        {
            var response = await cdp.SendAsync("Target.getTargets", cancellation);
            string? first = null;
            foreach (var target in response.GetProperty("targetInfos").EnumerateArray())
            {
                if (target.GetProperty("type").GetString() != "page" ||
                    !Uri.TryCreate(target.GetProperty("url").GetString(), UriKind.Absolute, out var uri) ||
                    uri.Scheme != "app" || uri.Query.Contains("avatar", StringComparison.OrdinalIgnoreCase))
                    continue;

                string id = target.GetProperty("targetId").GetString()!;
                if (uri.AbsolutePath.EndsWith("/index.html", StringComparison.Ordinal))
                    return id;
                first ??= id;
            }

            if (first is not null)
                return first;
            await Task.Delay(200, cancellation);
        }
    }

    private static async Task WaitForSkinAndReadinessAsync(
        Cdp cdp, string session, string skin, CancellationToken cancellation)
    {
        bool applied = false;
        string? previous = null;
        while (true)
        {
            if (!applied)
            {
                var injection = await cdp.SendAsync("Runtime.evaluate", cancellation,
                    new { expression = skin, returnByValue = true }, session);
                if (injection.TryGetProperty("exceptionDetails", out _))
                    Console.WriteLine("[skin] runtime exception, retrying");
                else if (injection.GetProperty("result").TryGetProperty("value", out var value))
                    applied = value.GetString() is "on" or "updated";
            }

            var state = await cdp.SendAsync("Runtime.evaluate", cancellation,
                new { expression = SkinScript.PageState, returnByValue = true }, session);
            if (state.GetProperty("result").TryGetProperty("value", out var valueObject))
            {
                bool ready = valueObject.GetProperty("ready").GetBoolean();
                bool skinned = valueObject.GetProperty("skin").GetBoolean();
                bool dark = valueObject.GetProperty("dark").GetBoolean();
                string status = $"[dom] ready={ready} skin={skinned} dark={dark}";
                if (status != previous)
                    Console.WriteLine(status);
                previous = status;
                if (ready && skinned && dark)
                    return;
                applied = skinned;
            }

            await Task.Delay(200, cancellation);
        }
    }

    private static string WindowState(PipeChild child)
    {
        if (child.WaitForExit(0))
            return $"exited/code={child.ExitCode}";
        try
        {
            using Process process = Process.GetProcessById((int)child.Pid);
            return process.MainWindowHandle != IntPtr.Zero ? "alive/window-present" : "alive/no-window";
        }
        catch (ArgumentException) when (child.WaitForExit(0))
        {
            return $"exited/code={child.ExitCode}";
        }
    }

    private static async Task<int> SelfTestAsync()
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        using var child = PipeChild.Start(Environment.ProcessPath!, mock: true);
        using var cdp = new Cdp(child.Input, child.Output);
        var first = await cdp.SendAsync("Browser.getVersion", deadline.Token);
        var second = await cdp.SendAsync("Target.getTargets", deadline.Token);
        if (first.GetProperty("echo").GetString() != "Browser.getVersion" ||
            second.GetProperty("echo").GetString() != "Target.getTargets")
            throw new InvalidDataException("Mock replies did not match both requests");
        child.Disconnect();
        if (!child.WaitForExit(5000) || child.ExitCode != 0)
            throw new IOException("Mock child did not observe EOF and exit cleanly");
        Console.WriteLine("[selftest] PASS: HANDLE inheritance, NUL framing, notification, fragmented reply, EOF");
        return 0;
    }

    private static async Task<int> MockChildAsync(string[] args)
    {
        var handles = PipeChild.ReadHandleArguments(args);
        using var input = new AnonymousPipeClientStream(PipeDirection.In, new SafePipeHandle(handles.Read, true));
        using var output = new AnonymousPipeClientStream(PipeDirection.Out, new SafePipeHandle(handles.Write, true));
        using var frame = new MemoryStream();
        while (true)
        {
            int value = input.ReadByte();
            if (value < 0)
                return frame.Length == 0 ? 0 : 1;
            if (value != 0)
            {
                frame.WriteByte((byte)value);
                continue;
            }

            using var document = JsonDocument.Parse(frame.ToArray());
            frame.SetLength(0);
            var request = document.RootElement;
            var reply = JsonSerializer.Serialize(new
            {
                id = request.GetProperty("id").GetInt32(),
                result = new { echo = request.GetProperty("method").GetString() }
            });
            byte[] first = Encoding.UTF8.GetBytes("{\"method\":\"mock.event\"}\0" + reply[..8]);
            output.Write(first);
            await Task.Delay(30);
            output.Write(Encoding.UTF8.GetBytes(reply[8..] + "\0"));
        }
    }
}
