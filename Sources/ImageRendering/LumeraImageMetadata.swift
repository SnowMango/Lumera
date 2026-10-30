import Foundation
import CoreImage
import CoreVideo
import ImageIO

/// Internal, deliberately conservative policy: capture facts survive; derived/opaque data do not.
enum LumeraImageMetadata {
    static func merge(_ image: [String: Any], supplement: [String: Any]?) -> [String: Any] {
        guard let supplement else { return image }
        var merged = image
        for (key, value) in supplement {
            if let incoming = value as? [String: Any], let existing = merged[key] as? [String: Any] {
                merged[key] = existing.merging(incoming) { _, new in new }
            } else { merged[key] = value }
        }
        return merged
    }

    static func orientation(_ properties: [String: Any]) -> CGImagePropertyOrientation {
        let value = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        return CGImagePropertyOrientation(rawValue: value) ?? .up
    }

    static func output(_ source: [String: Any], width: Int, height: Int, depth: Int) -> [String: Any] {
        var result: [String: Any] = [
            kCGImagePropertyPixelWidth as String: width, kCGImagePropertyPixelHeight as String: height,
            kCGImagePropertyOrientation as String: 1, kCGImagePropertyDepth as String: depth,
            kCGImagePropertyColorModel as String: kCGImagePropertyColorModelRGB,
            kCGImagePropertyProfileName as String: "sRGB IEC61966-2.1",
            kCGImagePropertyHasAlpha as String: true]
        func selected(_ dictionary: CFString, _ keys: [CFString]) -> [String: Any] {
            let values = source[dictionary as String] as? [String: Any] ?? [:]
            return values.filter { key, _ in keys.contains { $0 as String == key } }
        }
        var exif = selected(kCGImagePropertyExifDictionary, [
            kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber,
            kCGImagePropertyExifExposureProgram, kCGImagePropertyExifISOSpeedRatings,
            kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
            kCGImagePropertyExifSubsecTime, kCGImagePropertyExifSubsecTimeOriginal,
            kCGImagePropertyExifSubsecTimeDigitized, kCGImagePropertyExifShutterSpeedValue,
            kCGImagePropertyExifApertureValue, kCGImagePropertyExifBrightnessValue,
            kCGImagePropertyExifExposureBiasValue, kCGImagePropertyExifMaxApertureValue,
            kCGImagePropertyExifSubjectDistance, kCGImagePropertyExifMeteringMode,
            kCGImagePropertyExifLightSource, kCGImagePropertyExifFlash, kCGImagePropertyExifFocalLength,
            kCGImagePropertyExifExposureMode, kCGImagePropertyExifWhiteBalance,
            kCGImagePropertyExifFocalLenIn35mmFilm, kCGImagePropertyExifLensMake,
            kCGImagePropertyExifLensModel, kCGImagePropertyExifLensSpecification,
            kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
            kCGImagePropertyExifUserComment, kCGImagePropertyExifCameraOwnerName])
        exif[kCGImagePropertyExifPixelXDimension as String] = width
        exif[kCGImagePropertyExifPixelYDimension as String] = height
        exif[kCGImagePropertyExifColorSpace as String] = 1
        result[kCGImagePropertyExifDictionary as String] = exif
        var tiff = selected(kCGImagePropertyTIFFDictionary, [
            kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
            kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFImageDescription])
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        result[kCGImagePropertyTIFFDictionary as String] = tiff
        if let gps = source[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            result[kCGImagePropertyGPSDictionary as String] = gps
        }
        return result
    }

    static func attach(_ properties: [String: Any], to buffer: CVPixelBuffer) {
        for (key, value) in properties {
            CVBufferSetAttachment(buffer, key as CFString, value as CFTypeRef, .shouldPropagate)
        }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, LumeraRenderer.sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
    }
}
