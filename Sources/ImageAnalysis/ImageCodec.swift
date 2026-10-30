import ImageRendering
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ImagingCore
public enum OutputFormat: String, CaseIterable, Sendable { case png, jpeg, tiff }
public enum ImageCodec {
    public static let supportedInputTypes:[UTType]=[.jpeg,.png,.heic,.heif,.tiff,.rawImage]
    public static func supportsInputFile(_ url:URL)->Bool {
        guard url.isFileURL,let type=UTType(filenameExtension:url.pathExtension) else{return false}
        return supportedInputTypes.contains{type.conforms(to:$0)}
    }
    public static func isRAWFile(_ url:URL)->Bool {
        UTType(filenameExtension:url.pathExtension)?.conforms(to:.rawImage) == true
    }

    public static func load(_ url:URL, background:[Double]=[0,0,0]) throws -> ImageFrame {
        guard background.count==3,background.allSatisfy({$0.isFinite && (0...1).contains($0)}) else {throw LabError.invalid("透明区底色必须包含三个 0–1 范围内的有效数值")}
        guard let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary) else {
            if isRAWFile(url) {return try RAWImageDecoder.load(url)}
            throw LabError.unsupported("无法读取照片文件")
        }
        if let type=CGImageSourceGetType(source),let uniform=UTType(type as String),uniform.conforms(to:.rawImage) {
            return try RAWImageDecoder.load(url)
        }
        guard let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let w=props[kCGImagePropertyPixelWidth] as? Int,let h=props[kCGImagePropertyPixelHeight] as? Int else {throw LabError.unsupported("无法读取照片尺寸")}
        _=try ImageDimensions.pixelCount(width:w,height:h)
        let depth=props[kCGImagePropertyDepth] as? Int ?? 8
        // Float/HDR transfer functions have no implicit tone mapping in this SDR contract.
        let description=String(describing:props).lowercased()
        guard depth<=16,!description.contains("itu_r_2100"),!description.contains("st 2084"),!description.contains("hlg"),!description.contains("pq_eotf") else {throw LabError.unsupported("此 HDR 或高位深输入不受支持，请先将照片转换为 SDR 再导入")}
        let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(w,h),kCGImageSourceShouldCacheImmediately:true]
        guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else {throw LabError.unsupported("无法解码此照片，请转换为 SDR JPEG、HEIF 或 PNG 后重试")}
        let spaceName=(image.colorSpace?.name as String? ?? "").lowercased()
        guard !spaceName.contains("2100"),!spaceName.contains("pq"),!spaceName.contains("hlg"),!image.bitmapInfo.contains(.floatComponents) else {
            throw LabError.unsupported("不支持 HDR 或浮点输入，请先显式转换为 SDR")
        }
        var frame=try decode(image,background:background)
        frame.captureConditions=CaptureMetadataReader.read(properties:props)
        frame.provenance=["file":url.lastPathComponent,"fileSHA256":Digest.data(try Data(contentsOf:url)),"color":props[kCGImagePropertyProfileName] == nil ? "assumed sRGB (no profile name)" : "converted from \(props[kCGImagePropertyProfileName]!) to sRGB","orientation":"normalized","alphaBackground":background.map(String.init(describing:)).joined(separator:","),"hdr":"SDR base only; gain maps not applied","gamut":"ICC to sRGB, out-of-gamut channels clipped to 0–1"]
        return frame
    }
    /// Same 16-bit sRGB material conversion as encode(PNG) → load, without compression or disk I/O.
    public static func normalizedMaterial(_ frame:ImageFrame) throws -> ImageFrame {
        try autoreleasepool {try normalizedMaterialInPool(frame)}
    }
    private static func normalizedMaterialInPool(_ frame:ImageFrame) throws -> ImageFrame {
        try Task.checkCancellation();try frame.validateStorage(allowAlphaNormalization:true)
        let image:CGImage
        if stride(from:3,to:frame.pixels.count,by:4).contains(where:{frame.pixels[$0] != 1}) {
            // ImageIO quantizes premultiplied transparent PNGs differently; retain that path in memory.
            let data=try encode(frame)
            guard let source=CGImageSourceCreateWithData(data as CFData,nil),
                  let decoded=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(frame.width,frame.height),kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {throw LabError.io("无法准备标准化图像")}
            image=decoded
        } else {image=try cgImage(frame)}
        var normalized=try decode(image,background:[0,0,0])
        normalized.provenance=frame.provenance
        normalized.captureConditions=frame.captureConditions
        return normalized
    }
    static func decode(_ image:CGImage,background:[Double]) throws -> ImageFrame {
        let width=image.width,height=image.height
        let count=try ImageDimensions.pixelCount(width:width,height:height)
        var floats=[Float](repeating:0,count:count*4)
        let success=floats.withUnsafeMutableBytes { raw -> Bool in
            guard let context=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:32,bytesPerRow:width*16,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.floatComponents.rawValue|CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            context.setFillColor(CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:background.map { CGFloat($0) } + [CGFloat(1)])!)
            context.fill(CGRect(x:0,y:0,width:width,height:height));context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            return true
        }
        guard success else {throw LabError.io("无法创建色彩转换环境，请检查内存并重试")}
        try Task.checkCancellation()
        // Explicit SDR adapter gamut boundary, after ICC conversion. Never silently tone-map HDR.
        for i in floats.indices {floats[i]=min(1,max(0,floats[i]))}
        return try ImageFrame(width:width,height:height,pixels:floats)
    }
    public static func cgImage(_ frame:ImageFrame) throws -> CGImage {
        try frame.validateStorage(allowAlphaNormalization:true)
        let data=frame.pixels.map{UInt16((min(1,max(0,$0))*65535).rounded())}.withUnsafeBytes{Data($0)}
        guard let provider=CGDataProvider(data:data as CFData),let image=CGImage(width:frame.width,height:frame.height,bitsPerComponent:16,bitsPerPixel:64,bytesPerRow:frame.width*8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder16Little.rawValue|CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric) else {throw LabError.io("无法创建输出图像，请检查内存并重试")}
        return image
    }
    /// Display/delivery conversion only. Calibration continues to use cgImage/encode at 16 bits.
    /// Imported photos are already opaque; any remaining straight alpha is composited over black.
    public static func photoCGImage(_ frame:ImageFrame) throws -> CGImage {
        try frame.validateStorage(allowAlphaNormalization:true)
        try Task.checkCancellation()
        var data=Data(count:frame.width*frame.height*3)
        try data.withUnsafeMutableBytes { raw in
            let output=raw.bindMemory(to:UInt8.self).baseAddress!
            try frame.pixels.withUnsafeBufferPointer { buffer in
                let input=buffer.baseAddress!
                for y in 0..<frame.height {
                    if y%64==0 {try Task.checkCancellation()}
                    for x in 0..<frame.width {
                        let pixel=y*frame.width+x,i=pixel*4,j=pixel*3,alpha=min(1,max(0,input[i+3]))
                        output[j]=UInt8((min(1,max(0,input[i]*alpha))*255).rounded())
                        output[j+1]=UInt8((min(1,max(0,input[i+1]*alpha))*255).rounded())
                        output[j+2]=UInt8((min(1,max(0,input[i+2]*alpha))*255).rounded())
                    }
                }
            }
        }
        guard let provider=CGDataProvider(data:data as CFData),let image=CGImage(width:frame.width,height:frame.height,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:frame.width*3,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric) else{throw LabError.io("无法创建照片显示图像")}
        return image
    }
    /// Full-precision SDR reference export, directly from the floating-point render.
    /// RGB only; any remaining straight alpha is composited over black, as on import.
    public static func encodeReference(_ frame:ImageFrame) throws -> Data {
        try frame.validateStorage(allowAlphaNormalization:true)
        try Task.checkCancellation()
        var data=Data(count:frame.width*frame.height*6)
        try data.withUnsafeMutableBytes { raw in
            let output=raw.bindMemory(to:UInt16.self).baseAddress!
            try frame.pixels.withUnsafeBufferPointer { buffer in
                let input=buffer.baseAddress!
                for y in 0..<frame.height {
                    if y%64==0 {try Task.checkCancellation()}
                    for x in 0..<frame.width {
                        let pixel=y*frame.width+x,i=pixel*4,j=pixel*3,alpha=min(1,max(0,input[i+3]))
                        for channel in 0..<3 {
                            output[j+channel]=UInt16((min(1,max(0,input[i+channel]*alpha))*65535).rounded()).littleEndian
                        }
                    }
                }
            }
        }
        guard let provider=CGDataProvider(data:data as CFData),
              let image=CGImage(width:frame.width,height:frame.height,bitsPerComponent:16,bitsPerPixel:48,bytesPerRow:frame.width*6,
                                space:CGColorSpace(name:CGColorSpace.sRGB)!,
                                bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder16Little.rawValue|CGImageAlphaInfo.none.rawValue),
                                provider:provider,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric)
        else{throw LabError.io("无法创建 16 位 RGB 标定参考图")}
        return try encodeImage(image,format:.png)
    }
    public static func encodePhoto(_ frame:ImageFrame,format:OutputFormat = .png) throws -> Data {
        try encodeImage(photoCGImage(frame),format:format)
    }
    public static func encode(_ frame:ImageFrame,format:OutputFormat = .png) throws -> Data {
        try encodeImage(cgImage(frame),format:format)
    }
    private static func encodeImage(_ image:CGImage,format:OutputFormat) throws -> Data {
        try Task.checkCancellation()
        let type:CFString = (format == .png ? UTType.png.identifier : format == .jpeg ? UTType.jpeg.identifier : UTType.tiff.identifier) as CFString
        let data=NSMutableData()
        guard let dest=CGImageDestinationCreateWithData(data,type,1,nil) else {throw LabError.io("当前系统无法使用所需的图像编码器")}
        CGImageDestinationAddImage(dest,image,[kCGImagePropertyOrientation:1,kCGImageDestinationLossyCompressionQuality:0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {throw LabError.io("图像编码失败，请重试导出")}
        try Task.checkCancellation()
        return data as Data
    }
}
