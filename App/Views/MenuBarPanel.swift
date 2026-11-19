import SwiftUI

/// Menu bar icon: shows the timer while recording.
struct MenuBarLabel: View {
    @ObservedObject var rec: Recorder

    var body: some View {
        switch rec.state {
        case .idle, .saving:
            Image(systemName: "record.circle")
        case .recording:
            HStack(spacing: 4) {
                Image(systemName: "record.circle.fill")
                Text(Recorder.format(rec.elapsed)).monospacedDigit()
            }
        case .paused:
            HStack(spacing: 4) {
                Image(systemName: "pause.circle.fill")
                Text(Recorder.format(rec.elapsed)).monospacedDigit()
            }
        }
    }
}

/// Compact controls in the menu bar, usable while the main window is hidden.
struct MenuBarPanel: View {
    @EnvironmentObject private var rec: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecordBar()
            Divider()
            MicControls()
            HStack {
                Toggle("Noise cancel", isOn: $rec.noiseCancel)
                Spacer()
                Toggle("Enhance", isOn: $rec.enhance)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Picker("Voice style", selection: $rec.preset) {
                ForEach(VoicePreset.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            Toggle("Hear yourself", isOn: $rec.monitoring)
                .toggleStyle(.switch)
                .controlSize(.small)
            Divider()
            HStack {
                Button("Open window") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
    }
}
