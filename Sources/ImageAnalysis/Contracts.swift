import ImagingCore
import ImageRendering
import Foundation
public struct Region: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) { self.x=x; self.y=y; self.width=width; self.height=height }
    public func validate() throws {
        guard [x,y,width,height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0, x+width <= 1.000001, y+height <= 1.000001 else { throw LabError.measurement("选区必须位于图像范围内，请重新框选；坐标与宽高以整幅图像为 1") }
    }
}
public enum MeasurementKind: String, Codable, CaseIterable, Sendable { case edge, texture, noise, vignette, glow }
