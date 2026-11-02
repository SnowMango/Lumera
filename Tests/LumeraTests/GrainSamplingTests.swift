import XCTest
import ImagingCore
@testable import ImageAnalysis

final class GrainSamplingTests: XCTestCase {
    func testSinglePixelIntegratesWorstSpacingWithoutSerialLatticeTraversal() throws {
        let renderer = try MetalRenderer()
        let single = try ImageFrame.solid(width:1,height:1,value:0.5)
        let large = try ImageFrame.solid(width:256,height:256,value:0.5)
        var profile = Profile.standard
        profile.parameters.grain.enabled = true
        profile.parameters.grain.size = 0.5
        profile.parameters.grain.roughness = 0.99999
        profile.parameters.grain.amount = 0.1
        let style = try ResolvedStyle(profile:profile)
        let coarse = try renderer.render(single,style:style,request:.init(input:single.descriptor)).image
        let fine = try renderer.render(large,style:style,request:.init(input:large.descriptor)).image
        let expected = try GrainSamplingReference.sample(footprint:CGRect(x:0,y:0,width:2048,height:2048),seed:42,parameters:profile.parameters.grain)
        let envelope = profile.parameters.grain.luminanceCurve.value(at:0.5)
        for c in 0..<3 {
            XCTAssertEqual(Double(coarse.pixels[c]),0.5+envelope*expected[c],accuracy:1e-4)
            let mean = stride(from:c,to:fine.pixels.count,by:4).reduce(0.0){$0+Double(fine.pixels[$1])}/Double(large.width*large.height)
            XCTAssertEqual(Double(coarse.pixels[c]),mean,accuracy:1e-4)
        }
    }

    func testAreaReducedGPUFieldAndDoubleReference() throws {
        let renderer = try MetalRenderer()
        for width in [512,1024] {
            let source = try ImageFrame.solid(width:width,height:32,value:0.5)
            let reduced = try ImageFrame.solid(width:width/2,height:16,value:0.5)
            for size in [0.5,1,4,8] as [Double] { for roughness in [0,0.35,1] as [Double] {
                var profile = Profile.standard
                profile.parameters.grain.enabled = true
                profile.parameters.grain.amount = 0.02
                profile.parameters.grain.size = size
                profile.parameters.grain.roughness = roughness
                profile.parameters.grain.chroma = 0.5
                profile.parameters.grain.luminanceCurve = .init(function:.init(family:.constant,start:1,end:1))
                let style = try ResolvedStyle(profile:profile)
                let full = try renderer.render(source,style:style,request:.init(input:source.descriptor)).image
                let small = try renderer.render(reduced,style:style,request:.init(input:reduced.descriptor)).image
                let reference = try GrainSamplingReference(parameters:profile.parameters.grain)
                var ff = 0.0, ss = 0.0, fs = 0.0
                let footprint = 2048/Double(small.width)
                for y in 0..<small.height { for x in 0..<small.width {
                    let i = (y*small.width+x)*4
                    let s = Double(small.pixels[i])-0.5
                    var f = 0.0
                    for dy in 0...1 { for dx in 0...1 {
                        f += (Double(full.pixels[((2*y+dy)*width+2*x+dx)*4])-0.5)/4
                    }}
                    ff += f*f
                    ss += s*s
                    fs += f*s
                    if y%5==0 && x%31==0 {
                        let expected = try reference.sample(footprint:CGRect(x:Double(x)*footprint,y:Double(y)*footprint,
                                                                             width:footprint,height:footprint),seed:42)
                        for c in 0..<3 { XCTAssertEqual(Double(small.pixels[i+c]),0.5+expected[c],accuracy:1e-4) }
                    }
                }}
                XCTAssertGreaterThanOrEqual(fs/sqrt(ff*ss),0.95)
                XCTAssertTrue((0.9...1.1).contains(sqrt(ff/ss)))
            }}
        }
    }
}
