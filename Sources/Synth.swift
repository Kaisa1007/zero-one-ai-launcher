import AVFoundation

/// Interface sounds for the boot HUD. Generated procedurally (original, no licensing issues) and replaced
/// automatically by a downloaded sample when `Resources/Audio/sfx_<name>.wav` exists (see SFX_AND_UPSCALE.md).
enum SFX: String, CaseIterable {
    case boot       // CRT power-on line / HUD powers up
    case tick       // log line or module lights up
    case type       // one keystroke while the login fields are typed
    case panel      // login panel opens
    case lock       // fingerprint feature point locks on
    case swish      // AUTHORIZE card wipe
    case granted    // sync 100 %
    case chatter    // looping data chatter during synchronisation
    case converge   // light and hex fragments converge into the Hiden logo
    case boom       // the logo forms
    case shimmer    // light sweep across the logo
    case slam       // the アクセス承認 stamp
    case flip       // hex tile flip into Codex
    case whoosh     // air under the hex flip

    var clipID: String { "sfx_\(rawValue)" }
    /// Mix levels (the designed files are all normalised to the same peak).
    var gain: Float {
        switch self {
        case .tick: return 0.22
        case .type: return 0.15
        case .lock: return 0.17      // authorisation moment, -3 dB
        case .panel: return 0.30
        case .swish: return 0.21     // authorisation moment, -3 dB
        case .chatter: return 0.20
        case .boot: return 0.42
        case .granted: return 0.40
        case .converge: return 0.42
        case .boom: return 0.58
        case .shimmer: return 0.32
        case .slam: return 0.44
        case .flip: return 0.36
        case .whoosh: return 0.30
        }
    }
    /// Separate channels so overlapping beats do not cut each other off.
    var channel: AudioChannel {
        switch self {
        case .chatter: return .chatter
        case .converge, .boom: return .sfx2          // the boom deliberately cuts the riser
        case .panel, .swish, .flip, .slam: return .fx
        case .shimmer: return .henshin2
        case .type, .lock: return .key
        default: return .sfx
        }
    }
}

enum Synth {
    static func buffer(_ s: SFX, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Fallback only (the app ships designed files); newer sounds have no procedural version.
        if [.type, .panel, .lock, .swish, .flip].contains(s) { return nil }
        let sr = format.sampleRate
        let dur: Double
        switch s {
        case .tick: dur = 0.06
        case .boot: dur = 0.9
        case .slam: dur = 0.45
        case .granted: dur = 0.75
        case .whoosh: dur = 0.9
        case .boom: dur = 1.2
        case .chatter: dur = 1.6
        case .converge: dur = 1.35
        case .shimmer: dur = 1.1
        case .type, .panel, .lock, .swish, .flip: return nil
        }
        let n = AVAudioFrameCount(dur * sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n), let ch = buf.floatChannelData else { return nil }
        buf.frameLength = n
        var rng = SystemRandomNumberGenerator()
        func noise() -> Float { Float.random(in: -1...1, using: &rng) }
        var lp: Float = 0, lp2: Float = 0, phase: Double = 0
        var blips: [(start: Int, len: Int, f: Double)] = []
        if s == .chatter {
            var t = 0
            while t < Int(n) {
                t += Int(Double.random(in: 0.04...0.14) * sr)
                blips.append((t, Int(Double.random(in: 0.012...0.03) * sr), Double.random(in: 900...3200)))
            }
        }
        for i in 0..<Int(n) {
            let t = Double(i) / sr
            let x = t / dur
            var v: Float = 0
            switch s {
            case .tick:
                v = Float(sin(2 * .pi * 2300 * t)) * Float(exp(-t / 0.011)) * 0.9
            case .boot:
                let f = 110 + 900 * pow(x, 1.6)
                phase += 2 * .pi * f / sr
                let env = Float(min(1, t / 0.05) * exp(-max(0, t - 0.55) / 0.12))
                lp += 0.06 * (noise() - lp)
                v = (Float(sin(phase)) * 0.45 + lp * 0.5 + Float(sin(2 * .pi * 55 * t)) * 0.35 * Float(exp(-t / 0.4))) * env
            case .slam:
                lp += 0.25 * (noise() - lp)
                v = lp * Float(exp(-t / 0.05)) * 1.2 + Float(sin(2 * .pi * (72 - 20 * x) * t)) * Float(exp(-t / 0.16)) * 0.9
            case .granted:
                for (st, f) in [(0.0, 880.0), (0.11, 1318.5), (0.22, 1760.0)] where t >= st {
                    let tt = t - st
                    v += Float(sin(2 * .pi * f * tt) + 0.3 * sin(2 * .pi * f * 2 * tt)) * Float(exp(-tt / 0.18)) * 0.33
                }
            case .whoosh:
                let cutoff = Float(0.01 + 0.35 * sin(.pi * min(1, x * 1.1)))
                lp += cutoff * (noise() - lp)
                lp2 += cutoff * (lp - lp2)
                v = lp2 * Float(sin(.pi * x)) * 2.2
            case .boom:
                phase += 2 * .pi * (52 - 18 * x) / sr
                lp += 0.02 * (noise() - lp)
                v = Float(sin(phase)) * Float(exp(-t / 0.45)) * 0.95 + lp * Float(exp(-t / 0.08)) * 1.5
            case .converge:
                // Rising filtered noise + pitch sweep, cut sharply at the end (the logo slams in).
                let cutoff = Float(0.01 + 0.3 * pow(x, 2))
                lp += cutoff * (noise() - lp)
                phase += 2 * .pi * (180 + 1500 * pow(x, 2.4)) / sr
                let env = Float(pow(x, 1.5) * min(1, (1 - x) * 30))
                v = (lp * 1.6 + Float(sin(phase)) * 0.35) * env
            case .shimmer:
                let env = Float(min(1, t / 0.04) * exp(-t / 0.35))
                for (i, f) in [2637.0, 3520.0, 4186.0, 5274.0].enumerated() {
                    v += Float(sin(2 * .pi * f * (1 + 0.004 * Double(i)) * t + Double(i))) * 0.18
                }
                v *= env * Float(0.75 + 0.25 * sin(2 * .pi * 11 * t))
            case .type, .panel, .lock, .swish, .flip:
                break
            case .chatter:
                for b in blips where i >= b.start && i < b.start + b.len {
                    let tt = Double(i - b.start) / sr
                    v += Float(sin(2 * .pi * b.f * tt)) * Float(sin(.pi * Double(i - b.start) / Double(b.len))) * 0.5
                }
            }
            v = max(-1, min(1, v))
            for c in 0..<Int(format.channelCount) { ch[c][i] = v }
        }
        return buf
    }
}
