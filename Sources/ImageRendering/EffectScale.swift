import Foundation

public enum RenderingPrecision:Sendable {case float16,float32}
/// Spatial parameters are pixels at full-frame long edge 2048. A crop is a new frame.
/// Small previews retain a 0.5 actual-pixel grain floor: an explicit sampling approximation.
public enum EffectScale {
    public static let referenceLongEdge=2048.0
    public static let minimumGrainPixels=0.5
    public static func factor(width:Int,height:Int)->Double {Double(max(width,height))/referenceLongEdge}
}
