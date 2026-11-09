using System.Windows;
using System.Windows.Media;

namespace ZeroOne.Windows;

internal sealed partial class BootStage
{
    private void DrawFinale(DrawingContext dc, BootDirector boot, double time, bool skip)
    {
        double t = time - 1.7;
        double intro = Unit((time - .4) / 1.3);
        var centerGlow = new Rect(250, -160, 1100, 1100);
        DrawImage(dc, "light_lime", centerGlow, skip ? .30 : t >= 0 ? .25 + .07 * EaseOut(t / .4) : .25 * intro);

        if (!skip && time >= .4 && t < 0)
        {
            PointLight(dc, LogoCenter, 4 + 16 * intro, 1);
            for (int i = 0; i < fragments.Length; i++)
            {
                var (angle, radius, delay, size) = fragments[i];
                double age = time - .4 - delay;
                if (age <= 0)
                    continue;
                double progress = Unit(age / (1.3 - delay));
                var pos = Polar(LogoCenter, radius * (1 - progress * progress), radius * (1 - progress * progress) * .75, angle);
                double alpha = Math.Min(Unit(progress / .15), Unit((1 - progress) / .15));
                if (i < 44)
                {
                    double r = size * (1.4 - 1.2 * progress);
                    dc.PushTransform(new RotateTransform(progress * (i % 2 == 0 ? 160 : -160), pos.X, pos.Y));
                    dc.DrawGeometry(i % 2 == 0 ? Brush(Accent, alpha * .65) : null, Line(Accent, 1.5, alpha), Polygon(HexPoints(pos, r)));
                    dc.Pop();
                }
                else
                    dc.DrawLine(Line(Accent, 2, alpha * .9), pos, Polar(pos, size, size, angle));
            }
        }
        if (t < 0 && !skip)
            return;

        if (!skip && t < 1.7)
        {
            for (int i = 0; i < 3; i++)
            {
                double wave = (t - i * .14) / 1.1;
                if (wave is >= 0 and < 1)
                    dc.DrawGeometry(null, Line(Accent, 6 - 5.5 * wave, .9 * (1 - wave)),
                        Polygon(HexPoints(LogoCenter, 18 + (520 + 180 * i) * EaseOut(wave))));
            }
            for (int i = 0; i < sparks.Length; i++)
            {
                var (x, sparkY, angle, speed, size, life) = sparks[i];
                double age = t - i * .008;
                if (age is <= 0 || age >= life)
                    continue;
                var p = Polar(LogoCenter + new Vector(x, sparkY), age * speed, age * speed, angle);
                var rect = new Rect(p.X - size / 2, p.Y - size / 2, size, size);
                dc.PushOpacity(.75 * (1 - age / life));
                dc.DrawImage(images[i % 3 == 0 ? "fx_star_01" : "fx_spark_01"], rect);
                dc.Pop();
            }
        }

        double sway = Math.Sin(t * Math.Tau / 7.2);
        double logoScale = skip ? 1 : 1 + .12 * (1 - EaseOut(t / .5));
        dc.PushTransform(new ScaleTransform(logoScale * (1 - .013 * Math.Abs(sway)), logoScale, LogoCenter.X, LogoCenter.Y));
        dc.PushTransform(new SkewTransform(0, 1.35 * sway, LogoCenter.X, LogoCenter.Y));
        var logo = images["hiden_logo_vec"];
        if (t < .65 && !skip)
        {
            double chroma = 12 * Key(t / .6, [0, .35, .7, 1], [1, -.35, .12, 0]);
            double opacity = Key(t / .6, [0, .35, .7, 1], [.75, .5, .25, 0]);
            var a = finalLogo;
            a.Offset(-chroma, 0);
            DrawImage(dc, "hiden_magenta", a, opacity);
            var b = finalLogo;
            b.Offset(chroma, 0);
            DrawImage(dc, "hiden_cyan", b, opacity);
        }
        if (t >= .77 || skip)
            dc.DrawImage(logo, finalLogo);
        else
        {
            double sliceHeight = finalLogo.Height / slices.Length;
            for (int i = 0; i < slices.Length; i++)
            {
                var (dx, duration, delay) = slices[i];
                double phase = (t - delay) / duration;
                double x = dx * Key(phase, [0, .4, .7, 1], [1, -.4, .15, 0]);
                var box = finalLogo;
                box.Offset(x, 0);
                dc.PushClip(new RectangleGeometry(new Rect(box.X, box.Y + i * sliceHeight, box.Width, sliceHeight + .35)));
                dc.PushOpacity(Key(phase, [0, .15, .3, .5, .7, 1], [0, 1, .3, 1, .6, 1]));
                dc.DrawImage(logo, box);
                dc.Pop();
                dc.Pop();
            }
        }

        if (t > .5 || skip)
        {
            double holo = (t * 8) % 4;
            var scanBrush = new DrawingBrush(Drawing(d => d.DrawRectangle(Brush(Accent, .19), null, new Rect(0, 0, 4, 1.2))))
            {
                ViewportUnits = BrushMappingMode.Absolute,
                Viewport = new Rect(0, holo, 4, 4),
                Stretch = Stretch.None, AlignmentY = AlignmentY.Top, TileMode = TileMode.Tile,
                ViewboxUnits = BrushMappingMode.Absolute, Viewbox = new Rect(0, 0, 4, 4)
            };
            dc.PushOpacityMask(logoMask);
            dc.DrawRectangle(scanBrush, null, finalLogo);
            dc.Pop();
        }
        double sweep = (time - 2.4) / .85;
        if (!skip && sweep is >= 0 and < 1)
        {
            double x = finalLogo.Left - 240 + (finalLogo.Width + 480) * EaseInOut(sweep);
            var beam = new LinearGradientBrush
            {
                MappingMode = BrushMappingMode.Absolute, StartPoint = new Point(x - 110, LogoCenter.Y - 30),
                EndPoint = new Point(x + 110, LogoCenter.Y + 30),
                GradientStops =
                [
                    new GradientStop(Colors.Transparent, 0), new GradientStop(Color.FromArgb(242, 255, 255, 255), .45),
                    new GradientStop(Color.FromArgb(230, Accent.R, Accent.G, Accent.B), .6), new GradientStop(Colors.Transparent, 1)
                ]
            };
            dc.PushOpacityMask(logoMask);
            dc.DrawRectangle(beam, null, finalLogo);
            dc.Pop();
        }
        dc.Pop();
        dc.Pop();

        double title = time - 2.9;
        double stamp = time - boot.StampAt;
        double welcome = time - boot.WelcomeAt;
        double y = finalLogo.Bottom + 30;
        Fade(dc, skip ? 1 : title / .35, () =>
        {
            Text(dc, "飛電インテリジェンス", 800, y, 32, Brushes.White, Mincho, 18, TextAlignment.Center);
            double line = 330 * (skip ? 1 : EaseOut(title / .5));
            dc.DrawLine(Line(Accent, 2, .8), new Point(800 - line, y + 74), new Point(800 + line, y + 74));
            dc.DrawLine(Line(Accent, 2, .8), new Point(800 - line, y + 172), new Point(800 + line, y + 172));
        });
        if (skip || stamp >= 0)
        {
            double k = skip ? 1 : EaseOut(stamp / .35);
            double size = 1 + .35 * (1 - k);
            dc.PushTransform(new ScaleTransform(size, size, 800, y + 125));
            Fade(dc, skip ? 1 : Key(stamp / .35, [0, .3, .5, 1], [0, 1, .4, 1]), () =>
                Text(dc, "アクセス承認", 800, y + 84, 64, Brush(Accent), Heavy, 18, TextAlignment.Center));
            dc.Pop();
            if (!skip && stamp < .7)
            {
                double scale = .96 + .14 * EaseOut(stamp / .7);
                dc.PushTransform(new ScaleTransform(scale, scale, 800, y + 126));
                dc.DrawRoundedRectangle(null, Line(Accent, 2, .9 * (1 - stamp / .7)), new Rect(510, y + 77, 580, 98), 10, 10);
                dc.Pop();
            }
        }
        Fade(dc, skip ? 1 : welcome / .6, () =>
            Text(dc, "お帰りなさいませ、社長", 800, y + 190, 28, Brushes.White, Mincho, 10, TextAlignment.Center));
        Fade(dc, skip ? 1 : (welcome - .3) / .6, () =>
            Text(dc, "HIDEN INTELLIGENCE  ·  ACCESS GRANTED  ·  CODEX", 800, y + 246, 11, Brush(Accent, .65), Mono, 5, TextAlignment.Center));

        if (!skip && t < .6)
            dc.DrawRectangle(Brush(Color.FromRgb(233, 255, 175), Key(t / .6, [0, .1, 1], [0, .68, 0])), null, Canvas);
    }

    private sealed class HexReveal
    {
        private const int FrameCount = 69;
        private const int BrightnessSteps = 8;
        private readonly record struct MaskFrame(Geometry Mask, DrawingGroup Edges);
        private readonly (Point Center, double Delay)[] cells;
        private readonly Point[] fill, edge;
        private readonly Pen edgePen;
        private readonly Task<MaskFrame[]> prepared;

        public HexReveal(Size size, Point logo, Pen edgePen)
        {
            this.edgePen = edgePen;
            double radius = Math.Max(34, Math.Min(size.Width, size.Height) / 22);
            double width = Math.Sqrt(3) * radius;
            var tiles = new List<(Point P, double Distance)>();
            int row = 0;
            for (double y = -radius; y < size.Height + radius; y += 1.5 * radius, row++)
                for (double x = -width + (row % 2) * width / 2; x < size.Width + width; x += width)
                {
                    var point = new Point(x, y);
                    tiles.Add((point, (point - logo).Length));
                }
            double max = Math.Max(1, tiles.Max(tile => tile.Distance));
            cells = tiles.Select(t => (t.P, t.Distance / max * .7)).ToArray();
            fill = MakeHex(radius * 1.03);
            edge = MakeHex(radius * .96);
            prepared = Task.Run(() => Enumerable.Range(0, FrameCount).Select(i => BuildFrame(i / 60.0)).ToArray());
        }

        public void Draw(DrawingContext dc, Drawing scene, double time)
        {
            int index = Math.Clamp((int)Math.Round(time * 60), 0, FrameCount - 1);
            MaskFrame frame = prepared.IsCompletedSuccessfully ? prepared.Result[index] : BuildFrame(time);
            dc.PushClip(frame.Mask);
            dc.DrawDrawing(scene);
            dc.Pop();
            dc.DrawDrawing(frame.Edges);
        }

        private MaskFrame BuildFrame(double time)
        {
            var mask = new StreamGeometry { FillRule = FillRule.Nonzero };
            using (var path = mask.Open())
                foreach (var (center, delay) in cells)
                {
                    double x = Unit((time - delay) / .3);
                    if (x < 1)
                        Append(path, fill, center, 1 - x * x, 1 - .14 * x * x);
                }

            var edges = Drawing(dc =>
            {
                for (int level = 1; level <= BrightnessSteps; level++)
                {
                    var outlines = new StreamGeometry();
                    bool any = false;
                    using (var path = outlines.Open())
                        foreach (var (center, delay) in cells)
                        {
                            double x = (time - delay + .03) / .12;
                            if (x is <= 0 or >= 1)
                                continue;
                            double alpha = x < .3 ? x / .3 : (1 - x) / .7;
                            if ((int)Math.Round(alpha * BrightnessSteps) != level)
                                continue;
                            any = true;
                            Append(path, edge, center, Math.Max(.1, 1 - .9 * x), 1);
                        }
                    if (!any)
                        continue;
                    dc.PushOpacity(.75 * level / BrightnessSteps);
                    dc.DrawGeometry(null, edgePen, Freeze(outlines));
                    dc.Pop();
                }
            });
            return new MaskFrame(Freeze(mask), edges);
        }

        private static void Append(StreamGeometryContext path, Point[] shape, Point center, double sx, double sy)
        {
            path.BeginFigure(Transform(shape[0]), true, true);
            for (int i = 1; i < shape.Length; i++)
                path.LineTo(Transform(shape[i]), true, false);

            Point Transform(Point p) => new(center.X + sx * p.X, center.Y + sy * p.Y);
        }

        private static Point[] MakeHex(double radius) => Enumerable.Range(0, 6)
            .Select(i => Polar(new Point(), radius, radius, (i + .5) * Math.PI / 3)).ToArray();
    }
}
