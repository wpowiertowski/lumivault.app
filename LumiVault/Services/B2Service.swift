import Foundation
import CryptoKit

actor B2Service {
    private var authorization: B2Authorization?
    private var uploadURL: B2UploadURL?
    private let session = URLSession.shared

    // MARK: - Authorize

    func authorize(credentials: B2Credentials) async throws {
        let url = URL(string: "https://api.backblazeb2.com/b2api/v2/b2_authorize_account")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let credentialString = "\(credentials.applicationKeyId):\(credentials.applicationKey)"
        let base64 = Data(credentialString.utf8).base64EncodedString()
        request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try Self.checkResponse(response)

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
        try Self.checkResponse(response)

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
        try Self.checkResponse(response)

        // Upload URL is single-use per upload, refresh for next file
        uploadURL = nil

        return try await MainActor.run {
            try JSONDecoder().decode(B2FileResponse.self, from: data)
        }
    }

    // MARK: - High-Level Upload

    func uploadImage(
        fileURL: URL,
        remotePath: String,
        sha256: String,
        credentials: B2Credentials
    ) async throws -> String {
        if authorization == nil {
            try await authorize(credentials: credentials)
        }

        if uploadURL == nil {
            try await getUploadURL(bucketId: credentials.bucketId)
        }

        let fileData = try Data(contentsOf: fileURL)
        let sha1 = sha1Hash(of: fileData)
        let encodedPath = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath

        let result = try await uploadFile(
            fileData: fileData,
            fileName: encodedPath,
            sha1: sha1
        )

        return result.fileId
    }

    // MARK: - Helpers

    nonisolated private func sha1Hash(of data: Data) -> String {
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw B2Error.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw B2Error.httpError(statusCode: http.statusCode)
        }
    }

    // MARK: - Errors

    enum B2Error: Error {
        case notAuthorized
        case noUploadURL
        case invalidResponse
        case httpError(statusCode: Int)
    }
}
