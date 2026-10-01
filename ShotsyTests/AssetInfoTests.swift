import CoreGraphics
import Foundation
import ImageIO
import Photos
import Testing
import UniformTypeIdentifiers
@testable import Shotsy

// MARK: - Info formatting

@Suite("Asset info formatting")
struct AssetInfoFormatTests {
    let en = Locale(identifier: "en_US")

    @Test func shutterSpeedUsesFractionsBelowOneSecond() {
        #expect(AssetInfoFormat.shutterSpeed(1.0 / 125, locale: en) == "1/125 s")
        #expect(AssetInfoFormat.shutterSpeed(0.008, locale: en) == "1/125 s")
        #expect(AssetInfoFormat.shutterSpeed(1.0 / 3, locale: en) == "1/3 s")
        #expect(AssetInfoFormat.shutterSpeed(2, locale: en) == "2 s")
        #expect(AssetInfoFormat.shutterSpeed(1.5, locale: en) == "1.5 s")
        #expect(AssetInfoFormat.shutterSpeed(0, locale: en) == nil)
        #expect(AssetInfoFormat.shutterSpeed(.nan, locale: en) == nil)
    }

    @Test func megapixelsFromDimensions() {
        #expect(AssetInfoFormat.megapixels(width: 4032, height: 3024, locale: en) == "12 MP")
        #expect(AssetInfoFormat.megapixels(width: 8064, height: 6048, locale: en) == "49 MP")
        #expect(AssetInfoFormat.megapixels(width: 1920, height: 1080, locale: en) == "2.1 MP")
        #expect(AssetInfoFormat.megapixels(width: 1000, height: 1000, locale: en) == "1 MP")
        #expect(AssetInfoFormat.megapixels(width: 0, height: 1080, locale: en) == nil)
        #expect(AssetInfoFormat.megapixels(width: 1920, height: 1080, locale: Locale(identifier: "de_DE")) == "2,1 MP")
    }

    @Test func formatNamesFromUniformTypes() {
        #expect(AssetInfoFormat.formatName(uti: UTType.heic.identifier) == "HEIC")
        #expect(AssetInfoFormat.formatName(uti: UTType.jpeg.identifier) == "JPEG")
        #expect(AssetInfoFormat.formatName(uti: UTType.png.identifier) == "PNG")
        #expect(AssetInfoFormat.formatName(uti: UTType.quickTimeMovie.identifier) == "MOV")
        #expect(AssetInfoFormat.formatName(uti: "") == nil)
        #expect(AssetInfoFormat.isHEIF(uti: UTType.heic.identifier))
        #expect(AssetInfoFormat.isHEIF(uti: UTType.heif.identifier))
        #expect(!AssetInfoFormat.isHEIF(uti: UTType.jpeg.identifier))
        #expect(!AssetInfoFormat.isHEIF(uti: UTType.png.identifier))
    }

    @Test func cameraValues() {
        #expect(AssetInfoFormat.aperture(1.78, locale: en) == "ƒ/1.8")
        #expect(AssetInfoFormat.aperture(2, locale: en) == "ƒ/2")
        #expect(AssetInfoFormat.focalLength(6.765, locale: en) == "6.8 mm")
        #expect(AssetInfoFormat.focalLength(24, locale: en) == "24 mm")
        #expect(AssetInfoFormat.iso(100) == "ISO 100")
        #expect(AssetInfoFormat.iso(0) == nil)
        #expect(AssetInfoFormat.frameRate(29.97) == "30 fps")
        #expect(AssetInfoFormat.resolution(width: 4032, height: 3024) == "4032 × 3024")
    }

    @Test func cameraNameAvoidsRepeatingTheMake() {
        #expect(AssetInfoFormat.cameraName(make: "Apple", model: "iPhone 16 Pro") == "Apple iPhone 16 Pro")
        #expect(AssetInfoFormat.cameraName(make: "Canon", model: "Canon EOS R5") == "Canon EOS R5")
        #expect(AssetInfoFormat.cameraName(make: " ", model: "X100V") == "X100V")
        #expect(AssetInfoFormat.cameraName(make: nil, model: nil) == nil)
    }

    @Test func coordinatesIgnoreLocaleSeparators() {
        #expect(AssetInfoFormat.coordinate(latitude: 37.331821, longitude: -122.031181) == "37.33182, -122.03118")
    }

    @Test func cameraDetailsParseExif() {
        let properties: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: "iPhone 16 Pro",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFNumber as String: 1.78,
                kCGImagePropertyExifExposureTime as String: 0.008,
                kCGImagePropertyExifISOSpeedRatings as String: [80],
                kCGImagePropertyExifFocalLength as String: 6.765,
                kCGImagePropertyExifFocalLenIn35mmFilm as String: 24,
                kCGImagePropertyExifLensModel as String: "iPhone 16 Pro back camera",
            ],
        ]
        let details = CameraDetails(properties: properties)
        #expect(details.camera == "Apple iPhone 16 Pro")
        #expect(details.iso == 80)
        #expect(details.focalLength35 == 24)
        #expect(details.aperture == 1.78)
        #expect(details.exposure == 0.008)
        #expect(details.lens == "iPhone 16 Pro back camera")
        #expect(CameraDetails(properties: [:]).isEmpty)
    }

    @Test func kindsPreferTheMostSpecific() {
        #expect(AssetKind(mediaType: .image, subtypes: [], isBurst: false) == .photo)
        #expect(AssetKind(mediaType: .image, subtypes: [.photoLive, .photoDepthEffect], isBurst: false) == .portrait)
        #expect(AssetKind(mediaType: .image, subtypes: [.photoLive, .photoHDR], isBurst: false) == .livePhoto)
        #expect(AssetKind(mediaType: .image, subtypes: [.photoScreenshot], isBurst: false) == .screenshot)
        #expect(AssetKind(mediaType: .image, subtypes: [], isBurst: true) == .burst)
        #expect(AssetKind(mediaType: .image, subtypes: [.photoPanorama], isBurst: false) == .panorama)
        #expect(AssetKind(mediaType: .video, subtypes: [.videoHighFrameRate], isBurst: false) == .slowMotion)
        #expect(AssetKind(mediaType: .video, subtypes: [.videoScreenRecording], isBurst: false) == .screenRecording)
        #expect(AssetKind(mediaType: .video, subtypes: [.videoTimelapse], isBurst: false) == .timeLapse)
        #expect(AssetKind(mediaType: .video, subtypes: [], isBurst: false).isVideo)
    }
}

// MARK: - JPG copy

@Suite("HEIC to JPG conversion")
struct ImageConverterTests {
    /// A small gradient image encoded as HEIC (or TIFF where the runner can't encode HEIC), with EXIF, GPS and orientation.
    func sourceImage() throws -> (data: Data, type: UTType) {
        let width = 64, height = 48
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for x in 0..<width {
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: 0.4, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let image = try #require(context.makeImage())
        let metadata: [String: Any] = [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2024:05:01 10:20:30",
                kCGImagePropertyExifLensModel as String: "Test lens",
            ],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 37.3318,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 122.0312,
                kCGImagePropertyGPSLongitudeRef as String: "W",
            ],
        ]
        for type in [UTType.heic, UTType.tiff] {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, metadata as CFDictionary)
            if CGImageDestinationFinalize(dest), out.length > 0 { return (out as Data, type) }
        }
        throw ImageConverter.ConversionError.encodeFailed
    }

    @Test func convertsToJPEGKeepingMetadata() throws {
        let source = try sourceImage()
        let jpeg = try ImageConverter.jpegData(from: source.data)
        let image = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(image) as String? == UTType.jpeg.identifier)
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
        #expect(props[kCGImagePropertyPixelWidth as String] as? Int == 64)
        #expect(props[kCGImagePropertyOrientation as String] as? Int == 6)
        let exif = try #require(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2024:05:01 10:20:30")
        let gps = try #require(props[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        let latitude = try #require(gps[kCGImagePropertyGPSLatitude as String] as? Double)
        #expect(abs(latitude - 37.3318) < 0.001)
        #expect(gps[kCGImagePropertyGPSLongitudeRef as String] as? String == "W")
    }

    @Test func rejectsUnreadableData() {
        #expect(throws: ImageConverter.ConversionError.unreadable) {
            try ImageConverter.jpegData(from: Data("not an image".utf8))
        }
    }

    @Test func jpegFilenames() {
        #expect(ImageConverter.jpegFilename(for: "IMG_1234.HEIC") == "IMG_1234.JPG")
        #expect(ImageConverter.jpegFilename(for: "trip.photo.heif") == "trip.photo.JPG")
        #expect(ImageConverter.jpegFilename(for: nil) == "Photo.JPG")
    }
}

// MARK: - Camera details from a stream

@Suite("Camera details read while measuring")
struct StreamedCameraReaderTests {
    /// A large-ish JPEG (EXIF near the start, like camera files) with camera facts.
    func cameraJPEG() throws -> Data {
        let width = 1200, height = 900
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for x in stride(from: 0, to: width, by: 3) {
            context.setFillColor(red: CGFloat(x % 255) / 255, green: CGFloat((x * 7) % 255) / 255, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 3, height: height))
        }
        let image = try #require(context.makeImage())
        let metadata: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: "iPhone 16 Pro",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFNumber as String: 1.8,
                kCGImagePropertyExifISOSpeedRatings as String: [100],
            ],
        ]
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, metadata as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test func findsCameraDetailsInTheFirstChunks() throws {
        let data = try cameraJPEG()
        let reader = StreamedCameraReader()
        var offset = 0
        while offset < data.count {
            let end = min(offset + 4096, data.count)
            reader.append(data.subdata(in: offset..<end))
            offset = end
            if reader.isFinished { break }
        }
        #expect(reader.isFinished)
        #expect(offset < data.count) // stopped early, before the pixels were all read
        #expect(!reader.isReading)
        #expect(reader.details?.camera == "Apple iPhone 16 Pro")
        #expect(reader.details?.aperture == 1.8)
        #expect(reader.details?.iso == 100)
    }

    @Test func givesUpAtTheLimitWithoutMetadata() {
        let reader = StreamedCameraReader(limit: 10_000)
        for _ in 0..<5 { reader.append(Data(repeating: 0x42, count: 4096)) }
        #expect(!reader.isFinished)
        #expect(!reader.isReading)
        #expect(reader.details == nil)
    }
}
