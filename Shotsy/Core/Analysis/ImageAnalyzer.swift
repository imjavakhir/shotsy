import AVFoundation
import CoreGraphics
import CryptoKit
import Photos
import UIKit
import Vision

/// Vision + PhotoKit helpers. All nonisolated so they run on background actors, never the main thread.
nonisolated enum ImageAnalyzer {
    /// Local-only, downsampled image for analysis. Returns nil for cloud-only assets
    /// (Shotsy never eagerly downloads the library).
    static func localImage(for asset: PHAsset, maxSide: CGFloat) -> CGImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        var result: CGImage?
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: maxSide, height: maxSide),
            contentMode: .aspectFit, options: options
        ) { image, _ in
            result = image?.cgImage
        }
        return result
    }

    static func featureVector(_ image: CGImage) async throws -> [Float] {
        let observation = try await GenerateImageFeaturePrintRequest().perform(on: image)
        switch observation.elementType {
        case .float:
            return VectorMath.floats(from: observation.data)
        case .double:
            return observation.data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }.map(Float.init)
        @unknown default:
            return []
        }
    }

    /// Feature vector for the scan. Vision has no inference context in the Simulator, so DEBUG simulator
    /// builds fall back to a coarse color layout (only so App Store captures can show real groups).
    static func featureVectorForScan(_ image: CGImage) async -> [Float]? {
        if let vector = try? await featureVector(image) { return vector }
        #if DEBUG && targetEnvironment(simulator)
        return colorLayout(image)
        #else
        return nil
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    /// 8×8 RGB thumbnail, mean-centered and scaled to unit length, so near-identical shots land close together.
    private static func colorLayout(_ image: CGImage) -> [Float]? {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var v = pixels.enumerated().filter { $0.offset % 4 != 3 }.map { Float($0.element) / 255 }
        let mean = v.reduce(0, +) / Float(v.count)
        v = v.map { $0 - mean }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        return v.map { $0 / norm }
    }
    #endif

    static func sharpness(_ image: CGImage, side: Int = 384) -> Double? {
        let width = min(side, image.width), height = max(1, Int(Double(width) * Double(image.height) / Double(image.width)))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return BlurMetric.laplacianVariance(gray: pixels, width: width, height: height)
    }

    struct TextResult: Sendable {
        var text: String
        var languages: [String]
    }

    /// On-device OCR. Text never leaves the device and is never logged.
    static func recognizeText(_ image: CGImage) async throws -> TextResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: image)
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let languages = Set(observations.flatMap(\.recognitionLanguages).map { $0.minimalIdentifier })
        return TextResult(text: lines.joined(separator: "\n"), languages: Array(languages))
    }

    /// Computed once; the list doesn't change while the app runs.
    static func supportedOCRLanguages() -> [String] { ocrLanguages }

    private static let ocrLanguages: [String] = {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        return request.supportedRecognitionLanguages.map { $0.minimalIdentifier }
    }()

    // MARK: Video

    /// File size of a locally available video, read from its file URL. `nil` if the original is only in iCloud,
    /// is a composition (e.g. slow-motion), or can't be read without downloading.
    static func localVideoBytes(for asset: PHAsset) async -> Int64? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.version = .original
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let url = (avAsset as? AVURLAsset)?.url,
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Int64(size))
            }
        }
    }

    // MARK: Duplicate verification

    /// SHA-256 of every original resource of an asset. Reads full originals; `allowNetwork` downloads from iCloud.
    static func resourceFingerprints(for asset: PHAsset, allowNetwork: Bool) async -> [ResourceFingerprint]? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { return nil }
        var prints: [ResourceFingerprint] = []
        for resource in resources {
            guard let hash = await sha256(resource, allowNetwork: allowNetwork) else { return nil }
            prints.append(ResourceFingerprint(type: resource.type.rawValue, uti: resource.uniformTypeIdentifier, sha256: hash))
        }
        return prints
    }

    private static func sha256(_ resource: PHAssetResource, allowNetwork: Bool) async -> String? {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        final class Box: @unchecked Sendable { var hasher = SHA256() }
        let box = Box()
        nonisolated(unsafe) let resource = resource
        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                box.hasher.update(data: chunk)
            } completionHandler: { error in
                if error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: box.hasher.finalize().map { String(format: "%02x", $0) }.joined())
                }
            }
        }
    }
}
