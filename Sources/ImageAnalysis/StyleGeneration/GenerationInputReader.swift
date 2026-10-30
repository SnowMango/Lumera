import Foundation
import ImageIO
import CryptoKit
import ImagingCore

/// Import stays metadata-only: no decoded photograph or render texture is retained.
public enum GenerationInputReader {
    public static func read(_ url:URL,role:CaptureRole,target:CaptureTarget)throws->CaptureFile {
        try Task.checkCancellation()
        guard ImageCodec.supportsInputFile(url),let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any] else{throw LabError.unsupported("无法读取照片元数据："+url.lastPathComponent)}
        return .init(url:url.standardizedFileURL,digest:try digest(url),role:role,target:target,conditions:CaptureMetadataReader.read(properties:properties))
    }
    public static func digest(_ url:URL)throws->String {
        guard url.isFileURL else{throw LabError.invalid("仅支持本地照片")}
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
        var hash=SHA256()
        while let bytes=try handle.read(upToCount:1_048_576),!bytes.isEmpty {try Task.checkCancellation();hash.update(data:bytes)}
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
}
