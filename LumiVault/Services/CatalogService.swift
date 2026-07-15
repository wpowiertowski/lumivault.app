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

    /// Persist the catalog plus its .sha256/.par2 sidecars. Runs on this
    /// actor's executor — Catalog is nonisolated, so the JSON encode, hashing,
    /// and PAR2 generation stay off the main thread. `lastUpdated` is NOT
    /// bumped here: every mutating operation already bumps it, and bumping on
    /// save made each sync produce "new" content, fueling a cross-Mac
    /// push ping-pong that hung the UI on every iCloud round-trip.
    func save(to url: URL) async throws {
        try catalog.save(to: url)
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

    // MARK: - Query

    /// Aggregate image counts per album name across all year/month/day entries.
    func albumImageCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for year in catalog.years.values {
            for month in year.months.values {
                for day in month.days.values {
                    for (name, album) in day.albums {
                        counts[name, default: 0] += album.images.count
                    }
                }
            }
        }
        return counts
    }

    // MARK: - Remove Operations

    func removeAlbum(name: String, year: String, month: String, day: String) {
        guard var yearEntry = catalog.years[year],
              var monthEntry = yearEntry.months[month],
              var dayEntry = monthEntry.days[day] else { return }

        dayEntry.albums.removeValue(forKey: name)

        // Prune empty containers
        if dayEntry.albums.isEmpty {
            monthEntry.days.removeValue(forKey: day)
        } else {
            monthEntry.days[day] = dayEntry
        }

        if monthEntry.days.isEmpty {
            yearEntry.months.removeValue(forKey: month)
        } else {
            yearEntry.months[month] = monthEntry
        }

        if yearEntry.months.isEmpty {
            catalog.years.removeValue(forKey: year)
        } else {
            catalog.years[year] = yearEntry
        }

        catalog.lastUpdated = .now
    }

    func removeImage(sha256: String, fromAlbum name: String, year: String, month: String, day: String) {
        guard var yearEntry = catalog.years[year],
              var monthEntry = yearEntry.months[month],
              var dayEntry = monthEntry.days[day],
              var album = dayEntry.albums[name] else { return }

        album.images.removeAll { $0.sha256 == sha256 }

        // Removing the last image empties the album; prune it and any now-empty
        // day/month/year containers so catalog.json (shared with the CLI) doesn't
        // accumulate ghost albums that the UI can never clear.
        if album.images.isEmpty {
            dayEntry.albums.removeValue(forKey: name)
        } else {
            dayEntry.albums[name] = album
        }

        if dayEntry.albums.isEmpty {
            monthEntry.days.removeValue(forKey: day)
        } else {
            monthEntry.days[day] = dayEntry
        }

        if monthEntry.days.isEmpty {
            yearEntry.months.removeValue(forKey: month)
        } else {
            yearEntry.months[month] = monthEntry
        }

        if yearEntry.months.isEmpty {
            catalog.years.removeValue(forKey: year)
        } else {
            catalog.years[year] = yearEntry
        }

        catalog.lastUpdated = .now
    }

    /// Update the recorded B2 fileId for an image (matched by sha256) wherever it
    /// appears in the catalog tree. Used after the heal pass re-uploads a file that
    /// went missing from B2 and B2 assigns it a fresh fileId.
    func updateImageB2FileId(sha256: String, b2FileId: String) {
        var didChange = false
        for (year, var yearEntry) in catalog.years {
            for (month, var monthEntry) in yearEntry.months {
                for (day, var dayEntry) in monthEntry.days {
                    for (albumName, var album) in dayEntry.albums {
                        var albumChanged = false
                        for index in album.images.indices where album.images[index].sha256 == sha256 {
                            album.images[index].b2FileId = b2FileId
                            albumChanged = true
                        }
                        if albumChanged {
                            dayEntry.albums[albumName] = album
                            monthEntry.days[day] = dayEntry
                            yearEntry.months[month] = monthEntry
                            catalog.years[year] = yearEntry
                            didChange = true
                        }
                    }
                }
            }
        }
        if didChange { catalog.lastUpdated = .now }
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
                        // Drop tampered remote entries whose path keys/filenames would
                        // traverse out of the album directory once joined into a path.
                        guard PathComponentValidation.isSafeAlbum(
                            year: year, month: month, day: day, albumName: albumName
                        ) else { continue }
                        let safeImages = remoteAlbum.images.filter {
                            PathComponentValidation.isSafe($0.filename)
                                && ($0.par2Filename.isEmpty
                                    || PathComponentValidation.isSafe($0.par2Filename))
                        }

                        if var localAlbum = localDay.albums[albumName] {
                            // Union images by SHA-256
                            let existingHashes = Set(localAlbum.images.map(\.sha256))
                            for image in safeImages where !existingHashes.contains(image.sha256) {
                                localAlbum.images.append(image)
                            }
                            localAlbum.addedAt = max(localAlbum.addedAt, remoteAlbum.addedAt)
                            localDay.albums[albumName] = localAlbum
                        } else {
                            var sanitizedAlbum = remoteAlbum
                            sanitizedAlbum.images = safeImages
                            localDay.albums[albumName] = sanitizedAlbum
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
