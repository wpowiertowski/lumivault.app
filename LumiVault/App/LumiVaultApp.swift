import SwiftUI
import SwiftData
import AppKit

final class AppActivationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct LumiVaultApp: App {
    let container = SwiftDataContainer.create()
    let encryptionService = EncryptionService()
    @NSApplicationDelegateAdaptor(AppActivationDelegate.self) private var appDelegate
    @State private var syncCoordinator = SyncCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Constants.Design.accentColor)
                .environment(syncCoordinator)
                .environment(\.encryptionService, encryptionService)
                .task {
                    syncCoordinator.modelContainer = container
                    await syncCoordinator.setup()
                }
        }
        .modelContainer(container)
        .commands {
            ImportFromPhotosCommands()
        }

        Settings {
            SettingsView()
                .environment(syncCoordinator)
                .environment(\.encryptionService, encryptionService)
        }
        .modelContainer(container)
    }
}
