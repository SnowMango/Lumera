import ImagingCore

/// Owns static resources until released by the caller; one instance per compiled style.
public final class PreparedStyleDefinition:@unchecked Sendable {
    public let definition:CompiledStyleDefinition
    let fixed:PreparedCameraStyle
    init(definition:CompiledStyleDefinition,fixed:PreparedCameraStyle){self.definition=definition;self.fixed=fixed}
}
/// Immutable evaluator output; callers cannot supply unchecked numeric parameters or a different LUT.
public struct FrameStyleParameters:Sendable {
    let evaluated:EvaluatedStyle
    public init(_ evaluated:EvaluatedStyle){self.evaluated=evaluated}
}
public struct StaticResourceStatistics:Sendable {
    public let lutParses:Int,lutUploads:Int
}
public struct RenderCacheStatistics:Sendable {
    public let kernelCount:Int,textureBytes:Int,kernelBytes:Int
}
