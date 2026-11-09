using System.Collections.Concurrent;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace ZeroOne.Windows;

internal enum Channel { Hud, Key, Fx, Impact, Shine, Chatter, Scan, Authorize, Standby, Announce }

internal sealed class AudioMixer : ISampleProvider
{
    private sealed record Cue(Channel Channel, Clip Clip, float Gain, bool Loop, int Delay = 0);
    private sealed record Stop(Channel? Channel, int Fade);
    private sealed class Voice(Cue cue)
    {
        public Cue Cue { get; } = cue;
        public int Offset;
        public int Fade, FadeLeft;
    }

    private readonly ConcurrentQueue<object> commands = new();
    private readonly Voice?[] voices = new Voice?[Enum.GetValues<Channel>().Length];
    private readonly List<(long Frame, Cue Cue)> scheduled = [];
    private readonly CancellationTokenSource shutdown = new();
    private readonly Dictionary<string, Clip> clips;
    private long frame;
    private float limiter = 1;
    private readonly Task worker;
    private volatile bool active;

    private static readonly Dictionary<string, (Channel Channel, float Gain)> Effects = new()
    {
        ["boot"] = (Channel.Hud, .42f), ["tick"] = (Channel.Hud, .22f),
        ["type"] = (Channel.Key, .15f), ["lock"] = (Channel.Key, .17f),
        ["panel"] = (Channel.Fx, .30f), ["swish"] = (Channel.Fx, .21f),
        ["granted"] = (Channel.Hud, .40f), ["chatter"] = (Channel.Chatter, .20f),
        ["converge"] = (Channel.Impact, .42f), ["boom"] = (Channel.Impact, .58f),
        ["shimmer"] = (Channel.Shine, .32f), ["slam"] = (Channel.Fx, .44f),
        ["flip"] = (Channel.Fx, .36f), ["whoosh"] = (Channel.Hud, .30f)
    };

    public AudioMixer(Dictionary<string, Clip> clips, bool muted, Action<string> log)
    {
        this.clips = clips;
        active = !muted;
        worker = muted ? Task.CompletedTask : Task.Run(() =>
        {
            try
            {
                using var stopped = new ManualResetEventSlim();
                using var output = new WasapiOut(AudioClientShareMode.Shared, true, 45);
                output.PlaybackStopped += (_, e) =>
                {
                    if (e.Exception is not null)
                        log("audio device stopped: " + e.Exception.Message);
                    stopped.Set();
                };
                output.Init(this.ToWaveProvider());
                output.Play();
                log("WASAPI shared output started");
                WaitHandle.WaitAny([shutdown.Token.WaitHandle, stopped.WaitHandle]);
                output.Stop();
            }
            catch (Exception error)
            {
                log("audio unavailable: " + error.Message);
            }
            finally { active = false; }
        });
    }

    public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(Assets.SampleRate, 2);

    private void Play(string name, Channel channel, float gain, bool loop = false, double delay = 0)
    {
        if (active)
            commands.Enqueue(new Cue(channel, clips[name], gain, loop, (int)Math.Round(delay * Assets.SampleRate)));
    }

    public void PlayEffect(string name, bool loop = false)
    {
        var (channel, gain) = Effects[name];
        Play("sfx_" + name, channel, gain, loop);
    }

    public void PlayVoice(string name) => Play("voice_" + name, Channel.Announce, .95f);

    public void Driver()
    {
        Play("driver_scan", Channel.Scan, .7f);
        Play("authorize_common", Channel.Authorize, .7f, delay: 19 / 30.0);
        Play("driver_standby", Channel.Standby, .4f, loop: true, delay: 48 / 30.0);
    }

    public void Fade(Channel channel, double seconds)
    {
        if (active)
            commands.Enqueue(new Stop(channel, (int)(seconds * Assets.SampleRate)));
    }

    public void Skip()
    {
        if (active)
            commands.Enqueue(new Stop(null, Assets.SampleRate / 4));
    }

    public async Task CloseAsync()
    {
        shutdown.Cancel();
        await worker;
        shutdown.Dispose();
    }

    public int Read(float[] buffer, int offset, int count)
    {
        while (commands.TryDequeue(out var command))
        {
            if (command is Cue cue)
            {
                if (cue.Delay == 0)
                    voices[(int)cue.Channel] = new Voice(cue);
                else
                    scheduled.Add((frame + cue.Delay, cue));
                continue;
            }
            var stop = (Stop)command;
            if (stop.Channel is Channel channel)
                FadeVoice(channel, stop.Fade);
            else
            {
                scheduled.Clear();
                foreach (Channel item in Enum.GetValues<Channel>())
                    if (item is not (Channel.Announce or Channel.Authorize or Channel.Scan))
                        FadeVoice(item, stop.Fade);
            }
        }

        for (int sample = offset; sample + 1 < offset + count; sample += 2, frame++)
        {
            while (scheduled.Count > 0 && frame >= scheduled[0].Frame)
            {
                var cue = scheduled[0].Cue;
                scheduled.RemoveAt(0);
                voices[(int)cue.Channel] = new Voice(cue);
            }
            float left = 0, right = 0;
            for (int ch = 0; ch < voices.Length; ch++)
            {
                if (voices[ch] is not { } voice)
                    continue;
                float gain = voice.Cue.Gain * (voice.Fade == 0 ? 1 : (float)voice.FadeLeft / voice.Fade);
                float[] data = voice.Cue.Clip.Samples;
                left += data[voice.Offset++] * gain;
                right += data[voice.Offset++] * gain;
                if (voice.Fade > 0 && --voice.FadeLeft == 0)
                    voices[ch] = null;
                else if (voice.Offset >= data.Length)
                {
                    if (voice.Cue.Loop)
                        voice.Offset = 0;
                    else
                        voices[ch] = null;
                }
            }
            left *= .85f;
            right *= .85f;
            float peak = Math.Max(Math.Abs(left), Math.Abs(right));
            limiter = Math.Min(limiter + (1 - limiter) * .0008f, peak > .98f ? .98f / peak : 1);
            buffer[sample] = left * limiter;
            buffer[sample + 1] = right * limiter;
        }
        return count;
    }

    private void FadeVoice(Channel channel, int frames)
    {
        if (voices[(int)channel] is { } voice)
            voice.Fade = voice.FadeLeft = frames;
    }
}
