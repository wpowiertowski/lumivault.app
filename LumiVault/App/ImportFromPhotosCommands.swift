import SwiftUI

struct ImportFromPhotosCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import from Photos Library...") {
                NotificationCenter.default.post(
                    name: .showPhotosImport, object: nil
                )
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}

struct PhotosSyncCommands: Commands {
    let photosMonitor: PhotosLibraryMonitor

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Check Photos for Updates") {
                Task { await photosMonitor.recheckAll() }
            }
        }
    }
}

extension Notification.Name {
    static let showPhotosImport = Notification.Name("showPhotosImport")
}
