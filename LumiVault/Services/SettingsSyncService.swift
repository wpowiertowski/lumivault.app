import Foundation

/// Syncs settings.json through the same iCloud app container as catalog.json.
///
/// One sync pass: pull the remote document, apply it locally if it's newer than what
/// this device last applied, then push back only when local content actually differs —
/// so quiescent Macs never rewrite the file and there is no push ping-pong.
actor SettingsSyncService {
    private nonisolated let containerID = Constants.Paths.iCloudContainer
    private let syncURL: URL
    private let usesICloud: Bool
    // UserDefaults is documented thread-safe but not Sendable; unsafe-nonisolated lets
    // the MainActor apply/capture closures use the same instance the tests inject.
    private nonisolated(unsafe) let defaults: UserDefaults

    init() {
        self.defaults = .standard
        if let iCloudURL = FileManager.default.url(
            forUbiquityContainerIdentifier: containerID
        )?.appendingPathComponent("settings.json") {
            self.syncURL = iCloudURL
            self.usesICloud = true
        } else {
            #if DEBUG
            // Same fallback as SyncService: exercise the flow against the local library
            // when iCloud is unavailable (e.g. no provisioning profile).
            self.syncURL = Constants.Paths.libraryURL.appendingPathComponent("settings.json")
            self.usesICloud = false
            #else
            self.syncURL = URL(fileURLWithPath: "/dev/null")
            self.usesICloud = false
            #endif
        }
    }

    /// Test-only initializer pointing at an explicit file URL with an isolated
    /// UserDefaults suite, bypassing NSFileCoordinator. Takes a suite name rather than
    /// an instance so no non-Sendable UserDefaults crosses into the actor; the test's
    /// own instance for the same suite shares the backing store.
    init(syncURL: URL, defaultsSuiteName: String) {
        self.syncURL = syncURL
        self.usesICloud = false
        self.defaults = UserDefaults(suiteName: defaultsSuiteName) ?? .standard
    }

    var isAvailable: Bool {
        #if DEBUG
        return true
        #else
        return usesICloud
        #endif
    }

    /// Pull-apply-push. `localVolumes` is this Mac's registered volume identities
    /// (from SwiftData, resolved by the caller on MainActor).
    func sync(localVolumes: [VolumeIdentity]) async throws {
        guard isAvailable else { return }

        let remote = try readRemote()
        let deviceID = SyncedSettings.deviceID(defaults: defaults)

        if let remote {
            let lastApplied = defaults.object(
                forKey: SyncedSettings.lastAppliedDefaultsKey
            ) as? Date ?? .distantPast
            if remote.lastUpdated > lastApplied {
                remote.apply(defaults: defaults, deviceID: deviceID)
                defaults.set(remote.lastUpdated, forKey: SyncedSettings.lastAppliedDefaultsKey)
            }
        }

        let local = SyncedSettings.capture(
            defaults: defaults,
            localVolumes: localVolumes,
            deviceID: deviceID,
            remote: remote
        )

        guard !local.contentEquals(remote) else { return }

        var toPush = local
        toPush.lastUpdated = .now
        try write(toPush)
        defaults.set(toPush.lastUpdated, forKey: SyncedSettings.lastAppliedDefaultsKey)
    }

    // MARK: - File I/O

    private func readRemote() throws -> SyncedSettings? {
        if usesICloud {
            try? FileManager.default.startDownloadingUbiquitousItem(at: syncURL)
        }
        guard FileManager.default.fileExists(atPath: syncURL.path) else { return nil }

        var fileData: Data?
        if usesICloud {
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            coordinator.coordinate(readingItemAt: syncURL, options: [], error: &coordinatorError) { coordinatedURL in
                fileData = try? Data(contentsOf: coordinatedURL)
            }
            if let error = coordinatorError { throw error }
        } else {
            fileData = try? Data(contentsOf: syncURL)
        }

        guard let data = fileData else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncedSettings.self, from: data)
    }

    private func write(_ settings: SyncedSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)

        let dir = syncURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if usesICloud {
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            coordinator.coordinate(writingItemAt: syncURL, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
                try? data.write(to: coordinatedURL, options: .atomic)
            }
            if let error = coordinatorError { throw error }
        } else {
            try data.write(to: syncURL, options: .atomic)
        }
    }
}
