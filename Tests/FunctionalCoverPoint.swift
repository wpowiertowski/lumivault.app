import Testing

/// Declares every functional behavior LumiVault must test.
///
/// Add a new case when a feature ships. The `allCoverPointsHaveTests` meta-test
/// fails until the case appears in `coveredByTests`, forcing you to write (or
/// acknowledge) a test before the suite goes green.
enum FunctionalCoverPoint: String, CaseIterable {

    // MARK: - Catalog

    /// Catalog JSON encodes and decodes without data loss
    case catalogRoundTrip
    /// Catalog uses snake_case keys compatible with the CLI tool
    case catalogSnakeCaseEncoding
    /// Catalog reads/writes to disk via file I/O
    case catalogFileIO
    /// Disjoint and overlapping catalogs merge correctly
    case catalogMerge
    /// Adding an image deduplicates by SHA-256 within the catalog
    case catalogAddImageDedup
    /// Albums and images can be removed; empty containers are pruned
    case catalogRemoval
    /// Catalog backs up to and restores from external volumes
    case catalogBackupRestore

    // MARK: - Hashing

    /// SHA-256 produces correct, consistent hashes
    case sha256Hashing
    /// SHA-256 handles edge cases (empty file)
    case sha256EdgeCases

    // MARK: - PAR2 Error Correction

    /// PAR2 files are generated with correct header and format
    case par2Generation
    /// PAR2 verification detects intact vs corrupted files
    case par2Verification
    /// PAR2 repair restores corrupted data blocks
    case par2Repair
    /// PAR2 files interoperate with par2cmdline
    case par2Interoperability

    // MARK: - Encryption

    /// Password-based key derivation is deterministic and unique per input
    case keyDerivation
    /// Data encrypts and decrypts without loss (in-memory and file-based)
    case encryptDecryptRoundTrip
    /// Decryption fails with wrong key or tampered associated data
    case encryptionAuthFailure
    /// Each encryption produces a unique nonce
    case encryptionNonceUniqueness
    /// Edge cases: empty data, large data, size calculations
    case encryptionEdgeCases

    // MARK: - Integrity

    /// SHA-256 integrity verification passes for valid files
    case fileIntegrityVerification
    /// GCM tag integrity verification for encrypted files
    case gcmIntegrity

    // MARK: - Deduplication

    /// Exact-hash deduplication detects matches and unique files
    case exactDeduplication
    /// Perceptual hash Hamming distance is correct and symmetric
    case perceptualHashDistance
    /// Perceptual hash computation is deterministic
    case perceptualHashComputation

    // MARK: - Volume Sync

    /// All files sync from one volume to another with hash verification
    case volumeSyncAllFiles
    /// Sync deduplicates files already present on the target volume
    case volumeSyncDeduplication
    /// Sync detects hash mismatches on the target
    case volumeSyncHashMismatch

    // MARK: - Reconciliation

    /// B2 reconciliation detects dangling file IDs and orphans
    case b2ReconciliationDiff
    /// Volume scan detects dangling locations and orphan files
    case volumeScanDiscrepancies

    // MARK: - Deletion

    /// Files and PAR2 companions are removed from volumes
    case fileDeletion
    /// Empty ancestor directories are cleaned up after deletion
    case fileDeletionCleanup

    // MARK: - B2 Cloud

    /// B2 helper SHA-1 hashing produces correct values
    case b2SHA1Hashing
    /// B2 HTTP response status checking works correctly
    case b2ResponseChecking

    // MARK: - Image Processing

    /// Images convert between formats (HEIC → JPEG)
    case imageConversion
    /// Images scale down when exceeding max dimension
    case imageScaling

    // MARK: - Data Models

    /// SwiftData model relationships and defaults are correct
    case dataModelRelationships
    /// Enum types (StorageLocation, ThumbnailState) round-trip through Codable
    case dataModelCodable

    // MARK: - Export Progress

    /// Export progress fractions calculate correctly across phases
    case exportProgressCalculation

    // MARK: - Integration

    /// Encrypted files survive PAR2 repair and decrypt correctly
    case encryptPAR2Integration
}

// MARK: - Meta-Test

@Suite(.tags(.integration))
@MainActor
struct FunctionalCoverageTests {

    /// Every declared cover point must appear in `coveredByTests`.
    /// When you add a new `FunctionalCoverPoint` case, this test fails
    /// until you add corresponding test coverage and list it here.
    @Test func allCoverPointsHaveTests() {
        let coveredByTests: Set<FunctionalCoverPoint> = [
            // Catalog
            .catalogRoundTrip,
            .catalogSnakeCaseEncoding,
            .catalogFileIO,
            .catalogMerge,
            .catalogAddImageDedup,
            .catalogRemoval,
            .catalogBackupRestore,

            // Hashing
            .sha256Hashing,
            .sha256EdgeCases,

            // PAR2
            .par2Generation,
            .par2Verification,
            .par2Repair,
            .par2Interoperability,

            // Encryption
            .keyDerivation,
            .encryptDecryptRoundTrip,
            .encryptionAuthFailure,
            .encryptionNonceUniqueness,
            .encryptionEdgeCases,

            // Integrity
            .fileIntegrityVerification,
            .gcmIntegrity,

            // Deduplication
            .exactDeduplication,
            .perceptualHashDistance,
            .perceptualHashComputation,

            // Volume Sync
            .volumeSyncAllFiles,
            .volumeSyncDeduplication,
            .volumeSyncHashMismatch,

            // Reconciliation
            .b2ReconciliationDiff,
            .volumeScanDiscrepancies,

            // Deletion
            .fileDeletion,
            .fileDeletionCleanup,

            // B2 Cloud
            .b2SHA1Hashing,
            .b2ResponseChecking,

            // Image Processing
            .imageConversion,
            .imageScaling,

            // Data Models
            .dataModelRelationships,
            .dataModelCodable,

            // Export Progress
            .exportProgressCalculation,

            // Integration
            .encryptPAR2Integration,
        ]

        let allPoints = Set(FunctionalCoverPoint.allCases)
        let uncovered = allPoints.subtracting(coveredByTests)

        #expect(uncovered.isEmpty, """
            Missing test coverage for functional cover points: \
            \(uncovered.map(\.rawValue).sorted().joined(separator: ", "))
            """)
    }
}
