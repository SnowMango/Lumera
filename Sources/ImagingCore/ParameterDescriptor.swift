import Foundation

public struct ParameterDescriptor {
    public let id: String, title: String, module: String
    public let keyPath: WritableKeyPath<StyleParameters, Double>
    public let range: ClosedRange<Double>
    public var defaultValue: Double { StyleParameters()[keyPath:keyPath] }
    public var scope: String { "style" }
    public var unit: String { id.contains("whiteBalance") ? "CIE xy" : id.contains("matrix") ? "linear RGB coefficient" : title.contains("/ px") ? "px at long edge 2048" : title.contains("/ EV") ? "EV" : "normalized" }
    public var dependencies: String {
        switch module {
        case "detail", "softening": return "与柔化、细节、锐化及输入已有处理相关"
        case "noise", "grain": return "新增质感；不消除输入已有噪点或颗粒"
        case "glow", "halation": return "受亮源强度、色调和空间尺度影响"
        default: return "按固定渲染顺序处理"
        }
    }
    public init(_ id: String, _ title: String, _ module: String, _ keyPath: WritableKeyPath<StyleParameters,Double>, _ range: ClosedRange<Double>) {
        self.id = id; self.title = title; self.module = module; self.keyPath = keyPath; self.range = range
    }
    public static var colorControls:[ParameterDescriptor] { [
        .init("color.whiteBalance.source.x","源白点 x","color",\.color.whiteBalance.source.x,0...1),
        .init("color.whiteBalance.source.y","源白点 y","color",\.color.whiteBalance.source.y,0...1),
        .init("color.whiteBalance.destination.x","目标白点 x","color",\.color.whiteBalance.destination.x,0...1),
        .init("color.whiteBalance.destination.y","目标白点 y","color",\.color.whiteBalance.destination.y,0...1)
    ] + (0..<9).map { i in .init("color.matrix.\(i)","颜色矩阵 [\(i/3+1), \(i%3+1)]","color",\StyleParameters.color.matrix.values[i],-4...4) } }
    public static var shiftControls:[ParameterDescriptor] { [
        .init("color.shift.redGreen","红绿轴 / normalized","color",\.color.shift.redGreen,-1...1),
        .init("color.shift.yellowBlue","黄蓝轴 / normalized","color",\.color.shift.yellowBlue,-1...1)
    ] }
    public static var all: [ParameterDescriptor] { [
        .init("color.exposureEV", "映射前曝光 / EV", "color", \.color.exposureEV, -3...3),
        .init("detail.fineSigma", "细纹理尺度 / px", "detail", \.detail.fineSigma, 0.1...8),
        .init("detail.midSigma", "中纹理尺度 / px", "detail", \.detail.midSigma, 0.1...16),
        .init("detail.fineGain", "细纹理强度", "detail", \.detail.fineGain, 0...1.5),
        .init("detail.midGain", "中纹理强度", "detail", \.detail.midGain, 0...1.5),
        .init("detail.sharpenSigma", "锐化范围 / px", "detail", \.detail.sharpenSigma, 0.1...8),
        .init("detail.sharpenAmount", "锐化强度", "detail", \.detail.sharpenAmount, 0...1),
        .init("detail.threshold", "锐化阈值", "detail", \.detail.threshold, 0...0.1),
        .init("detail.maxAdjustment", "锐化亮度限幅", "detail", \.detail.maxAdjustment, 0...0.05),
        .init("vignette.amountEV", "最大压暗 / EV", "vignette", \.vignette.amountEV, 0...2),
        .init("vignette.startRadius", "暗角起始位置", "vignette", \.vignette.startRadius, 0...0.95),
        .init("vignette.falloff", "暗角衰减指数", "vignette", \.vignette.falloff, 0.25...4),
        .init("vignette.centerX", "中心横向位置", "vignette", \.vignette.centerX, 0...1),
        .init("vignette.centerY", "中心纵向位置", "vignette", \.vignette.centerY, 0...1),
        .init("glow.threshold", "亮源亮度门槛", "glow", \.glow.threshold, 0...1),
        .init("glow.knee", "亮度过渡半宽", "glow", \.glow.knee, 0.001...0.5),
        .init("glow.nearSigma", "近光晕范围 / px", "glow", \.glow.nearSigma, 0.1...32),
        .init("glow.farSigma", "远光晕范围 / px", "glow", \.glow.farSigma, 0.1...64),
        .init("glow.farWeight", "远光晕占比", "glow", \.glow.farWeight, 0...1),
        .init("glow.amount", "光晕强度", "glow", \.glow.amount, 0...1),
        .init("noise.chromaRatio", "彩色噪点比例", "noise", \.noise.chromaRatio, 0...1),
        .init("noise.lumaSigma", "明暗颗粒大小 / px", "noise", \.noise.lumaSigma, 0...4),
        .init("noise.chromaSigma", "彩色颗粒大小 / px", "noise", \.noise.chromaSigma, 0...6),
        .init("noise.chromaCorrelation", "彩色噪点关联度", "noise", \.noise.chromaCorrelation, -0.95...0.95)
    ] + cameraEffects + colorControls + shiftControls }
}
