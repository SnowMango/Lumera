import Foundation
import ImageIO
import ImagingCore
import ImageRendering

/// 复用输入链路的拍摄元数据解释。只读取单位明确的量，EXIF 白平衡模式不提供色温或 Duv。
public enum CaptureMetadataReader {
    public static func read(properties:[CFString:Any])->CaptureConditions {
        InputCaptureMetadataReader.read(properties: properties)
    }

    /// 读取首帧图像属性。无法读取时返回空拍摄条件。
    public static func read(url:URL)->CaptureConditions {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any] else{return CaptureConditions()}
        return read(properties:properties)
    }
}
