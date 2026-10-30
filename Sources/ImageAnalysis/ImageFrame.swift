import ImageRendering
import Foundation
import ImagingCore
public struct ImageFrame: Sendable {
    public let width: Int, height: Int
    public var captureConditions=CaptureConditions()
    public var descriptor:InputDescriptor
    public var pixels: [Float]
    public var provenance: [String:String] = [:]
    public init(width: Int, height: Int, pixels: [Float]) throws {
        let count=try ImageDimensions.pixelCount(width:width,height:height)
        guard pixels.count==count*4,pixels.allSatisfy(\.isFinite) else {throw LabError.invalid("图像必须包含与尺寸匹配的有限 RGBA 数值")}

        self.width=width; self.height=height; self.pixels=pixels;self.descriptor=InputDescriptor(width:width,height:height)
    }
    public static func solid(width: Int,height: Int,value: Float) throws -> ImageFrame {
        let count=try ImageDimensions.pixelCount(width:width,height:height)
        var pixels=[Float](repeating:value,count:count*4)
        for i in stride(from:3,to:pixels.count,by:4){pixels[i]=1}
        return try ImageFrame(width:width,height:height,pixels:pixels)
    }
    /// ImageFrame storage is mutable; every processing boundary must recheck its declaration.
    public func validateStorage(allowAlphaNormalization:Bool=false) throws {
        var declared=descriptor
        if allowAlphaNormalization,declared.alphaMode == .straight {declared.alphaMode = .opaque}
        try declared.validate()
        guard descriptor.width==width,descriptor.height==height,pixels.count==width*height*4,
              pixels.allSatisfy(\.isFinite) else {throw LabError.invalid("图像声明与像素存储不一致或包含非有限值")}
    }
    public var digest: String { pixels.withUnsafeBytes { Digest.buffer($0) } }
}
/// Non-overlapping host phases; GPU duration is a subset of styleSeconds, not additive.
public struct RenderTiming:Codable,Sendable {
    public var waitAndValidationSeconds:Double
    public var inputPreparationSeconds:Double
    /// Host preparation/encoding subset of inputPreparationSeconds, not an extra GPU measurement.
    public var correctionSeconds:Double = 0
    public var effectsSeconds:Double
    public var readbackSeconds:Double
    public var metadataSeconds:Double
    public var gpuSeconds:Double?
    public var reusedInput:Bool
    public var reusedEffects:Bool
    public var styleSeconds:Double {inputPreparationSeconds+effectsSeconds}
    public var totalSeconds:Double {waitAndValidationSeconds+styleSeconds+readbackSeconds+metadataSeconds}
}
public struct RenderManifest: Codable, Sendable {
    public var engineVersion=Profile.engineVersion
    public var profileDigest: String, effectiveDigest:String, inputDigest: String, lutDigest: String, device: String, quality: String
    public var correctionDigest:String = "identity"
    public var width: Int, height: Int
    public var timing:RenderTiming? = nil
    public var seconds: Double
    public var seed: UInt32
    public var frameIndex:UInt32
    public var input:InputDescriptor
    public var previewGlow:Bool
    public var precision="RGBA float32; Gaussian truncated at 3 sigma; reflected boundary for noise, clamped for optics"
    public var assumptions: [String:String]
    public var peakWorkingSetEstimateBytes: Int
}
public struct RenderResult: Sendable {
    public var image: ImageFrame
    public var glowLayer: ImageFrame?
    public var manifest: RenderManifest
}
