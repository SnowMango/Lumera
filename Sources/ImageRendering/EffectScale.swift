import Foundation

public enum RenderingPrecision:Sendable {case float16,float32}
/// Spatial parameters are pixels at full-frame long edge 2048. A crop is a new frame.
/// Grain integrates each output pixel in this shared reference coordinate space.
public enum EffectScale {
    public static let referenceLongEdge=2048.0
    public static func factor(width:Int,height:Int)->Double {Double(max(width,height))/referenceLongEdge}
}
