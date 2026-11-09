using System.Windows;
using System.Windows.Media;

namespace ZeroOne.Windows;

internal sealed partial class BootStage
{
    private static readonly Point Finger = new(1070, 472);
    private const double FingerScanLength = 19 / 30.0 + .05;

    private static (Point[][] Ridges, Point[] Minutiae) MakeFingerprint()
    {
        var rng = new Random(0x01FEED);
        var ridges = new List<Point[]>();
        for (int i = 0; i < 16; i++)
        {
            double rx = 9 + i * 7.4, ry = 12 + i * 9.2;
            bool draw = rng.NextDouble() > .2;
            double toggle = Range(rng, .6, 2.4);
            var segment = new List<Point>();
            for (int j = 0; j <= 140; j++)
            {
                double angle = j * Math.Tau / 140;
                if (angle > toggle)
                {
                    if (segment.Count > 1)
                        ridges.Add(segment.ToArray());
                    segment.Clear();
                    draw = !draw;
                    toggle = angle + (draw ? Range(rng, .7, 2.2) : Range(rng, .12, .32));
                }
                if (draw)
                {
                    double wave = 1 + .035 * Math.Sin(5 * angle + i) + .02 * Math.Sin(9 * angle + i * .7);
                    segment.Add(Polar(Finger, rx * wave, ry * wave * (Math.Sin(angle) > 0 ? .92 : 1), angle));
                }
            }
            if (segment.Count > 1)
                ridges.Add(segment.ToArray());
        }
        Point[] points = Enumerable.Range(0, 7).Select(_ =>
        {
            double angle = Range(rng, 0, Math.Tau), radius = Range(rng, 30, 110);
            return Polar(Finger, radius * .8, radius, angle);
        }).ToArray();
        return (ridges.ToArray(), points);
    }

    private void StrokeRidges(DrawingContext dc, double amount, Pen pen)
    {
        var geometry = new StreamGeometry();
        int remaining = (int)(ridges.Sum(r => r.Length) * amount);
        using (var stream = geometry.Open())
            foreach (Point[] ridge in ridges)
            {
                if (remaining <= 1)
                    break;
                stream.BeginFigure(ridge[0], false, false);
                for (int i = 1; i < Math.Min(ridge.Length, remaining); i++)
                    stream.LineTo(ridge[i], true, false);
                remaining -= ridge.Length;
            }
        dc.DrawGeometry(null, pen, Freeze(geometry));
    }

    private static Geometry Chamfer(Rect box, double cut) => Polygon(
        [new(box.Left + cut, box.Top), box.TopRight, new(box.Right, box.Bottom - cut),
         new(box.Right - cut, box.Bottom), box.BottomLeft, new(box.Left, box.Top + cut)]);

    private void BuildLogin(DrawingContext dc)
    {
        dc.DrawGeometry(Brush(Color.FromRgb(8, 13, 9), .88), Line(Accent, 1.5, .7), Chamfer(Panel, 34));
        dc.DrawGeometry(Brush(Accent, .92), null, Polygon(
            [new(334, 230), new(1300, 230), new(1300, 276), new(300, 276), new(300, 264)]));
        Text(dc, "社員認証システム", 350, 241, 18, Brushes.Black, Heavy, 6);
        Text(dc, "機密区分　レベル01", 1276, 244, 14, Brushes.Black, Sans, 3, TextAlignment.Right);
        for (int i = 0; i < BootDirector.Profile.Length; i++)
        {
            double y = 306 + i * 66;
            Text(dc, BootDirector.Profile[i].Label, 356, y, 13, Brush(Accent, .7), Sans, 4);
            dc.DrawLine(Line(Accent, 1, .2), new Point(356, y + 58), new Point(840, y + 58));
        }
        dc.DrawRectangle(Brush(Colors.Black, .55), Line(Accent, 1, .25), Scanner);
        Grid(dc, Scanner, 20, .07);
        var box = Scanner;
        box.Inflate(6, 6);
        Brackets(dc, box, 26, Line(Accent, 2));
    }

    private void DrawLogin(DrawingContext dc, double now)
    {
        double close = Unit((now - BootDirector.SyncAt) / .3);
        double scale = (.02 + .98 * EaseOut((now - 3.2) / .32)) * (1 - .98 * close * close);
        dc.PushTransform(new ScaleTransform(1, scale, 800, 480));
        dc.PushOpacity(1 - close);
        dc.DrawDrawing(login);
        for (int i = 0; i < BootDirector.Profile.Length; i++)
        {
            var (_, value, at) = BootDirector.Profile[i];
            int count = Math.Clamp((int)((now - at) * 30), 0, value.Length);
            if (count > 0)
                Text(dc, value[..count] + (count < value.Length ? "▌" : ""), 356, 328 + i * 66, 21, Brushes.White, Sans, 2);
        }
        double scan = now - BootDirector.ScanAt;
        double auth = now - BootDirector.AuthorizeAt;
        string instruction = auth >= 0 ? "認証完了　ようこそ、社長" : scan >= 0 ? "指紋照合中…" :
            now >= 6 ? "指紋センサーに接触" : "認証情報を入力中…";
        string scannerStatus = auth >= 0 ? "照合一致　本人確認済" : scan >= 0 ? "生体認証　照合中" :
            now >= 6 ? "指を検出　照合準備" : "生体認証　待機中";
        Text(dc, instruction, 356, 680, 15, auth >= 0 ? Brushes.White : Brush(Accent, now < 6 ? .6 : 1), Sans, 4);
        Text(dc, scannerStatus, 1070, 672, 13, Brush(Accent), Sans, 4, TextAlignment.Center);

        double touch = now - 6;
        dc.DrawGeometry(null, Line(Accent, 1.2,
            auth >= 0 ? 1 : .35 + (touch >= 0 && touch < .45 ? .33 * Math.Abs(Math.Cos(touch * Math.Tau / .9)) : 0),
            new DashStyle([3, 6], 0)), fingerprintTip);
        if (touch >= 0)
        {
            dc.PushClip(fingerprintTip);
            if (touch >= .5)
                dc.DrawDrawing(allRidges);
            else
                StrokeRidges(dc, EaseOut(touch / .5), Line(Accent, 1.6, .18));
            for (int i = 0; i < 3; i++)
            {
                double phase = (touch + i * .6) * Math.Tau / (1.4 + i * .5);
                var dot = Polar(Finger, 9 + (4 + 4 * i) * 7.4, 12 + (4 + 4 * i) * 9.2, phase);
                PointLight(dc, dot, 2.5, 1 - Unit(auth / .3));
            }
            dc.Pop();
        }

        if (scan >= 0)
        {
            double beam = EaseInOut(scan / (FingerScanLength * .75));
            dc.PushClip(fingerprintTip);
            dc.PushClip(new RectangleGeometry(new Rect(Scanner.Left, Scanner.Top, Scanner.Width, Scanner.Height * beam)));
            dc.DrawDrawing(auth >= 0 ? whiteRidges : litRidges);
            dc.Pop();
            dc.Pop();
            dc.PushClip(new RectangleGeometry(Scanner));
            Fade(dc, 1 - Unit((scan - FingerScanLength * .75) / .2), () =>
                dc.DrawImage(images["scan_glow"], new Rect(840, 273 + beam * 380, 460, 34)));
            dc.Pop();
            var points = new List<Point>();
            for (int i = 0; i < minutiae.Length; i++)
            {
                double age = scan - FingerScanLength * (.18 + .11 * i);
                if (age < 0)
                    break;
                Point point = minutiae[i];
                points.Add(point);
                if (i > 0)
                    dc.DrawLine(Line(Colors.White, .8, .55), points[i - 1], point);
                double radius = 7 * (2.2 - 1.2 * EaseOut(age / .2));
                dc.DrawEllipse(null, Line(Colors.White, 1.5), point, radius, radius);
                dc.DrawLine(Line(Colors.White, 1, .7), new Point(point.X + 7, point.Y), new Point(point.X + 20, point.Y - 9));
            }
            double match = 99.8 * (1 - Math.Pow(1 - Unit(scan / FingerScanLength), 2));
            Text(dc, FormattableString.Invariant($"照合率  {match:0.0}%"), 1228, 632, 13,
                match >= 99.8 ? Brushes.White : Brush(Accent), Mono, 2, TextAlignment.Right);
        }
        if (auth >= 0 && auth < .75)
        {
            double k = EaseOut(auth / .75);
            var bloom = Panel;
            bloom.Inflate(18 * k, 9 * k);
            dc.DrawGeometry(null, Line(Accent, 5 - 4.5 * k, .9 * (1 - k)), Chamfer(bloom, 34));
        }
        dc.Pop();
        dc.Pop();
    }

    private void BuildCard(DrawingContext dc)
    {
        Text(dc, "飛電インテリジェンス　社長認証", 800, 306, 16, Brushes.Black, Sans, 8, TextAlignment.Center);
        Text(dc, "認証", 800, 345, 200, Brushes.Black, Heavy, 60, TextAlignment.Center);
        Text(dc, "AUTHORIZE", 800, 606, 26, Brushes.Black, Mono, 22, TextAlignment.Center);
        dc.DrawLine(Line(Colors.Black, 3), new Point(160, 340), new Point(1440, 340));
        dc.DrawLine(Line(Colors.Black, 3), new Point(160, 660), new Point(1440, 660));
    }

    private void DrawCard(DrawingContext dc, double time)
    {
        dc.PushOpacity(Math.Min(Unit(time / .06), 1 - Unit((time - 1.2) / .15)));
        // Slide a single soft gradient over the full canvas.
        double front = -170 + 1950 * EaseOut(time / .4);
        var wipe = new LinearGradientBrush(Accent, Color.FromArgb(0, Accent.R, Accent.G, Accent.B), 0)
        {
            MappingMode = BrushMappingMode.Absolute,
            StartPoint = new Point(front - 134, 0), EndPoint = new Point(front, 0)
        };
        dc.DrawRectangle(front - 134 >= Canvas.Right ? Brush(Accent) : wipe, null, Canvas);
        double punch = 1 + .18 * (1 - EaseOut(time / .35));
        dc.PushTransform(new ScaleTransform(punch, punch, 800, 480));
        dc.PushOpacity(Key(time / .25, [0, .3, .5, 1], [0, 1, .2, 1]));
        dc.DrawDrawing(card);
        dc.Pop();
        dc.Pop();
        dc.Pop();
    }

    private void PointLight(DrawingContext dc, Point point, double radius, double opacity)
    {
        dc.DrawEllipse(Brush(Accent, .1 * opacity), null, point, 3 * radius, 3 * radius);
        dc.DrawEllipse(Brush(Accent, .3 * opacity), null, point, 1.7 * radius, 1.7 * radius);
        dc.DrawEllipse(Brush(Colors.White, opacity), null, point, radius, radius);
    }
}
