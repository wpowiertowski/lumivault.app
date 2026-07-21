import Testing
import Foundation
import SwiftData
import AVFoundation
import CoreVideo
@testable import LumiVault

// MARK: - Catalog Schema (video fields)

@MainActor
struct CatalogVideoSchemaTests {

    private func makeCatalog(images: [CatalogImage]) -> Catalog {
        Catalog(
            version: 1,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            years: ["2026": CatalogYear(months: ["07": CatalogMonth(days: ["20": CatalogDay(albums: [
                "Trip": CatalogAlbum(addedAt: Date(timeIntervalSince1970: 1_700_000_000), images: images)
            ])])])],
            deletions: nil
        )
    }

    @Test func videoFieldsRoundTripThroughJSON() throws {
        let video = CatalogImage(
            filename: "clip.mov",
            sha256: "aabbcc",
            sizeBytes: 5_000_000,
            par2Filename: "clip.mov.par2",
            mediaType: "video",
            durationSeconds: 12.5
        )
        let catalog = makeCatalog(images: [video])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(catalog)

        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"media_type\":\"video\""))
        #expect(json.contains("\"duration_seconds\":12.5"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Catalog.self, from: data)
        let decodedImage = decoded.years["2026"]?.months["07"]?.days["20"]?.albums["Trip"]?.images.first
        #expect(decodedImage?.mediaType == "video")
        #expect(decodedImage?.durationSeconds == 12.5)
        #expect(decoded.contentEquals(catalog))
    }

    @Test func imageEntriesOmitVideoKeys() throws {
        let image = CatalogImage(filename: "a.heic", sha256: "dd", sizeBytes: 1, par2Filename: "")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(makeCatalog(images: [image]))
        let json = String(decoding: data, as: UTF8.self)

        // nil optionals are omitted, keeping pre-video catalogs byte-compatible.
        #expect(!json.contains("media_type"))
        #expect(!json.contains("duration_seconds"))
    }

    @Test func legacyCatalogWithoutVideoFieldsDecodes() throws {
        let legacyJSON = """
        {
          "version": 1,
          "last_updated": "2025-01-01T00:00:00Z",
          "years": {
            "2025": { "months": { "01": { "days": { "01": { "albums": {
              "Old": {
                "added_at": "2025-01-01T00:00:00Z",
                "images": [
                  { "filename": "old.heic", "sha256": "ff00", "size_bytes": 42, "par2_filename": "" }
                ]
              }
            } } } } } }
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(Catalog.self, from: Data(legacyJSON.utf8))
        let image = catalog.years["2025"]?.months["01"]?.days["01"]?.albums["Old"]?.images.first
        #expect(image?.mediaType == nil)
        #expect(image?.durationSeconds == nil)
    }

    @Test func reconciledMergesVideoFieldsCommutatively() {
        var a = CatalogImage(filename: "clip.mov", sha256: "s", sizeBytes: 10, par2Filename: "")
        a.mediaType = "video"
        a.durationSeconds = nil
        var b = CatalogImage(filename: "clip.mov", sha256: "s", sizeBytes: 10, par2Filename: "")
        b.mediaType = nil
        b.durationSeconds = 9.75

        let ab = a.reconciled(with: b)
        let ba = b.reconciled(with: a)
        #expect(ab == ba)
        #expect(ab.mediaType == "video")
        #expect(ab.durationSeconds == 9.75)
    }
}

// MARK: - SwiftData Model (lightweight migration semantics)

@MainActor
struct VideoRecordSchemaTests {

    @Test func defaultRecordIsImage() throws {
        let record = ImageRecord(sha256: "cafe", filename: "x.jpg", sizeBytes: 1)
        #expect(record.mediaType == .image)
        #expect(record.durationSeconds == nil)
        #expect(record.pixelWidth == nil)
        #expect(record.pixelHeight == nil)
    }

    @Test func videoFieldsPersist() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ImageRecord.self, AlbumRecord.self, VolumeRecord.self,
            configurations: config
        )
        let context = container.mainContext

        let record = ImageRecord(
            sha256: "beef",
            filename: "clip.mov",
            sizeBytes: 100,
            mediaType: .video,
            durationSeconds: 31.2,
            pixelWidth: 1920,
            pixelHeight: 1080
        )
        context.insert(record)
        try context.save()

        let sha = "beef"
        let fetched = try context.fetch(
            FetchDescriptor<ImageRecord>(predicate: #Predicate { $0.sha256 == sha })
        ).first
        #expect(fetched?.mediaType == .video)
        #expect(fetched?.durationSeconds == 31.2)
        #expect(fetched?.pixelWidth == 1920)
        #expect(fetched?.pixelHeight == 1080)
    }

    @Test func unknownMediaTypeRawReadsAsImage() {
        let record = ImageRecord(sha256: "aa", filename: "x.jpg", sizeBytes: 1)
        record.mediaTypeRaw = "hologram"
        #expect(record.mediaType == .image)
    }
}

// MARK: - Import Settings & Filters

@MainActor
struct VideoImportSettingsTests {

    @Test func includeVideosDefaultsToTrue() {
        let settings = ImportSettings(albumName: "A", year: "2026", month: "07", day: "20")
        #expect(settings.includeVideos == true)
    }

    @Test func includeVideosDefaultReadsUserDefaults() {
        let key = ImportSettings.includeVideosDefaultsKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(ImportSettings.includeVideosDefault == true)
        UserDefaults.standard.set(false, forKey: key)
        #expect(ImportSettings.includeVideosDefault == false)
        UserDefaults.standard.set(true, forKey: key)
        #expect(ImportSettings.includeVideosDefault == true)
    }

    @Test func dropFilterAcceptsMoviesAndImagesOnly() {
        #expect(ImportSheet.isImportableFile(URL(fileURLWithPath: "/tmp/a.mov")))
        #expect(ImportSheet.isImportableFile(URL(fileURLWithPath: "/tmp/a.mp4")))
        #expect(ImportSheet.isImportableFile(URL(fileURLWithPath: "/tmp/a.m4v")))
        #expect(ImportSheet.isImportableFile(URL(fileURLWithPath: "/tmp/a.HEIC")))
        #expect(ImportSheet.isImportableFile(URL(fileURLWithPath: "/tmp/a.jpg")))
        #expect(!ImportSheet.isImportableFile(URL(fileURLWithPath: "/tmp/a.pdf")))
        #expect(!ImportSheet.isImportableFile(URL(fileURLWithPath: "/tmp/a.txt")))
        #expect(!ImportSheet.isImportableFile(URL(fileURLWithPath: "/tmp/a.mp3")))
    }

    @Test func durationLabelFormats() {
        #expect(PhotoGridItem.durationLabel(0) == "0:00")
        #expect(PhotoGridItem.durationLabel(9.4) == "0:09")
        #expect(PhotoGridItem.durationLabel(75) == "1:15")
        #expect(PhotoGridItem.durationLabel(3_671) == "1:01:11")
    }
}

// MARK: - B2 Large-File API

/// Separate URLProtocol stub class for this suite. `B2ServiceNetworkTests` owns
/// `StubURLProtocol` and runs concurrently with other suites — sharing its
/// global responder caused cross-suite request bleed. A distinct class keeps
/// each suite's stub state fully isolated.
final class LargeFileStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> Result<(HTTPURLResponse, Data), Error>)?

    static func reset() {
        responder = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch responder(request) {
        case .success(let (response, data)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func makeLargeFileStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LargeFileStubURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized)
@MainActor
struct B2LargeFileTests {

    let credentials = B2Credentials(
        applicationKeyId: "key-id",
        applicationKey: "key-secret",
        bucketId: "bucket-abc",
        bucketName: "test-bucket"
    )

    @Test func startUploadFinishLargeFileFlow() async throws {
        LargeFileStubURLProtocol.reset()
        let service = B2Service(session: makeLargeFileStubSession())

        let partBodies = Locked<[Int: String]>([:])
        let finishBody = Locked<[String: Any]?>(nil)

        LargeFileStubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_start_large_file"):
                let body = bodyJSON(from: request) as? [String: Any]
                #expect(body?["bucketId"] as? String == "bucket-abc")
                #expect(body?["fileName"] as? String == "big/clip.mov")
                return jsonResponse(for: request, status: 200, json: ["fileId": "large-1"])
            case let p where p.hasSuffix("/b2_get_upload_part_url"):
                let body = bodyJSON(from: request) as? [String: Any]
                #expect(body?["fileId"] as? String == "large-1")
                return jsonResponse(for: request, status: 200, json: [
                    "uploadUrl": "https://pod.backblazeb2.com/part/abc",
                    "authorizationToken": "part-token"
                ])
            case let p where p.contains("/part/"):
                let number = Int(request.value(forHTTPHeaderField: "X-Bz-Part-Number") ?? "") ?? -1
                let sha1 = request.value(forHTTPHeaderField: "X-Bz-Content-Sha1") ?? ""
                partBodies.mutate { $0[number] = sha1 }
                #expect(request.value(forHTTPHeaderField: "Authorization") == "part-token")
                return jsonResponse(for: request, status: 200, json: [
                    "partNumber": number, "contentSha1": sha1
                ])
            case let p where p.hasSuffix("/b2_finish_large_file"):
                finishBody.value = bodyJSON(from: request) as? [String: Any]
                return jsonResponse(for: request, status: 200, json: [
                    "fileId": "large-1", "fileName": "big/clip.mov", "contentSha1": "none"
                ])
            default:
                return failure(URLError(.badURL))
            }
        }

        try await service.authorize(credentials: credentials)
        let fileId = try await service.startLargeFile(fileName: "big/clip.mov", bucketId: credentials.bucketId)
        #expect(fileId == "large-1")

        let partOne = Data(repeating: 0xAB, count: 1024)
        let partTwo = Data(repeating: 0xCD, count: 512)
        let sha1One = B2Service.sha1Hash(of: partOne)
        let sha1Two = B2Service.sha1Hash(of: partTwo)

        let partURL1 = try await service.getUploadPartURL(fileId: fileId)
        try await service.uploadPart(partNumber: 1, data: partOne, sha1: sha1One, to: partURL1)
        let partURL2 = try await service.getUploadPartURL(fileId: fileId)
        try await service.uploadPart(partNumber: 2, data: partTwo, sha1: sha1Two, to: partURL2)

        let finishedId = try await service.finishLargeFile(fileId: fileId, partSha1Array: [sha1One, sha1Two])
        #expect(finishedId == "large-1")
        #expect(partBodies.value == [1: sha1One, 2: sha1Two])
        #expect(finishBody.value?["partSha1Array"] as? [String] == [sha1One, sha1Two])
    }

    @Test func cancelLargeFilePostsFileId() async throws {
        LargeFileStubURLProtocol.reset()
        let service = B2Service(session: makeLargeFileStubSession())

        let cancelBody = Locked<[String: Any]?>(nil)
        LargeFileStubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_cancel_large_file"):
                cancelBody.value = bodyJSON(from: request) as? [String: Any]
                return jsonResponse(for: request, status: 200, json: ["fileId": "large-9"])
            default:
                return failure(URLError(.badURL))
            }
        }

        try await service.authorize(credentials: credentials)
        await service.cancelLargeFile(fileId: "large-9")
        #expect(cancelBody.value?["fileId"] as? String == "large-9")
    }

    @Test func smallUploadStreamsFromDiskWithCorrectSha1() async throws {
        LargeFileStubURLProtocol.reset()
        let service = B2Service(session: makeLargeFileStubSession())

        let payload = Data("streamed from disk".utf8)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("b2-stream-test-\(UUID().uuidString).jpg")
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let expectedSha1 = B2Service.sha1Hash(of: payload)
        #expect(try B2Service.sha1Hash(ofFileAt: fileURL) == expectedSha1)

        let sawUpload = Locked(false)
        LargeFileStubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_get_upload_url"):
                return jsonResponse(for: request, status: 200, json: [
                    "uploadUrl": "https://pod.backblazeb2.com/upload/abc",
                    "authorizationToken": "upload-token"
                ])
            case let p where p.contains("/upload/"):
                sawUpload.value = true
                #expect(request.value(forHTTPHeaderField: "X-Bz-Content-Sha1") == expectedSha1)
                #expect(request.value(forHTTPHeaderField: "Content-Length") == String(payload.count))
                return jsonResponse(for: request, status: 200, json: [
                    "fileId": "small-1", "fileName": "photos/streamed.jpg", "contentSha1": expectedSha1
                ])
            default:
                return failure(URLError(.badURL))
            }
        }

        let fileId = try await service.uploadImage(
            fileURL: fileURL,
            remotePath: "photos/streamed.jpg",
            sha256: "unused",
            credentials: credentials
        )
        #expect(fileId == "small-1")
        #expect(sawUpload.value == true)
    }

    @Test func uploadImageRoutesLargeFilesThroughPartAPI() async throws {
        LargeFileStubURLProtocol.reset()
        let service = B2Service(session: makeLargeFileStubSession())

        // Sparse file just over the 200 MB threshold — APFS materializes no data.
        let fileSize = Constants.Media.b2LargeFileThreshold + 1024
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("b2-large-test-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: UInt64(fileSize))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let partNumbers = Locked<[Int]>([])
        let finished = Locked(false)

        LargeFileStubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_start_large_file"):
                return jsonResponse(for: request, status: 200, json: ["fileId": "large-route"])
            case let p where p.hasSuffix("/b2_get_upload_part_url"):
                return jsonResponse(for: request, status: 200, json: [
                    "uploadUrl": "https://pod.backblazeb2.com/part/route",
                    "authorizationToken": "part-token"
                ])
            case let p where p.contains("/part/"):
                let number = Int(request.value(forHTTPHeaderField: "X-Bz-Part-Number") ?? "") ?? -1
                partNumbers.mutate { $0.append(number) }
                return jsonResponse(for: request, status: 200, json: ["partNumber": number])
            case let p where p.hasSuffix("/b2_finish_large_file"):
                finished.value = true
                let body = bodyJSON(from: request) as? [String: Any]
                #expect((body?["partSha1Array"] as? [String])?.count == 3)
                return jsonResponse(for: request, status: 200, json: [
                    "fileId": "large-route", "fileName": "big.mov", "contentSha1": "none"
                ])
            default:
                return failure(URLError(.badURL))
            }
        }

        let fileId = try await service.uploadImage(
            fileURL: fileURL,
            remotePath: "big.mov",
            sha256: "unused",
            credentials: credentials
        )
        // 200 MB + 1 KB at 100 MB parts → parts 1, 2, 3.
        #expect(fileId == "large-route")
        #expect(partNumbers.value == [1, 2, 3])
        #expect(finished.value == true)
    }
}

// MARK: - Video Thumbnails (poster frame + probe)

@MainActor
struct VideoThumbnailTests {

    /// Renders a small H.264 QuickTime file with AVAssetWriter. Software
    /// encoding via VideoToolbox works headless, unlike CIContext rendering.
    private static func makeTestVideo(at url: URL, width: Int = 640, height: Int = 480, frameCount: Int = 12) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            var pixelBuffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            }
            guard let buffer = pixelBuffer else {
                throw CocoaError(.fileWriteUnknown)
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let byteCount = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
                memset(base, Int32(40 + frame * 10), byteCount)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    @Test func posterFrameAndProbeFromGeneratedVideo() async throws {
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumivault-test-\(UUID().uuidString).mov")
        try await Self.makeTestVideo(at: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let sha256 = "video-thumb-test-\(UUID().uuidString)"
        let service = ThumbnailService()
        defer { Task { await service.removeThumbnails(for: sha256) } }

        let probe = try await service.generateVideoThumbnail(for: videoURL, sha256: sha256)

        // 12 frames at 30 fps ≈ 0.4 s.
        #expect(probe.durationSeconds > 0.1)
        #expect(probe.durationSeconds < 2.0)
        #expect(probe.pixelWidth == 640)
        #expect(probe.pixelHeight == 480)

        let grid = await service.thumbnail(for: sha256, size: .grid)
        let list = await service.thumbnail(for: sha256, size: .list)
        #expect(grid != nil)
        #expect(list != nil)

        await service.removeThumbnails(for: sha256)
    }

    @Test func nonVideoInputThrows() async throws {
        let bogusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-video-\(UUID().uuidString).mov")
        try Data("plain text".utf8).write(to: bogusURL)
        defer { try? FileManager.default.removeItem(at: bogusURL) }

        let service = ThumbnailService()
        await #expect(throws: Error.self) {
            _ = try await service.generateVideoThumbnail(for: bogusURL, sha256: "bogus")
        }
    }
}
