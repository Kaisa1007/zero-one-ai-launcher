using System.Windows;
using System.Windows.Media;

namespace ZeroOne.Windows;

internal sealed partial class BootStage
{
    private const double RingRadius = 190;

    private void BuildRing(DrawingContext dc)
    {
        dc.DrawEllipse(Brush(Colors.Black, .5), Line(Colors.White, 2, .10), Center, RingRadius, RingRadius);
        var pen = Line(Accent, 1, .35);
        foreach (double x in new[] { 78.0, 54.6, 27.3 })
            dc.DrawEllipse(null, pen, Center, x, 78);
        for (int i = -1; i <= 1; i++)
        {
            double dy = i * 39, dx = Math.Sqrt(78 * 78 - dy * dy);
            dc.DrawLine(pen, new Point(800 - dx, 480 + dy), new Point(800 + dx, 480 + dy));
        }
        dc.PushTransform(new RotateTransform(-.32 * 180 / Math.PI, 800, 480));
        dc.DrawEllipse(null, Line(Accent, 1.2, .6, new DashStyle([6, 5], 0)), Center, 150, 46);
        dc.Pop();
        Text(dc, "人工知能衛星ゼア　同期中", 800, 222, 16, Brush(Accent), Sans, 6, TextAlignment.Center);
        Text(dc, "同期率　／　CODEX 作業環境との接続", 800, 768, 13, Brush(Accent, .8), Sans, 4, TextAlignment.Center);
    }

    private void DrawRing(DrawingContext dc, BootDirector boot)
    {
        double elapsed = boot.Now - BootDirector.SyncAt;
        double close = Unit(boot.LogoTime / .45);
        double scale = (.6 + .4 * EaseOut(elapsed / .5)) * (1 - .98 * close * close);
        dc.PushTransform(new ScaleTransform(scale, scale, Center.X, Center.Y));
        dc.PushOpacity(Unit(elapsed / .4) * (1 - close));
        dc.DrawDrawing(ring);
        double theta = elapsed * Math.Tau / 3.2;
        var satellite = new RotateTransform(-.32 * 180 / Math.PI, Center.X, Center.Y).Transform(Polar(Center, 150, 46, theta));
        PointLight(dc, satellite, 6, 1);
        double phase = elapsed % 1.7 / 1.7;
        if (phase < .32)
        {
            double alpha = Math.Sin(phase / .32 * Math.PI);
            var delta = satellite - Center;
            delta.Normalize();
            var hit = Center + delta * 78;
            dc.DrawLine(Line(Accent, 1.8, alpha * .8), satellite, hit);
            PointLight(dc, hit, 4, alpha);
        }
        dc.DrawEllipse(null, Line(Accent, 6, .5, new DashStyle([1.0 / 3, 5.0 / 3], elapsed * 4.5)), Center, 214, 214);

        double angle = boot.Progress / 100 * Math.Tau;
        var arc = new StreamGeometry();
        using (var g = arc.Open())
        {
            g.BeginFigure(new Point(800, 290), false, false);
            double half = angle * .5 - Math.PI / 2;
            g.ArcTo(Polar(Center, RingRadius, RingRadius, half), new Size(RingRadius, RingRadius), 0, false, SweepDirection.Clockwise, true, false);
            g.ArcTo(Polar(Center, RingRadius, RingRadius, angle - Math.PI / 2), new Size(RingRadius, RingRadius), 0, false, SweepDirection.Clockwise, true, false);
        }
        Freeze(arc);
        double flash = boot.Progress >= 100 ? Math.Sin(Math.PI * Unit((boot.LogoTime + .5) / .5)) : 0;
        dc.DrawGeometry(null, Line(Accent, 22 + 15 * flash, .1), arc);
        dc.DrawGeometry(null, Line(Accent, 13 + 15 * flash, .2), arc);
        dc.DrawGeometry(null, Line(Accent, 7 + 15 * flash), arc);
        Text(dc, FormattableString.Invariant($"{boot.Progress:0.0}%"), 800, 700, 60, boot.Progress >= 100 ? Brush(Accent) : Brushes.White, Mono, 1, TextAlignment.Center);

        if (boot.LogoTime < 0)
            for (int i = Math.Max(1, (int)((elapsed - .95) / .3)); i * .3 <= elapsed; i++)
            {
                double p = (elapsed - i * .3) / .95;
                if (p >= 1)
                    continue;
                var from = panelCenters[i % panelCenters.Length];
                var inward = from - Center;
                inward.Normalize();
                var to = Center + inward * (RingRadius + 8);
                var mid = new Point((from.X + to.X) / 2, (from.Y + to.Y) / 2 + (i * 83 % 140 - 70));
                double u = p * p, v = 1 - u;
                var dot = new Point(v * v * from.X + 2 * v * u * mid.X + u * u * to.X,
                                    v * v * from.Y + 2 * v * u * mid.Y + u * u * to.Y);
                PointLight(dc, dot, 2, Math.Min(Unit(p / .15), Unit((1 - p) / .2)));
            }
        dc.Pop();
        dc.Pop();
    }
}
