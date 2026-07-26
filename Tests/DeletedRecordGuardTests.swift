import Testing
import Foundation
import SwiftData
@testable import LumiVault

// Regression coverage for the Photos re-sync removal crash.
//
// A thumbnail-regeneration task in `PhotoGridItem` can still hold an `ImageRecord`
// after a re-sync deletes that photo from the album. Writing the deleted record's
// persisted attributes (`thumbnailState`, `storageLocations`) traps with
// "backing data was detached from a context", and that corruption surfaces as an
// EXC_BAD_ACCESS in the sidebar's `AlbumRecord.images` read. PhotoGridItem now
// gates every post-`await` write-back on `image.modelContext != nil`; these tests
// lock in the SwiftData behavior that guard depends on.
@Suite
@MainActor
struct DeletedRecordGuardTests {

    func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: AlbumRecord.self, ImageRecord.self, VolumeRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @Test func deletedRecordDetachesAndRelationshipStaysReadable() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let album = AlbumRecord(name: "Grasslawn", year: "2026", month: "07", day: "24")
        ctx.insert(album)
        let keep = ImageRecord(sha256: "keep", filename: "a.heic", sizeBytes: 1, album: album)
        let drop = ImageRecord(sha256: "drop", filename: "b.heic", sizeBytes: 1, album: album)
        ctx.insert(keep)
        ctx.insert(drop)
        album.images.append(keep)
        album.images.append(drop)
        try ctx.save()

        // Re-sync removes `drop` while a grid task still holds this reference.
        let inflight = drop
        ctx.delete(drop)
        try ctx.save()

        // The guard PhotoGridItem uses: a detached record reports a nil context,
        // and reading `modelContext` on it is safe (does not trap).
        #expect(inflight.modelContext == nil)

        // Because the write-back is skipped, the album's `images` relationship —
        // the sidebar read that crashed — stays valid and reflects the deletion.
        #expect(album.images.map(\.sha256) == ["keep"])
    }
}
