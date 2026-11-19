import AVFoundation
import os

/// Plays the processed voice to the default output (headphones) so you can hear the result live.
/// Latency is kept under ~60 ms; older audio is dropped instead of piling up.
final class Monitor {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?

    private let capacity = 48_000
    private let maxQueued = 2_400            // 50 ms
    private let buffer: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var readPos = 0
    private var count = 0

    init() {
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        engine.stop()
        buffer.deallocate()
        lock.deallocate()
    }

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        guard !engine.isRunning else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        if source == nil {
            let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl in
                let out = UnsafeMutableAudioBufferListPointer(abl)
                guard let dst = out.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                self.read(into: dst, count: Int(frameCount))
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            source = node
        }
        clear()
        try engine.start()
    }

    func stop() {
        engine.stop()
        clear()
    }

    /// Called from the audio processing queue.
    func push(_ samples: [Float]) {
        os_unfair_lock_lock(lock)
        for s in samples {
            buffer[(readPos + count) % capacity] = s
            if count < capacity { count += 1 } else { readPos = (readPos + 1) % capacity }
        }
        if count > maxQueued { // keep latency low
            readPos = (readPos + count - maxQueued) % capacity
            count = maxQueued
        }
        os_unfair_lock_unlock(lock)
    }

    private func read(into dst: UnsafeMutablePointer<Float>, count n: Int) {
        os_unfair_lock_lock(lock)
        let available = min(n, count)
        for i in 0..<available { dst[i] = buffer[(readPos + i) % capacity] }
        readPos = (readPos + available) % capacity
        count -= available
        os_unfair_lock_unlock(lock)
        if available < n { (dst + available).update(repeating: 0, count: n - available) }
    }

    private func clear() {
        os_unfair_lock_lock(lock)
        readPos = 0
        count = 0
        os_unfair_lock_unlock(lock)
    }
}
