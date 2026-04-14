import Testing

extension Tag {
    /// Catalog JSON serialization, merge, removal, backup/restore
    @Tag static var catalog: Self
    /// SHA-256 file hashing
    @Tag static var hashing: Self
    /// PAR2 error-correction generation, verification, and repair
    @Tag static var par2: Self
    /// AES-GCM encryption, decryption, and key derivation
    @Tag static var encryption: Self
    /// File integrity verification (SHA-256 and GCM tag checks)
    @Tag static var integrity: Self
    /// Exact-hash and perceptual-hash duplicate detection
    @Tag static var deduplication: Self
    /// Volume-to-volume file synchronization
    @Tag static var volumeSync: Self
    /// Volume scanning and B2 reconciliation diffs
    @Tag static var reconciliation: Self
    /// File and PAR2 companion deletion from volumes
    @Tag static var deletion: Self
    /// Backblaze B2 cloud API helpers
    @Tag static var b2Cloud: Self
    /// Image format conversion and scaling
    @Tag static var imageProcessing: Self
    /// SwiftData model correctness
    @Tag static var dataModels: Self
    /// Export progress fraction calculations
    @Tag static var exportProgress: Self
    /// Cross-service integration scenarios
    @Tag static var integration: Self
}
