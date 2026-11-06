import AVFoundation

/// One player per role. Starting a clip on a channel replaces whatever was on it,
/// so a channel can never stack the same voice twice.
enum AudioChannel: CaseIterable {
    case intro, key, scan, voice, standby, progrise, henshin, henshin2, fx, sfx, sfx2, chatter, announce
}

final class AudioDirector {
    private let engine = AVAudioEngine()
    private var players: [AudioChannel: AVAudioPlayerNode] = [:]
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var generation: [AudioChannel: Int] = [:]
    private var fadeTimers: [AudioChannel: Timer] = [:]
    private let assets: AssetStore
    private(set) var engineRunning = false
    private var format: AVAudioFormat?

    /// Main-thread callback with an RMS level (0...1) of the progrise/henshin channels.
    var onLevel: ((Float) -> Void)?
    /// Every clip start is reported (used by the self-test to detect overlaps / repeats).
    var onEvent: ((String) -> Void)?
    private var lastLevel: Float = 0

    var volume: Float = 0.85 { didSet { applyVolume() } }
    var muted = false { didSet { applyVolume() } }

    init(assets: AssetStore) {
        self.assets = assets
        for (id, clip) in assets.clips {
            do {
                let file = try AVAudioFile(forReading: assets.url(for: clip))
                let fmt = file.processingFormat
                let start = AVAudioFramePosition(clip.play_start_frame)
                let count = AVAudioFrameCount(min(Int64(clip.play_frame_count), file.length - start))
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: count) else { continue }
                file.framePosition = start
                try file.read(into: buf, frameCount: count)
                buffers[id] = buf
                if format == nil { format = fmt }
            } catch {
                NSLog("ZeroOne: audio load failed \(id): \(error)")
            }
        }
        guard let format else { return }
        // HUD sounds: a downloaded sample (Audio/sfx_<name>.wav) wins, otherwise the procedural version.
        for sfx in SFX.allCases where buffers[sfx.clipID] == nil {
            if let b = Synth.buffer(sfx, format: format) { buffers[sfx.clipID] = b }
        }
        for ch in AudioChannel.allCases {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players[ch] = p
        }
        for ch in [AudioChannel.progrise, .henshin, .henshin2] {
            players[ch]?.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                guard let data = buf.floatChannelData?[0] else { return }
                let n = Int(buf.frameLength)
                var s: Float = 0
                var i = 0
                while i < n { s += data[i] * data[i]; i += 4 }
                let rms = sqrt(s / Float(max(1, n / 4)))
                DispatchQueue.main.async { self?.reportLevel(rms) }
            }
        }
        // Safety peak limiter on the master output: only acts when overlapping sounds would clip, so levels
        // (including the voice) stay as designed.
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        let limiter = AVAudioUnitEffect(audioComponentDescription: desc)
        engine.attach(limiter)
        let outFmt = engine.outputNode.inputFormat(forBus: 0)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(engine.mainMixerNode, to: limiter, format: outFmt)
        engine.connect(limiter, to: engine.outputNode, format: outFmt)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.startEngine()
        }
        startEngine()
        applyVolume()
    }

    private func reportLevel(_ rms: Float) {
        let v = min(1, rms * 4)
        lastLevel = max(v, lastLevel * 0.85)
        onLevel?(lastLevel)
    }

    private func startEngine() {
        do {
            engine.prepare()
            try engine.start()
            engineRunning = true
        } catch {
            engineRunning = false
            NSLog("ZeroOne: audio engine unavailable, timing falls back to clip durations: \(error)")
        }
    }

    private func applyVolume() { engine.mainMixerNode.outputVolume = muted ? 0 : volume }

    func duration(_ clip: String) -> Double {
        if let c = assets.clips[clip] { return c.play_duration_s }
        if let b = buffers[clip] { return Double(b.frameLength) / b.format.sampleRate }
        return 0
    }

    func play(_ sfx: SFX, loop: Bool = false) {
        play(sfx.clipID, on: sfx.channel, loop: loop, gain: sfx.gain)
    }
    func audibleEnd(_ clip: String) -> Double { assets.clips[clip]?.audible_end_s ?? duration(clip) }
    /// End of the spoken words of a voice line (0 if the line is not bundled).
    func speechEnd(_ clip: String) -> Double { guard let c = assets.clips[clip] else { return 0 }; return c.speech_end_s ?? c.audible_end_s }
    func has(_ clip: String) -> Bool { assets.clips[clip] != nil }
    func isPlaying(_ ch: AudioChannel) -> Bool { players[ch]?.isPlaying ?? false }

    /// Plays a clip; `completion` fires once on the main thread when the audio has been
    /// played back (not merely scheduled), and never fires if the channel is stopped or reused.
    func play(_ clip: String, on ch: AudioChannel, loop: Bool = false, gain: Float = 1, completion: (() -> Void)? = nil) {
        let gen = (generation[ch] ?? 0) + 1
        generation[ch] = gen
        fadeTimers[ch]?.invalidate()
        onEvent?("play \(clip) on \(ch)")
        guard engineRunning, let p = players[ch], let buf = buffers[clip] else {
            // No audio device: keep the flow timing intact.
            if !loop, let completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration(clip)) { [weak self] in
                    if self?.generation[ch] == gen { completion() }
                }
            }
            return
        }
        // Replace whatever the channel is playing without stop(): stop() waits for the audio thread and cost the
        // main thread 4-13 ms per sound.
        p.volume = gain
        p.scheduleBuffer(buf, at: nil, options: loop ? [.loops, .interrupts] : [.interrupts], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation[ch] == gen else { return }
                completion?()
            }
        }
        if !p.isPlaying { p.play() }
    }

    func stop(_ ch: AudioChannel, fade: Double = 0) {
        let gen = (generation[ch] ?? 0) + 1
        generation[ch] = gen
        fadeTimers[ch]?.invalidate()
        guard let p = players[ch] else { return }
        if fade <= 0 || !p.isPlaying { p.stop(); return }
        let start = p.volume
        let steps = max(1, Int(fade * 60))   // 60 steps per second
        var i = 0
        fadeTimers[ch] = Timer.scheduledTimer(withTimeInterval: fade / Double(steps), repeats: true) { [weak self] t in
            i += 1
            p.volume = start * Float(max(0, 1 - Double(i) / Double(steps)))
            if i >= steps {
                t.invalidate()
                if self?.generation[ch] == gen { p.stop() }
            }
        }
    }

    /// Equivalent of the SWF's stopAllSounds().
    func stopAll(fade: Double = 0, except: Set<AudioChannel> = []) {
        for ch in AudioChannel.allCases where !except.contains(ch) { stop(ch, fade: fade) }
    }
}
