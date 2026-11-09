using System.IO;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using NAudio.Wave;

namespace ZeroOne.Windows;

internal sealed record Clip(string id, string file, int play_start_frame, int play_frame_count,
    double play_duration_s, double audible_end_s, double? speech_end_s)
{
    public double SpeechEnd => speech_end_s ?? audible_end_s;
    public float[] Samples { get; set; } = [];
}

internal sealed class Assets
{
    private sealed record ImageEntry(string name, string file);
    private sealed record Manifest(ImageEntry[] images, Clip[] audio);
    public const int SampleRate = 44100;
    public static string Root => Path.Combine(AppContext.BaseDirectory, "Resources");
    public Dictionary<string, BitmapSource> Images { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Clip> Clips { get; } = new(StringComparer.Ordinal);

    private static BitmapSource Tint(BitmapSource source, byte r, byte g, byte b)
    {
        int stride = source.PixelWidth * 4;
        byte[] pixels = new byte[stride * source.PixelHeight];
        source.CopyPixels(pixels, stride, 0);
        for (int i = 0; i < pixels.Length; i += 4)
        {
            int a = pixels[i + 3];
            pixels[i] = (byte)(a * b / 255);
            pixels[i + 1] = (byte)(a * g / 255);
            pixels[i + 2] = (byte)(a * r / 255);
        }
        var tinted = BitmapSource.Create(source.PixelWidth, source.PixelHeight, 96, 96,
            PixelFormats.Pbgra32, null, pixels, stride);
        tinted.Freeze();
        return tinted;
    }

    public static Assets Load()
    {
        var assets = new Assets();
        var manifest = JsonSerializer.Deserialize<Manifest>(File.ReadAllText(Path.Combine(Root, "manifest.json")))
            ?? throw new InvalidDataException("素材清单为空");
        var decoded = new BitmapSource[manifest.images.Length];
        Parallel.For(0, decoded.Length, index =>
        {
            using var input = File.OpenRead(Path.Combine(Root, manifest.images[index].file));
            var bitmap = BitmapFrame.Create(input, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            var native = new FormatConvertedBitmap(bitmap, PixelFormats.Pbgra32, null, 0);
            int stride = native.PixelWidth * 4;
            byte[] pixels = new byte[stride * native.PixelHeight];
            native.CopyPixels(pixels, stride, 0);
            var image = BitmapSource.Create(native.PixelWidth, native.PixelHeight, 96, 96,
                PixelFormats.Pbgra32, null, pixels, stride);
            image.Freeze();
            decoded[index] = image;
        });
        for (int i = 0; i < decoded.Length; i++)
            assets.Images.Add(manifest.images[i].name, decoded[i]);

        assets.Images.Add("hiden_magenta", Tint(assets.Images["hiden_logo_vec"], 255, 38, 140));
        assets.Images.Add("hiden_cyan", Tint(assets.Images["hiden_logo_vec"], 25, 230, 255));
        assets.Images.Add("hex_lime", Tint(assets.Images["fx_hex_mask"], 214, 250, 13));
        assets.Images.Add("light_lime", Tint(assets.Images["fx_light_01"], 214, 250, 13));

        foreach (var clip in manifest.audio)
        {
            using var reader = new WaveFileReader(Path.Combine(Root, clip.file));
            if (reader.WaveFormat.SampleRate != SampleRate || reader.WaveFormat.Channels != 2)
                throw new InvalidDataException($"不支持的音频格式 {clip.id}: {reader.WaveFormat}");
            long start = (long)clip.play_start_frame * reader.WaveFormat.BlockAlign;
            long end = start + (long)clip.play_frame_count * reader.WaveFormat.BlockAlign;
            if (start < 0 || end > reader.Length || end <= start)
                throw new InvalidDataException($"素材清单中的采样范围无效: {clip.id}");
            reader.Position = start;
            var samples = reader.ToSampleProvider();
            clip.Samples = new float[checked(clip.play_frame_count * 2)];
            int read = 0;
            while (read < clip.Samples.Length)
            {
                int count = samples.Read(clip.Samples, read, clip.Samples.Length - read);
                if (count == 0)
                    throw new EndOfStreamException($"音频在清单指定的区间结束前读完: {clip.id}");
                read += count;
            }
            assets.Clips.Add(clip.id, clip);
        }
        return assets;
    }
}
