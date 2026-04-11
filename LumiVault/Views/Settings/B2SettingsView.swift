import SwiftUI
import SwiftData

struct B2SettingsView: View {
    @AppStorage("b2Enabled") private var b2Enabled = false
    @AppStorage("b2BucketName") private var bucketName = ""
    @State private var keyId = ""
    @State private var applicationKey = ""
    @State private var bucketId = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var showingSyncSheet = false

    var body: some View {
        Form {
            Section("Backblaze B2") {
                Toggle("Enable B2 cloud uploads", isOn: $b2Enabled)
                    .accessibilityIdentifier("b2.enable")
            }

            if b2Enabled {
                Section {
                    DisclosureGroup("How to set up Backblaze B2") {
                        VStack(alignment: .leading, spacing: 10) {
                            SetupStep(number: 1, title: "Create a Backblaze account",
                                      detail: "Sign up at backblaze.com. The first 10 GB of storage is free.")
                            SetupStep(number: 2, title: "Create a B2 bucket",
                                      detail: "Go to B2 Cloud Storage > Buckets > Create a Bucket. Choose \"Private\" for file visibility. Note the Bucket Name and Bucket ID shown after creation.")
                            SetupStep(number: 3, title: "Create an Application Key",
                                      detail: "Go to Account > Application Keys > Add a New Application Key. Restrict it to your bucket for security. Copy the Application Key ID and the Application Key (shown only once).")
                            SetupStep(number: 4, title: "Enter credentials below",
                                      detail: "Paste the Application Key ID, Application Key, Bucket ID, and Bucket Name into the fields below, then click Test Connection to verify.")
                        }
                        .padding(.vertical, 4)
                    }
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.secondary)
                }

                Section("Credentials") {
                    TextField("Application Key ID", text: $keyId)
                        .font(Constants.Design.monoBody)
                        .accessibilityIdentifier("b2.keyId")
                    SecureField("Application Key", text: $applicationKey)
                        .font(Constants.Design.monoBody)
                        .accessibilityIdentifier("b2.appKey")
                }

                Section("Bucket") {
                    TextField("Bucket ID", text: $bucketId)
                        .font(Constants.Design.monoBody)
                        .accessibilityIdentifier("b2.bucketId")
                    TextField("Bucket Name", text: $bucketName)
                        .font(Constants.Design.monoBody)
                        .accessibilityIdentifier("b2.bucketName")
                }

                Section {
                    HStack {
                        Button("Test Connection") { testConnection() }
                            .disabled(keyId.isEmpty || applicationKey.isEmpty || isTesting)
                            .accessibilityIdentifier("b2.testConnection")

                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if let result = testResult {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? Color.green : Color.red)
                            Text(result.message)
                                .font(Constants.Design.monoCaption)
                                .foregroundStyle(result.success ? Color.secondary : Color.red)
                        }

                        Spacer()

                        Button("Save") { saveCredentials() }
                            .disabled(keyId.isEmpty || applicationKey.isEmpty || bucketId.isEmpty)
                            .accessibilityIdentifier("b2.save")
                    }
                }

                Section("Sync") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Upload existing images to B2")
                                .font(Constants.Design.monoBody)
                            Text("Finds images on external volumes that haven't been uploaded to B2 yet.")
                                .font(Constants.Design.monoCaption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sync Volumes to B2...") { showingSyncSheet = true }
                            .disabled(!hasCredentials)
                            .accessibilityIdentifier("b2.syncVolumes")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { loadCredentials() }
        .sheet(isPresented: $showingSyncSheet) {
            B2SyncSheet(credentials: currentCredentials())
        }
    }

    private var hasCredentials: Bool {
        !keyId.isEmpty && !applicationKey.isEmpty && !bucketId.isEmpty
    }

    private func currentCredentials() -> B2Credentials {
        B2Credentials(
            applicationKeyId: keyId.trimmingCharacters(in: .whitespacesAndNewlines),
            applicationKey: applicationKey.trimmingCharacters(in: .whitespacesAndNewlines),
            bucketId: bucketId.trimmingCharacters(in: .whitespacesAndNewlines),
            bucketName: bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            let service = B2Service()
            let credentials = B2Credentials(
                applicationKeyId: keyId.trimmingCharacters(in: .whitespacesAndNewlines),
                applicationKey: applicationKey.trimmingCharacters(in: .whitespacesAndNewlines),
                bucketId: bucketId.trimmingCharacters(in: .whitespacesAndNewlines),
                bucketName: bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            do {
                try await service.authorize(credentials: credentials)
                testResult = TestResult(success: true, message: "Connected successfully")
            } catch {
                testResult = TestResult(success: false, message: error.localizedDescription)
            }

            isTesting = false
        }
    }

    private func saveCredentials() {
        let credentials = B2Credentials(
            applicationKeyId: keyId.trimmingCharacters(in: .whitespacesAndNewlines),
            applicationKey: applicationKey.trimmingCharacters(in: .whitespacesAndNewlines),
            bucketId: bucketId.trimmingCharacters(in: .whitespacesAndNewlines),
            bucketName: bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let data = try? JSONEncoder().encode(credentials) {
            UserDefaults.standard.set(data, forKey: B2Credentials.defaultsKey)
        }
    }

    private func loadCredentials() {
        guard let data = UserDefaults.standard.data(forKey: B2Credentials.defaultsKey),
              let credentials = try? JSONDecoder().decode(B2Credentials.self, from: data) else { return }
        keyId = credentials.applicationKeyId
        applicationKey = credentials.applicationKey
        bucketId = credentials.bucketId
        bucketName = credentials.bucketName
    }

    private struct TestResult {
        let success: Bool
        let message: String
    }
}

// MARK: - B2 Sync Sheet

struct B2SyncSheet: View {
    let credentials: B2Credentials
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Query private var images: [ImageRecord]
    @Query private var volumes: [VolumeRecord]

    @State private var phase: SyncPhase = .ready
    @State private var totalImages = 0
    @State private var processedImages = 0
    @State private var uploadedCount = 0
    @State private var skippedCount = 0
    @State private var alreadyInB2Count = 0
    @State private var errors: [String] = []

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "cloud.fill")
                    .foregroundStyle(Constants.Design.accentColor)
                Text("Sync Volumes to B2")
                    .font(Constants.Design.monoHeadline)
            }
            .padding(.top)

            Divider()

            switch phase {
            case .ready:
                readyView
            case .syncing:
                syncingView
            case .complete:
                completeView
            }

            Divider()

            HStack {
                if phase == .complete {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Start Sync") { startSync() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(phase == .syncing || pendingImages.isEmpty)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 400, height: 320)
    }

    private var pendingImages: [ImageRecord] {
        images.filter { image in
            image.b2FileId == nil
                && image.album != nil
                && !image.storageLocations.isEmpty
        }
    }

    private var readyView: some View {
        VStack(spacing: 12) {
            Spacer()
            if pendingImages.isEmpty {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
                Text("All images are already in B2")
                    .font(Constants.Design.monoBody)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(pendingImages.count) images not yet in B2")
                    .font(Constants.Design.monoBody)
                    .foregroundStyle(.secondary)
                Text("Files will be read from external volumes\nand uploaded to your B2 bucket.")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
    }

    private var syncingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: fraction)
                .padding(.horizontal, 32)
            Text("Uploading \(processedImages)/\(totalImages)")
                .font(Constants.Design.monoBody)
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                B2SyncStat(label: "Uploaded", value: uploadedCount)
                B2SyncStat(label: "In B2", value: alreadyInB2Count)
                B2SyncStat(label: "Skipped", value: skippedCount)
            }
            Spacer()
        }
    }

    private var completeView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text("Sync Complete")
                .font(Constants.Design.monoHeadline)
            HStack(spacing: 20) {
                B2SyncStat(label: "Uploaded", value: uploadedCount)
                B2SyncStat(label: "In B2", value: alreadyInB2Count)
                B2SyncStat(label: "Skipped", value: skippedCount)
            }
            if !errors.isEmpty {
                Text("\(errors.count) errors")
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
    }

    private var fraction: Double {
        guard totalImages > 0 else { return 0 }
        return Double(processedImages) / Double(totalImages)
    }

    private func startSync() {
        let pending = pendingImages
        phase = .syncing
        totalImages = pending.count
        processedImages = 0
        uploadedCount = 0
        skippedCount = 0
        alreadyInB2Count = 0
        errors = []

        // Resolve volume bookmarks
        var resolvedVolumes: [String: URL] = [:]
        for volume in volumes {
            if let url = try? BookmarkResolver.resolveAndAccess(volume.bookmarkData) {
                resolvedVolumes[volume.volumeID] = url
            }
        }

        let b2Service = B2Service()

        Task { @MainActor in
            defer {
                for (_, url) in resolvedVolumes {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            for image in pending {
                guard let album = image.album else {
                    skippedCount += 1
                    processedImages += 1
                    continue
                }

                let remotePath = "\(album.year)/\(album.month)/\(album.day)/\(album.name)/\(image.filename)"

                // Find the file on a volume
                var sourceURL: URL?
                for loc in image.storageLocations {
                    if let volURL = resolvedVolumes[loc.volumeID] {
                        let candidate = volURL.appendingPathComponent(loc.relativePath)
                        if FileManager.default.fileExists(atPath: candidate.path) {
                            sourceURL = candidate
                            break
                        }
                    }
                }

                guard let source = sourceURL else {
                    skippedCount += 1
                    processedImages += 1
                    continue
                }

                var lastError: Error?
                for attempt in 1...3 {
                    do {
                        let alreadyExists = try await b2Service.fileExists(
                            fileName: remotePath,
                            bucketId: credentials.bucketId,
                            credentials: credentials
                        )

                        if alreadyExists {
                            let listings = try await b2Service.listAllFiles(
                                bucketId: credentials.bucketId,
                                credentials: credentials,
                                prefix: remotePath
                            )
                            if let listing = listings.first(where: { $0.fileName == remotePath }) {
                                image.b2FileId = listing.fileId
                            }
                            alreadyInB2Count += 1
                        } else {
                            let fileId = try await b2Service.uploadImage(
                                fileURL: source,
                                remotePath: remotePath,
                                sha256: image.sha256,
                                credentials: credentials
                            )
                            image.b2FileId = fileId
                            uploadedCount += 1
                        }
                        lastError = nil
                        break
                    } catch {
                        lastError = error
                        if attempt < 3 {
                            try? await Task.sleep(for: .seconds(attempt))
                        }
                    }
                }
                if let lastError {
                    errors.append("\(image.filename): \(lastError.localizedDescription)")
                    skippedCount += 1
                }

                processedImages += 1
            }

            try? modelContext.save()
            await syncCoordinator.pushAfterLocalChange()
            phase = .complete
        }
    }

    private enum SyncPhase {
        case ready, syncing, complete
    }
}

private struct B2SyncStat: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(Constants.Design.monoTitle3)
            Text(label)
                .font(Constants.Design.monoCaption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Setup Step

private struct SetupStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(Constants.Design.monoCaption)
                .fontWeight(.semibold)
                .foregroundStyle(Constants.Design.accentColor)
                .frame(width: 16, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Constants.Design.monoCaption)
                    .fontWeight(.medium)
                Text(detail)
                    .font(Constants.Design.monoCaption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
