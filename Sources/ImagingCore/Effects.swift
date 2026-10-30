import Foundation

public struct Detail: Codable, Equatable, Sendable {
    public var enabled = false
    public var fineSigma = 0.75, midSigma = 2.5, fineGain = 1.0, midGain = 1.0
    public var sharpenSigma = 0.8, sharpenAmount = 0.0, threshold = 0.008, maxAdjustment = 0.015
    public init() {}
}
public struct Vignette: Codable, Equatable, Sendable {
    public var enabled = false
    public var amountEV = 0.0, startRadius = 0.35, falloff = 1.5, centerX = 0.5, centerY = 0.5
    public init() {}
}
public struct Glow: Codable, Equatable, Sendable {
    public var enabled = false
    public var threshold = 0.70, knee = 0.15, nearSigma = 3.0, farSigma = 14.0, farWeight = 0.25, amount = 0.0
    public init() {}
}
public struct Noise: Codable, Equatable, Sendable {
    public var enabled = false
    public var curve=ResponseCurve(function:.init(family:.constant,start:0,end:0))
    /// Overall amplitude multiplier; saturation is applied after evaluating the brightness curve.
    public var gain=1.0
    public func effectiveSigma(at x:Double)->Double {min(0.1,max(0,curve.value(at:x)*gain))}
    public var chromaRatio = 0.15, lumaSigma = 0.65, chromaSigma = 1.3, chromaCorrelation = 0.0
    public init() {}
}
extension Detail { public var isActive: Bool { enabled && (fineGain != 1 || midGain != 1 || sharpenAmount > 0) } }
extension Vignette { public var isActive: Bool { enabled && amountEV > 0 } }
extension Glow { public var isActive: Bool { enabled && amount > 0 } }
extension Noise { public var isActive: Bool { enabled && gain>0 && curve.outputRange.upperBound>0 } }
