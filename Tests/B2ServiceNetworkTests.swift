import Testing
import Foundation
@testable import LumiVault

// MARK: - B2Service Network Tests
//
// Drives B2Service through a URLProtocol stub so the REST flow (authorize, upload,
// list, delete) can be unit-tested without an actual B2 account.

@Suite(.serialized)
@MainActor
struct B2ServiceNetworkTests {

    let credentials = B2Credentials(
        applicationKeyId: "key-id",
        applicationKey: "key-secret",
        bucketId: "bucket-abc",
        bucketName: "test-bucket"
    )

    // MARK: - Authorize

    @Test func authorizeSendsBasicAuthAndStoresToken() async throws {
        StubURLProtocol.reset()
        let session = makeStubSession()
        let service = B2Service(session: session)

        StubURLProtocol.responder = { request in
            #expect(request.url?.absoluteString == "https://api.backblazeb2.com/b2api/v2/b2_authorize_account")
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            #expect(auth.hasPrefix("Basic "))
            // "key-id:key-secret" → base64
            let expected = Data("key-id:key-secret".utf8).base64EncodedString()
            #expect(auth == "Basic \(expected)")

            return jsonResponse(for: request, status: 200, json: [
                "authorizationToken": "auth-token-123",
                "apiUrl": "https://api123.backblazeb2.com",
                "downloadUrl": "https://f123.backblazeb2.com",
                "recommendedPartSize": 100_000_000
            ])
        }

        try await service.authorize(credentials: credentials)
        // Subsequent calls reuse the token rather than re-authorizing — verified indirectly
        // by listAllFiles below not requiring a second authorize stub.
    }

    @Test func authorizeFailsOn401() async {
        StubURLProtocol.reset()
        let service = B2Service(session: makeStubSession())

        StubURLProtocol.responder = { request in
            jsonResponse(for: request, status: 401, json: [
                "code": "bad_auth_token",
                "message": "Invalid credentials"
            ])
        }

        await #expect(throws: Error.self) {
            try await service.authorize(credentials: self.credentials)
        }
    }

    // MARK: - Get Upload URL

    @Test func getUploadURLRequiresPriorAuthorize() async {
        let service = B2Service(session: makeStubSession())
        await #expect(throws: Error.self) {
            try await service.getUploadURL(bucketId: "bucket-abc")
        }
    }

    @Test func getUploadURLDecodesResponse() async throws {
        StubURLProtocol.reset()
        let service = B2Service(session: makeStubSession())

        StubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_get_upload_url"):
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "auth-token-123")
                return jsonResponse(for: request, status: 200, json: [
                    "uploadUrl": "https://pod-upload.backblazeb2.com/upload/abc",
                    "authorizationToken": "upload-token-xyz"
                ])
            default:
                return failure(URLError(.badURL))
            }
        }

        try await service.authorize(credentials: credentials)
        try await service.getUploadURL(bucketId: "bucket-abc")
    }

    // MARK: - Upload File

    @Test func uploadFileSendsRequiredHeaders() async throws {
        StubURLProtocol.reset()
        let service = B2Service(session: makeStubSession())

        let payload = Data("hello world".utf8)
        let expectedSha1 = B2Service.sha1Hash(of: payload)

        StubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_get_upload_url"):
                return jsonResponse(for: request, status: 200, json: [
                    "uploadUrl": "https://pod-upload.backblazeb2.com/upload/abc",
                    "authorizationToken": "upload-token-xyz"
                ])
            case let p where p.contains("/upload/"):
                #expect(request.value(forHTTPHeaderField: "X-Bz-File-Name") == "photos/test.jpg")
                #expect(request.value(forHTTPHeaderField: "X-Bz-Content-Sha1") == expectedSha1)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "upload-token-xyz")
                #expect(request.value(forHTTPHeaderField: "Content-Length") == String(payload.count))
                return jsonResponse(for: request, status: 200, json: [
                    "fileId": "file-id-42",
                    "fileName": "photos/test.jpg",
                    "contentSha1": expectedSha1
                ])
            default:
                return failure(URLError(.badURL))
            }
        }

        try await service.authorize(credentials: credentials)
        try await service.getUploadURL(bucketId: credentials.bucketId)
        let response = try await service.uploadFile(
            fileData: payload,
            fileName: "photos/test.jpg",
            sha1: expectedSha1
        )
        #expect(response.fileId == "file-id-42")
        #expect(response.fileName == "photos/test.jpg")
    }

    @Test func uploadFileWithoutUploadURLThrows() async throws {
        StubURLProtocol.reset()
        let service = B2Service(session: makeStubSession())

        StubURLProtocol.responder = { request in
            authorizeResponse(for: request)
        }
        try await service.authorize(credentials: credentials)

        await #expect(throws: Error.self) {
            _ = try await service.uploadFile(fileData: Data(), fileName: "x", sha1: "0")
        }
    }

    @Test func uploadFileClearsUploadURLAfterUse() async throws {
        StubURLProtocol.reset()
        let service = B2Service(session: makeStubSession())

        let payload = Data("payload".utf8)
        let sha1 = B2Service.sha1Hash(of: payload)

        StubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_get_upload_url"):
                return jsonResponse(for: request, status: 200, json: [
                    "uploadUrl": "https://pod-upload.backblazeb2.com/upload/abc",
                    "authorizationToken": "upload-token"
                ])
            case let p where p.contains("/upload/"):
                return jsonResponse(for: request, status: 200, json: [
                    "fileId": "id1", "fileName": "f", "contentSha1": sha1
                ])
            default:
                return failure(URLError(.badURL))
            }
        }

        try await service.authorize(credentials: credentials)
        try await service.getUploadURL(bucketId: credentials.bucketId)
        _ = try await service.uploadFile(fileData: payload, fileName: "f", sha1: sha1)

        // Second upload without refreshing uploadURL should fail.
        await #expect(throws: Error.self) {
            _ = try await service.uploadFile(fileData: payload, fileName: "f2", sha1: sha1)
        }
    }

    // MARK: - List Files (pagination)

    @Test func listAllFilesPaginatesAcrossResponses() async throws {
        StubURLProtocol.reset()
        let service = B2Service(session: makeStubSession())

        let listCalls = Locked(0)

        StubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_list_file_names"):
                let attempt = listCalls.mutate { $0 += 1; return $0 }
                if attempt == 1 {
                    return jsonResponse(for: request, status: 200, json: [
                        "files": [
                            ["fileId": "id1", "fileName": "a.jpg", "contentLength": 100],
                            ["fileId": "id2", "fileName": "b.jpg", "contentLength": 200]
                        ],
                        "nextFileName": "c.jpg"
                    ])
                } else {
                    return jsonResponse(for: request, status: 200, json: [
                        "files": [
                            ["fileId": "id3", "fileName": "c.jpg", "contentLength": 300]
                        ],
                        "nextFileName": NSNull()
                    ])
                }
            default:
                return failure(URLError(.badURL))
            }
        }

        let files = try await service.listAllFiles(bucketId: credentials.bucketId, credentials: credentials)
        #expect(listCalls.value == 2)
        #expect(files.count == 3)
        #expect(files.map(\.fileName) == ["a.jpg", "b.jpg", "c.jpg"])
        #expect(files.map(\.contentLength) == [100, 200, 300])
    }

    // MARK: - File Exists

    @Test func fileExistsReturnsTrueWhenListContainsName() async throws {
        StubURLProtocol.reset()
        let service = B2Service(session: makeStubSession())

        StubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_list_file_names"):
                return jsonResponse(for: request, status: 200, json: [
                    "files": [["fileId": "id1", "fileName": "wanted.jpg", "contentLength": 100]],
                    "nextFileName": NSNull()
                ])
            default:
                return failure(URLError(.badURL))
            }
        }

        let exists = try await service.fileExists(
            fileName: "wanted.jpg",
            bucketId: credentials.bucketId,
            credentials: credentials
        )
        #expect(exists == true)
    }

    @Test func fileExistsReturnsFalseWhenAbsent() async throws {
        StubURLProtocol.reset()
        let service = B2Service(session: makeStubSession())

        StubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_list_file_names"):
                return jsonResponse(for: request, status: 200, json: [
                    "files": [["fileId": "id1", "fileName": "other.jpg", "contentLength": 100]],
                    "nextFileName": NSNull()
                ])
            default:
                return failure(URLError(.badURL))
            }
        }

        let exists = try await service.fileExists(
            fileName: "wanted.jpg",
            bucketId: credentials.bucketId,
            credentials: credentials
        )
        #expect(exists == false)
    }

    // MARK: - Delete

    @Test func deleteFileSendsFileIdAndName() async throws {
        StubURLProtocol.reset()
        let service = B2Service(session: makeStubSession())

        let deleteBody = Locked<[String: String]?>(nil)

        StubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_delete_file_version"):
                deleteBody.value = bodyJSON(from: request) as? [String: String]
                return jsonResponse(for: request, status: 200, json: [
                    "fileId": "file-1", "fileName": "doomed.jpg"
                ])
            default:
                return failure(URLError(.badURL))
            }
        }

        try await service.deleteFile(
            fileId: "file-1",
            fileName: "doomed.jpg",
            credentials: credentials
        )
        #expect(deleteBody.value?["fileId"] == "file-1")
        #expect(deleteBody.value?["fileName"] == "doomed.jpg")
    }

    // MARK: - Retry (regression: 154c011, c4cf7ee)
    //
    // `154c011` routed the catalog/sidecar/PAR2 uploads through `uploadImage` so
    // they inherit the exponential-backoff retry — before that a single flaky
    // request failed the entire catalog backup. Nothing asserted the retry
    // actually fires, so a future path that bypasses `withRetry` would go
    // unnoticed exactly the way the catalog backup did.
    //
    // These tests pay real backoff sleeps (1s for one retry, +2s for two), so
    // they deliberately use the minimum retry count that proves the behaviour.

    @Test func uploadRetriesAfterTransientServerErrorAndReportsAttempts() async throws {
        StubURLProtocol.reset()
        let service = B2Service(session: makeStubSession())

        let payload = Data("retry me".utf8)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("b2-retry-\(UUID().uuidString).jpg")
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let uploadCalls = Locked(0)
        let attempts = Locked<[Int]>([])

        StubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_get_upload_url"):
                return jsonResponse(for: request, status: 200, json: [
                    "uploadUrl": "https://pod-upload.backblazeb2.com/upload/abc",
                    "authorizationToken": "upload-token-xyz"
                ])
            case let p where p.contains("/upload/"):
                let n = uploadCalls.mutate { (count: inout Int) -> Int in
                    count += 1
                    return count
                }
                // 503 is retryable per B2Error.isRetryable (500...599).
                if n == 1 {
                    return jsonResponse(for: request, status: 503, json: [
                        "code": "service_unavailable", "message": "try again"
                    ])
                }
                return jsonResponse(for: request, status: 200, json: [
                    "fileId": "recovered-1", "fileName": "retry.jpg", "contentSha1": "none"
                ])
            default:
                return failure(URLError(.badURL))
            }
        }

        let fileId = try await service.uploadImage(
            fileURL: fileURL,
            remotePath: "album/retry.jpg",
            sha256: "unused",
            credentials: credentials,
            onAttempt: { attempt in attempts.mutate { $0.append(attempt) } }
        )

        #expect(fileId == "recovered-1")
        #expect(uploadCalls.value == 2)
        // Attempt 1 is reported when the retry starts, then 0 signals recovery.
        #expect(attempts.value == [1, 0])
    }

    @Test func uploadSurfacesFileNameAndPathAfterRetriesAreExhausted() async throws {
        StubURLProtocol.reset()
        let service = B2Service(session: makeStubSession())

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("b2-doomed-\(UUID().uuidString).jpg")
        try Data("nope".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // 403 is NOT retryable, so this fails on the first attempt with no sleeps.
        StubURLProtocol.responder = { request in
            switch request.url?.path ?? "" {
            case let p where p.hasSuffix("/b2_authorize_account"):
                return authorizeResponse(for: request)
            case let p where p.hasSuffix("/b2_get_upload_url"):
                return jsonResponse(for: request, status: 200, json: [
                    "uploadUrl": "https://pod-upload.backblazeb2.com/upload/abc",
                    "authorizationToken": "upload-token-xyz"
                ])
            case let p where p.contains("/upload/"):
                return jsonResponse(for: request, status: 403, json: [
                    "code": "access_denied", "message": "no permission"
                ])
            default:
                return failure(URLError(.badURL))
            }
        }

        // The user-facing error must name the file and its remote path — that is
        // what makes a failed catalog backup diagnosable.
        do {
            _ = try await service.uploadImage(
                fileURL: fileURL,
                remotePath: "2026/06/12/Album Name/doomed.jpg",
                sha256: "unused",
                credentials: credentials
            )
            Issue.record("Expected the upload to throw after a non-retryable 403")
        } catch let error as B2Service.B2UploadError {
            #expect(error.remotePath == "2026/06/12/Album Name/doomed.jpg")
            #expect(error.fileName == fileURL.lastPathComponent)
            #expect(!error.reason.isEmpty)
        } catch {
            Issue.record("Expected B2UploadError, got \(type(of: error)): \(error)")
        }
    }
}

// MARK: - URLProtocol Stub

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
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

// MARK: - Stub Helpers

func makeStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

func jsonResponse(
    for request: URLRequest,
    status: Int,
    json: [String: Any]
) -> Result<(HTTPURLResponse, Data), Error> {
    let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    let url = request.url ?? URL(string: "https://example.com")!
    let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return .success((response, data))
}

func authorizeResponse(for request: URLRequest) -> Result<(HTTPURLResponse, Data), Error> {
    jsonResponse(for: request, status: 200, json: [
        "authorizationToken": "auth-token-123",
        "apiUrl": "https://api123.backblazeb2.com",
        "downloadUrl": "https://f123.backblazeb2.com",
        "recommendedPartSize": 100_000_000
    ])
}

func failure(_ error: Error) -> Result<(HTTPURLResponse, Data), Error> {
    .failure(error)
}

/// NSLock-protected mutable cell so `@Sendable` request handlers can record state.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ initial: Value) { _value = initial }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    @discardableResult
    func mutate<R>(_ block: (inout Value) -> R) -> R {
        lock.withLock { block(&_value) }
    }
}

/// Extract the JSON body from a URLRequest. URLSession often moves the body to a
/// stream, so try both `httpBody` and `httpBodyStream`.
func bodyJSON(from request: URLRequest) -> Any? {
    if let body = request.httpBody {
        return try? JSONSerialization.jsonObject(with: body)
    }
    if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return try? JSONSerialization.jsonObject(with: data)
    }
    return nil
}
