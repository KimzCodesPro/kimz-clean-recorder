import AVFoundation

/// After recording: brings the whole file to a loudness target (e.g. -14 LUFS for YouTube).
/// Video is copied as-is (no re-encode, no quality loss); only the audio track is re-encoded.
enum LoudnessNormalizer {
    /// Returns the gain applied in dB (0 if no change was needed).
    static func normalize(_ rec: FinishedRecording, targetLUFS: Double) async throws -> Double {
        guard let measured = rec.loudnessLUFS else { return 0 }
        // Don't push more than +12 dB: it would mostly raise leftover noise.
        let gainDB = min(max(targetLUFS - measured, -12), 12)
        guard abs(gainDB) >= 0.5 else { return 0 }
        let gain = Float(pow(10, gainDB / 20))

        try await rewriteMovie(rec.url, gain: gain)
        if let wav = rec.wavURL { try rewriteWav(wav, gain: gain) }
        return gainDB
    }

    // MARK: - Movie

    private static func rewriteMovie(_ url: URL, gain: Float) async throws {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else { return }
        let videoHint = try await videoTrack.load(.formatDescriptions).first

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).mp4")
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil) // passthrough
        let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: AudioSamples.floatReaderSettings)
        reader.add(videoOut)
        reader.add(audioOut)

        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoHint)
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: AudioSamples.aacSettings)
        writer.add(videoIn)
        writer.add(audioIn)

        guard let format = AudioSamples.monoFloatFormat(),
              reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? RecorderError.message("Couldn't normalize the audio.")
        }
        writer.startSession(atSourceTime: .zero)

        let limiter = Locked(Limiter())  // shared with the audio callback
        let group = DispatchGroup()

        group.enter()
        let vq = DispatchQueue(label: "clean-recorder.normalize.video")
        videoIn.requestMediaDataWhenReady(on: vq) {
            while videoIn.isReadyForMoreMediaData {
                guard let sb = videoOut.copyNextSampleBuffer() else {
                    videoIn.markAsFinished(); group.leave(); return
                }
                videoIn.append(sb)
            }
        }

        group.enter()
        let aq = DispatchQueue(label: "clean-recorder.normalize.audio")
        audioIn.requestMediaDataWhenReady(on: aq) {
            while audioIn.isReadyForMoreMediaData {
                guard let sb = audioOut.copyNextSampleBuffer() else {
                    audioIn.markAsFinished(); group.leave(); return
                }
                var samples = AudioSamples.floats(in: sb)
                limiter.update { l in for i in samples.indices { samples[i] = l.process(samples[i] * gain) } }
                if let out = AudioSamples.makeBuffer(samples[...], at: sb.presentationTimeStamp, format: format) {
                    audioIn.append(out)
                }
            }
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tmp)
            throw reader.error ?? RecorderError.message("Couldn't read the recording.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw writer.error ?? RecorderError.message("Couldn't save the normalized recording.")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: - WAV

    private static func rewriteWav(_ url: URL, gain: Float) throws {
        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).wav")
        let output = try AVAudioFile(forWriting: tmp, settings: input.fileFormat.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        var limiter = Limiter()
        guard let buf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 48_000) else { return }
        while input.framePosition < input.length {
            try input.read(into: buf)
            guard buf.frameLength > 0, let ch = buf.floatChannelData?[0] else { break }
            for i in 0..<Int(buf.frameLength) { ch[i] = limiter.process(ch[i] * gain) }
            try output.write(from: buf)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
