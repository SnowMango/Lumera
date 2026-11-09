import Foundation
import ImageIO
import ImagingCore

/// 提取可用的拍摄事实。EXIF 白平衡模式和 RAW 色偏设置不提供色温或 Duv 数值。
public enum InputCaptureMetadataReader {
    public static func read(properties: [CFString: Any]) -> CaptureConditions {
        guard let exif=properties[kCGImagePropertyExifDictionary] as? [CFString:Any] else{return CaptureConditions()}
        func finite(_ value:Any?,positive:Bool=false)->Double? {
            guard let number=value as? NSNumber else{return nil}
            let x=number.doubleValue
            return x.isFinite && (!positive || x>0) ? x:nil
        }
        var c=CaptureConditions()
        if let values=exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber],values.count==1 {c.iso=finite(values[0],positive:true)}
        c.exposureDurationSeconds=finite(exif[kCGImagePropertyExifExposureTime],positive:true)
        c.exposureBiasEV=finite(exif[kCGImagePropertyExifExposureBiasValue])
        return c
    }
}
