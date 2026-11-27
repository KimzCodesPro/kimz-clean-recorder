import AppKit

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// UserDefaults keys, shared by @AppStorage in views and by the Recorder.
enum Pref {
    static let theme = "theme"
    static let quality = "videoQuality"
    static let fps = "fps"
    static let showsCursor = "showsCursor"
    static let hideWindow = "hideWindowWhileRecording"
    static let saveWav = "saveCleanWav"
    static let folder = "saveFolder"
    static let noiseCancel = "noiseCancel"
    static let enhance = "enhance"
    static let micGain = "micGain"
    static let micID = "micID"
    static let preset = "voicePreset"
    static let noiseStrength = "noiseStrength"
    static let popReducer = "popReducer"
    static let roomEcho = "roomEcho"
    static let expander = "expander"
    static let warmth = "warmth"
    static let normalize = "normalizeLoudness"
    static let loudnessTarget = "loudnessTarget"
    static let diagnostics = "saveDiagnostics"
    static let depth = "voiceDepth"
    static let power = "voicePower"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            theme: AppTheme.system.rawValue,
            quality: VideoQuality.high.rawValue,
            fps: 60,
            showsCursor: true,
            hideWindow: true,
            saveWav: false,
            noiseCancel: true,
            enhance: true,
            micGain: 1.0,
            preset: VoicePreset.natural.rawValue,
            noiseStrength: NoiseStrength.strong.rawValue,
            popReducer: true,
            roomEcho: false,
            expander: true,
            warmth: false,
            normalize: true,
            loudnessTarget: -14.0,
            depth: 0.4,
            power: 0.3,
        ])
    }

    static var saveFolder: URL {
        if let path = UserDefaults.standard.string(forKey: folder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kimz Clean Recorder", isDirectory: true)
    }

    /// "Recording 2026-11-19 at 02.34.12.mp4"
    static func newRecordingURL() throws -> URL {
        let dir = saveFolder
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return dir.appendingPathComponent("Recording \(f.string(from: Date())).mp4")
    }
}
