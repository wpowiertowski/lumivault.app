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

        // Stamp the add time so a re-import can out-date a prior deletion tombstone.
        var image = image
        if image.addedAt == nil { image.addedAt = .now }

        if !album.images.contains(where: { $0.sha256 == image.sha256 }) {
            album.images.append(image)
        }

        dayEntry.albums[name] = album
        monthEntry.days[day] = dayEntry
        yearEntry.months[month] = monthEntry
        catalog.years[year] = yearEntry

        // Re-adding revives the album and this image, so clear their tombstones.
        let albumKey = "\(year)/\(month)/\(day)/\(name)"
        clearTombstones { $0.albumKey == albumKey && ($0.sha256 == nil || $0.sha256 == image.sha256) }

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
        catalog.removeAlbum(year: year, month: month, day: day, album: name)
        // Tombstone the whole album so a peer's merge can't resurrect it. The
        // album marker subsumes any per-image tombstones under the same path.
        let albumKey = "\(year)/\(month)/\(day)/\(name)"
        clearTombstones { $0.albumKey == albumKey }
        recordTombstone(CatalogTombstone(
            year: year, month: month, day: day, album: name, sha256: nil, deletedAt: .now
        ))
        catalog.lastUpdated = .now
    }

    func removeImage(sha256: String, fromAlbum name: String, year: String, month: String, day: String) {
        catalog.removeImage(sha256: sha256, year: year, month: month, day: day, album: name)
        // Tombstone this specific image so a peer's merge can't resurrect it.
        let albumKey = "\(year)/\(month)/\(day)/\(name)"
        clearTombstones { $0.albumKey == albumKey && $0.sha256 == sha256 }
        recordTombstone(CatalogTombstone(
            year: year, month: month, day: day, album: name, sha256: sha256, deletedAt: .now
        ))
        catalog.lastUpdated = .now
    }

    // MARK: - Tombstones

    private func recordTombstone(_ tombstone: CatalogTombstone) {
        var deletions = catalog.deletions ?? []
        deletions.append(tombstone)
        catalog.deletions = deletions
    }

    private func clearTombstones(where shouldRemove: (CatalogTombstone) -> Bool) {
        guard catalog.deletions != nil else { return }
        catalog.deletions?.removeAll(where: shouldRemove)
        if catalog.deletions?.isEmpty == true { catalog.deletions = nil }
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
                            // Union images by SHA-256. For an image present on both
                            // sides, reconcile field-by-field with a commutative rule
                            // so both Macs converge on identical content (otherwise a
                            // differing field — e.g. a healed b2FileId — ping-pongs
                            // forever). Sort by sha256 so the merged array is canonical
                            // regardless of which side contributed which image.
                            var imagesBySHA = Dictionary(
                                localAlbum.images.map { ($0.sha256, $0) },
                                uniquingKeysWith: { $0.reconciled(with: $1) }
                            )
                            for image in safeImages {
                                if let existing = imagesBySHA[image.sha256] {
                                    imagesBySHA[image.sha256] = existing.reconciled(with: image)
                                } else {
                                    imagesBySHA[image.sha256] = image
                                }
                            }
                            localAlbum.images = imagesBySHA.values.sorted { $0.sha256 < $1.sha256 }
                            localAlbum.addedAt = max(localAlbum.addedAt, remoteAlbum.addedAt)
                            localDay.albums[albumName] = localAlbum
                        } else {
                            var sanitizedAlbum = remoteAlbum
                            sanitizedAlbum.images = safeImages.sorted { $0.sha256 < $1.sha256 }
                            localDay.albums[albumName] = sanitizedAlbum
                        }
                    }

                    localMonth.days[day] = localDay
                }

                localYear.months[month] = localMonth
            }

            merged.years[year] = localYear
        }

        merged.deletions = Self.applyTombstones(
            local: catalog.deletions, remote: remote.deletions, to: &merged
        )
        merged.lastUpdated = max(catalog.lastUpdated, remote.lastUpdated)
        catalog = merged
        return merged
    }

    /// Union the two tombstone lists (latest `deletedAt` per target wins), then
    /// apply them to `catalog`: an item older than its tombstone is removed; an
    /// item re-added more recently supersedes and drops the tombstone. Returns
    /// the surviving tombstones (nil when none), so a catalog with no deletions
    /// stays in the legacy on-disk shape.
    private static func applyTombstones(
        local: [CatalogTombstone]?,
        remote: [CatalogTombstone]?,
        to catalog: inout Catalog
    ) -> [CatalogTombstone]? {
        // Union by target, keeping the most recent deletion.
        var latest: [String: CatalogTombstone] = [:]
        for tombstone in (local ?? []) + (remote ?? []) {
            let key = "\(tombstone.albumKey)\u{0}\(tombstone.sha256 ?? "")"
            if let existing = latest[key], existing.deletedAt >= tombstone.deletedAt { continue }
            latest[key] = tombstone
        }

        var surviving: [CatalogTombstone] = []
        for tombstone in latest.values {
            if let sha = tombstone.sha256 {
                let itemTime = catalog.imageAddedAt(
                    sha256: sha, year: tombstone.year, month: tombstone.month,
                    day: tombstone.day, album: tombstone.album
                )
                if let itemTime, itemTime > tombstone.deletedAt {
                    continue  // re-added after the deletion → tombstone superseded
                }
                catalog.removeImage(
                    sha256: sha, year: tombstone.year, month: tombstone.month,
                    day: tombstone.day, album: tombstone.album
                )
            } else {
                let itemTime = catalog.albumAddedAt(
                    year: tombstone.year, month: tombstone.month,
                    day: tombstone.day, album: tombstone.album
                )
                if let itemTime, itemTime > tombstone.deletedAt {
                    continue  // album re-created after the deletion → superseded
                }
                catalog.removeAlbum(
                    year: tombstone.year, month: tombstone.month,
                    day: tombstone.day, album: tombstone.album
                )
            }
            surviving.append(tombstone)
        }
        return surviving.isEmpty ? nil : surviving
    }
}
