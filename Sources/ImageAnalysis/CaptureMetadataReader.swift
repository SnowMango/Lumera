import Foundation
import ImageIO
import ImagingCore

/// Only quantities with known units; EXIF WhiteBalance is a mode, not Kelvin or Duv.
public enum CaptureMetadataReader {
    public static func read(properties:[CFString:Any])->CaptureConditions {
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
    public static func read(url:URL)->CaptureConditions {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any] else{return CaptureConditions()}
        return read(properties:properties)
    }
}
