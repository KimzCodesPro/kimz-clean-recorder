import CoreMedia

/// Mic chain:
/// high-pass → DeepFilterNet → mic gain → pop reducer → room echo → expander
/// → EQ → compressor → de-esser → warmth → limiter
/// Runs on the mic's audio queue. Output timestamps are corrected for DeepFilterNet's delay.
final class AudioProcessor {
    struct Params: Equatable {
        var noiseCancel = true
        var noiseStrength = NoiseStrength.strong
        var enhance = true            // EQ + compressor + de-esser (shaped by preset)
        var preset = VoicePreset.natural
        var gain: Float = 1           // linear, 0...2 (0 % ... 200 %)
        var popReducer = true
        var roomEcho = false
        var expander = true
        var warmth = false
    }

    let params = Locked(Params())
    /// Where processed audio goes while recording (nil when idle).
    let sink = Locked<MovieWriter?>(nil)
    /// Live headphone monitoring (nil when off).
    let monitor = Locked<Monitor?>(nil)
    /// Peak level 0...1, about 20 times per second (called on the audio queue).
    var onLevel: (@Sendable (Float) -> Void)?

    private static let sr = 48_000.0

    private let dfn: OpaquePointer?
    private let frameLength: Int
    private var dfnAtten: Float?
    private var builtPreset: VoicePreset?

    private var highPass = Biquad.highPass(80)
    private var plosive = PlosiveReducer()
    private var roomEcho = RoomEchoReducer()
    private var expander = Expander()
    private var eq = VoiceEQ(VoicePreset.natural.values)
    private var compressor = Compressor(VoicePreset.natural.values)
    private var deEsser = DeEsser()
    private var warmth = Warmth()
    private var limiter = Limiter()

    private var pending: [Float] = []         // high-passed input waiting for a full DFN frame
    private var frameOut: [Float]
    private var out: [Float] = []
    private var toDrop: Int                   // DFN latency still to discard

    // Timing: input sample index <-> host time, refreshed every buffer (no clock drift).
    private var inputCount: Int64 = 0
    private var outputCount: Int64 = 0
    private var anchorIndex: Int64 = 0
    private var anchorTime = CMTime.zero

    private var peak: Float = 0
    private var peakCount = 0

    init() {
        dfn = dfn_create(NoiseStrength.strong.db)
        frameLength = dfn.map { Int(dfn_frame_length($0)) } ?? 480
        toDrop = dfn.map { Int(dfn_latency_samples($0)) } ?? 0
        frameOut = [Float](repeating: 0, count: frameLength)
        pending.reserveCapacity(frameLength * 8)
        out.reserveCapacity(frameLength * 8)
    }

    deinit { if let dfn { dfn_free(dfn) } }

    var isNoiseModelLoaded: Bool { dfn != nil }

    func process(_ input: UnsafeBufferPointer<Float>, pts: CMTime) {
        let p = params.get()
        let atten = p.noiseCancel ? p.noiseStrength.db : 0   // 0 = pass-through, same latency
        if let dfn, dfnAtten != atten {
            dfn_set_attenuation(dfn, atten)
            dfnAtten = atten
        }
        if builtPreset != p.preset {
            let v = p.preset.values
            eq = VoiceEQ(v)
            compressor = Compressor(v)
            warmth.amount = v.warmth
            builtPreset = p.preset
        }

        anchorIndex = inputCount
        anchorTime = pts
        inputCount += Int64(input.count)

        for x in input { pending.append(highPass.process(x)) }

        out.removeAll(keepingCapacity: true)
        var start = 0
        if let dfn {
            while pending.count - start >= frameLength {
                pending.withUnsafeBufferPointer { inBuf in
                    frameOut.withUnsafeMutableBufferPointer { outBuf in
                        _ = dfn_process(dfn, inBuf.baseAddress! + start, outBuf.baseAddress!)
                    }
                }
                for y in frameOut { post(y, p) }
                start += frameLength
            }
        } else {
            for y in pending { post(y, p) }
            start = pending.count
        }
        pending.removeFirst(start)

        guard !out.isEmpty else { return }

        // Output sample m (after dropping the latency) lines up with input sample m.
        let offset = Double(outputCount - anchorIndex) / Self.sr
        let outPTS = anchorTime + CMTime(seconds: offset, preferredTimescale: 48_000)
        outputCount += Int64(out.count)

        sink.get()?.appendAudio(out, at: outPTS)
        monitor.get()?.push(out)
    }

    @inline(__always) private func post(_ y: Float, _ p: Params) {
        if toDrop > 0 { toDrop -= 1; return }
        var s = y * p.gain
        if p.popReducer { s = plosive.process(s) }
        if p.roomEcho { s = roomEcho.process(s) }
        if p.expander { s = expander.process(s) }
        if p.enhance {
            s = eq.process(s)
            s = compressor.process(s)
            s = deEsser.process(s)
        }
        if p.warmth { s = warmth.process(s) }
        s = limiter.process(s)
        out.append(s)

        peak = max(peak, abs(s))
        peakCount += 1
        if peakCount >= 2_400 { // 50 ms
            let db = 20 * log10(max(peak, 1e-5))
            onLevel?(min(max((db + 60) / 60, 0), 1))
            peak = 0
            peakCount = 0
        }
    }
}
