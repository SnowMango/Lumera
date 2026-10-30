import Foundation

public struct Chromaticity: Codable, Equatable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x=x; self.y=y }
    public static let d65=Chromaticity(x:0.3127,y:0.3290)
    public func validate() throws {
        guard x.isFinite, y.isFinite, x>0, y>0, x+y<1 else { throw LabError.invalid("白点 xy 必须为有效色度坐标") }
    }
}
public struct WhiteBalanceCorrection: Codable, Equatable, Sendable {
    public var source: Chromaticity, destination: Chromaticity
    public init(source: Chromaticity = .d65, destination: Chromaticity = .d65) {self.source=source;self.destination=destination}
    public func validate() throws {try source.validate();try destination.validate()}
}
public struct ColorMatrix3x3: Codable, Equatable, Sendable {
    public var values: [Double]
    public init(values:[Double] = [1,0,0,0,1,0,0,0,1]) {self.values=values}
    public func validate() throws {
        guard values.count == 9,values.allSatisfy({$0.isFinite && (-4...4).contains($0)}) else {throw LabError.invalid("颜色矩阵需要九个 -4 至 4 的有限数值")}
    }
}
/// Creative opponent-axis channel balance. Not Kelvin, Duv, or camera WB steps.
/// Axes are normalized -1...1; positive R / Y, negative G / B.
/// Log2 weights [2r+y, -2r+y, -2y], normalized by their maximum:
/// gains stay in 1/32...1 across the full square. Strong shifts can darken.
public struct ColorShift: Codable, Equatable, Sendable {
    public var redGreen:Double
    public var yellowBlue:Double
    public init(redGreen:Double=0,yellowBlue:Double=0) {self.redGreen=redGreen;self.yellowBlue=yellowBlue}
    public func validate() throws {
        guard redGreen.isFinite,yellowBlue.isFinite,(-1...1).contains(redGreen),(-1...1).contains(yellowBlue) else {
            throw LabError.invalid("色彩偏移两轴必须在 -1 至 1 范围内")
        }
    }
    public var linearGains:[Double] {
        let weights=[2*redGreen+yellowBlue,-2*redGreen+yellowBlue,-2*yellowBlue]
        let maximum=weights.max()!
        return weights.map{pow(2,$0-maximum)}
    }
}
public struct ColorResponse: Codable, Equatable, Sendable {
    public var shift=ColorShift()
    public var exposureEV=0.0
    public var whiteBalance=WhiteBalanceCorrection()
    public var matrix=ColorMatrix3x3()
    public init() {}
    public var isActive: Bool {shift != ColorShift() || exposureEV != 0 || whiteBalance.source != whiteBalance.destination || matrix != ColorMatrix3x3()}
    public func validate(resolved:Bool = false) throws {
        guard exposureEV.isFinite, (resolved ? -6.0...6.0 : -3.0...3.0).contains(exposureEV) else {throw LabError.invalid("曝光超出允许范围")}
        try shift.validate();try whiteBalance.validate();try matrix.validate()
    }
}
