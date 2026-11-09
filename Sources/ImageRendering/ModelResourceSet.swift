import Foundation
import ImagingCore

/// 调用方按资源 ID 提供的不可变 LUT 与曲线，供模型准备直接验证和使用。
public struct ModelResourceSet: Equatable, Sendable {
    public let luts: [String: LUTAsset]
    public let curves: [String: ResponseCurve]
    public init(luts: [String: LUTAsset] = [:], curves: [String: ResponseCurve] = [:]) throws {
        guard Set(luts.keys).isDisjoint(with: curves.keys),
              (Array(luts.keys) + Array(curves.keys)).allSatisfy({ !$0.isEmpty }) else {
            throw LabError.invalid("Invalid or overlapping resource IDs")
        }
        for asset in luts.values { try asset.validate() }
        for curve in curves.values { try curve.validate(kind: .tone) }
        self.luts = luts; self.curves = curves
    }
}
