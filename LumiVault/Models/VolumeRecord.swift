import SwiftData
import Foundation

@Model
final class VolumeRecord {
    @Attribute(.unique) var volumeID: String
    var label: String
    var mountPoint: String
    var bookmarkData: Data
    var lastSyncedAt: Date?

    init(
        volumeID: String = UUID().uuidString,
        label: String,
        mountPoint: String,
        bookmarkData: Data,
        lastSyncedAt: Date? = nil
    ) {
        self.volumeID = volumeID
        self.label = label
        self.mountPoint = mountPoint
        self.bookmarkData = bookmarkData
        self.lastSyncedAt = lastSyncedAt
    }
}
