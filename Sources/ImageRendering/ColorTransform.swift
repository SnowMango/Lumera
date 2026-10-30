import Foundation
import ImagingCore

/// Row-major matrix for linear sRGB. No clipping: bounded LUT/tone and final output own that decision.
public struct PreparedColorTransform:Sendable {
    public let exposureMultiplier:Double
    public let matrix:[Double]
    /// Conservative linear-channel bound for normalized input.
    public var maximumGain:Double {
        var bound=0.0
        for row in 0..<3 {
            let sum=abs(matrix[row*3])+abs(matrix[row*3+1])+abs(matrix[row*3+2])
            bound=max(bound,sum*exposureMultiplier)
        }
        return bound
    }
    public var uniforms:[Float] {[Float(exposureMultiplier)]+matrix.map(Float.init)}
    public func apply(_ rgb:[Double])->[Double] {
        precondition(rgb.count==3)
        return (0..<3).map { row in (0..<3).reduce(0.0) {$0 + matrix[row*3+$1]*rgb[$1]} * exposureMultiplier }
    }
}
public enum ColorTransform {
    // sRGB primaries / D65, W3C CSS Color 4 §19. Row-major, column vectors.
    // https://www.w3.org/TR/css-color-4/#color-conversion-code
    private static let rgbToXYZ:[Double]=[506752.0/1228815,87881.0/245763,12673.0/70218,
        87098.0/409605,175762.0/245763,12673.0/175545,7918.0/409605,87881.0/737289,1001167.0/1053270]
    private static let xyzToRGB:[Double]=[12831.0/3959,-329.0/214,-1974.0/3959,
        -851781.0/878810,1648619.0/878810,36519.0/878810,705.0/12673,-2585.0/12673,705.0/667]
    // ICC.1:2022 Annex E.3, equations E.1–E.4 (linearized Bradford).
    // https://www.color.org/specifications/ICC.1-2022-05.pdf
    private static let bradford:[Double]=[0.8951,0.2664,-0.1614,-0.7502,1.7135,0.0367,0.0389,-0.0685,1.0296]
    public static func prepare(_ color:ColorResponse) throws -> PreparedColorTransform {
        try color.validate(resolved:true)
        let source=try cone(color.whiteBalance.source),destination=try cone(color.whiteBalance.destination)
        var adapted=ColorMatrix3x3().values
        if color.whiteBalance.source != color.whiteBalance.destination {
            let ratio=zip(destination,source).map(/)
            let diagonal=[ratio[0],0,0,0,ratio[1],0,0,0,ratio[2]]
            adapted=multiply(xyzToRGB,multiply(inverse(bradford),multiply(diagonal,multiply(bradford,rgbToXYZ))))
        }
        let gains=color.shift.linearGains
        let shift=[gains[0],0,0,0,gains[1],0,0,0,gains[2]]
        let combined=multiply(shift,multiply(color.matrix.values,adapted)),exposure=pow(2,color.exposureEV)
        guard combined.allSatisfy({$0.isFinite && Float($0).isFinite && Float($0*exposure).isFinite}) else {
            throw LabError.invalid("白点产生无法表示的颜色变换，请选择有效光源白点")
        }
        return PreparedColorTransform(exposureMultiplier:exposure,matrix:combined)
    }
    private static func cone(_ xy:Chromaticity) throws -> [Double] {
        let xyz=[xy.x/xy.y,1,(1-xy.x-xy.y)/xy.y]
        let result=(0..<3).map { row in (0..<3).reduce(0.0){$0+bradford[row*3+$1]*xyz[$1]} }
        guard result.allSatisfy({$0.isFinite && $0>1e-12}) else {throw LabError.invalid("白点无法形成有效的 Bradford 锥体响应")}
        return result
    }
    private static func multiply(_ a:[Double],_ b:[Double])->[Double] {
        (0..<9).map { index in (0..<3).reduce(0.0) {$0+a[(index/3)*3+$1]*b[$1*3+index%3]} }
    }
    private static func inverse(_ a:[Double])->[Double] {
        let c=[a[4]*a[8]-a[5]*a[7],a[2]*a[7]-a[1]*a[8],a[1]*a[5]-a[2]*a[4],
               a[5]*a[6]-a[3]*a[8],a[0]*a[8]-a[2]*a[6],a[2]*a[3]-a[0]*a[5],
               a[3]*a[7]-a[4]*a[6],a[1]*a[6]-a[0]*a[7],a[0]*a[4]-a[1]*a[3]]
        let determinant=a[0]*c[0]+a[1]*c[3]+a[2]*c[6]
        return c.map{$0/determinant}
    }
}
