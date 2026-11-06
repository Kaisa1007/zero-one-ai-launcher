// Turns a clean voice recording (ElevenLabs export in Assets/14_Voice) into the boot animation's
// "mechanical, ethereal" system voice. Offline AVAudioEngine render, build time only:
//   voice_tool <in.(mp3|wav|aiff)> <out.wav> [key=value ...]
//   keys (defaults = first version): pitch_cents=40 double_detune_cents=14 double_level=0.45 double_delay_ms=18
//                                    distortion_mix=14 slap_delay_mix=16 reverb_wet=32
//   The build reads the saved values from Tools/voice_settings.json.
// Chain: dry voice pitched up + a detuned, slightly delayed double (chorus) -> metallic distortion
// (speech preset, low mix) -> short slap delay -> large-hall reverb. A short tail is appended for the reverb.
import AVFoundation

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: voice_tool in out [key=value ...]"); exit(2) }
var opt: [String: Float] = ["pitch_cents": 40, "double_detune_cents": 14, "double_level": 0.45, "double_delay_ms": 18,
                            "distortion_mix": 14, "slap_delay_mix": 16, "reverb_wet": 32]
for a in args.dropFirst(3) {
    let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
    guard kv.count == 2, opt[kv[0]] != nil, let v = Float(kv[1]) else { print("bad option \(a)"); exit(2) }
    opt[kv[0]] = v
}
let pitch = opt["pitch_cents"]!, wet = opt["reverb_wet"]!

let src = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
// Read + convert to the processing format.
let inBuf: AVAudioPCMBuffer = {
    let raw = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: AVAudioFrameCount(src.length))!
    try! src.read(into: raw)
    let conv = AVAudioConverter(from: src.processingFormat, to: fmt)!
    let cap = AVAudioFrameCount(Double(raw.frameLength) * fmt.sampleRate / src.processingFormat.sampleRate) + 1024
    let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap)!
    var done = false
    var err: NSError?
    conv.convert(to: out, error: &err) { _, status in
        if done { status.pointee = .endOfStream; return nil }
        done = true; status.pointee = .haveData; return raw
    }
    return out
}()

let engine = AVAudioEngine()
let dry = AVAudioPlayerNode(), dbl = AVAudioPlayerNode()
let p1 = AVAudioUnitTimePitch(), p2 = AVAudioUnitTimePitch()
p1.pitch = pitch; p2.pitch = pitch + opt["double_detune_cents"]!   // the detuned double beats against the voice
let mixBus = AVAudioMixerNode()
let dist = AVAudioUnitDistortion(); dist.loadFactoryPreset(.speechCosmicInterference); dist.wetDryMix = opt["distortion_mix"]!
let slap = AVAudioUnitDelay(); slap.delayTime = 0.11; slap.feedback = 18; slap.lowPassCutoff = 6000; slap.wetDryMix = opt["slap_delay_mix"]!
let verb = AVAudioUnitReverb(); verb.loadFactoryPreset(.largeHall2); verb.wetDryMix = wet
let eq = AVAudioUnitEQ(numberOfBands: 2)
eq.bands[0].filterType = .highPass; eq.bands[0].frequency = 180; eq.bands[0].bypass = false
eq.bands[1].filterType = .highShelf; eq.bands[1].frequency = 6500; eq.bands[1].gain = 4; eq.bands[1].bypass = false
for n in [dry, dbl, p1, p2, mixBus, dist, slap, verb, eq] as [AVAudioNode] { engine.attach(n) }
engine.connect(dry, to: p1, format: fmt); engine.connect(p1, to: mixBus, format: fmt)
engine.connect(dbl, to: p2, format: fmt); engine.connect(p2, to: mixBus, format: fmt)
engine.connect(mixBus, to: eq, format: fmt)
engine.connect(eq, to: dist, format: fmt)
engine.connect(dist, to: slap, format: fmt)
engine.connect(slap, to: verb, format: fmt)
engine.connect(verb, to: engine.mainMixerNode, format: fmt)
dbl.volume = opt["double_level"]!; dbl.pan = 0.25; dry.pan = -0.08

try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
try engine.start()
dry.scheduleBuffer(inBuf, at: nil)
dbl.scheduleBuffer(inBuf, at: AVAudioTime(sampleTime: AVAudioFramePosition(Double(opt["double_delay_ms"]!) / 1000 * fmt.sampleRate), atRate: fmt.sampleRate))
dry.play(); dbl.play()

let tail = AVAudioFramePosition(1.6 * fmt.sampleRate)
let total = AVAudioFramePosition(inBuf.frameLength) + tail
let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
var peak: Float = 0
var rendered: [AVAudioPCMBuffer] = []
while engine.manualRenderingSampleTime < total {
    let n = AVAudioFrameCount(min(Int64(4096), total - engine.manualRenderingSampleTime))
    guard try engine.renderOffline(n, to: buf) == .success else { break }
    let copy = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength)!
    copy.frameLength = buf.frameLength
    for c in 0..<Int(buf.format.channelCount) {
        for i in 0..<Int(buf.frameLength) { let v = buf.floatChannelData![c][i]; copy.floatChannelData![c][i] = v; peak = max(peak, abs(v)) }
    }
    rendered.append(copy)
}
// Normalise to -1 dBFS so every line has the same level. Written inside a function so the file is
// closed (and its header finalised) before the process exits.
func writeOut() throws {
    let out = try AVAudioFile(forWriting: URL(fileURLWithPath: args[2]),
                              settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                                         AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
    let g = peak > 0 ? 0.89 / peak : 1
    for b in rendered {
        for c in 0..<Int(b.format.channelCount) { for i in 0..<Int(b.frameLength) { b.floatChannelData![c][i] *= g } }
        try out.write(from: b)
    }
}
try writeOut()
print(String(format: "%@ %.2f s", args[2], Double(total) / fmt.sampleRate))
