using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ZeroOne.Windows;

internal sealed partial class BootStage : FrameworkElement
{
    private static readonly Color Accent = Color.FromRgb(214, 250, 13);
    private static readonly Rect Canvas = new(0, 0, 1600, 1000);
    private static readonly Point Center = new(800, 480), LogoCenter = new(800, 390);
    private static readonly Rect Panel = new(300, 230, 1000, 500), Scanner = new(900, 300, 340, 360);
    private static readonly CultureInfo Japanese = CultureInfo.GetCultureInfo("ja-JP");
    private static readonly Typeface Sans = new(new FontFamily("Yu Gothic UI, Meiryo"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    private static readonly Typeface Heavy = new(new FontFamily("Yu Gothic UI, Meiryo"), FontStyles.Normal, FontWeights.Heavy, FontStretches.Normal);
    private static readonly Typeface Mincho = new(new FontFamily("Yu Mincho, MS Mincho"), FontStyles.Normal, FontWeights.DemiBold, FontStretches.Normal);
    private static readonly Typeface Mono = new(new FontFamily("Consolas, Yu Gothic UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
    private static readonly string[] PanelLabels = ["通信", "衛星", "暗号", "認証", "生体", "承認", "同期", "演算", "CODEX", "展開", "防壁", "接続"];
    private readonly Dictionary<(Color Color, byte Alpha), SolidColorBrush> brushes = [];
    private readonly Dictionary<(char Char, Typeface Font, double Size, Brush Brush), FormattedText> glyphs = [];
    private readonly Dictionary<string, BitmapSource> images;
    private readonly Dictionary<(string Value, Typeface Font, double Size, Brush Brush, double Tracking), (DrawingGroup Drawing, double Width)> textCache = [];
    private readonly DrawingVisual visual = new(), revealVisual = new();
    public FrameworkElement RevealSurface { get; }
    private bool drawingReveal;
    private readonly DrawingGroup background, hud, login, ring, card, rainLeft, rainRight;
    private readonly DrawingGroup[,] modules = new DrawingGroup[12, 3];
    private DrawingGroup? terminalInk;
    private (string? Last, string? Status, int Count) terminalKey;
    private Task<BitmapSource>? revealFrame;
    private readonly Point[] panelCenters;
    private readonly Geometry[] panels;
    private readonly ImageBrush logoMask;
    private readonly Geometry fingerprintTip;
    private readonly Point[][] ridges;
    private readonly Point[] minutiae;
    private readonly DrawingGroup allRidges, litRidges, whiteRidges;
    private readonly Rect splashLogo, finalLogo;
    private readonly (double Angle, double Radius, double Delay, double Size)[] fragments;
    private readonly (double X, double Length, double Delay)[] slices;
    private readonly (double X, double Y, double Angle, double Speed, double Size, double Life)[] sparks;
    private DrawingGroup? lastScene;
    private HexReveal? hex;

    public BootStage(Assets assets)
    {
        images = assets.Images;
        AddVisualChild(visual);
        RevealSurface = new VisualHost(revealVisual);
        TextOptions.SetTextRenderingMode(this, TextRenderingMode.Grayscale);
        var logo = images["hiden_logo_vec"];
        double aspect = (double)logo.PixelHeight / logo.PixelWidth;
        double width = Math.Min(720, logo.PixelWidth / 2.0);
        finalLogo = new(LogoCenter.X - width / 2, LogoCenter.Y - width * aspect / 2, width, width * aspect);
        width = Math.Min(640, logo.PixelWidth / 2.0);
        splashLogo = new(800 - width / 2, 400 - width * aspect / 2, width, width * aspect);
        logoMask = Freeze(new ImageBrush(logo));
        panelCenters = Enumerable.Range(0, 12).Select(i =>
        {
            int row = i % 6;
            double x = 104 + row % 2 * 88;
            return new Point(i < 6 ? x : 1600 - x, 200 + row * 76);
        }).ToArray();
        panels = panelCenters.Select(p => Polygon(HexPoints(p, 50))).ToArray();
        (ridges, minutiae) = MakeFingerprint();
        fingerprintTip = Freeze(new EllipseGeometry(new Point(1070, 472), 118, 148));
        allRidges = Drawing(dc => StrokeRidges(dc, 1, Line(Accent, 1.6, .18)));
        litRidges = Drawing(dc => StrokeRidges(dc, 1, Line(Accent, 2)));
        whiteRidges = Drawing(dc => StrokeRidges(dc, 1, Line(Colors.White, 2)));
        var rng = new Random(0xC0DE);
        fragments = Enumerable.Range(0, 70).Select(i =>
            (rng.NextDouble() * Math.Tau, Range(rng, 480, 950), Range(rng, 0, .45), i < 44 ? Range(rng, 5, 18) : Range(rng, 60, 180))).ToArray();
        slices = Enumerable.Range(0, 9).Select(_ => (Range(rng, -140, 140), Range(rng, .4, .65), Range(rng, 0, .12))).ToArray();
        sparks = Enumerable.Range(0, 37).Select(_ => (Range(rng, -300, 300), Range(rng, -60, 60),
            Range(rng, 0, Math.Tau), Range(rng, 180, 520), Range(rng, 8, 36), Range(rng, .55, 1.5))).ToArray();
        var rain = new Random(0x7001);
        rainLeft = Rasterize(Drawing(dc => BuildRain(dc, rain, 18)), new Rect(16, 0, 30, 1040));
        rainRight = Rasterize(Drawing(dc => BuildRain(dc, rain, 1562)), new Rect(1560, 0, 30, 1040));
        for (int i = 0; i < panels.Length; i++)
        {
            int index = i;
            for (int state = 0; state < 3; state++)
            {
                int kind = state;
                modules[i, state] = Drawing(dc => DrawModule(dc, index, kind));
            }
        }
        background = Rasterize(Drawing(BuildBackground), Canvas);
        hud = Drawing(BuildHud);
        login = Rasterize(Drawing(BuildLogin), new Rect(296, 226, 1008, 508));
        ring = Drawing(BuildRing);
        card = Drawing(BuildCard);
    }

    private sealed class VisualHost : FrameworkElement
    {
        private readonly DrawingVisual child;
        public VisualHost(DrawingVisual child)
        {
            this.child = child;
            AddVisualChild(child);
        }

        protected override int VisualChildrenCount => 1;
        protected override Visual GetVisualChild(int index) =>
            index == 0 ? child : throw new ArgumentOutOfRangeException(nameof(index));
    }

    protected override int VisualChildrenCount => 1;
    protected override Visual GetVisualChild(int index) => index == 0 ? visual : throw new ArgumentOutOfRangeException(nameof(index));

    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo)
    {
        base.OnRenderSizeChanged(sizeInfo);
        if (ActualWidth > 0 && ActualHeight > 0)
            hex = new HexReveal(RenderSize, MapLogo(), Line(Accent, 1.5));
    }

    private Point MapLogo()
    {
        double scale = Math.Min(ActualWidth / 1600, ActualHeight / 1000);
        return new((ActualWidth - 1600 * scale) / 2 + LogoCenter.X * scale,
                   (ActualHeight - 1000 * scale) / 2 + LogoCenter.Y * scale);
    }

    public void Render(BootDirector boot, bool preview)
    {
        if (ActualWidth <= 0 || ActualHeight <= 0)
            return;
        if (boot.RevealTime >= 0 && lastScene is not null)
        {
            drawingReveal = true;
            using var overlay = revealVisual.RenderOpen();
            if (preview)
                overlay.DrawRectangle(Brush(Color.FromRgb(51, 26, 77)), null, new Rect(RenderSize));
            Drawing revealInk = lastScene;
            if (revealFrame is { IsCompletedSuccessfully: true })
                revealInk = new ImageDrawing(revealFrame.Result, new Rect(RenderSize));
            hex?.Draw(overlay, revealInk, boot.RevealTime);
            return;
        }

        var scene = new DrawingGroup();
        using (var stage = scene.Open())
        {
            double scale = Math.Min(ActualWidth / 1600, ActualHeight / 1000);
            stage.DrawRectangle(Brushes.Black, null, new Rect(RenderSize));
            stage.PushTransform(new TranslateTransform((ActualWidth - 1600 * scale) / 2, (ActualHeight - 1000 * scale) / 2));
            stage.PushTransform(new ScaleTransform(scale, scale));
            stage.PushClip(new RectangleGeometry(Canvas));
            DrawStage(stage, boot);
            stage.Pop();
            stage.Pop();
            stage.Pop();
        }
        lastScene = scene;
        using var dc = visual.RenderOpen();
        dc.DrawDrawing(scene);
        if (revealFrame is null && (boot.Skipped || boot.LogoTime >= boot.FinaleAt - .3))
            PrepareReveal(scene);
    }

    private void PrepareReveal(DrawingGroup scene)
    {
        scene.Freeze();
        Size size = RenderSize;
        DpiScale dpi = VisualTreeHelper.GetDpi(this);
        var promise = new TaskCompletionSource<BitmapSource>(TaskCreationOptions.RunContinuationsAsynchronously);
        revealFrame = promise.Task;
        var rasterizer = new Thread(() =>
        {
            try
            {
                var target = new DrawingVisual();
                using (var dc = target.RenderOpen())
                    dc.DrawDrawing(scene);
                var bitmap = new RenderTargetBitmap((int)Math.Ceiling(size.Width * dpi.DpiScaleX),
                    (int)Math.Ceiling(size.Height * dpi.DpiScaleY), dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
                bitmap.Render(target);
                bitmap.Freeze();
                promise.TrySetResult(bitmap);
            }
            catch
            {
                promise.TrySetCanceled(); // The existing vector scene is the fallback.
            }
        }) { IsBackground = true };
        rasterizer.SetApartmentState(ApartmentState.STA);
        rasterizer.Start();
    }


    public DrawingGroup SnapshotDrawing()
    {
        var drawing = (drawingReveal ? revealVisual : visual).Drawing;
        drawing.Freeze();
        return drawing;
    }

    private void DrawStage(DrawingContext dc, BootDirector boot)
    {
        double now = boot.Now, logo = boot.LogoTime;
        double authorize = now - BootDirector.AuthorizeAt;
        if (!boot.Skipped && authorize >= .30 && authorize <= 1.2)
        {
            DrawCard(dc, authorize);
            return;
        }
        dc.DrawDrawing(background);
        var textureRect = new Rect(-50, -350, 1700, 1700);
        double hexOpacity = boot.Skipped ? .14 : logo >= 1.7 ? .14 + .31 * Math.Max(0, 1 - Math.Abs(logo - 1.89) / 1.41) : .06 * Unit((now - .4) / 1.2);
        DrawImage(dc, "hex_lime", textureRect, hexOpacity);

        if (now >= .35)
        {
            dc.PushOpacity(Unit((now - .35) / .4));
            DrawHud(dc, boot);
            dc.Pop();
        }
        if (boot.Skipped)
            DrawFinale(dc, boot, boot.FinaleAt, true);
        else
        {
            if (now >= .6 && now < 3.35)
                DrawSplash(dc, now);
            if (now >= 3.2 && now < BootDirector.SyncAt + .3)
                DrawLogin(dc, now);
            if (now >= BootDirector.SyncAt && logo < .45)
                DrawRing(dc, boot);
            if (logo >= 0)
                DrawFinale(dc, boot, logo, false);
            if (authorize >= 0 && authorize < 1.35)
                DrawCard(dc, authorize);
        }
        if (now < .62)
        {
            double t = now / .62;
            double width = 1600 * EaseOut(now / .28);
            double h = Key(t, [0, .45, .7, 1], [2, 2, 600, 0]);
            double opacity = Key(t, [0, .60, .85, 1], [1, 1, .35, 0]);
            Glow(dc, new Rect(800 - width / 2, 500 - h / 2 - 12, width, h + 24), .8 * opacity);
            dc.DrawRectangle(Brush(Colors.White, opacity), null, new Rect(800 - width / 2, 500 - h / 2, width, h));
        }
    }

    private void BuildBackground(DrawingContext dc)
    {
        dc.DrawRectangle(Brush(Color.FromRgb(3, 5, 4)), null, Canvas);
        Grid(dc, Canvas, 40, .035);
        var shade = Freeze(new RadialGradientBrush(Color.FromArgb(0, 0, 0, 0), Color.FromArgb(230, 0, 0, 0))
        {
            Center = new Point(.5, .5), GradientOrigin = new Point(.5, .5), RadiusX = .68, RadiusY = .76
        });
        dc.DrawRectangle(shade, null, Canvas);
        var scan = new StreamGeometry();
        using (var g = scan.Open())
            for (int y = 0; y < 1000; y += 3)
            {
                g.BeginFigure(new Point(0, y), false, false);
                g.LineTo(new Point(1600, y), true, false);
            }
        dc.DrawGeometry(null, Line(Colors.White, 1, .025), Freeze(scan));
    }

    private void BuildHud(DrawingContext dc)
    {
        Brackets(dc, new Rect(26, 26, 1548, 948), 70, Line(Accent, 2, .85));
        dc.DrawImage(images["hiden_logo_vec"], new Rect(54, 46, 140, 40));
        Text(dc, "飛電インテリジェンス　社内ネットワーク", 214, 50, 13, Brush(Accent, .85), Sans, 4);
        Text(dc, "機密端末　／　CODEX 作業環境", 1546, 50, 13, Brush(Accent, .85), Sans, 4, TextAlignment.Right);
        var dash = Line(Accent, 1, .22, new DashStyle([2, 6], 0));
        dc.DrawLine(dash, new Point(54, 112), new Point(1546, 112));
        dc.DrawLine(dash, new Point(54, 800), new Point(1546, 800));
        Text(dc, "利用者　飛電 或人　／　接続先　CODEX", 1546, 878, 12.5, Brush(Accent, .8), Sans, 2, TextAlignment.Right);
    }

    private void DrawHud(DrawingContext dc, BootDirector boot)
    {
        dc.DrawDrawing(hud);
        double now = boot.Now;
        double clock = Math.Min(boot.HandoffAt, now);
        string stamp = FormattableString.Invariant($"T+{(int)clock / 60:00}:{clock % 60:00.00}");
        Text(dc, stamp, 1546, 74, 22, Brushes.White, Mono, 3, TextAlignment.Right);
        if (now >= .6)
        {
            dc.PushOpacity(Unit((now - .6) / 1));
            dc.PushClip(new RectangleGeometry(new Rect(0, 0, 1600, 500)));
            dc.PushTransform(new TranslateTransform(0, (now * 25) % 520 - 520));
            dc.DrawDrawing(rainLeft);
            dc.Pop();
            dc.PushTransform(new TranslateTransform(0, -(now * 25) % 520));
            dc.DrawDrawing(rainRight);
            dc.Pop();
            dc.Pop();
            dc.Pop();
        }
        for (int i = 0; i < panels.Length; i++)
        {
            bool lit = boot.Skipped || (i switch
            {
                0 => now >= 1.3, 1 => now >= 2, 2 => now >= 2.6, 3 => now >= 6.4,
                4 or 5 => now >= BootDirector.AuthorizeAt, _ => boot.Progress >= (i - 5) * 100.0 / 6
            });
            bool blink = !lit && ((now >= .6 + i * .06 && now < 1.5) ||
                (i == 3 && now >= 3.2) || (i == 4 && now >= BootDirector.ScanAt) ||
                (i >= 6 && now >= BootDirector.SyncAt && i == 6 + (int)(boot.Progress * .06)));
            if (blink)
                dc.PushOpacity(.25 + .75 * (.5 + .5 * Math.Cos(now * Math.PI / .18)));
            dc.DrawDrawing(modules[i, lit ? 2 : blink ? 1 : 0]);
            if (blink)
                dc.Pop();
        }

        var key = (boot.Terminal.LastOrDefault().Text, boot.Status, boot.Terminal.Count);
        if (terminalInk is null || terminalKey != key)
        {
            terminalKey = key;
            terminalInk = Drawing(ink =>
            {
                for (int i = 0; i < boot.Terminal.Count; i++)
                {
                    var (line, highlight) = boot.Terminal[i];
                    bool last = i == boot.Terminal.Count - 1;
                    Text(ink, "▸ " + line, 54, 812 + i * 16, 12.5,
                        last && highlight ? Brushes.White : Brush(Accent, last ? 1 : .5), Mono, 1.5);
                }
                Text(ink, "状態　" + boot.Status, 1546, 898, 15, Brushes.White, Sans, 3, TextAlignment.Right);
            });
        }
        dc.DrawDrawing(terminalInk);
    }

    private void DrawModule(DrawingContext dc, int i, int state)
    {
        var tint = state == 1 ? Colors.OrangeRed : Accent;
        dc.DrawGeometry(Brush(tint, state == 2 ? .85 : state == 1 ? .25 : .03),
            Line(tint, 1.5, state == 0 ? .28 : 1), panels[i]);
        Text(dc, PanelLabels[i], panelCenters[i].X, panelCenters[i].Y - 10, i == 8 ? 11 : 15,
            state == 2 ? Brushes.Black : state == 1 ? Brushes.White : Brush(Accent, .5), i == 8 ? Mono : Sans, 2, TextAlignment.Center);
    }

    private void BuildRain(DrawingContext dc, Random random, int x)
    {
        for (int row = 0; row < 40; row++)
        {
            string bits = Convert.ToString(random.Next(0, 4), 2).PadLeft(2, '0');
            var tone = Brush(Accent, .12 + random.NextDouble() * .17);
            Text(dc, bits, x, row * 13, 10, tone, Mono, 2);
            Text(dc, bits, x, row * 13 + 520, 10, tone, Mono, 2);
        }
    }

    private void DrawSplash(DrawingContext dc, double now)
    {
        double t = now - .6;
        double close = Unit((now - 3) / .35);
        double y = splashLogo.Bottom;
        double scale = (1 + .05 * (1 - EaseOut(t / 1.6))) * (1 - .08 * close);
        dc.PushTransform(new ScaleTransform(scale, scale, 800, 400));
        dc.PushOpacity(1 - close);
        Glow(dc, new Rect(splashLogo.X - 100, splashLogo.Y - 70, splashLogo.Width + 200, splashLogo.Height + 140), .43);
        dc.PushOpacity(Key(t / .5, [0, .2, .3, .45, .55, 1], [0, 1, .25, 1, .7, 1]));
        dc.DrawImage(images["hiden_logo_vec"], splashLogo);
        dc.Pop();
        Fade(dc, (t - .3) / .4, () => Text(dc, "飛電インテリジェンス", 800, y + 34, 30, Brushes.White, Mincho, 14, TextAlignment.Center));
        Fade(dc, (t - .48) / .4, () => Text(dc, "新時代の人工知能技術　・　社内システム起動中", 800, y + 86, 15, Brush(Accent), Sans, 6, TextAlignment.Center));
        Fade(dc, (t - .66) / .4, () =>
        {
            dc.DrawRectangle(Brush(Accent, .18), null, new Rect(600, y + 132, 400, 3));
            dc.DrawRectangle(Brush(Accent), null, new Rect(600, y + 132, 400 * EaseInOut(t / 2.2), 3));
        });
        dc.Pop();
        dc.Pop();
    }

    private void Text(DrawingContext dc, string value, double x, double y, double size,
                      Brush brush, Typeface font, double tracking = 0, TextAlignment align = TextAlignment.Left)
    {
        if (glyphs.Count > 2800)
            glyphs.Clear();
        if (textCache.Count > 2400)
            textCache.Clear();
        var key = (value, font, size, brush, tracking);
        if (!textCache.TryGetValue(key, out var text))
        {
            var drawing = new DrawingGroup();
            double advance = 0;
            using (var ink = drawing.Open())
                foreach (char ch in value)
                {
                    var glyph = Glyph(ch);
                    ink.DrawText(glyph, new Point(advance, 0));
                    advance += glyph.WidthIncludingTrailingWhitespace + tracking;
                }
            text = (Freeze(drawing), Math.Max(0, advance - tracking));
            textCache.Add(key, text);
        }
        if (align == TextAlignment.Center)
            x -= text.Width / 2;
        else if (align == TextAlignment.Right)
            x -= text.Width;
        dc.PushTransform(new TranslateTransform(x, y));
        dc.DrawDrawing(text.Drawing);
        dc.Pop();

        FormattedText Glyph(char ch)
        {
            var key = (ch, font, size, brush);
            if (!glyphs.TryGetValue(key, out var run))
            {
                run = new FormattedText(ch.ToString(), Japanese, FlowDirection.LeftToRight, font, size, brush, 1);
                glyphs.Add(key, run);
            }
            return run;
        }
    }

    private SolidColorBrush Brush(Color color, double opacity = 1)
    {
        byte alpha = (byte)Math.Round(Unit(opacity) * 255);
        if (!brushes.TryGetValue((color, alpha), out var brush))
        {
            brush = Freeze(new SolidColorBrush(Color.FromArgb(alpha, color.R, color.G, color.B)));
            brushes.Add((color, alpha), brush);
        }
        return brush;
    }

    private Pen Line(Color color, double width, double opacity = 1, DashStyle? dash = null)
    {
        var pen = new Pen(Brush(color, opacity), width);
        if (dash is not null)
            pen.DashStyle = dash;
        return Freeze(pen);
    }

    private void Glow(DrawingContext dc, Rect bounds, double opacity)
    {
        dc.PushOpacity(Unit(opacity));
        dc.DrawImage(images["fx_light_01"], bounds);
        dc.Pop();
    }

    private void DrawImage(DrawingContext dc, string key, Rect bounds, double opacity)
    {
        dc.PushOpacity(Unit(opacity));
        dc.DrawImage(images[key], bounds);
        dc.Pop();
    }

    private void Grid(DrawingContext dc, Rect rect, int step, double opacity)
    {
        var pen = Line(Accent, 1, opacity);
        for (double x = rect.Left; x <= rect.Right; x += step)
            dc.DrawLine(pen, new Point(x, rect.Top), new Point(x, rect.Bottom));
        for (double y = rect.Top; y <= rect.Bottom; y += step)
            dc.DrawLine(pen, new Point(rect.Left, y), new Point(rect.Right, y));
    }

    private static void Brackets(DrawingContext dc, Rect box, double length, Pen pen)
    {
        foreach (var (x, y, dx, dy) in new[] { (box.Left, box.Top, 1, 1), (box.Right, box.Top, -1, 1),
            (box.Left, box.Bottom, 1, -1), (box.Right, box.Bottom, -1, -1) })
            dc.DrawGeometry(null, pen, Polygon([new Point(x + dx * length, y), new Point(x, y), new Point(x, y + dy * length)], false));
    }

    private static void Fade(DrawingContext dc, double opacity, Action draw)
    {
        if (opacity <= 0)
            return;
        dc.PushOpacity(Unit(opacity));
        draw();
        dc.Pop();
    }

    private static DrawingGroup Rasterize(DrawingGroup drawing, Rect bounds)
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new TranslateTransform(-bounds.X, -bounds.Y));
            dc.DrawDrawing(drawing);
            dc.Pop();
        }
        var bitmap = new RenderTargetBitmap((int)bounds.Width, (int)bounds.Height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return Drawing(dc => dc.DrawImage(bitmap, bounds));
    }

    private static DrawingGroup Drawing(Action<DrawingContext> draw)
    {
        var group = new DrawingGroup();
        using (var dc = group.Open())
            draw(dc);
        return Freeze(group);
    }

    private static StreamGeometry Polygon(Point[] points, bool closed = true)
    {
        var shape = new StreamGeometry();
        using (var g = shape.Open())
        {
            g.BeginFigure(points[0], closed, closed);
            for (int i = 1; i < points.Length; i++)
                g.LineTo(points[i], true, false);
        }
        return Freeze(shape);
    }

    private static Point[] HexPoints(Point center, double radius) =>
        Enumerable.Range(0, 6).Select(i => Polar(center, radius, radius, i * Math.PI / 3)).ToArray();

    private static Point Polar(Point center, double rx, double ry, double theta) =>
        new(center.X + rx * Math.Cos(theta), center.Y + ry * Math.Sin(theta));

    private static T Freeze<T>(T item) where T : Freezable { item.Freeze(); return item; }
    private static double Unit(double t) => Math.Clamp(t, 0, 1);
    private static double EaseOut(double t) => 1 - Math.Pow(1 - Unit(t), 3);
    private static double EaseInOut(double t) { t = Unit(t); return t * t * (3 - 2 * t); }
    private static double Range(Random rng, double lo, double hi) => lo + rng.NextDouble() * (hi - lo);
    private static double Key(double t, double[] keys, double[] values)
    {
        for (int i = 1; i < keys.Length; i++)
            if (t < keys[i])
                return values[i - 1] + (values[i] - values[i - 1]) * Unit((t - keys[i - 1]) / (keys[i] - keys[i - 1]));
        return values[^1];
    }
}
