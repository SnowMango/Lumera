import Foundation
import CoreImage
import ImageIO
import ImagingCore

/// Decode once on import. The style engine continues to receive bounded sRGB SDR pixels.
enum RAWImageDecoder {
    static func load(_ url:URL) throws -> ImageFrame {
        try autoreleasepool {
            try Task.checkCancellation()
            guard let raw=CIRAWFilter(imageURL:url) else {
                throw LabError.unsupported("系统无法显影此 RAW：文件可能损坏，或当前 macOS 不支持该相机型号")
            }
            let native=raw.nativeSize
            let target=try RAWImportGeometry.size(width:native.width,height:native.height)
            raw.scaleFactor=Float(min(Double(target.width)/native.width,Double(target.height)/native.height))
            raw.isDraftModeEnabled=false
            raw.extendedDynamicRangeAmount=0
            // Retain the file's as-shot white balance, baseline exposure and system
            // default tone/noise/lens processing. This is developed input, not raw RGB.
            guard var output=raw.outputImage else {throw LabError.unsupported("系统 RAW 显影失败；不会改用内嵌预览图")}
            let extent=output.extent
            guard extent.origin.x.isFinite,extent.origin.y.isFinite else {throw LabError.invalid("RAW 输出范围无效")}
            let bounded=try RAWImportGeometry.size(width:extent.width,height:extent.height)
            output=output.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY))
            // Normalize fractional output extents to integer pixel geometry only.
            if extent.width>Double(bounded.width) || extent.height>Double(bounded.height) {
                output=output.transformed(by:CGAffineTransform(scaleX:Double(bounded.width)/extent.width,y:Double(bounded.height)/extent.height))
            }
            let bounds=CGRect(x:0,y:0,width:bounded.width,height:bounded.height)
            let sRGB=CGColorSpace(name:CGColorSpace.sRGB)!
            let context=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!,
                                           .workingFormat:CIFormat.RGBAf,.cacheIntermediates:false])
            defer{context.clearCaches()}
            try Task.checkCancellation()
            guard let image=context.createCGImage(output,from:bounds,format:.RGBA16,colorSpace:sRGB) else {
                throw LabError.io("无法完成 RAW 显影，请检查文件与可用内存")
            }
            var frame=try ImageCodec.decode(image,background:[0,0,0])
            frame.captureConditions=CaptureMetadataReader.read(url:url)
            let originalOriented=(5...8).contains(raw.orientation.rawValue) ? "\(Int(native.height))×\(Int(native.width))":"\(Int(native.width))×\(Int(native.height))"
            frame.provenance=["file":url.lastPathComponent,"fileSHA256":Digest.data(try Data(contentsOf:url,options:.mappedIfSafe)),
                "color":"system RAW development converted to encoded sRGB",
                "orientation":"normalized by CIRAWFilter; EXIF \(raw.orientation.rawValue)","alphaBackground":"opaque RAW",
                "hdr":"RAW developed to SDR; extendedDynamicRangeAmount=0","gamut":"system gamut mapping; sRGB output clipped to 0–1",
                "rawDecoder":"CIRAWFilter","rawDecoderVersion":raw.decoderVersion.rawValue,
                "rawNativeSize":originalOriented,"rawOutputSize":"\(frame.width)×\(frame.height)",
                "rawResized":frame.width*frame.height<Int(native.width*native.height) ? "true":"false",
                "rawDevelopment":"as-shot white balance; system default baseline exposure, tone, noise reduction and lens correction; full-quality decode",
                "rawNeutralTemperature":String(raw.neutralTemperature),"rawNeutralTint":String(raw.neutralTint),
                "rawBaselineExposure":String(raw.baselineExposure)]
            try Task.checkCancellation()
            return frame
        }
    }
}

/// Validate integer geometry without imposing a product resolution policy.
enum RAWImportGeometry {
    static func size(width:Double,height:Double) throws -> (width:Int,height:Int) {
        guard width.isFinite,height.isFinite,width>=1,height>=1,width<Double(Int.max),height<Double(Int.max) else {
            throw LabError.unsupported("RAW 尺寸无效")
        }
        let w=Int(floor(width)),h=Int(floor(height))
        _=try ImageDimensions.pixelCount(width:w,height:h)
        return (w,h)
    }
}
