import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ImagingCore

/// Load caller-owned LUT samples. Resource data is independent of saved configurations.
public enum LUTImporter {
    public enum FileFormat:Sendable {case cube,tiledPNG}

    public static func load(_ url:URL) throws -> LUTAsset {
        try Task.checkCancellation()
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=16_000_000 else {
            throw LabError.invalid("LUT 文件超过 16 MB，请使用较小的文件")
        }
        let format:FileFormat
        switch url.pathExtension.lowercased() {
        case "cube":format = .cube
        case "png":format = .tiledPNG
        default:throw LabError.unsupported("支持 .cube 或 512×512 平铺 PNG LUT")
        }
        return try load(data:Data(contentsOf:url),format:format,name:url.lastPathComponent)
    }
    /// Encoded file bytes, not CIColorCubeWithColorSpace's raw Float32 RGBA data.
    public static func load(data:Data,format:FileFormat,name:String) throws -> LUTAsset {
        try autoreleasepool {
            try Task.checkCancellation()
            guard data.count<=16_000_000 else {throw LabError.invalid("LUT 文件超过 16 MB，请使用较小的文件")}
            let text:String
            switch format {
            case .cube:
                guard let decoded=String(data:data,encoding:.utf8) else {throw LabError.invalid("cube 数据必须是有效的 UTF-8 文本")}
                _=try CubeLUT.parse(decoded);text=decoded
            case .tiledPNG:text=try tiledPNG(data)
            }
            try Task.checkCancellation()
            return LUTAsset(name:name,cubeText:text)
        }
    }
    /// Raw native-endian Float32 samples, not encoded file bytes. Samples are interpreted
    /// under Lumera's encoded-sRGB input/output contract; no color conversion is performed.
    public static func load(data:Data,descriptor:LUTDataDescriptor,name:String) throws -> LUTAsset {
        try Task.checkCancellation()
        let n=descriptor.dimension
        guard (2...128).contains(n) else {throw LabError.unsupported("原始 3D LUT 每边尺寸须为 2–128")}
        let channels=descriptor.layout == .rgbFloat32 ? 3:4
        let expected=n*n*n*channels*MemoryLayout<Float>.size
        guard data.count==expected else {throw LabError.invalid("LUT Data 长度应为 dimension³ × 通道数 × Float32，共 \(expected) 字节；实际 \(data.count) 字节")}
        var values=[Float](repeating:1,count:n*n*n*4)
        try data.withUnsafeBytes { bytes in
            for b in 0..<n {
                try Task.checkCancellation()
                for g in 0..<n {for r in 0..<n {
                    let source=(descriptor.order == .redFastest ? (b*n+g)*n+r:(r*n+g)*n+b)*channels
                    let target=((b*n+g)*n+r)*4
                    for c in 0..<channels {
                        let value=bytes.loadUnaligned(fromByteOffset:(source+c)*4,as:Float.self)
                        guard value.isFinite,(0...1).contains(value) else {throw LabError.invalid("LUT Data 含非有限数或超出 0–1 的 SDR 数值")}
                        guard c != 3 || value==1 else {throw LabError.unsupported("Lumera 照片 LUT 要求 Alpha 为 1；不支持透明或预乘半透明色表")}
                        values[target+c]=value
                    }
                }}
            }
        }
        return LUTAsset(name:name,cube:CubeLUT(size:n,rgba:values))
    }
    /// GPUImage-style atlas: blue slices run left-to-right then top-to-bottom;
    /// red increases across each 64-pixel tile, green increases down it.
    private static func tiledPNG(_ data:Data) throws -> String {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source)==1,
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              properties[kCGImagePropertyPixelWidth] as? Int == 512,
              properties[kCGImagePropertyPixelHeight] as? Int == 512 else {
            throw LabError.unsupported("图片 LUT 必须是 512×512 的单张 PNG：8×8 平铺，每格 64×64；不支持 Hald、普通照片或缩放后的色表")
        }
        guard (properties[kCGImagePropertyOrientation] as? Int ?? 1)==1 else {
            throw LabError.unsupported("LUT 图片带有旋转或镜像标记，请使用原始方向的平铺色表")
        }
        guard let image=CGImageSourceCreateImageAtIndex(source,0,nil),
              image.colorSpace?.model == .rgb,[8,16].contains(image.bitsPerComponent) else {
            throw LabError.unsupported("图片 LUT 需要 8 位或 16 位 RGB PNG")
        }
        // LUT pixels are numeric samples, not a display image. Re-tag without
        // transforming ICC/gamma values, and never resize, orient or composite them.
        let space=CGColorSpaceCreateDeviceRGB()
        guard let numeric=image.copy(colorSpace:space) else {throw LabError.io("无法读取 LUT 色表数值")}
        var pixels=[Float](repeating:0,count:512*512*4)
        let decoded=pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context=CGContext(data:raw.baseAddress,width:512,height:512,bitsPerComponent:32,bytesPerRow:512*16,space:space,
                bitmapInfo:CGBitmapInfo.floatComponents.rawValue|CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue) else {return false}
            context.setBlendMode(.copy);context.interpolationQuality = .none
            context.draw(numeric,in:CGRect(x:0,y:0,width:512,height:512));return true
        }
        guard decoded else {throw LabError.io("无法解码 LUT 图片")}
        guard stride(from:3,to:pixels.count,by:4).allSatisfy({pixels[$0]==1}) else {
            throw LabError.invalid("图片 LUT 不能含透明或半透明像素，请使用不透明色表")
        }
        var text="# Imported from a 512x512 tiled PNG; numeric RGB samples, no ICC conversion\nLUT_3D_SIZE 64\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
        text.reserveCapacity(10_000_000)
        for b in 0..<64 {
            try Task.checkCancellation()
            for g in 0..<64 {for r in 0..<64 {
                let x=(b%8)*64+r,y=(b/8)*64+g,i=(y*512+x)*4
                let red=pixels[i],green=pixels[i+1],blue=pixels[i+2]
                guard [red,green,blue].allSatisfy({$0.isFinite && (0...1).contains($0)}) else {throw LabError.invalid("LUT 包含无效色值")}
                text += "\(red) \(green) \(blue)\n"
            }}
        }
        guard text.utf8.count<=16_000_000 else {throw LabError.invalid("转换后的 LUT 超过风格文件的支持范围")}
        return text
    }
}
