// Build-time sound design for the boot HUD (original sounds, no samples):
//   sfx_tool <outdir> [name ...]        writes <outdir>/sfx_<name>.wav (44.1 kHz, 16-bit, stereo)
// Each sound is layered from sines, FM bells and filtered noise with envelopes and stereo placement, then
// rendered offline through AVAudioEngine (high-pass EQ + room / hall reverb), soft-limited and normalised.
// Family: clean, soft, restrained ("premium system UI"). A downloaded file in Assets/13_SFX wins over these.
import AVFoundation

let sr = 44100.0
typealias Stereo = (l: [Float], r: [Float])

// MARK: - DSP building blocks

struct Rng {
    var s: UInt64
    mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double((s >> 11) & ((1 << 53) - 1)) / Double(1 << 53) }
    mutating func bi() -> Float { Float(next() * 2 - 1) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

func buffer(_ dur: Double) -> Stereo { let n = Int(dur * sr); return ([Float](repeating: 0, count: n), [Float](repeating: 0, count: n)) }

/// Constant-power pan, p in -1...1.
func panGains(_ p: Double) -> (Float, Float) { let a = (p + 1) * .pi / 4; return (Float(cos(a)), Float(sin(a))) }

/// Adds a mono signal produced per-sample by `f(t)` (t from the voice start) into the buffer.
func add(_ b: inout Stereo, at start: Double, dur: Double, pan: Double = 0, gain: Float = 1, _ f: (Double) -> Float) {
    let (gl, gr) = panGains(pan)
    let s0 = Int(start * sr), n = Int(dur * sr)
    for i in 0..<n {
        let k = s0 + i; guard k >= 0, k < b.l.count else { continue }
        let v = f(Double(i) / sr) * gain
        b.l[k] += v * gl; b.r[k] += v * gr
    }
}
/// Same, but with a pan that changes over time.
func addPanned(_ b: inout Stereo, at start: Double, dur: Double, pan: (Double) -> Double, gain: Float = 1, _ f: (Double) -> Float) {
    let s0 = Int(start * sr), n = Int(dur * sr)
    for i in 0..<n {
        let k = s0 + i; guard k >= 0, k < b.l.count else { continue }
        let t = Double(i) / sr
        let (gl, gr) = panGains(pan(t))
        let v = f(t) * gain
        b.l[k] += v * gl; b.r[k] += v * gr
    }
}

/// Attack / exponential decay envelope.
func env(_ t: Double, a: Double, d: Double) -> Float { t < a ? Float(t / a) : Float(exp(-(t - a) / d)) }
func smooth(_ x: Double) -> Double { let c = max(0, min(1, x)); return c * c * (3 - 2 * c) }

/// FM bell: carrier f, modulator f*ratio, index decaying with the amplitude (bright attack, pure tail).
func bell(_ f: Double, ratio: Double = 3.5, index: Double = 2.2, decay: Double, attack: Double = 0.002) -> (Double) -> Float {
    return { t in
        let e = Double(env(t, a: attack, d: decay))
        let m = sin(2 * .pi * f * ratio * t) * index * e
        return Float(sin(2 * .pi * f * t + m) * e)
    }
}

/// State-variable filter on noise, cutoff (Hz) and Q may change over time. Returns band-pass output.
final class NoiseBand {
    var low = 0.0, band = 0.0
    var rng: Rng
    init(seed: UInt64) { rng = Rng(s: seed) }
    func next(cutoff: Double, q: Double) -> Float {
        let f = 2 * sin(.pi * min(cutoff, sr / 6) / sr)
        let x = rng.next() * 2 - 1
        low += f * band
        let high = x - low - band / q
        band += f * high
        return Float(band)
    }
}

/// Exponential glide between two values over the duration (for pitch / cutoff sweeps).
func glide(_ a: Double, _ b: Double, _ x: Double) -> Double { a * pow(b / a, max(0, min(1, x))) }

// MARK: - Offline post-processing (EQ + reverb), soft limit, normalise

func post(_ dry: Stereo, preset: AVAudioUnitReverbPreset, wet: Float, tail: Double, peak: Float = 0.89, loop: Bool = false) -> Stereo {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let n = dry.l.count
    let input = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
    input.frameLength = AVAudioFrameCount(n)
    for i in 0..<n { input.floatChannelData![0][i] = dry.l[i]; input.floatChannelData![1][i] = dry.r[i] }
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 2)
    eq.bands[0].filterType = .highPass; eq.bands[0].frequency = 32; eq.bands[0].bypass = false
    eq.bands[1].filterType = .lowPass; eq.bands[1].frequency = 15500; eq.bands[1].bypass = false
    let verb = AVAudioUnitReverb(); verb.loadFactoryPreset(preset); verb.wetDryMix = wet
    for x in [player, eq, verb] as [AVAudioNode] { engine.attach(x) }
    engine.connect(player, to: eq, format: fmt); engine.connect(eq, to: verb, format: fmt); engine.connect(verb, to: engine.mainMixerNode, format: fmt)
    try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
    try! engine.start()
    player.scheduleBuffer(input, at: nil); player.play()
    let total = n + Int(tail * sr)
    var out: Stereo = ([Float](repeating: 0, count: total), [Float](repeating: 0, count: total))
    let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
    var pos = 0
    while pos < total {
        let k = AVAudioFrameCount(min(4096, total - pos))
        guard (try? engine.renderOffline(k, to: buf)) == .success else { break }
        for i in 0..<Int(buf.frameLength) where pos + i < total {
            out.l[pos + i] = buf.floatChannelData![0][i]; out.r[pos + i] = buf.floatChannelData![1][i]
        }
        pos += Int(buf.frameLength)
    }
    engine.stop()
    if loop {
        // Wrap the reverb tail onto the start so the loop is seamless, then trim to the dry length.
        for i in n..<total { out.l[i - n] += out.l[i]; out.r[i - n] += out.r[i] }
        out.l = Array(out.l[0..<n]); out.r = Array(out.r[0..<n])
    }
    // Gentle soft limit, short fades (0.5 ms in, 4 ms out), then normalise to the target peak.
    let fadeIn = Int(0.0005 * sr), fade = Int(0.004 * sr)
    for i in 0..<out.l.count {
        var e: Float = 1
        if !loop { if i < fadeIn { e = Float(i) / Float(fadeIn) }; if i > out.l.count - fade { e = Float(out.l.count - i) / Float(fade) } }
        out.l[i] = tanh(out.l[i] * 1.2) / 1.2 * e; out.r[i] = tanh(out.r[i] * 1.2) / 1.2 * e
    }
    var p: Float = 0
    for i in 0..<out.l.count { p = max(p, abs(out.l[i]), abs(out.r[i])) }
    let g = p > 0 ? peak / p : 1
    for i in 0..<out.l.count { out.l[i] *= g; out.r[i] *= g }
    // Trim silent end (below -66 dB) for one-shots.
    if !loop {
        var last = out.l.count - 1
        while last > 0 && abs(out.l[last]) < 0.0005 && abs(out.r[last]) < 0.0005 { last -= 1 }
        let end = min(out.l.count, last + fade + 1)
        out.l = Array(out.l[0..<end]); out.r = Array(out.r[0..<end])
    }
    return out
}

func write(_ s: Stereo, to url: URL) throws {
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
                                                          AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.l.count))!
    b.frameLength = AVAudioFrameCount(s.l.count)
    for i in 0..<s.l.count { b.floatChannelData![0][i] = s.l[i]; b.floatChannelData![1][i] = s.r[i] }
    try file.write(from: b)
}

// MARK: - Recipes

var recipes: [String: () -> Stereo] = [:]

recipes["boot"] = {
    var b = buffer(1.5)
    add(&b, at: 0, dur: 1.4, gain: 0.55) { t in Float(sin(2 * .pi * glide(46, 74, t / 0.7) * t)) * env(t, a: 0.09, d: 0.45) }
    let nl = NoiseBand(seed: 11), nr = NoiseBand(seed: 12)
    for (nb, p) in [(nl, -0.6), (nr, 0.6)] {
        add(&b, at: 0, dur: 1.1, pan: p, gain: 0.28) { t in nb.next(cutoff: glide(350, 3400, t / 0.75), q: 0.8) * Float(smooth(t / 0.45) * exp(-max(0, t - 0.5) / 0.22)) }
    }
    add(&b, at: 0.56, dur: 0.9, pan: 0.2, gain: 0.2, bell(1568, ratio: 2, index: 1.4, decay: 0.32))
    return post(b, preset: .mediumHall, wet: 24, tail: 1.2)
}
recipes["tick"] = {
    var b = buffer(0.12)
    add(&b, at: 0, dur: 0.06, gain: 0.7) { t in Float(sin(2 * .pi * 2350 * t)) * env(t, a: 0.0006, d: 0.011) }
    let n = NoiseBand(seed: 3)
    add(&b, at: 0, dur: 0.01, gain: 0.25) { t in n.next(cutoff: 5200, q: 1.4) * env(t, a: 0.0003, d: 0.002) }
    return post(b, preset: .smallRoom, wet: 10, tail: 0.15)
}
recipes["type"] = {
    var b = buffer(0.08)
    let n = NoiseBand(seed: 5)
    add(&b, at: 0, dur: 0.02, gain: 0.5) { t in n.next(cutoff: 2600, q: 1.1) * env(t, a: 0.0004, d: 0.003) }
    add(&b, at: 0, dur: 0.04, gain: 0.35) { t in Float(sin(2 * .pi * 1150 * t)) * env(t, a: 0.0005, d: 0.008) }
    return post(b, preset: .smallRoom, wet: 7, tail: 0.1)
}
recipes["panel"] = {
    var b = buffer(0.8)
    let n = NoiseBand(seed: 21)
    addPanned(&b, at: 0, dur: 0.4, pan: { t in -0.3 + t * 1.4 }, gain: 0.22) { t in n.next(cutoff: glide(1800, 6500, t / 0.32), q: 0.9) * Float(sin(.pi * min(1, t / 0.36))) }
    add(&b, at: 0.04, dur: 0.6, pan: -0.15, gain: 0.22, bell(1046.5, ratio: 2, index: 1.1, decay: 0.16))
    add(&b, at: 0.1, dur: 0.6, pan: 0.2, gain: 0.18, bell(1568, ratio: 2, index: 1.0, decay: 0.18))
    return post(b, preset: .mediumRoom, wet: 18, tail: 0.6)
}
recipes["lock"] = {
    var b = buffer(0.3)
    add(&b, at: 0, dur: 0.25, gain: 0.5, bell(2637, ratio: 1.5, index: 0.9, decay: 0.05))
    add(&b, at: 0, dur: 0.12, gain: 0.12) { t in Float(sin(2 * .pi * 5274 * t)) * env(t, a: 0.0005, d: 0.02) }
    return post(b, preset: .smallRoom, wet: 14, tail: 0.3)
}
recipes["swish"] = {
    var b = buffer(0.6)
    let n = NoiseBand(seed: 31), m = NoiseBand(seed: 32)
    addPanned(&b, at: 0, dur: 0.5, pan: { t in -0.85 + 1.7 * smooth(t / 0.45) }, gain: 0.5) { t in
        let c = glide(700, 7200, t / 0.42); return (n.next(cutoff: c, q: 1.3) * 0.7 + m.next(cutoff: c * 1.6, q: 2) * 0.3) * Float(pow(sin(.pi * min(1, t / 0.46)), 2))
    }
    return post(b, preset: .mediumRoom, wet: 14, tail: 0.4)
}
recipes["granted"] = {
    var b = buffer(2.0)
    for (i, (f, p)) in [(1318.5, -0.35), (1975.5, 0.0), (2637.0, 0.35)].enumerated() {
        add(&b, at: Double(i) * 0.075, dur: 1.8, pan: p, gain: 0.26, bell(f, ratio: 2, index: 1.6, decay: 0.55))
    }
    add(&b, at: 0, dur: 1.4, gain: 0.12) { t in Float(sin(2 * .pi * 659.25 * t) + 0.3 * sin(2 * .pi * 988 * t)) * env(t, a: 0.05, d: 0.45) }
    return post(b, preset: .largeHall2, wet: 30, tail: 2.0)
}
recipes["chatter"] = {
    let dur = 2.4
    var b = buffer(dur)
    var r = Rng(s: 77)
    var t = 0.02
    while t < dur - 0.04 {
        let f = r.range(3000, 7200), d = r.range(0.004, 0.011), p = r.range(-0.8, 0.8), g = Float(r.range(0.06, 0.16))
        add(&b, at: t, dur: d * 4, pan: p, gain: g) { x in Float(sin(2 * .pi * f * x)) * env(x, a: 0.0006, d: d) }
        t += r.range(0.05, 0.17)
    }
    return post(b, preset: .mediumRoom, wet: 22, tail: 0.6, peak: 0.6, loop: true)
}
recipes["converge"] = {
    let dur = 1.35
    var b = buffer(dur)
    let nl = NoiseBand(seed: 41), nr = NoiseBand(seed: 42)
    for (nb, p) in [(nl, -0.7), (nr, 0.7)] {
        add(&b, at: 0, dur: dur, pan: p, gain: 0.5) { t in nb.next(cutoff: glide(280, 6800, t / dur), q: 1.1) * Float(pow(t / dur, 2.2)) }
    }
    var ph = 0.0
    add(&b, at: 0, dur: dur, gain: 0.22) { t in ph += 2 * .pi * glide(170, 1450, pow(t / dur, 1.6)) / sr; return Float(sin(ph)) * Float(pow(t / dur, 1.8)) }
    return post(b, preset: .mediumHall, wet: 16, tail: 0.05)
}
recipes["boom"] = {
    var b = buffer(2.6)
    var ph = 0.0
    add(&b, at: 0, dur: 1.8, gain: 0.85) { t in ph += 2 * .pi * glide(58, 36, t / 0.45) / sr; return Float(sin(ph)) * env(t, a: 0.003, d: 0.55) }
    add(&b, at: 0, dur: 0.6, gain: 0.3) { t in Float(sin(2 * .pi * glide(120, 72, t / 0.2) * t)) * env(t, a: 0.002, d: 0.12) }
    let n = NoiseBand(seed: 51)
    add(&b, at: 0, dur: 0.12, gain: 0.35) { t in n.next(cutoff: 1300, q: 0.7) * env(t, a: 0.0008, d: 0.022) }
    return post(b, preset: .largeHall2, wet: 34, tail: 2.2)
}
recipes["shimmer"] = {
    let dur = 1.25
    var b = buffer(dur)
    var r = Rng(s: 61)
    for k in 0..<7 {
        let f = 2900 * pow(2, Double(k) / 3.5) * (1 + r.range(-0.004, 0.004)), off = Double(k) * 0.045, ph0 = r.range(0, 6.28)
        addPanned(&b, at: off, dur: dur - off, pan: { t in -0.8 + 1.6 * smooth((t + off) / 0.9) }, gain: 0.11) { t in
            Float(sin(2 * .pi * f * t + ph0)) * env(t, a: 0.05, d: 0.28) * Float(0.8 + 0.2 * sin(2 * .pi * 9 * t))
        }
    }
    return post(b, preset: .mediumHall, wet: 32, tail: 1.4)
}
recipes["slam"] = {
    var b = buffer(1.6)
    add(&b, at: 0, dur: 0.5, gain: 0.7) { t in Float(sin(2 * .pi * glide(96, 70, t / 0.12) * t)) * env(t, a: 0.0015, d: 0.11) }
    let n = NoiseBand(seed: 71)
    add(&b, at: 0, dur: 0.03, gain: 0.3) { t in n.next(cutoff: 3600, q: 1.0) * env(t, a: 0.0004, d: 0.005) }
    add(&b, at: 0.01, dur: 1.4, pan: -0.15, gain: 0.16, bell(880, ratio: 2, index: 1.2, decay: 0.42))
    add(&b, at: 0.03, dur: 1.4, pan: 0.15, gain: 0.13, bell(1318.5, ratio: 2, index: 1.0, decay: 0.45))
    return post(b, preset: .mediumHall, wet: 26, tail: 1.5)
}
recipes["flip"] = {
    let dur = 1.2
    var b = buffer(dur)
    var r = Rng(s: 81)
    for i in 0..<44 {
        let x = Double(i) / 43, t = 0.9 * pow(x, 0.75), f = r.range(2100, 4300), p = r.range(-1, 1) * (0.2 + 0.8 * x)
        add(&b, at: t, dur: 0.12, pan: p, gain: Float(0.22 - 0.1 * x), bell(f, ratio: 1.5, index: 0.8, decay: 0.022))
    }
    return post(b, preset: .mediumHall, wet: 24, tail: 0.9)
}
recipes["whoosh"] = {
    let dur = 1.0
    var b = buffer(dur)
    let nl = NoiseBand(seed: 91), nr = NoiseBand(seed: 92)
    for (nb, p) in [(nl, -0.5), (nr, 0.5)] {
        add(&b, at: 0, dur: dur, pan: p, gain: 0.45) { t in
            let x = t / dur; return nb.next(cutoff: x < 0.4 ? glide(450, 2600, x / 0.4) : glide(2600, 700, (x - 0.4) / 0.6), q: 0.8) * Float(pow(sin(.pi * x), 1.5))
        }
    }
    return post(b, preset: .mediumHall, wet: 20, tail: 0.8)
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: sfx_tool <outdir> [name ...]"); exit(2) }
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let names = args.count > 2 ? Array(args[2...]) : recipes.keys.sorted()
for n in names {
    guard let r = recipes[n] else { print("unknown sound \(n)"); exit(1) }
    let s = r()
    try write(s, to: outDir.appendingPathComponent("sfx_\(n).wav"))
    print(String(format: "sfx_%@.wav %.2f s", n, Double(s.l.count) / sr))
}
