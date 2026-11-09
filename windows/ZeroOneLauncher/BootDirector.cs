using System.Globalization;

namespace ZeroOne.Windows;

internal sealed class BootDirector(AudioMixer audio, Dictionary<string, Clip> clips, Action<string> log)
{
    public const double ScanAt = 6.45;
    public const double AuthorizeAt = ScanAt + 19 / 30.0;
    public const double SyncAt = ScanAt + 48 / 30.0;
    public const double RevealLength = 1.12;
    public const double Deadline = 30;
    private const double Uniform = 100.0 / 6;

    public static readonly (string Label, string Value, double At)[] Profile =
    [
        ("社員番号", "HI-0001", 3.55), ("氏　名", "飛電 或人", 4.0),
        ("役　職", "代表取締役社長", 4.45), ("権　限", "レベル01　全権限", 4.95),
        ("端　末", "CODEX 作業端末　Windows", 5.5)
    ];

    public readonly List<(double At, string Name)> Events = [];
    public readonly List<(string Text, bool Highlight)> Terminal = [];
    private readonly HashSet<string> dispatched = new(StringComparer.Ordinal);
    private double lastSyncTime = SyncAt;
    private double speed = Uniform, targetSpeed = Uniform, speedFrom = Uniform, speedChangeAt;
    private double lastRise = SyncAt;
    private double skipAt = double.PositiveInfinity;
    private double welcomeEnd;
    private double sync100At = double.PositiveInfinity;
    public double Now { get; private set; }
    public double Progress { get; private set; }
    public double HandoffAt { get; private set; } = double.PositiveInfinity;
    public double LogoTime => Now - sync100At - .5;
    public double RevealTime => Now - HandoffAt;
    public bool Skipped => !double.IsPositiveInfinity(skipAt);
    public bool Released { get; private set; }
    public bool Finished => RevealTime >= RevealLength;
    public bool Waiting { get; private set; }
    public bool Ready { get; private set; }
    public bool TimedOut { get; private set; }
    public bool Forced { get; private set; }
    public bool Missing { get; set; }
    public bool Existing { get; set; }
    public double StampAt => 3.25;
    public double WelcomeAt => StampAt + clips["voice_granted"].SpeechEnd + .12;
    public double FinaleAt => Math.Max(6.3, WelcomeAt + clips["voice_welcome"].SpeechEnd + .15);
    public string Phase => RevealTime >= 0 ? "handoff" : Skipped || !double.IsPositiveInfinity(sync100At) ? "logo"
        : Now >= SyncAt ? "sync" : Now >= ScanAt ? "scan+auth" : Now >= 3.2 ? "login" : "boot";
    public string Status { get; private set; } = "起動中";

    public void Frame(double time, bool ready, bool skinned, double? launchedAt, double? simulatedReady)
    {
        Now = time;
        if (!Released)
        {
            if (ready && Existing)
                Release("codex already running", "CODEX　起動済み");
            else if (ready && Missing)
                Release("codex unavailable", "CODEX　未検出");
            else if (ready || (simulatedReady is double at && time >= at))
                Release("codex ready", "CODEX 画面　準備完了", genuine: !Existing && !Missing);
            else if (launchedAt is double launch && time - launch >= Deadline)
            {
                TimedOut = true;
                Release("codex timeout", "CODEX　応答待ち超過・続行");
            }
        }

        if (RevealTime >= 0)
            return;
        if (Skipped)
        {
            if (Released && time >= Math.Max(skipAt + .8, welcomeEnd))
                Handoff();
            return;
        }

        At(0, "power", () => Effect("boot"));
        At(.35, "hud", () => { Line("飛電インテリジェンス　システム起動"); Effect("tick"); });
        At(.6, "splash", () => { });
        At(.70, "boot voice", () => Voice("boot"));
        At(1.3, "network", () => { Line("社内ネットワーク　接続完了"); Effect("tick"); });
        At(2.0, "satellite", () => { Line("衛星ゼア　応答良好"); Effect("tick"); });
        At(2.6, "cipher", () => { Line("暗号通信　AES-256 確立"); Effect("tick"); });
        At(3.2, "login", () => { Status = "ログイン"; Effect("panel"); });
        At(3.45, "login voice", () => Voice("login"));
        if (time >= 3.55 && time < ScanAt)
        {
            foreach (var (_, value, at) in Profile)
            {
                int count = Math.Min(value.Length, Math.Max(0, (int)((time - at) * 30 + .0001)));
                if (count > 0)
                    At(at + count / 30.0, $"type {at} {count}", () => { if (count % 2 != 0) Effect("type"); });
            }
        }
        At(6, "contact", () => Effect("tick"));
        At(ScanAt, "scan", () => { Line("生体認証　照合開始"); Record("play driver_scan"); audio.Driver(); });
        for (int i = 0; i < 5; i++)
            At(ScanAt + (19 / 30.0 + .05) * (.18 + .11 * i), $"lock {i}", () => Effect("lock"));
        At(AuthorizeAt, "authorize", () =>
        {
            Record("play authorize_common");
            Line("認証　承認", true);
            Effect("swish");
        });
        At(SyncAt, "sync", () =>
        {
            Status = Existing ? "起動済み" : Missing ? "未検出" : "接続中";
            Record("play driver_standby");
            Effect("chatter", loop: true);
            Line("衛星ゼア　同期開始");
        });
        At(SyncAt + .3, "sync voice", () => Voice("sync"));
        At(SyncAt + 1.2, "skin status", () => Line(skinned ? "CODEX　飛電テーマ適用" : "CODEX　待機中"));

        if (time >= SyncAt && double.IsPositiveInfinity(sync100At))
            TickSync();
        if (double.IsPositiveInfinity(sync100At))
            return;

        double start = sync100At + .5;
        At(start, "collapse", () =>
        {
            Status = "承認処理中";
            Line("飛電システム　最終承認");
            audio.Fade(Channel.Standby, .9);
        });
        At(start + .4, "converge", () => Effect("converge"));
        At(start + 1.7, "logoForm", () => Effect("boom"));
        At(start + 2.4, "sweep", () => Effect("shimmer"));
        At(start + 2.9, "titles", () =>
        {
            Status = Missing ? "CODEX 未検出" : "アクセス承認";
            Line("アクセス承認　お帰りなさいませ、社長", true);
        });
        At(start + StampAt, "stamp", () => { Effect("slam"); Voice("granted"); });
        At(start + WelcomeAt, "welcome", () =>
        {
            Voice("welcome");
            welcomeEnd = Now + clips["voice_welcome"].SpeechEnd + .15;
        });
        if (time >= Math.Max(start + FinaleAt, welcomeEnd))
            Handoff();
    }

    private void TickSync()
    {
        double dt = Now - lastSyncTime;
        if (dt <= 0)
            return;
        double desired = !Released && Progress >= 90 ? .8 : Uniform;
        if (desired != targetSpeed)
        {
            speedFrom = speed;
            targetSpeed = desired;
            speedChangeAt = lastSyncTime;
        }
        double blend = Math.Clamp((Now - speedChangeAt) / .3, 0, 1);
        double newSpeed = speedFrom + (targetSpeed - speedFrom) * blend * blend * (3 - 2 * blend);
        double next = Math.Min(Released ? 100 : 99, Progress + (newSpeed + speed) * .5 * dt);
        if (Released && Now - Math.Max(lastRise, Events.LastOrDefault(e =>
                e.Name is "codex ready" or "codex timeout").At) > .25)
            At(0, "sync stall", () => { });
        if (next > Progress + .00001)
            lastRise = Now;
        lastSyncTime = Now;
        speed = newSpeed;
        Progress = next;

        if (!Released && Progress >= 90 && !Waiting)
        {
            Waiting = true;
            Status = "応答待ち";
            Record("waiting");
            Line("CODEX 画面の準備を待機中…");
        }
        if (Released && Progress >= 100 - 1e-8)
        {
            Progress = 100;
            sync100At = Now;
            Record("sync100");
            audio.Fade(Channel.Chatter, .2);
            Effect("granted");
            Voice("sync_done");
            Line("同期率　100%", true);
        }
    }

    public void Skip()
    {
        if (RevealTime >= 0)
            return;
        if (!Skipped)
        {
            skipAt = Now;
            Waiting = !Released;
            Status = Waiting ? "応答待ち" : "アクセス承認";
            Record("skip");
            audio.Skip();
            Effect("slam");
        }
        else if (!Released)
        {
            Forced = true;
            Release("forced", "CODEX　社長権限で強制接続");
        }
    }

    private void Release(string reason, string text, bool genuine = false)
    {
        Released = true;
        Ready = genuine;
        if (Waiting)
            Status = Skipped ? "アクセス承認" : "接続中";
        Waiting = false;
        Record(reason);
        Line(text, true);
    }

    private void Handoff()
    {
        HandoffAt = Now;
        Record("handoff");
        Effect("flip");
        Effect("whoosh");
    }

    private void At(double time, string name, Action action)
    {
        if (Now + 1e-8 < time || !dispatched.Add(name))
            return;
        Record(name);
        action();
    }

    private void Effect(string name, bool loop = false) => audio.PlayEffect(name, loop);

    private void Voice(string name)
    {
        Record("play voice_" + name);
        audio.PlayVoice(name);
    }

    private void Line(string text, bool highlight = false)
    {
        Terminal.Add((text, highlight));
        if (Terminal.Count > 7)
            Terminal.RemoveAt(0);
    }

    private void Record(string name)
    {
        Events.Add((Now, name));
        log(Now.ToString("0.000", CultureInfo.InvariantCulture) + " " + name);
    }
}
