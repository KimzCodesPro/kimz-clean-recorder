import SwiftUI

@main
struct CleanRecorderApp: App {
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
