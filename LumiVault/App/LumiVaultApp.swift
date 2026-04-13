import SwiftUI
import SwiftData

#if os(macOS)
import AppKit

final class AppActivationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif

@main
struct LumiVaultApp: App {
    let container = SwiftDataContainer.create()
    let encryptionService = EncryptionService()
    let thumbnailService = ThumbnailService()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppActivationDelegate.self) private var appDelegate
    #endif
    @State private var syncCoordinator = SyncCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Constants.Design.accentColor)
                .environment(syncCoordinator)
                .environment(\.encryptionService, encryptionService)
                .environment(\.thumbnailService, thumbnailService)
                .task {
                    syncCoordinator.modelContainer = container
                    await syncCoordinator.setup()
                }
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            ImportFromPhotosCommands()
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(syncCoordinator)
                .environment(\.encryptionService, encryptionService)
                .environment(\.thumbnailService, thumbnailService)
        }
        .modelContainer(container)
        #endif
    }
}
