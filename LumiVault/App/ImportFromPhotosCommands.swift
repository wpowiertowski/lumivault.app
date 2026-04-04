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

extension Notification.Name {
    static let showPhotosImport = Notification.Name("showPhotosImport")
}
