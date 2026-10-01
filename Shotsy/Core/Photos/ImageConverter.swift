import CoreLocation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Makes a JPEG copy of a still image with ImageIO. Metadata (EXIF, GPS, TIFF, orientation) is carried over;
/// pixels keep their stored orientation, so the copy looks the same as the original. The original is never touched.
nonisolated enum ImageConverter {
    enum ConversionError: Error, Equatable {
        case unreadable
        case encodeFailed
    }

    static let defaultQuality = 0.9

    /// Re-encodes any ImageIO-readable still (HEIC, HEIF, PNG, TIFF…) as JPEG. Only the first frame is used.
    static func jpegData(from data: Data, quality: Double = defaultQuality) throws -> Data {
        // Drains ImageIO's autoreleased intermediates (decoded tiles, metadata) as soon as the encode finishes.
        try autoreleasepool { try encode(data, quality: quality) }
    }

    private static func encode(_ data: Data, quality: Double) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw ConversionError.unreadable }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        // Container-specific groups don't apply to JPEG; everything else (EXIF, GPS, TIFF, IPTC, orientation) stays.
        properties[kCGImagePropertyHEICSDictionary as String] = nil
        properties[kCGImagePropertyPNGDictionary as String] = nil
        properties[kCGImageDestinationLossyCompressionQuality as String] = min(max(quality, 0), 1)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString,
                                                                 1, nil) else { throw ConversionError.encodeFailed }
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { throw ConversionError.encodeFailed }
        return output as Data
    }

    /// Off the main actor, for large originals.
    @concurrent
    static func convert(_ data: Data, quality: Double = defaultQuality) async throws -> Data {
        try jpegData(from: data, quality: quality)
    }

    /// "IMG_1234.HEIC" → "IMG_1234.JPG". Falls back to a generic name.
    static func jpegFilename(for original: String?) -> String {
        let base = ((original ?? "") as NSString).deletingPathExtension
        return (base.isEmpty ? "Photo" : base) + ".JPG"
    }

    /// Adds the JPEG as a new Photos asset with the original's date, location, and favorite state.
    /// Returns the new asset's identifier when Photos provides one.
    static func saveCopy(_ jpeg: Data, filename: String, creationDate: Date?, location: CLLocation?,
                         isFavorite: Bool) async throws -> String? {
        nonisolated(unsafe) var placeholder: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            options.uniformTypeIdentifier = UTType.jpeg.identifier
            request.addResource(with: .photo, data: jpeg, options: options)
            request.creationDate = creationDate
            request.location = location
            request.isFavorite = isFavorite
            placeholder = request.placeholderForCreatedAsset?.localIdentifier
        }
        return placeholder
    }
}
