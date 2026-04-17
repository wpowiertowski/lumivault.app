import Foundation
import CryptoKit

actor B2Service {
    private var authorization: B2Authorization?
    private var uploadURL: B2UploadURL?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    // MARK: - Authorize

    func authorize(credentials: B2Credentials) async throws {
        let url = URL(string: "https://api.backblazeb2.com/b2api/v2/b2_authorize_account")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let credentialString = "\(credentials.applicationKeyId):\(credentials.applicationKey)"
        let base64 = Data(credentialString.utf8).base64EncodedString()
        request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data: data)

        authorization = try await MainActor.run {
            try JSONDecoder().decode(B2Authorization.self, from: data)
        }
    }

    // MARK: - Get Upload URL

    func getUploadURL(bucketId: String) async throws {
        guard let auth = authorization else { throw B2Error.notAuthorized }

        let url = URL(string: "\(auth.apiURL)/b2api/v2/b2_get_upload_url")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(auth.authorizationToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bodyDict = ["bucketId": bucketId]
        request.httpBody = try await MainActor.run {
            try JSONEncoder().encode(bodyDict)
        }

        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data: data)

        uploadURL = try await MainActor.run {
            try JSONDecoder().decode(B2UploadURL.self, from: data)
        }
    }

    // MARK: - Upload File

    func uploadFile(
        fileData: Data,
        fileName: String,
        sha1: String,
        contentType: String = "b2/x-auto"
    ) async throws -> B2FileResponse {
        guard let upload = uploadURL else { throw B2Error.noUploadURL }

        // Clear immediately — URL is single-use regardless of outcome.
        // On failure, reusing a stale URL would cause all subsequent uploads to fail.
        uploadURL = nil

        let url = URL(string: upload.uploadUrl)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(upload.authorizationToken, forHTTPHeaderField: "Authorization")
        request.setValue(fileName, forHTTPHeaderField: "X-Bz-File-Name")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(sha1, forHTTPHeaderField: "X-Bz-Content-Sha1")
        request.setValue(String(fileData.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = fileData

        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data: data)

        return try await MainActor.run {
            try JSONDecoder().decode(B2FileResponse.self, from: data)
        }
    }

    // MARK: - Check File Exists

    func fileExists(
        fileName: String,
        bucketId: String,
        credentials: B2Credentials
    ) async throws -> Bool {
        try await withRetry(credentials: credentials) {
            if self.authorization == nil {
                try await self.authorize(credentials: credentials)
            }

            guard let auth = self.authorization else { throw B2Error.notAuthorized }

            let url = URL(string: "\(auth.apiURL)/b2api/v2/b2_list_file_names")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(auth.authorizationToken, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "bucketId": bucketId,
                "prefix": fileName,
                "maxFileCount": 1
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await self.session.data(for: request)
            try Self.checkResponse(response, data: data)

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let files = json?["files"] as? [[String: Any]] ?? []
            return files.contains { ($0["fileName"] as? String) == fileName }
        }
    }

    // MARK: - List All Files

    func listAllFiles(
        bucketId: String,
        credentials: B2Credentials,
        prefix: String? = nil
    ) async throws -> [B2FileListing] {
        if authorization == nil {
            try await authorize(credentials: credentials)
        }

        guard let auth = authorization else { throw B2Error.notAuthorized }

        var allFiles: [B2FileListing] = []
        var nextFileName: String? = nil

        repeat {
            let url = URL(string: "\(auth.apiURL)/b2api/v2/b2_list_file_names")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(auth.authorizationToken, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            var body: [String: Any] = [
                "bucketId": bucketId,
                "maxFileCount": 10000
            ]
            if let prefix { body["prefix"] = prefix }
            if let next = nextFileName { body["startFileName"] = next }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)
            try Self.checkResponse(response, data: data)

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let files = json?["files"] as? [[String: Any]] ?? []

            for file in files {
                guard let fileId = file["fileId"] as? String,
                      let fileName = file["fileName"] as? String,
                      let contentLength = file["contentLength"] as? Int64 else { continue }
                allFiles.append(B2FileListing(fileId: fileId, fileName: fileName, contentLength: contentLength))
            }

            nextFileName = json?["nextFileName"] as? String
        } while nextFileName != nil

        return allFiles
    }

    // MARK: - Download File

    func downloadFile(
        fileId: String,
        credentials: B2Credentials
    ) async throws -> Data {
        if authorization == nil {
            try await authorize(credentials: credentials)
        }

        guard let auth = authorization else { throw B2Error.notAuthorized }

        let url = URL(string: "\(auth.downloadURL)/b2api/v2/b2_download_file_by_id?fileId=\(fileId)")!
        var request = URLRequest(url: url)
        request.setValue(auth.authorizationToken, forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data: data)
        return data
    }

    func downloadFile(
        fileName: String,
        bucketId: String,
        credentials: B2Credentials
    ) async throws -> Data {
        if authorization == nil {
            try await authorize(credentials: credentials)
        }

        guard let auth = authorization else { throw B2Error.notAuthorized }

        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: Self.b2AllowedCharacters) ?? fileName
        let url = URL(string: "\(auth.downloadURL)/file/\(credentials.bucketName)/\(encodedName)")!
        var request = URLRequest(url: url)
        request.setValue(auth.authorizationToken, forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response, data: data)
        return data
    }

    // MARK: - Delete File

    func deleteFile(
        fileId: String,
        fileName: String,
        credentials: B2Credentials
    ) async throws {
        if authorization == nil {
            try await authorize(credentials: credentials)
        }

        guard let auth = authorization else { throw B2Error.notAuthorized }

        let url = URL(string: "\(auth.apiURL)/b2api/v2/b2_delete_file_version")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(auth.authorizationToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["fileId": fileId, "fileName": fileName]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (deleteData, response) = try await session.data(for: request)
        try Self.checkResponse(response, data: deleteData)
    }

    // MARK: - High-Level Upload

    func uploadImage(
        fileURL: URL,
        remotePath: String,
        sha256: String,
        credentials: B2Credentials,
        onAttempt: (@Sendable (Int) -> Void)? = nil
    ) async throws -> String {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw B2UploadError(
                fileName: fileURL.lastPathComponent,
                remotePath: remotePath,
                reason: "Could not read file from disk: \(error.localizedDescription)"
            )
        }
        let sha1 = sha1Hash(of: fileData)
        let encodedPath = remotePath.addingPercentEncoding(withAllowedCharacters: Self.b2AllowedCharacters) ?? remotePath

        do {
            return try await withRetry(credentials: credentials, onAttempt: onAttempt) {
                if self.authorization == nil {
                    try await self.authorize(credentials: credentials)
                }
                try await self.getUploadURL(bucketId: credentials.bucketId)

                let result = try await self.uploadFile(
                    fileData: fileData,
                    fileName: encodedPath,
                    sha1: sha1
                )
                return result.fileId
            }
        } catch {
            throw B2UploadError(
                fileName: fileURL.lastPathComponent,
                remotePath: remotePath,
                reason: Self.userFacingDescription(for: error)
            )
        }
    }

    // MARK: - Retry

    private func withRetry<T>(
        maxAttempts: Int = 5,
        credentials: B2Credentials,
        onAttempt: (@Sendable (Int) -> Void)? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                // Exponential backoff: 1s, 2s, 4s, 8s
                let delay = UInt64(min(pow(2.0, Double(attempt - 1)), 8)) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                onAttempt?(attempt)
            }

            do {
                let result = try await operation()
                if attempt > 0 { onAttempt?(0) }  // signal recovery
                return result
            } catch let error as B2Error where error.isRetryable {
                lastError = error
                // Invalidate stale state so next attempt re-authorizes and gets a fresh upload URL
                authorization = nil
                uploadURL = nil
                try? await authorize(credentials: credentials)
            } catch let error as URLError where error.isTransient {
                lastError = error
                // Network-level failure — upload URL is likely stale, force refresh on next attempt
                authorization = nil
                uploadURL = nil
                try? await authorize(credentials: credentials)
            }
        }

        throw lastError!
    }

    // MARK: - Helpers

    /// B2-specific percent encoding for file names in headers and URLs.
    /// Only these characters are left unencoded: A-Z a-z 0-9 - . _ ~ / !
    nonisolated static let b2AllowedCharacters: CharacterSet = {
        var cs = CharacterSet()
        cs.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        cs.insert(charactersIn: "-._~/!")
        return cs
    }()

    nonisolated func sha1Hash(of data: Data) -> String {
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func checkResponse(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw B2Error.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            var message: String?
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = json["message"] as? String ?? json["code"] as? String
            }
            throw B2Error.httpError(statusCode: http.statusCode, message: message)
        }
    }

    // MARK: - User-Facing Descriptions

    nonisolated static func userFacingDescription(for error: Error) -> String {
        switch error {
        case let urlError as URLError:
            switch urlError.code {
            case .timedOut:
                "The upload timed out. The file may be too large for the current connection speed."
            case .networkConnectionLost:
                "The network connection was lost during upload."
            case .notConnectedToInternet:
                "No internet connection. Check your network and try again."
            case .cannotConnectToHost:
                "Could not connect to Backblaze B2. The service may be temporarily unavailable."
            case .dnsLookupFailed:
                "DNS lookup failed. Check your internet connection."
            default:
                "Network error: \(urlError.localizedDescription)"
            }
        case let b2Error as B2Error:
            b2Error.errorDescription ?? b2Error.localizedDescription
        default:
            error.localizedDescription
        }
    }

    // MARK: - Errors

    enum B2Error: Error, LocalizedError, Sendable {
        case notAuthorized
        case noUploadURL
        case invalidResponse
        case httpError(statusCode: Int, message: String?)

        var isRetryable: Bool {
            switch self {
            case .httpError(let statusCode, _):
                // 401: expired token, 408: timeout, 429: rate limit, 5xx: server errors
                statusCode == 401 || statusCode == 408 || statusCode == 429
                    || (500...599).contains(statusCode)
            case .invalidResponse:
                true
            default:
                false
            }
        }

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                "B2 authorization failed. Check your Application Key ID and Application Key in Settings."
            case .noUploadURL:
                "Failed to obtain B2 upload URL. Try again or check your bucket configuration."
            case .invalidResponse:
                "Received an invalid response from B2. Check your network connection."
            case .httpError(let statusCode, let message):
                switch statusCode {
                case 401:
                    "B2 authentication failed (401). Verify your Application Key ID and Application Key are correct."
                case 403:
                    "B2 access denied (403). Your application key may not have permission for this bucket."
                case 404:
                    "B2 bucket not found (404). Verify the Bucket ID in Settings."
                case 408:
                    "B2 request timed out (408). Try again in a moment."
                case 429:
                    "B2 rate limited (429). Too many requests — try again shortly."
                case 500...599:
                    "B2 server error (\(statusCode)). Backblaze may be experiencing issues. Try again later."
                default:
                    "B2 error \(statusCode)\(message.map { ": \($0)" } ?? ""). Check your B2 settings and try again."
                }
            }
        }
    }

    /// Error surfaced to the user when an upload fails after all retries.
    /// Includes the file name and a plain-language reason.
    struct B2UploadError: Error, LocalizedError, Sendable {
        let fileName: String
        let remotePath: String
        let reason: String

        var errorDescription: String? {
            "Upload failed for \"\(fileName)\": \(reason)"
        }
    }
}

extension URLError {
    var isTransient: Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .dnsLookupFailed:
            true
        default:
            false
        }
    }
}
