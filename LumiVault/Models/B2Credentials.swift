import Foundation

struct B2Credentials: Codable, Sendable {
    var applicationKeyId: String
    var applicationKey: String
    var bucketId: String
    var bucketName: String

    static let keychainKey = "b2.credentials"
}

struct B2Authorization: Codable, Sendable {
    var authorizationToken: String
    var apiURL: String
    var downloadURL: String
    var recommendedPartSize: Int

    enum CodingKeys: String, CodingKey {
        case authorizationToken
        case apiURL = "apiUrl"
        case downloadURL = "downloadUrl"
        case recommendedPartSize
    }
}

struct B2UploadURL: Codable, Sendable {
    var uploadUrl: String
    var authorizationToken: String
}

struct B2FileResponse: Codable, Sendable {
    var fileId: String
    var fileName: String
    var contentSha1: String
}
