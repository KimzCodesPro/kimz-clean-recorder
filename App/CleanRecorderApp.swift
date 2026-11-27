import SwiftUI

/// Quitting: stop and save an in-progress recording first, then exit
/// (exiting releases the mic, screen capture and everything else).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let rec = Recorder.current, rec.state != .idle else { return .terminateNow }
        Task { @MainActor in
            await rec.stop()
            while rec.state != .idle { try? await Task.sleep(for: .milliseconds(100)) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct CleanRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        Window("Kimz Clean Recorder", id: "main") {
            ControlPanel()
                .environmentObject(recorder)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(recorder)
        } label: {
            MenuBarLabel(rec: recorder)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(recorder)
        }
    }
}
