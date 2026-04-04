import Foundation

actor CatalogService {
    private var catalog: Catalog

    init() {
        self.catalog = Catalog(version: 1, lastUpdated: .now, years: [:])
    }

    // MARK: - Load / Save

    func load(from url: URL) async throws {
        catalog = try await MainActor.run {
            try Catalog.load(from: url)
        }
    }

    func save(to url: URL) async throws {
        catalog.lastUpdated = .now
        let catalogToSave = catalog
        try await MainActor.run {
            try catalogToSave.save(to: url)
        }
    }

    func currentCatalog() -> Catalog {
        catalog
    }

    // MARK: - Album Operations

    func addImage(_ image: CatalogImage, toAlbum name: String, year: String, month: String, day: String) {
        var yearEntry = catalog.years[year] ?? CatalogYear(months: [:])
        var monthEntry = yearEntry.months[month] ?? CatalogMonth(days: [:])
        var dayEntry = monthEntry.days[day] ?? CatalogDay(albums: [:])
        var album = dayEntry.albums[name] ?? CatalogAlbum(addedAt: .now, images: [])

        if !album.images.contains(where: { $0.sha256 == image.sha256 }) {
            album.images.append(image)
        }

        dayEntry.albums[name] = album
        monthEntry.days[day] = dayEntry
        yearEntry.months[month] = monthEntry
        catalog.years[year] = yearEntry
        catalog.lastUpdated = .now
    }

    // MARK: - Merge (iCloud Sync)

    func merge(remote: Catalog) -> Catalog {
        var merged = catalog

        for (year, remoteYear) in remote.years {
            var localYear = merged.years[year] ?? CatalogYear(months: [:])

            for (month, remoteMonth) in remoteYear.months {
                var localMonth = localYear.months[month] ?? CatalogMonth(days: [:])

                for (day, remoteDay) in remoteMonth.days {
                    var localDay = localMonth.days[day] ?? CatalogDay(albums: [:])

                    for (albumName, remoteAlbum) in remoteDay.albums {
                        if var localAlbum = localDay.albums[albumName] {
                            // Union images by SHA-256
                            let existingHashes = Set(localAlbum.images.map(\.sha256))
                            for image in remoteAlbum.images where !existingHashes.contains(image.sha256) {
                                localAlbum.images.append(image)
                            }
                            localAlbum.addedAt = max(localAlbum.addedAt, remoteAlbum.addedAt)
                            localDay.albums[albumName] = localAlbum
                        } else {
                            localDay.albums[albumName] = remoteAlbum
                        }
                    }

                    localMonth.days[day] = localDay
                }

                localYear.months[month] = localMonth
            }

            merged.years[year] = localYear
        }

        merged.lastUpdated = max(catalog.lastUpdated, remote.lastUpdated)
        catalog = merged
        return merged
    }
}
