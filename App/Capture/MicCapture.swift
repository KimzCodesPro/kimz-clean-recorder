import AVFoundation

struct MicInfo: Identifiable, Hashable {
    let id: String      // AVCaptureDevice.uniqueID
    let name: String
}

/// Captures the selected microphone as mono 48 kHz Float32.
/// The mic can be switched while running; samples keep flowing with host-clock timestamps.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let sampleRate: Double = 48_000

    /// Called on `audioQueue` with each chunk and its start time on the host clock.
    var onSamples: (@Sendable (UnsafeBufferPointer<Float>, CMTime) -> Void)?
    /// Called on the main queue when a mic is plugged in or removed.
    var onDevicesChanged: (() -> Void)?
    /// Called on the main queue with the selected mic's native sample rate (16 kHz = headset).
    var onSourceRate: ((Double) -> Void)?

    let audioQueue = DispatchQueue(label: "clean-recorder.mic.audio", qos: .userInteractive)

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "clean-recorder.mic.session")
    private var input: AVCaptureDeviceInput?
    private var observers: [NSObjectProtocol] = []
    private let hostClock = CMClockGetHostTimeClock()

    // Fallback conversion for mics macOS doesn't deliver as 48 kHz mono Float32.
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                       channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private var reportedRate: Double = 0

    static func availableMics() -> [MicInfo] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { MicInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func defaultMicID() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    override init() {
        super.init()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: audioQueue)

        let nc = NotificationCenter.default
        for name in [Notification.Name.AVCaptureDeviceWasConnected, .AVCaptureDeviceWasDisconnected] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                if name == .AVCaptureDeviceWasDisconnected,
                   let dev = note.object as? AVCaptureDevice,
                   dev.uniqueID == self.currentDeviceID {
                    // Active mic was unplugged: fall back to the system default.
                    self.select(deviceID: Self.defaultMicID())
                }
                self.onDevicesChanged?()
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private(set) var currentDeviceID: String?

    /// Starts capturing (or switches device if already running). Safe to call anytime.
    func select(deviceID: String?) {
        sessionQueue.async { [self] in
            let id = deviceID ?? Self.defaultMicID()
            guard let id, id != input?.device.uniqueID,
                  let device = AVCaptureDevice(uniqueID: id),
                  let newInput = try? AVCaptureDeviceInput(device: device) else {
                if !session.isRunning, input != nil { session.startRunning() }
                return
            }

            session.beginConfiguration()
            if let input { session.removeInput(input) }
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                input = newInput
            } else if let old = input, session.canAddInput(old) {
                session.addInput(old) // keep the old mic if the new one fails
            }
            if session.outputs.isEmpty, session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()

            currentDeviceID = input?.device.uniqueID
            if !session.isRunning { session.startRunning() }
            if let rate = input?.device.activeFormat.formatDescription.audioStreamBasicDescription?.mSampleRate {
                report(rate: rate)
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in session.stopRunning() }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let fd = sampleBuffer.formatDescription,
              let asbd = fd.audioStreamBasicDescription else { return }

        // Put the timestamp on the same clock ScreenCaptureKit uses.
        let pts = session.synchronizationClock.map {
            CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: $0, to: hostClock)
        } ?? sampleBuffer.presentationTimeStamp

        let isTarget = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && asbd.mChannelsPerFrame == 1
            && Int(asbd.mSampleRate) == Int(Self.sampleRate)

        if isTarget {
            try? sampleBuffer.withAudioBufferList { list, _ in
                guard let buf = list.first, let data = buf.mData else { return }
                let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                onSamples?(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count), pts)
            }
        } else {
            report(rate: asbd.mSampleRate)
            convert(sampleBuffer, format: fd, pts: pts)
        }
    }

    /// Resamples / downmixes any PCM format to 48 kHz mono Float32 (e.g. 16 kHz headset mics).
    private func convert(_ sb: CMSampleBuffer, format fd: CMFormatDescription, pts: CMTime) {
        let source = AVAudioFormat(cmAudioFormatDescription: fd)
        if converterSource != source {
            converter = AVAudioConverter(from: source, to: target)
            converter?.downmix = true
            converterSource = source
        }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard let converter, frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { return }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sb, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr else { return }

        let capacity = AVAudioFrameCount(Double(frames) * Self.sampleRate / source.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let fed = Locked(false)   // the input block may be @Sendable: no captured `var`
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed.get() { status.pointee = .noDataNow; return nil }
            fed.set(true)
            status.pointee = .haveData
            return input
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
        onSamples?(UnsafeBufferPointer(start: data, count: Int(out.frameLength)), pts)
    }

    private func report(rate: Double) {
        guard rate > 0, rate != reportedRate else { return }
        reportedRate = rate
        DispatchQueue.main.async { [weak self] in self?.onSourceRate?(rate) }
    }
}
