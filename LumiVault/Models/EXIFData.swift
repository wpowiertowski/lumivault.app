import Foundation
import ImageIO
import CoreLocation

/// Parsed EXIF metadata extracted from an image file via ImageIO.
struct EXIFData: Sendable {
    // Camera
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var software: String?

    // Capture settings
    var exposureTime: Double?
    var fNumber: Double?
    var iso: Int?
    var focalLength: Double?
    var focalLength35mm: Int?

    // Image dimensions (from pixel data, not file size)
    var pixelWidth: Int?
    var pixelHeight: Int?
    var colorSpace: String?
    var bitDepth: Int?

    // Date
    var dateTaken: Date?

    // GPS
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?

    var hasGPS: Bool { latitude != nil && longitude != nil }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Formatted Strings

    var exposureString: String? {
        guard let t = exposureTime else { return nil }
        if t >= 1 { return "\(String(format: "%.1f", t))s" }
        let denominator = Int(round(1.0 / t))
        return "1/\(denominator)s"
    }

    var fNumberString: String? {
        guard let f = fNumber else { return nil }
        return String(format: "f/%.1f", f)
    }

    var isoString: String? {
        guard let iso else { return nil }
        return "ISO \(iso)"
    }

    var focalLengthString: String? {
        guard let fl = focalLength else { return nil }
        let base = String(format: "%.0f", fl) + "mm"
        if let eq = focalLength35mm { return "\(base) (\(eq)mm eq.)" }
        return base
    }

    var dimensionsString: String? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        let mp = Double(w * h) / 1_000_000.0
        return "\(w) × \(h) (\(String(format: "%.1f", mp)) MP)"
    }

    var altitudeString: String? {
        guard let alt = altitude else { return nil }
        return String(format: "%.0f m", alt)
    }

    var coordinateString: String? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return String(format: "%.5f, %.5f", lat, lon)
    }

    // MARK: - Extraction

    /// Extract EXIF data from a file URL.
    nonisolated static func extract(from url: URL) -> EXIFData? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return extract(from: source)
    }

    /// Extract EXIF data from in-memory image data (e.g., decrypted).
    nonisolated static func extract(from data: Data) -> EXIFData? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return extract(from: source)
    }

    private nonisolated static func extract(from source: CGImageSource) -> EXIFData? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        var exif = EXIFData()

        // Top-level properties
        exif.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        exif.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        exif.bitDepth = properties[kCGImagePropertyDepth] as? Int
        exif.colorSpace = properties[kCGImagePropertyColorModel] as? String

        // TIFF dictionary
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            exif.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
            exif.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
            exif.software = tiff[kCGImagePropertyTIFFSoftware] as? String

            if let dateString = tiff[kCGImagePropertyTIFFDateTime] as? String {
                exif.dateTaken = parseEXIFDate(dateString)
            }
        }

        // EXIF dictionary
        if let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.exposureTime = exifDict[kCGImagePropertyExifExposureTime] as? Double
            exif.fNumber = exifDict[kCGImagePropertyExifFNumber] as? Double
            exif.focalLength = exifDict[kCGImagePropertyExifFocalLength] as? Double
            exif.focalLength35mm = exifDict[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
            exif.lensModel = exifDict[kCGImagePropertyExifLensModel] as? String

            if let isoArray = exifDict[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isoArray.first {
                exif.iso = first
            }

            // Fallback date from EXIF if TIFF didn't have it
            if exif.dateTaken == nil, let dateString = exifDict[kCGImagePropertyExifDateTimeOriginal] as? String {
                exif.dateTaken = parseEXIFDate(dateString)
            }
        }

        // GPS dictionary
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
               let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String {
                exif.latitude = latRef == "S" ? -lat : lat
            }
            if let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
               let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
                exif.longitude = lonRef == "W" ? -lon : lon
            }
            exif.altitude = gps[kCGImagePropertyGPSAltitude] as? Double
        }

        return exif
    }

    private nonisolated static func parseEXIFDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)
    }
}
