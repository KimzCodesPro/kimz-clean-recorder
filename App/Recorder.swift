import SwiftUI
import ScreenCaptureKit
import AVFoundation
import Carbon.HIToolbox

enum RecState { case idle, recording, paused, saving }

/// The app's single source of truth: screens, mics, audio settings, and the recording lifecycle.
@MainActor
final class Recorder: ObservableObject {
    // Screens
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var selectedDisplayID: CGDirectDisplayID? = nil

    // Mics (can change while recording)
    @Published private(set) var mics: [MicInfo] = []
    @Published var selectedMicID: String? = nil {
        didSet {
            guard selectedMicID != oldValue else { return }
            mic.select(deviceID: selectedMicID)
            UserDefaults.standard.set(selectedMicID, forKey: Pref.micID)
        }
    }
    /// 0 ... 2 (0 % ... 200 %).
    @Published var micGain: Double { didSet { pushParams(); save(micGain, Pref.micGain) } }
    @Published var noiseCancel: Bool { didSet { pushParams(); save(noiseCancel, Pref.noiseCancel) } }
    @Published var enhance: Bool { didSet { pushParams(); save(enhance, Pref.enhance) } }
    @Published var preset: VoicePreset { didSet { pushParams(); save(preset.rawValue, Pref.preset) } }
    @Published var noiseStrength: NoiseStrength { didSet { pushParams(); save(noiseStrength.rawValue, Pref.noiseStrength) } }
    @Published var popReducer: Bool { didSet { pushParams(); save(popReducer, Pref.popReducer) } }
    @Published var roomEcho: Bool { didSet { pushParams(); save(roomEcho, Pref.roomEcho) } }
    @Published var expander: Bool { didSet { pushParams(); save(expander, Pref.expander) } }
    @Published var warmth: Bool { didSet { pushParams(); save(warmth, Pref.warmth) } }
    /// 0 ... 1: deeper voice / stronger bass.
    @Published var depth: Double { didSet { pushParams(); save(depth, Pref.depth) } }
    /// 0 ... 1: bigger, "amplified" voice (density + saturation).
    @Published var power: Double { didSet { pushParams(); save(power, Pref.power) } }
    /// Hear the processed voice live (use headphones).
    @Published var monitoring = false { didSet { setMonitoring(monitoring) } }
    @Published private(set) var level: Float = 0

    // Recording
    @Published private(set) var state: RecState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastRecording: URL?
    @Published var errorMessage: String?

    var isNoiseModelLoaded: Bool { processor.isNoiseModelLoaded }

    private let mic = MicCapture()
    private let processor = AudioProcessor()
    private let screen = ScreenCapture()
    private let monitor = Monitor()
    private var writer: MovieWriter?
    private var bootstrapped = false
    private var hiddenWindow: NSWindow?
    private var timerTask: Task<Void, Never>?
    private var startDate = Date()
    private var pausedTotal: TimeInterval = 0
    private var pauseStart: Date?

    init() {
        Pref.registerDefaults()
        let d = UserDefaults.standard
        micGain = d.double(forKey: Pref.micGain)
        noiseCancel = d.bool(forKey: Pref.noiseCancel)
        enhance = d.bool(forKey: Pref.enhance)
        preset = VoicePreset(rawValue: d.string(forKey: Pref.preset) ?? "") ?? .natural
        noiseStrength = NoiseStrength(rawValue: d.string(forKey: Pref.noiseStrength) ?? "") ?? .strong
        popReducer = d.bool(forKey: Pref.popReducer)
        roomEcho = d.bool(forKey: Pref.roomEcho)
        expander = d.bool(forKey: Pref.expander)
        warmth = d.bool(forKey: Pref.warmth)
        depth = d.double(forKey: Pref.depth)
        power = d.double(forKey: Pref.power)
        selectedMicID = d.string(forKey: Pref.micID)
        pushParams()
    }

    // MARK: - Setup

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        AppTheme(rawValue: UserDefaults.standard.string(forKey: Pref.theme) ?? "")?.apply()

        mic.onSamples = { [processor] buf, pts in processor.process(buf, pts: pts) }
        processor.onLevel = { [weak self] v in Task { @MainActor in self?.level = v } }
        mic.onDevicesChanged = { [weak self] in self?.refreshMics() }
        screen.onError = { [weak self] err in
            Task { @MainActor in
                self?.errorMessage = "Screen capture stopped: \(err.localizedDescription)"
                await self?.stop()
            }
        }

        Task {
            if await AVCaptureDevice.requestAccess(for: .audio) {
                refreshMics()
                mic.select(deviceID: selectedMicID)
            } else {
                errorMessage = "Allow microphone access in System Settings → Privacy & Security → Microphone."
            }
            await refreshDisplays()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { await self?.refreshDisplays() } }

        // ⌃⌘R record/stop, ⌃⌘P pause/resume (⌘⇧R is taken by browsers' hard reload).
        Hotkeys.shared.register(id: 1, keyCode: kVK_ANSI_R, modifiers: cmdKey | controlKey) { [weak self] in
            Task { await self?.toggleRecord() }
        }
        Hotkeys.shared.register(id: 2, keyCode: kVK_ANSI_P, modifiers: cmdKey | controlKey) { [weak self] in
            self?.togglePause()
        }
    }

    func refreshMics() {
        mics = MicCapture.availableMics()
        if selectedMicID == nil || !mics.contains(where: { $0.id == selectedMicID }) {
            selectedMicID = mic.currentDeviceID ?? MicCapture.defaultMicID() ?? mics.first?.id
        }
    }

    func refreshDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = content.displays.map { DisplayInfo.make(from: $0) }
            if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = displays.first?.id
            }
            for d in content.displays {
                let img = await ScreenCapture.thumbnail(of: d)
                if let i = displays.firstIndex(where: { $0.id == d.displayID }) { displays[i].thumbnail = img }
            }
        } catch {
            errorMessage = "Allow screen recording in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app."
        }
    }

    // MARK: - Recording

    func toggleRecord() async {
        if state == .idle { await start() } else { await stop() }
    }

    func togglePause() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        switch state {
        case .recording:
            writer?.pause(at: now)
            pauseStart = Date()
            state = .paused
        case .paused:
            writer?.resume(at: now)
            if let p = pauseStart { pausedTotal += Date().timeIntervalSince(p) }
            pauseStart = nil
            state = .recording
        case .idle, .saving:
            break
        }
    }

    func start() async {
        guard state == .idle, let displayID = selectedDisplayID else { return }
        errorMessage = nil
        let d = UserDefaults.standard
        let fps = d.integer(forKey: Pref.fps)
        let quality = VideoQuality(rawValue: d.string(forKey: Pref.quality) ?? "") ?? .high

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError.message("That screen is no longer connected.")
            }
            // Keep this app's own windows (control panel, menu bar panel) out of the video.
            let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let (w, h) = DisplayInfo.pixelSize(display)

            let url = try Pref.newRecordingURL()
            let wavURL = d.bool(forKey: Pref.saveWav)
                ? url.deletingPathExtension().appendingPathExtension("wav") : nil
            let writer = try MovieWriter(url: url, width: w, height: h, fps: fps,
                                         quality: quality, wavURL: wavURL,
                                         diagnostics: d.bool(forKey: Pref.diagnostics))
            try writer.start(at: CMClockGetTime(CMClockGetHostTimeClock()))
            self.writer = writer
            processor.sink.set(writer)

            try await screen.start(filter: filter, width: w, height: h, fps: fps,
                                   showsCursor: d.bool(forKey: Pref.showsCursor)) { [weak writer] sb in
                writer?.appendVideo(sb)
            }

            state = .recording
            startDate = Date()
            pausedTotal = 0
            pauseStart = nil
            startTimer()

            if d.bool(forKey: Pref.hideWindow),
               let win = NSApp.windows.first(where: { $0.title == "Kimz Clean Recorder" && $0.isVisible }) {
                hiddenWindow = win
                win.orderOut(nil)
            }
        } catch {
            processor.sink.set(nil)
            writer = nil
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        guard state == .recording || state == .paused, let writer else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        state = .saving
        timerTask?.cancel()
        await screen.stop()
        processor.sink.set(nil)
        self.writer = nil

        hiddenWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hiddenWindow = nil

        do {
            let rec = try await withCheckedThrowingContinuation { (c: CheckedContinuation<FinishedRecording, Error>) in
                writer.finish(at: now) { c.resume(with: $0) }
            }
            let d = UserDefaults.standard
            if d.bool(forKey: Pref.normalize) {
                do {
                    _ = try await LoudnessNormalizer.normalize(rec, targetLUFS: d.double(forKey: Pref.loudnessTarget))
                } catch {
                    errorMessage = "Saved, but loudness normalization failed: \(error.localizedDescription)"
                }
            }
            lastRecording = rec.url
        } catch {
            errorMessage = error.localizedDescription
        }
        state = .idle
    }

    // MARK: - Helpers

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pausedNow = self.pauseStart.map { Date().timeIntervalSince($0) } ?? 0
                self.elapsed = Date().timeIntervalSince(self.startDate) - self.pausedTotal - pausedNow
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func pushParams() {
        processor.params.set(AudioProcessor.Params(
            noiseCancel: noiseCancel, noiseStrength: noiseStrength,
            enhance: enhance, preset: preset, gain: Float(micGain),
            popReducer: popReducer, roomEcho: roomEcho, voiceGate: expander, warmth: warmth,
            depth: Float(depth), power: Float(power)))
    }

    private func setMonitoring(_ on: Bool) {
        if on {
            do {
                try monitor.start()
                processor.monitor.set(monitor)
            } catch {
                errorMessage = "Couldn't start monitoring: \(error.localizedDescription)"
                monitoring = false
            }
        } else {
            processor.monitor.set(nil)
            monitor.stop()
        }
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}
