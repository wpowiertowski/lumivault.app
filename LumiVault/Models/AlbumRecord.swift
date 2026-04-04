import SwiftData
import Foundation

@Model
final class AlbumRecord {
    var name: String
    var year: String
    var month: String
    var day: String
    var addedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ImageRecord.album)
    var images: [ImageRecord]

    init(
        name: String,
        year: String,
        month: String,
        day: String,
        addedAt: Date = .now,
        images: [ImageRecord] = []
    ) {
        self.name = name
        self.year = year
        self.month = month
        self.day = day
        self.addedAt = addedAt
        self.images = images
    }

    var dateLabel: String {
        "\(year)-\(month)-\(day)"
    }
}
