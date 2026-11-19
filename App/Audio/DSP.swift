import Foundation

// Small, allocation-free DSP blocks. All run per-sample at 48 kHz.

/// RBJ cookbook biquad, transposed direct form II.
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// Raw, already-normalized coefficients (a0 = 1).
    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = Float(b0); self.b1 = Float(b1); self.b2 = Float(b2)
        self.a1 = Float(a1); self.a2 = Float(a2)
    }

    private init(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) {
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func highPass(_ f: Double, q: Double = 0.707, sr: Double = 48_000) -> Biquad {
        let w = 2 * .pi * f / sr, c = cos(w), alpha = sin(w) / (2 * q)
        return Biquad((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func lowPass(_ f: Double, q: Double = 0.707, sr: Double = 48_000) -> Biquad {
        let w = 2 * .pi * f / sr, c = cos(w), alpha = sin(w) / (2 * q)
        return Biquad((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func peaking(_ f: Double, q: Double, gainDB: Double, sr: Double = 48_000) -> Biquad {
        let a = pow(10, gainDB / 40), w = 2 * .pi * f / sr, c = cos(w), alpha = sin(w) / (2 * q)
        return Biquad(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
    }

    static func highShelf(_ f: Double, gainDB: Double, sr: Double = 48_000) -> Biquad {
        let a = pow(10, gainDB / 40), w = 2 * .pi * f / sr, c = cos(w)
        let alpha = sin(w) / 2 * sqrt(2.0), sa = 2 * sqrt(a) * alpha
        return Biquad(a * ((a + 1) + (a - 1) * c + sa),
                      -2 * a * ((a - 1) + (a + 1) * c),
                      a * ((a + 1) + (a - 1) * c - sa),
                      (a + 1) - (a - 1) * c + sa,
                      2 * ((a - 1) - (a + 1) * c),
                      (a + 1) - (a - 1) * c - sa)
    }
}

@inline(__always) func coef(ms: Double, sr: Double = 48_000) -> Float {
    Float(exp(-1 / (ms / 1000 * sr)))
}

@inline(__always) private func follow(_ env: inout Float, _ x: Float, _ attack: Float, _ release: Float) {
    let c = x > env ? attack : release
    env = c * env + (1 - c) * x
}

// MARK: - Noise reduction strength

/// Max noise attenuation for DeepFilterNet. Lower = more natural, keeps more soft speech.
enum NoiseStrength: String, CaseIterable, Identifiable {
    case light, balanced, strong, max
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var db: Float {
        switch self {
        case .light: 12
        case .balanced: 24
        case .strong: 40
        case .max: 100
        }
    }
}

// MARK: - Voice presets

enum VoicePreset: String, CaseIterable, Identifiable {
    case natural, warm, bright, broadcast
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    struct Values {
        var bodyDB: Double      // 140 Hz: chest / fullness
        var mudDB: Double       // 250 Hz: boxiness
        var presenceDB: Double  // ~4 kHz: clarity
        var airDB: Double       // 10 kHz+: crispness
        var compThreshold: Float
        var compRatio: Float
        var compMakeup: Float
        var warmth: Float       // saturation mix when Warmth is on
    }

    var values: Values {
        switch self {
        case .natural:   Values(bodyDB: 0, mudDB: -2, presenceDB: 2, airDB: 1, compThreshold: -24, compRatio: 2, compMakeup: 4, warmth: 0.15)
        case .warm:      Values(bodyDB: 2, mudDB: -1.5, presenceDB: 1, airDB: 0, compThreshold: -24, compRatio: 2.5, compMakeup: 5, warmth: 0.35)
        case .bright:    Values(bodyDB: 0, mudDB: -3, presenceDB: 4, airDB: 3, compThreshold: -22, compRatio: 3, compMakeup: 6, warmth: 0.1)
        case .broadcast: Values(bodyDB: 2.5, mudDB: -4, presenceDB: 4, airDB: 2, compThreshold: -26, compRatio: 4, compMakeup: 8, warmth: 0.25)
        }
    }
}

/// Voice EQ: body, less mud, more presence and air.
struct VoiceEQ {
    private var body, mud, presence, air: Biquad

    init(_ v: VoicePreset.Values) {
        body = .peaking(140, q: 0.8, gainDB: v.bodyDB)
        mud = .peaking(250, q: 1.0, gainDB: v.mudDB)
        presence = .peaking(4_000, q: 0.9, gainDB: v.presenceDB)
        air = .highShelf(10_000, gainDB: v.airDB)
    }

    mutating func process(_ x: Float) -> Float {
        air.process(presence.process(mud.process(body.process(x))))
    }
}

// MARK: - Dynamics

/// Feed-forward compressor with makeup gain: evens out loud and quiet speech.
struct Compressor {
    var thresholdDB: Float = -22
    var ratio: Float = 3
    var makeupDB: Float = 6
    private let attack = coef(ms: 5), release = coef(ms: 120)
    private var envDB: Float = -120

    init(_ v: VoicePreset.Values) {
        thresholdDB = v.compThreshold
        ratio = v.compRatio
        makeupDB = v.compMakeup
    }

    mutating func process(_ x: Float) -> Float {
        let lvl = 20 * log10(max(abs(x), 1e-6))
        follow(&envDB, lvl, attack, release)
        let over = envDB - thresholdDB
        let gainDB = (over > 0 ? -over * (1 - 1 / ratio) : 0) + makeupDB
        return x * pow(10, gainDB / 20)
    }
}

/// Downward expander: gently lowers breaths and leftover background between words.
struct Expander {
    var thresholdDB: Float = -55      // well below quiet speech
    var ratio: Float = 1.5
    var rangeDB: Float = 8
    private let attack = coef(ms: 1), release = coef(ms: 250)
    private let open = coef(ms: 1), close = coef(ms: 200)   // slow close keeps word endings
    private var envDB: Float = -120
    private var gain: Float = 1

    mutating func process(_ x: Float) -> Float {
        let lvl = 20 * log10(max(abs(x), 1e-6))
        follow(&envDB, lvl, attack, release)
        let below = thresholdDB - envDB
        let target = below > 0 ? pow(10, -min(below * (ratio - 1), rangeDB) / 20) : 1
        follow(&gain, target, open, close)
        return x * gain
    }
}

/// Split-band de-esser: turns down only the >6 kHz band when "s" sounds spike.
struct DeEsser {
    var threshold: Float = 0.06
    var minGain: Float = 0.4         // at most ~ -8 dB
    private var hp = Biquad.highPass(6_000)
    private let attack = coef(ms: 1), release = coef(ms: 60)
    private var env: Float = 0

    mutating func process(_ x: Float) -> Float {
        let high = hp.process(x)
        let low = x - high
        follow(&env, abs(high), attack, release)
        let g = env > threshold ? max(threshold / env, minGain) : 1
        return low + high * g
    }
}

/// Pop reducer: turns down only the <150 Hz band when "p"/"b" air bursts hit the mic.
struct PlosiveReducer {
    var threshold: Float = 0.12
    var minGain: Float = 0.25        // at most ~ -12 dB
    private var lp = Biquad.lowPass(150)
    private let attack = coef(ms: 0.5), release = coef(ms: 40)
    private var env: Float = 0

    mutating func process(_ x: Float) -> Float {
        let low = lp.process(x)
        let high = x - low
        follow(&env, abs(low), attack, release)
        let g = env > threshold ? max(threshold / env, minGain) : 1
        return high + low * g
    }
}

/// Light room-echo reduction: in 3 bands, shortens the decaying "tail" after each word.
/// A fast and a slow envelope are compared; in tails the fast one drops first, so gain drops.
struct RoomEchoReducer {
    var amount: Float = 0.6
    var minGain: Float = 0.32        // at most ~ -10 dB

    private var lowLP = Biquad.lowPass(500)
    private var highHP = Biquad.highPass(3_000)
    private var fast = [Float](repeating: 0, count: 3)
    private var slow = [Float](repeating: 0, count: 3)
    private let fastA = coef(ms: 1), fastR = coef(ms: 15)
    private let slowA = coef(ms: 1), slowR = coef(ms: 250)

    mutating func process(_ x: Float) -> Float {
        let low = lowLP.process(x)
        let rest = x - low
        let high = highHP.process(rest)
        let mid = rest - high
        return band(0, low) + band(1, mid) + band(2, high)
    }

    @inline(__always) private mutating func band(_ i: Int, _ s: Float) -> Float {
        let a = abs(s)
        follow(&fast[i], a, fastA, fastR)
        follow(&slow[i], a, slowA, slowR)
        guard slow[i] > 1e-5 else { return s }
        let ratio = min(fast[i] / slow[i], 1)
        return s * max(pow(ratio, amount), minGain)
    }
}

/// Subtle harmonic warmth (soft saturation), unity gain for small signals.
struct Warmth {
    var amount: Float = 0.25
    private let drive: Float = 2

    @inline(__always) func process(_ x: Float) -> Float {
        x + amount * (tanh(drive * x) / drive - x)
    }
}

/// Brick-wall peak limiter (instant attack): output never exceeds the ceiling.
struct Limiter {
    var ceiling: Float = 0.89        // -1 dBFS
    private let release = coef(ms: 80)
    private var gain: Float = 1

    mutating func process(_ x: Float) -> Float {
        let a = abs(x)
        let want: Float = a > ceiling ? ceiling / a : 1
        gain = want < gain ? want : release * gain + (1 - release) * want
        return x * gain
    }
}

// MARK: - Loudness (ITU-R BS.1770 / EBU R128, integrated, gated)

struct LoudnessMeter {
    // K-weighting at 48 kHz.
    private var shelf = Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                               a1: -1.69065929318241, a2: 0.73248077421585)
    private var rlb = Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)
    private var subSum: Double = 0
    private var subCount = 0
    private var subBlocks: [Double] = []        // 100 ms mean squares
    private(set) var peak: Float = 0

    mutating func add(_ samples: ArraySlice<Float>) {
        for x in samples {
            peak = max(peak, abs(x))
            let k = Double(rlb.process(shelf.process(x)))
            subSum += k * k
            subCount += 1
            if subCount == 4_800 {
                subBlocks.append(subSum / 4_800)
                subSum = 0
                subCount = 0
            }
        }
    }

    /// Integrated loudness in LUFS, or nil if the recording is (almost) silent.
    var integratedLUFS: Double? {
        guard subBlocks.count >= 4 else { return nil }
        // 400 ms blocks, 75 % overlap.
        var blocks: [Double] = []
        blocks.reserveCapacity(subBlocks.count)
        for i in 3..<subBlocks.count {
            let sum: Double = subBlocks[i - 3] + subBlocks[i - 2] + subBlocks[i - 1] + subBlocks[i]
            blocks.append(sum / 4)
        }
        func lufs(_ p: Double) -> Double { -0.691 + 10 * log10(max(p, 1e-12)) }
        let audible = blocks.filter { lufs($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let relGate = lufs(audible.reduce(0, +) / Double(audible.count)) - 10
        let gated = audible.filter { lufs($0) > relGate }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }
}

/// Simple thread-safe box.
final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
}
