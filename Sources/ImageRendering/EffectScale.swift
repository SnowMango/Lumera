import Foundation
import ImagingCore

/// 指定图像与效果纹理的浮点存储精度；不会将着色器中的 Float32 运算改为 Half 运算。
public enum RenderingPrecision: Sendable {
    case float16, float32
    public init(_ value: ExecutionPrecision) { self = value == .float16 ? .float16 : .float32 }
    public var executionPrecision: ExecutionPrecision { self == .float16 ? .float16 : .float32 }
}
/// 空间参数以整帧长边为 2048 像素时的尺度定义，颗粒在此参考坐标中积分。
/// 作为新输入的裁剪按自身尺寸定标，同一帧的分块沿用整帧坐标。
public enum EffectScale {
    public static let referenceLongEdge=2048.0
    public static func factor(width:Int,height:Int)->Double {Double(max(width,height))/referenceLongEdge}
}
