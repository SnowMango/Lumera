import Foundation

public struct InputDescriptor: Codable, Equatable, Sendable {
    public enum Primaries: String,Codable,Sendable {case sRGB,displayP3,unknown}
    public enum Transfer: String,Codable,Sendable {case sRGB,linear,pq,hlg,unknown}
    public enum Reference: String,Codable,Sendable {case display,scene,unknown}
    public enum AlphaMode: String,Codable,Sendable {case opaque,straight,premultiplied}
    public var width:Int,height:Int
    public var primaries:Primaries = .sRGB
    public var transfer:Transfer = .sRGB
    public var reference:Reference = .display
    public var alphaMode:AlphaMode = .opaque
    public var orientationNormalized=true
    public init(width:Int,height:Int) {self.width=width;self.height=height}
    public func validate() throws {
        _=try ImageDimensions.pixelCount(width:width,height:height)
        guard primaries == .sRGB,transfer == .sRGB,reference == .display,alphaMode == .opaque,orientationNormalized else {
            throw LabError.unsupported("运行入口需要已转为标准方向、不透明、编码 sRGB 的 SDR 成片纹理")
        }
    }
}
