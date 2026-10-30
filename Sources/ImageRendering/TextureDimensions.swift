import Metal
import ImagingCore

/// Device capabilities, not an application resolution budget.
/// https://developer.apple.com/metal/capabilities/ (maximum 2D texture dimensions)
package enum TextureDimensions {
    package static func validate(width:Int,height:Int,device:MTLDevice) throws {
        _=try ImageDimensions.pixelCount(width:width,height:height)
        let limit:Int
        if #available(iOS 26.0,macOS 26.0,*),device.supportsFamily(.apple10) {limit=32768}
        else if device.supportsFamily(.apple3) || device.supportsFamily(.mac2) {limit=16384}
        else {limit=8192}
        guard width<=limit,height<=limit else {
            throw LabError.unsupported("画面 \(width)×\(height) 超过当前 GPU 的单张 2D 纹理边长能力 \(limit)；请由调用方缩放或分块处理")
        }
    }
}
