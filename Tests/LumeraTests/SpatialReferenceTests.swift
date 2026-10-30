import XCTest
import ImagingCore
@testable import ImageAnalysis
final class SpatialReferenceTests:XCTestCase {
    func testPointDiffusionAgainstIndependent2DConvolution() throws {
        let renderer=try MetalRenderer(),w=65,h=49,scale=Double(w)/2048
        var input=try ImageFrame.solid(width:w,height:h,value:0)
        for y in 22...26 {for x in 30...34 {for c in 0..<3 {input.pixels[(y*w+x)*4+c]=Float(AcceptanceReference.encode(0.7))}}}
        let linear=(0..<(w*h)).map{AcceptanceReference.decode(Double(input.pixels[$0*4]))}
        for tinted in [false,true] {
            var p=Profile.standard
            if tinted {p.parameters.halation.enabled=true;p.parameters.halation.amount=0.4;p.parameters.halation.sigma=32;p.parameters.halation.threshold=0.5;p.parameters.halation.knee=0.1}
            else {p.parameters.glow.enabled=true;p.parameters.glow.amount=0.4;p.parameters.glow.nearSigma=16;p.parameters.glow.farSigma=32;p.parameters.glow.threshold=0.5;p.parameters.glow.knee=0.1}
            let near=AcceptanceReference.gaussian(linear,width:w,height:h,sigma:(tinted ? 32:16)*scale)
            let far=AcceptanceReference.gaussian(linear,width:w,height:h,sigma:32*scale)
            let out=try renderer.render(input,style:ResolvedStyle(profile:p),request:RenderRequest(input:input.descriptor)).image
            var referenceEnergy=0.0,energy=0.0,maxError=0.0
            var expectedRings=[Double](repeating:0,count:64),actualRings=expectedRings
            for i in 0..<(w*h) {
                let spread=tinted ? far[i]:near[i]*0.75+far[i]*0.25
                let residual=tinted ? max(0,spread-linear[i])*0.4:(spread-linear[i])*0.4
                let expected=linear[i]+residual,actual=AcceptanceReference.decode(Double(out.pixels[i*4]))
                maxError=max(maxError,abs(actual-expected))
                let er=max(0,residual),ar=max(0,actual-linear[i]),r=min(63,Int(hypot(Double(i%w-32),Double(i/w-24))))
                referenceEnergy+=er;energy+=ar;expectedRings[r]+=er;actualRings[r]+=ar
            }
            func halfRadius(_ bins:[Double])->Int {var sum=0.0;let half=bins.reduce(0,+)/2;for (i,v) in bins.enumerated(){sum+=v;if sum>=half{return i}};return bins.count-1}
            XCTAssertLessThan(maxError,0.0002)
            XCTAssertEqual(energy,referenceEnergy,accuracy:max(referenceEnergy*0.02,Double(w*h)*0.000002))
            XCTAssertLessThanOrEqual(abs(halfRadius(expectedRings)-halfRadius(actualRings)),1)
        }
    }
}
