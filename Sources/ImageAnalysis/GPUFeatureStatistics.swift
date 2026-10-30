import ImageRendering
import Foundation
import ImagingCore

/// Shared output for calibration and developer measurement checks.
/// Compact measurement output; raw pixels stay on the GPU.
public struct GPUFeatureStatistics:Sendable {
    public var metrics:[String:Double]
    public var curves:[String:[Double]]
    public var warnings:[String]
    public var width:Int,height:Int
    public var readbackBytes:Int
    public var submissions:Int
    public var gpuSeconds:Double
    public init(metrics:[String:Double],curves:[String:[Double]],warnings:[String]=[],width:Int,height:Int,readbackBytes:Int=0,submissions:Int=0,gpuSeconds:Double=0) {
        self.metrics=metrics;self.curves=curves;self.warnings=warnings;self.width=width;self.height=height
        self.readbackBytes=readbackBytes;self.submissions=submissions;self.gpuSeconds=gpuSeconds
    }
}
