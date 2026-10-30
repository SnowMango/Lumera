import XCTest
import ImagingCore
@testable import ImageRendering
final class ColorShiftTests:XCTestCase {
    func testNeutralAxesAndFullRange() throws {
        XCTAssertEqual(ColorShift().linearGains,[1,1,1])
        for r in stride(from:-1.0,through:1.0,by:0.1) {
            for y in stride(from:-1.0,through:1.0,by:0.1) {
                let s=ColorShift(redGreen:r,yellowBlue:y);try s.validate()
                let g=s.linearGains
                XCTAssertTrue(g.allSatisfy{$0.isFinite && $0>=1.0/32-1e-12 && $0<=1})
                XCTAssertEqual(g.max()!,1)
            }
        }
        XCTAssertEqual(ColorShift(redGreen:1,yellowBlue:1).linearGains,[1,1.0/16,1.0/32])
        XCTAssertEqual(ColorShift(redGreen:0,yellowBlue:1).linearGains,[1,1,1.0/8])
        XCTAssertEqual(ColorShift(redGreen:1,yellowBlue:0).linearGains,[1,1.0/16,1.0/4])
        XCTAssertThrowsError(try ColorShift(redGreen:1.001,yellowBlue:0).validate())
        XCTAssertThrowsError(try ColorShift(redGreen:0,yellowBlue:.nan).validate())
    }
    func testPersistenceDigestAndIndependentCorrection() throws {
        var p=Profile();let before=try p.effectDigest()
        p.parameters.color.shift = .init(redGreen:-0.6,yellowBlue:0.8)
        let restored=try JSONDecoder().decode(Profile.self,from:JSON.encode(p))
        XCTAssertEqual(restored,p);XCTAssertNotEqual(try p.effectDigest(),before)
        XCTAssertEqual(p.parameters.color.whiteBalance,WhiteBalanceCorrection())
        XCTAssertEqual(p.parameters.color.matrix,ColorMatrix3x3())
        XCTAssertTrue(p.parameters.color.isActive)
        p.parameters.color.shift = .init();XCTAssertEqual(try p.effectDigest(),before)
    }
    func testGPUCornersAxesAndBlack() throws {
        let h=try RenderHarness(precision:.float32)
        for r in [-1.0,0,1] {for y in [-1.0,0,1] {
            var p=Profile();p.parameters.color.shift = .init(redGreen:r,yellowBlue:y)
            for value:Float in [0,0.5,1] {
                let out=try h.render(p,width:4,height:4,value:value)
                let v=Double(value),linear=v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)
                let logs=[2*r+y,-2*r+y,-2*y],top=logs.max()!
                for i in 0..<3 {
                    let x=linear*pow(2,logs[i]-top)
                    let expected=x<=0.0031308 ? 12.92*x:1.055*pow(x,1/2.4)-0.055
                    XCTAssertEqual(Double(out[i]),expected,accuracy:0.0001)
                }
            }
        }}
    }
    func testGPUShiftBetweenWhiteBalanceMatrixAndLUT() throws {
        let h=try RenderHarness(precision:.float32)
        var p=Profile();p.parameters.color.whiteBalance.destination = .init(x:0.3457,y:0.3585)
        p.parameters.color.matrix.values=[0,1,0,0,0,1,1,0,0]
        p.parameters.color.shift = .init(redGreen:1,yellowBlue:1)
        var cube=["LUT_3D_SIZE 2"]
        for b in 0...1 {for g in 0...1 {for r in 0...1 {cube.append("\(b) \(r) \(g)")}}}
        let lut = LUTAsset(name:"channel permutation",cubeText:cube.joined(separator:"\n"))
        let actual=try h.render(p,width:4,height:4,value:0.5,lut:lut)
        // Independent D50 XYZ -> linear sRGB white, followed by explicit channel operations.
        let x=0.3457/0.3585,z=(1-0.3457-0.3585)/0.3585
        let white=[3.2409699419*x-1.5373831776-0.4986107603*z,
                   -0.9692436363*x+1.8759675015+0.0415550574*z,
                   0.0556300797*x-0.2039769589+1.0569715142*z]
        let linear=pow((0.5+0.055)/1.055,2.4)
        let shifted=[white[1]*linear,white[2]*linear/16,white[0]*linear/32]
        let encoded=shifted.map {v in v<=0.0031308 ? v*12.92:1.055*pow(v,1/2.4)-0.055}
        let expected=[encoded[2],encoded[0],encoded[1]]
        for i in 0..<3 {XCTAssertEqual(Double(actual[i]),expected[i],accuracy:0.0001)}
    }
    func testShiftFollowsMatrix() throws {
        var c=ColorResponse();c.matrix.values=[0,1,0,0,0,1,1,0,0]
        c.shift = .init(redGreen:1,yellowBlue:1)
        let out=try ColorTransform.prepare(c).apply([0.2,0.4,0.6])
        XCTAssertEqual(out[0],0.4,accuracy:1e-12)
        XCTAssertEqual(out[1],0.6/16,accuracy:1e-12)
        XCTAssertEqual(out[2],0.2/32,accuracy:1e-12)
    }
}
