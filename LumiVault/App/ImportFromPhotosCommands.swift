import SwiftUI

#if os(macOS)
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
#endif

extension Notification.Name {
    static let showPhotosImport = Notification.Name("showPhotosImport")
}
