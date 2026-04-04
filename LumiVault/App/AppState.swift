import SwiftUI
import Observation

@MainActor
@Observable
final class AppState {
    var selectedAlbum: AlbumRecord?
    var selectedImage: ImageRecord?
    var searchText: String = ""
    var isImporting: Bool = false
    var isSyncing: Bool = false

    static let shared = AppState()

    private init() {}
}
