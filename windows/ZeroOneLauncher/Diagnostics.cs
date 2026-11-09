using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ZeroOne.Windows;

internal sealed class RunLog
{
    private readonly ConcurrentQueue<string> entries = new();

    private int printed;

    // Console I/O and terminal redraw wait until the animation has finished.
    public void Write(string message) => entries.Enqueue(message);

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        string[] snapshot = entries.ToArray();
        File.WriteAllLines(path, snapshot);
        while (printed < snapshot.Length)
            Console.WriteLine(snapshot[printed++]);
    }
}

internal sealed class FrameClock
{
    private TimeSpan? start;
    private long previousIndex = -1;
    private double previousTime;
    private readonly Dictionary<string, List<(double Interval, int Dropped, double UpdateMs)>> phases = [];

    public (double Seconds, int Dropped, double Interval)? Advance(TimeSpan timestamp)
    {
        start ??= timestamp;
        double seconds = (timestamp - start.Value).TotalSeconds;
        // On high-refresh displays only render the first callback for each 60 Hz slot.
        long index = (long)Math.Floor(seconds * 60 + .1);
        if (index <= previousIndex)
            return null;
        var tick = (index / 60.0, (int)Math.Max(0, index - previousIndex - 1),
                    previousIndex < 0 ? 0 : seconds - previousTime);
        previousTime = seconds;
        previousIndex = index;
        return tick;
    }

    public void Count(string phase, double interval, int dropped, double updateMs)
    {
        if (!phases.TryGetValue(phase, out var frames))
            phases.Add(phase, frames = []);
        frames.Add((interval, dropped, updateMs));
    }

    public void Report(RunLog log)
    {
        foreach (var (phase, frames) in phases)
        {
            double[] intervals = frames.Where(f => f.Interval > 0).Select(f => f.Interval * 1000).Order().ToArray();
            if (intervals.Length == 0)
                continue;
            double p95 = intervals[(int)Math.Ceiling(intervals.Length * .95) - 1];
            double[] updates = frames.Select(f => f.UpdateMs).Order().ToArray();
            double updateP95 = updates[(int)Math.Ceiling(updates.Length * .95) - 1];
            log.Write(FormattableString.Invariant(
                $"frames {phase}: {frames.Count}, mean={intervals.Average():0.00}ms, p95={p95:0.00}ms, worst={intervals[^1]:0.00}ms, dropped={frames.Sum(f => f.Dropped)}, UI update p95={updateP95:0.00}ms"));
        }
    }
}

internal sealed class BootSelfTest(string directory, double readyAt)
{
    private static readonly (string Cue, double Offset, string File)[] Schedule =
    [
        ("power", .15, "00_power"), ("splash", 1.2, "01_splash"), ("login", 2.4, "02_login"),
        ("contact", .35, "03_contact"), ("scan", .40, "04_scan"), ("authorize", .35, "05_authorize"),
        ("sync", 2.5, "06_sync"), ("waiting", .15, "07_waiting"), ("sync100", .1, "08_sync100"),
        ("converge", .8, "09_converge"), ("logoForm", .35, "10_logo"), ("sweep", .45, "11_sweep"),
        ("titles", 1.6, "12_titles"), ("welcome", 1.1, "13_welcome"),
        ("handoff", .15, "14_hex_150ms"), ("handoff", .4, "15_hex_400ms"),
        ("handoff", .65, "16_hex_650ms"), ("handoff", .9, "17_hex_900ms")
    ];

    private readonly Dictionary<string, (DrawingGroup Drawing, Size Size)> snapshots = [];

    public void Capture(BootStage stage, BootDirector boot)
    {
        foreach (var (cue, offset, file) in Schedule)
        {
            if (snapshots.ContainsKey(file))
                continue;
            double time = TimeOf(boot, cue);
            if (boot.Now >= time + offset)
                snapshots.Add(file, (stage.SnapshotDrawing(), stage.RenderSize));
        }
    }

    public int Finish(BootDirector boot, Dictionary<string, Clip> clips, RunLog log)
    {
        Directory.CreateDirectory(directory);
        var failures = new List<string>();
        string[] order = ["voice_boot", "voice_login", "driver_scan", "authorize_common", "driver_standby",
            "voice_sync", "voice_sync_done", "voice_granted", "voice_welcome"];
        double previous = -1;
        foreach (string clip in order)
        {
            string name = "play " + clip;
            var plays = boot.Events.Where(e => e.Name == name).ToArray();
            if (plays.Length != 1)
                failures.Add($"{name}: expected 1, found {plays.Length}");
            else
            {
                if (plays[0].At < previous)
                    failures.Add("out of order: " + name);
                previous = plays[0].At;
            }
        }
        double scan = TimeOf(boot, "play driver_scan");
        double authorize = TimeOf(boot, "play authorize_common");
        double standby = TimeOf(boot, "play driver_standby");
        log.Write(FormattableString.Invariant($"scan → authorize {authorize - scan:0.000}s, scan → standby {standby - scan:0.000}s"));
        if (Math.Abs(authorize - scan - 19 / 30.0) > .035 || Math.Abs(standby - scan - 48 / 30.0) > .035)
            failures.Add("SWF cue spacing");

        string[] voices = order.Where(id => id.StartsWith("voice_", StringComparison.Ordinal)).ToArray();
        for (int i = 0; i < voices.Length - 1; i++)
            if (TimeOf(boot, "play " + voices[i + 1]) + .02 < TimeOf(boot, "play " + voices[i]) + clips[voices[i]].SpeechEnd)
                failures.Add("speech overlap: " + voices[i]);
        if (TimeOf(boot, "play voice_sync") + .001 < authorize + clips["authorize_common"].play_duration_s ||
            authorize < TimeOf(boot, "play voice_login") + clips["voice_login"].SpeechEnd ||
            boot.HandoffAt < TimeOf(boot, "play voice_welcome") + clips["voice_welcome"].SpeechEnd)
            failures.Add("Authorize or welcome overlap");

        double release = TimeOf(boot, readyAt <= BootDirector.Deadline ? "codex ready" : "codex timeout");
        double sync = TimeOf(boot, "sync"), full = TimeOf(boot, "sync100");
        log.Write(FormattableString.Invariant($"ready/timeout={release:0.000}s, sync={sync:0.000}s, 100%={full:0.000}s, end={boot.Now:0.000}s"));
        if (!double.IsFinite(release) || !double.IsFinite(full) || full < release || full - sync < 5.98)
            failures.Add("sync readiness/minimum duration");
        if (boot.Events.Any(e => e.Name == "sync stall"))
            failures.Add("sync stalled over 0.25s after release");
        if (readyAt <= 20 && (boot.Now < 20 || boot.Now > 30))
            failures.Add("default/late-ready duration outside 20–30s");
        if (readyAt > 20 && (boot.Now < 20 || boot.Now > 40))
            failures.Add("extended wait duration outside 20–40s");

        foreach (var (cue, _, file) in Schedule)
            if ((cue != "waiting" || readyAt >= 14) && !snapshots.ContainsKey(file))
                failures.Add("missing snapshot " + file);
        foreach (var (file, (drawing, size)) in snapshots)
        {
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
                dc.DrawDrawing(drawing);
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(size.Width), (int)Math.Ceiling(size.Height), 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            using var output = File.Create(Path.Combine(directory, file + ".png"));
            var png = new PngBitmapEncoder();
            png.Frames.Add(BitmapFrame.Create(bitmap));
            png.Save(output);
        }
        snapshots.Clear();
        log.Write(failures.Count == 0 ? "SELFTEST PASS" : "SELFTEST FAIL");
        foreach (string failure in failures)
            log.Write(failure);
        log.Save(Path.Combine(directory, "selftest.log"));
        return failures.Count == 0 ? 0 : 1;
    }

    private static double TimeOf(BootDirector boot, string name)
    {
        foreach (var entry in boot.Events)
            if (entry.Name == name)
                return entry.At;
        return double.PositiveInfinity;
    }
}
