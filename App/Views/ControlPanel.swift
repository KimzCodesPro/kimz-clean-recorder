import SwiftUI

struct ControlPanel: View {
    @EnvironmentObject private var rec: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Screen").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                ThemePicker().frame(width: 190)
            }

            DisplayGrid()

            Divider()
            MicControls()
            Divider()

            Toggle(isOn: $rec.noiseCancel) {
                Label("Noise cancel", systemImage: "waveform.badge.minus")
            }
            .disabled(!rec.isNoiseModelLoaded)
            Picker("Strength", selection: $rec.noiseStrength) {
                ForEach(NoiseStrength.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!rec.noiseCancel)
            .help("Lower strength keeps more of your voice; higher removes more noise")
            Toggle(isOn: $rec.enhance) {
                Label("Enhance voice", systemImage: "sparkles")
            }
            Picker("Voice style", selection: $rec.preset) {
                ForEach(VoicePreset.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!rec.enhance)
            Toggle(isOn: $rec.monitoring) {
                Label("Hear yourself (use headphones)", systemImage: "headphones")
            }

            LevelMeter(level: rec.level)

            Divider()
            RecordBar()

            if let url = rec.lastRecording, rec.state == .idle {
                SavedBanner(url: url)
            }
            if let err = rec.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(18)
        .frame(width: 380)
        .onAppear { rec.bootstrap() }
    }
}

// MARK: - Screens

private struct DisplayGrid: View {
    @EnvironmentObject private var rec: Recorder

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
            ForEach(rec.displays) { d in
                DisplayCard(display: d, selected: d.id == rec.selectedDisplayID)
                    .onTapGesture { rec.selectedDisplayID = d.id }
            }
        }
        .disabled(rec.state != .idle)
        .overlay {
            if rec.displays.isEmpty {
                Text("Looking for screens…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 60)
    }
}

private struct DisplayCard: View {
    let display: DisplayInfo
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let img = display.thumbnail {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(display.name).font(.caption).lineLimit(1)
            Text("\(display.pixelWidth)×\(display.pixelHeight)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                              lineWidth: selected ? 2 : 0.5)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Mic (works while recording)

struct MicControls: View {
    @EnvironmentObject private var rec: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Mic", systemImage: "mic")
                Spacer()
                Picker("", selection: $rec.selectedMicID) {
                    if rec.mics.isEmpty { Text("No mic found").tag(String?.none) }
                    ForEach(rec.mics) { m in Text(m.name).tag(Optional(m.id)) }
                }
                .labelsHidden()
                .frame(width: 210)
                Button { rec.refreshMics() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh mic list")
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $rec.micGain, in: 0...2, step: 0.05)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                Text("\(Int((rec.micGain * 100).rounded()))%")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 42, alignment: .trailing)
                    .onTapGesture(count: 2) { rec.micGain = 1 } // double-click resets to 100 %
            }
            .help("Mic volume (double-click the % to reset)")
        }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.92 ? Color.red : level > 0.8 ? .orange : .green)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Record bar

struct RecordBar: View {
    @EnvironmentObject private var rec: Recorder

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            if rec.state == .saving {
                ProgressView().controlSize(.small)
                Text("Saving…").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(Recorder.format(rec.elapsed))
                    .font(.system(size: 15, design: .monospaced))
            }
            Spacer()
            Button { rec.togglePause() } label: {
                Image(systemName: rec.state == .paused ? "play.fill" : "pause.fill").frame(width: 18)
            }
            .disabled(rec.state == .idle || rec.state == .saving)
            .help("Pause / resume (⌃⌘P)")

            Button { Task { await rec.stop() } } label: {
                Image(systemName: "stop.fill").frame(width: 18)
            }
            .disabled(rec.state == .idle || rec.state == .saving)
            .help("Stop (⌃⌘R)")

            Button { Task { await rec.start() } } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(rec.state != .idle || rec.selectedDisplayID == nil)
            .help("Record (⌃⌘R)")
        }
        .controlSize(.large)
    }

    private var dotColor: Color {
        switch rec.state {
        case .recording: .red
        case .paused: .orange
        case .idle, .saving: .secondary
        }
    }
}

private struct SavedBanner: View {
    let url: URL

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .controlSize(.small)
        .padding(8)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ThemePicker: View {
    @AppStorage(Pref.theme) private var theme: AppTheme = .system

    var body: some View {
        Picker("", selection: $theme) {
            ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: theme, initial: true) { _, t in t.apply() }
    }
}
