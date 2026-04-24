import SwiftData
import Foundation

@Model
final class AlbumRecord {
    var name: String
    var year: String
    var month: String
    var day: String
    var addedAt: Date
    var photosAlbumLocalIdentifier: String?

    @Relationship(deleteRule: .cascade, inverse: \ImageRecord.album)
    var images: [ImageRecord]

    init(
        name: String,
        year: String,
        month: String,
        day: String,
        addedAt: Date = .now,
        photosAlbumLocalIdentifier: String? = nil,
        images: [ImageRecord] = []
    ) {
        self.name = name
        self.year = year
        self.month = month
        self.day = day
        self.addedAt = addedAt
        self.photosAlbumLocalIdentifier = photosAlbumLocalIdentifier
        self.images = images
    }

    var dateLabel: String {
        "\(year)-\(month)-\(day)"
    }
}
