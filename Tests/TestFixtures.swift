import Foundation
@testable import LumiVault

// MARK: - Synthetic Test Dataset

/// Provides 8 deterministic synthetic files (512 bytes–10 KB) across 3 albums and 2 dates.
/// Content is generated from `(index * prime + offset) % 256` so hashes are stable.
/// PAR2 files are generated on demand via RedundancyService.
@MainActor
enum TestFixtures {

    struct FileSpec: Sendable {
        nonisolated let name: String
        nonisolated let size: Int
        nonisolated let prime: Int
        nonisolated let offset: Int
        nonisolated let sha256: String
        nonisolated let album: String
        nonisolated let year: String
        nonisolated let month: String
        nonisolated let day: String

        var albumPath: String { "\(year)/\(month)/\(day)/\(album)" }
        var par2Name: String { "\(name).par2" }

        nonisolated init(name: String, size: Int, prime: Int, offset: Int, sha256: String,
             album: String, year: String, month: String, day: String) {
            self.name = name; self.size = size; self.prime = prime; self.offset = offset
            self.sha256 = sha256; self.album = album; self.year = year; self.month = month; self.day = day
        }
    }

    /// All 8 fixture files. Grouped: 3 in Vacation, 2 in Nature, 3 in Portraits.
    static let files: [FileSpec] = [
        FileSpec(name: "sunset.heic",    size: 1024,  prime: 37, offset: 13, sha256: "15c7be47d93f2f2786bda2b188de3c42c35432ce7ce48b15a8b3d56beacdf896", album: "Vacation",  year: "2025", month: "07", day: "15"),
        FileSpec(name: "beach.heic",     size: 2048,  prime: 53, offset:  7, sha256: "925dd3eef2e812a9cdbebc55d0a757d69cc3747e0d0cd68a078ff66b1c2c7037", album: "Vacation",  year: "2025", month: "07", day: "15"),
        FileSpec(name: "mountain.heic",  size: 4096,  prime: 97, offset:  3, sha256: "b46186d5652517a5fc887a4cc4a31a6f65586aaa6751cc48fc05f6485ba23a15", album: "Vacation",  year: "2025", month: "07", day: "15"),
        FileSpec(name: "forest.heic",    size: 8192,  prime: 41, offset: 29, sha256: "34bd9400bc23da35d0ff175abfe7c40b2289c1722c55b0e99c7ab9529c03f9bc", album: "Nature",    year: "2025", month: "07", day: "15"),
        FileSpec(name: "city.heic",      size: 3072,  prime: 67, offset: 11, sha256: "45db3b40bc99e289fb57881b01de9a5fd95cd03dbf9e2cea584b866571fe7408", album: "Nature",    year: "2025", month: "07", day: "15"),
        FileSpec(name: "portrait.heic",  size: 5120,  prime: 73, offset: 17, sha256: "e701ea3bc8fef4af8dc07104b68c2925e665cecdcf19f272607ce3dc57ecab5e", album: "Portraits", year: "2025", month: "08", day: "01"),
        FileSpec(name: "landscape.heic", size: 10240, prime: 89, offset: 23, sha256: "6f1982f405ee9952d9ed60d1e3bad07579fa9a5a22133575a7754ad311838578", album: "Portraits", year: "2025", month: "08", day: "01"),
        FileSpec(name: "macro.heic",     size: 512,   prime: 31, offset:  5, sha256: "d2ac2f9510a2993696a180b29b311f6e0075487a11e0a7f1983712d8fcbcb780", album: "Portraits", year: "2025", month: "08", day: "01"),
    ]

    /// Unique album paths in the dataset.
    static let albumPaths: [String] = Array(Set(files.map(\.albumPath))).sorted()

    /// Total size of all fixture files.
    static let totalSize: Int = files.reduce(0) { $0 + $1.size }

    // MARK: - Data Generation

    /// Generate deterministic content bytes for a fixture spec.
    static func content(for spec: FileSpec) -> Data {
        Data((0..<spec.size).map { UInt8(($0 * spec.prime + spec.offset) % 256) })
    }

    /// Look up a spec by filename.
    static func spec(named name: String) -> FileSpec? {
        files.first { $0.name == name }
    }

    /// Files belonging to a specific album.
    static func files(inAlbum album: String) -> [FileSpec] {
        files.filter { $0.album == album }
    }

    // MARK: - Filesystem Materialization

    /// Materializes all fixture files into a temp directory organized by album path.
    /// Returns the root URL. Caller is responsible for cleanup via `removeItem`.
    static func materializeVolume(label: String = "TestVolume") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-fixtures-\(label)-\(UUID().uuidString)")

        for spec in files {
            let dir = root.appendingPathComponent(spec.albumPath, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content(for: spec).write(to: dir.appendingPathComponent(spec.name))
        }

        return root
    }

    /// Materializes fixture files AND generates PAR2 companions via RedundancyService.
    static func materializeVolumeWithPAR2(label: String = "TestVolume") async throws -> URL {
        let root = try materializeVolume(label: label)
        let redundancy = RedundancyService()

        for spec in files {
            let dir = root.appendingPathComponent(spec.albumPath, isDirectory: true)
            let fileURL = dir.appendingPathComponent(spec.name)
            _ = try await redundancy.generatePAR2(for: fileURL, outputDirectory: dir)
        }

        return root
    }

    /// Materializes only specific files (by name) to a directory.
    static func materialize(fileNames: [String], to root: URL) throws {
        for name in fileNames {
            guard let spec = spec(named: name) else { continue }
            let dir = root.appendingPathComponent(spec.albumPath, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content(for: spec).write(to: dir.appendingPathComponent(spec.name))
        }
    }

    // MARK: - Catalog Generation

    /// Builds a Catalog from the fixture dataset.
    static func catalog() -> Catalog {
        var years: [String: CatalogYear] = [:]

        for spec in files {
            let image = CatalogImage(
                filename: spec.name,
                sha256: spec.sha256,
                sizeBytes: Int64(spec.size),
                par2Filename: spec.par2Name
            )

            if years[spec.year] == nil {
                years[spec.year] = CatalogYear(months: [:])
            }
            if years[spec.year]!.months[spec.month] == nil {
                years[spec.year]!.months[spec.month] = CatalogMonth(days: [:])
            }
            if years[spec.year]!.months[spec.month]!.days[spec.day] == nil {
                years[spec.year]!.months[spec.month]!.days[spec.day] = CatalogDay(albums: [:])
            }
            if years[spec.year]!.months[spec.month]!.days[spec.day]!.albums[spec.album] == nil {
                years[spec.year]!.months[spec.month]!.days[spec.day]!.albums[spec.album] = CatalogAlbum(addedAt: Date(timeIntervalSince1970: 1750000000), images: [])
            }
            years[spec.year]!.months[spec.month]!.days[spec.day]!.albums[spec.album]!.images.append(image)
        }

        return Catalog(version: 1, lastUpdated: Date(timeIntervalSince1970: 1750000000), years: years)
    }

    // MARK: - Snapshot Generation

    /// Builds ImageSnapshots for reconciliation tests, optionally placing files on a given volumeID.
    static func imageSnapshots(onVolume volumeID: String? = nil) -> [ImageSnapshot] {
        files.map { spec in
            var locations: [StorageLocation] = []
            if let vid = volumeID {
                locations.append(StorageLocation(volumeID: vid, relativePath: "\(spec.albumPath)/\(spec.name)"))
            }
            return ImageSnapshot(
                sha256: spec.sha256,
                filename: spec.name,
                b2FileId: nil,
                storageLocations: locations,
                albumPath: spec.albumPath
            )
        }
    }

    /// Builds SyncImageInput entries for VolumeService sync tests.
    static func syncInputs(onVolume volumeID: String) -> [VolumeService.SyncImageInput] {
        files.map { spec in
            VolumeService.SyncImageInput(
                sha256: spec.sha256,
                filename: spec.name,
                par2Filename: spec.par2Name,
                albumPath: spec.albumPath,
                existingLocations: [
                    StorageLocation(volumeID: volumeID, relativePath: "\(spec.albumPath)/\(spec.name)")
                ]
            )
        }
    }
}
