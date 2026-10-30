import Foundation

/// RGB master function/custom curve in encoded sRGB, after LUT.
public struct ToneResponse: Codable, Equatable, Sendable {
    public var enabled=false
    public var curve=ResponseCurve.identity
    public init() {}
    public var isActive:Bool {enabled && curve.knots.contains(where:{$0.x != $0.y})}
}
/// Linear-light RGB diffusion; independent from luminance frequency-band contrast.
public struct Softening: Codable, Equatable, Sendable {
    public var enabled=false
    public var amount=0.0, sigma=1.5
    public init() {}
    public var isActive:Bool {enabled && amount>0}
}
/// Procedural correlated grain, not a physical silver-halide emulsion simulation.
public struct FilmGrain: Codable, Equatable, Sendable {
    public var enabled=false
    public var amount=0.0, size=1.0, roughness=0.35, chroma=0.15
    public var luminanceCurve=ResponseCurve.grainDefault
    public init() {}
    public var isActive:Bool {enabled && amount>0}
}
/// Tinted bright-edge diffusion approximation, independent of neutral highlight bloom.
public struct Halation: Codable, Equatable, Sendable {
    public var enabled=false
    public var amount=0.0, sigma=4.0, threshold=0.7, knee=0.15
    public var red=1.0, green=0.2, blue=0.04
    public init() {}
    public var isActive:Bool {enabled && amount>0 && red+green+blue>0}
}

extension ParameterDescriptor {
    public static var cameraEffects:[ParameterDescriptor] {[
        .init("softening.amount","柔化强度","softening",\.softening.amount,0...1),
        .init("softening.sigma","柔化尺度 / px","softening",\.softening.sigma,0.1...8),
        .init("grain.amount","胶片颗粒强度","grain",\.grain.amount,0...0.1),
        .init("grain.size","胶片颗粒尺度 / px","grain",\.grain.size,0.5...8),
        .init("grain.roughness","粗颗粒占比","grain",\.grain.roughness,0...1),
        .init("grain.chroma","颗粒彩色比例","grain",\.grain.chroma,0...1),
        .init("halation.amount","染色光晕强度","halation",\.halation.amount,0...1),
        .init("halation.sigma","染色扩散尺度 / px","halation",\.halation.sigma,0.1...32),
        .init("halation.threshold","染色亮源门槛","halation",\.halation.threshold,0...1),
        .init("halation.knee","染色门槛过渡半宽","halation",\.halation.knee,0.001...0.5),
        .init("halation.red","光晕红色分量","halation",\.halation.red,0...1),
        .init("halation.green","光晕绿色分量","halation",\.halation.green,0...1),
        .init("halation.blue","光晕蓝色分量","halation",\.halation.blue,0...1)
    ]}
}
