import AVFoundation
import VideoToolbox

enum VideoQuality: String, CaseIterable, Identifiable {
    case balanced, high, maximum
    var id: String { rawValue }
    var label: String {
        switch self {
        case .balanced: "Balanced (smaller)"
        case .high: "High"
        case .maximum: "Maximum"
        }
    }
    /// Constant-quality target for the HEVC hardware encoder (0...1).
    var quality: Double {
        switch self {
        case .balanced: 0.6
        case .high: 0.75
        case .maximum: 0.9
        }
    }
    /// Bits per pixel per frame, used only if the encoder rejects constant quality.
    var bitsPerPixel: Double {
        switch self {
        case .balanced: 0.03
        case .high: 0.05
        case .maximum: 0.09
        }
    }
}

/// Writes HEVC video + AAC audio (and an optional clean .wav) with pause support.
/// All work happens on one serial queue, so video and audio can be appended from any thread.
final class MovieWriter {
    let url: URL
    let wavURL: URL?

    private let queue = DispatchQueue(label: "clean-recorder.writer", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput
    private let audioFormat: CMAudioFormatDescription
    private var wavFile: AVAudioFile?
    private let wavFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                          channels: 1, interleaved: false)!

    private var t0 = CMTime.zero
    private var pauses: [(start: CMTime, end: CMTime?)] = []
    private var lastVideoTime = CMTime.negativeInfinity
    private var nextAudioTime = CMTime.zero
    private var finished = false
    private var loudness = LoudnessMeter()

    init(url: URL, width: Int, height: Int, fps: Int, quality: VideoQuality, wavURL: URL?) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Constant quality keeps text sharp and spends almost nothing on static frames.
        var settings = Self.videoSettings(width: width, height: height, fps: fps,
                                          rate: [AVVideoQualityKey: quality.quality])
        if !writer.canApply(outputSettings: settings, forMediaType: .video) {
            let bitrate = Double(width * height * fps) * quality.bitsPerPixel
            settings = Self.videoSettings(width: width, height: height, fps: fps,
                                          rate: [AVVideoAverageBitRateKey: Int(bitrate)])
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: AudioSamples.aacSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw RecorderError.message("Can't configure the video file.")
        }
        writer.add(videoInput)
        writer.add(audioInput)

        guard let fmt = AudioSamples.monoFloatFormat() else {
            throw RecorderError.message("Can't create the audio format.")
        }

        var wav: AVAudioFile?
        if let wavURL {
            wav = try AVAudioFile(forWriting: wavURL, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        self.url = url
        self.wavURL = wavURL
        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                            sourcePixelBufferAttributes: nil)
        self.audioInput = audioInput
        self.audioFormat = fmt
        self.wavFile = wav
    }

    private static func videoSettings(width: Int, height: Int, fps: Int, rate: [String: Any]) -> [String: Any] {
        var props: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
        ]
        props.merge(rate) { $1 }
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: props,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    /// `hostTime` = recording start on the host clock.
    func start(at hostTime: CMTime) throws {
        try queue.sync {
            t0 = hostTime
            guard writer.startWriting() else {
                throw writer.error ?? RecorderError.message("Can't start writing the file.")
            }
            writer.startSession(atSourceTime: .zero)
        }
    }

    func pause(at hostTime: CMTime) {
        queue.async { [self] in
            if pauses.last?.end != nil || pauses.isEmpty { pauses.append((hostTime, nil)) }
        }
    }

    func resume(at hostTime: CMTime) {
        queue.async { [self] in
            if let i = pauses.indices.last, pauses[i].end == nil { pauses[i].end = hostTime }
        }
    }

    /// Maps a host time to file time, removing paused spans. nil = drop (paused / before start).
    private func fileTime(_ pts: CMTime) -> CMTime? {
        var paused = CMTime.zero
        for p in pauses {
            if pts < p.start { break }
            guard let end = p.end else { return nil }
            if pts < end { return nil }
            paused = paused + (end - p.start)
        }
        let t = pts - t0 - paused
        return t >= .zero ? t : nil
    }

    // MARK: - Video

    func appendVideo(_ sb: CMSampleBuffer) {
        guard let pixelBuffer = sb.imageBuffer else { return }
        let pts = sb.presentationTimeStamp
        queue.async { [self] in
            guard !finished, let t = fileTime(pts), t > lastVideoTime,
                  videoInput.isReadyForMoreMediaData else { return }
            if adaptor.append(pixelBuffer, withPresentationTime: t) { lastVideoTime = t }
        }
    }

    // MARK: - Audio

    func appendAudio(_ samples: [Float], at pts: CMTime) {
        queue.async { [self] in
            guard !finished, let t = fileTime(pts) else { return }
            var chunk = samples[...]
            let drift = (t - nextAudioTime).seconds
            if drift > 0.02 {
                // Gap (mic switch, hiccup): fill with silence so audio stays continuous.
                write(ArraySlice(repeating: 0, count: Int(drift * 48_000)))
            } else if drift < -0.02 {
                // Mic clock running ahead: drop the overlap.
                chunk = chunk.dropFirst(min(chunk.count, Int(-drift * 48_000)))
            }
            if !chunk.isEmpty { write(chunk) }
        }
    }

    private func write(_ samples: ArraySlice<Float>) {
        let count = samples.count
        defer { nextAudioTime = nextAudioTime + CMTime(value: CMTimeValue(count), timescale: 48_000) }

        if let wavFile, let buf = AVAudioPCMBuffer(pcmFormat: wavFormat, frameCapacity: AVAudioFrameCount(count)) {
            buf.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
            try? wavFile.write(from: buf)
        }

        loudness.add(samples)
        guard audioInput.isReadyForMoreMediaData,
              let sb = AudioSamples.makeBuffer(samples, at: nextAudioTime, format: audioFormat) else { return }
        audioInput.append(sb)
    }

    // MARK: - Finish

    func finish(at hostTime: CMTime, completion: @escaping @Sendable (Result<FinishedRecording, Error>) -> Void) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            wavFile = nil // closes the .wav

            var end = CMTimeMaximum(lastVideoTime, nextAudioTime)
            if let t = fileTime(hostTime) { end = CMTimeMaximum(end, t) }
            guard lastVideoTime > .negativeInfinity else {
                writer.cancelWriting()
                completion(.failure(RecorderError.message("No video frames were captured.")))
                return
            }
            writer.endSession(atSourceTime: end)
            videoInput.markAsFinished()
            audioInput.markAsFinished()
            let result = FinishedRecording(url: url, wavURL: wavURL,
                                           loudnessLUFS: loudness.integratedLUFS, peak: loudness.peak)
            writer.finishWriting { [writer] in
                if writer.status == .completed { completion(.success(result)) }
                else { completion(.failure(writer.error ?? RecorderError.message("Saving failed."))) }
            }
        }
    }
}

struct FinishedRecording: Sendable {
    let url: URL
    let wavURL: URL?
    let loudnessLUFS: Double?
    let peak: Float
}

/// Helpers for mono 48 kHz Float32 CMSampleBuffers.
enum AudioSamples {
    static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 192_000,
    ]

    static let floatReaderSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    static func monoFloatFormat() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
                                       layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &fmt)
        return fmt
    }

    static func makeBuffer(_ samples: ArraySlice<Float>, at pts: CMTime,
                           format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytes = samples.count * MemoryLayout<Float>.size
        guard bytes > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block) == noErr, let block else { return nil }
        samples.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: bytes)
        }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: samples.count, presentationTimeStamp: pts,
            packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }

    /// Copies the Float32 samples out of a decoded audio sample buffer.
    static func floats(in sb: CMSampleBuffer) -> [Float] {
        var result: [Float] = []
        try? sb.withAudioBufferList { list, _ in
            guard let buf = list.first, let data = buf.mData else { return }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            result = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: n))
        }
        return result
    }
}

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): m }
    }
}
