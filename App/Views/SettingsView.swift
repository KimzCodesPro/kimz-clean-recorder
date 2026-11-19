import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var rec: Recorder
    @AppStorage(Pref.normalize) private var normalize = true
    @AppStorage(Pref.loudnessTarget) private var loudnessTarget = -14.0
    @AppStorage(Pref.quality) private var quality: VideoQuality = .high
    @AppStorage(Pref.fps) private var fps = 60
    @AppStorage(Pref.showsCursor) private var showsCursor = true
    @AppStorage(Pref.hideWindow) private var hideWindow = true
    @AppStorage(Pref.saveWav) private var saveWav = false
    @AppStorage(Pref.folder) private var folder = ""

    var body: some View {
        Form {
            Section("Appearance") {
                ThemePicker()
            }
            Section("Video") {
                Picker("Quality", selection: $quality) {
                    ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                }
                Picker("Frame rate", selection: $fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Show mouse cursor", isOn: $showsCursor)
                Text("HEVC (.mp4) at native resolution. Higher quality means larger files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Voice") {
                Picker("Voice style", selection: $rec.preset) {
                    ForEach(VoicePreset.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Pop reducer (p / b sounds)", isOn: $rec.popReducer)
                Toggle("Silence cleanup (breaths, small noises)", isOn: $rec.expander)
                Toggle("Room echo reduction", isOn: $rec.roomEcho)
                Toggle("Warmth", isOn: $rec.warmth)
                Text("Room echo reduction is light. Best for small echoes. Treating the room works better for big ones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Loudness") {
                Toggle("Normalize loudness after recording", isOn: $normalize)
                Picker("Target", selection: $loudnessTarget) {
                    Text("−14 LUFS (YouTube)").tag(-14.0)
                    Text("−16 LUFS (Podcast)").tag(-16.0)
                }
                .disabled(!normalize)
                Toggle("Also save clean audio as .wav", isOn: $saveWav)
            }
            Section("Saving") {
                HStack {
                    Text(Pref.saveFolder.path).lineLimit(1).truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                }
                Toggle("Hide window while recording", isOn: $hideWindow)
            }
            Section("Shortcuts") {
                LabeledContent("Record / stop", value: "⌃⌘R")
                LabeledContent("Pause / resume", value: "⌃⌘P")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Pref.saveFolder
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}
