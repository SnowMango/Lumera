import Foundation
import ImagingCore

/// 渲染资源的语义身份，同时记录源内容、编码契约与采样策略。
public struct RenderResourceIdentity: Codable, Equatable, Sendable {
    /// 单张 LUT 的内容和应用语义。
    public struct LUTIdentity: Codable, Equatable, Sendable {
        public let sha256: String
        public let contract: String
        public let boundaryPolicy: LUTBoundaryPolicy
        fileprivate init(_ asset: LUTAsset) {
            sha256 = asset.sha256; contract = asset.contract; boundaryPolicy = asset.boundaryPolicy
        }
    }
    public let styleLUT: LUTIdentity?
    public let correctionLUT: LUTIdentity?

    public init(resources: RenderResources) throws {
        try resources.validate()
        self.init(validated: resources)
    }
    package init(validated resources: RenderResources) {
        styleLUT = resources.lut.map(LUTIdentity.init)
        correctionLUT = resources.correctionLUT.map(LUTIdentity.init)
    }
    /// 将资源身份编码为带版本的摘要。
    public func digest() throws -> String {
        struct Versioned: Encodable { let version: Int; let resources: RenderResourceIdentity }
        return Digest.data(try JSON.encode(Versioned(version: 1, resources: self)))
    }
}
