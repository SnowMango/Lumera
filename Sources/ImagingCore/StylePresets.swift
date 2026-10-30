import Foundation

/// Original demonstration values, not measurements or replicas of named cameras.
public enum StylePresets {
    public static let names=["standard","digital-demo","film-demo"]
    public static func make(_ name:String) throws -> Profile {
        var p=Profile.standard
        switch name {
        case "standard":return p
        case "digital-demo":
            p.id="digital-demo";p.name="数码质感示例";p.description="原创演示参数；未标定到具体相机。"
            p.parameters.tone.enabled=true;p.parameters.tone.curve = .init(knots:zip([0.0,0.25,0.5,0.75,1],[0,0.22,0.5,0.79,1]).map{.init(x:$0,y:$1)},interpolation:.smooth)
            p.parameters.detail.enabled=true;p.parameters.detail.fineGain=0.88;p.parameters.detail.midGain=0.96;p.parameters.detail.sharpenAmount=0.2
            p.parameters.vignette.enabled=true;p.parameters.vignette.amountEV=0.3
            p.parameters.glow.enabled=true;p.parameters.glow.amount=0.08
            p.parameters.noise.enabled=true;p.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],[0.012,0.008,0.004,0.002,0.001]).map{.init(x:$0,y:$1)})
        case "film-demo":
            p.id="film-demo";p.name="胶片质感示例";p.description="原创演示参数；不是胶片乳剂的物理模拟或具体胶片复刻。"
            p.parameters.tone.enabled=true;p.parameters.tone.curve = .init(knots:zip([0.0,0.25,0.5,0.75,1],[0.025,0.23,0.5,0.78,0.97]).map{.init(x:$0,y:$1)},interpolation:.smooth)
            p.parameters.softening.enabled=true;p.parameters.softening.amount=0.2;p.parameters.softening.sigma=1.4
            p.parameters.grain.enabled=true;p.parameters.grain.amount=0.018;p.parameters.grain.size=1.2
            p.parameters.vignette.enabled=true;p.parameters.vignette.amountEV=0.25
            p.parameters.glow.enabled=true;p.parameters.glow.amount=0.06
            p.parameters.halation.enabled=true;p.parameters.halation.amount=0.12
        default:throw LabError.invalid("Unknown preset: \(name). Choose \(names.joined(separator:", "))")
        }
        try p.validate();return p
    }
}
