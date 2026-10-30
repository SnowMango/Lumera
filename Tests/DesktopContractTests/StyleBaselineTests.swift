import XCTest
import Foundation
import ImagingCore
import ImageAnalysis

/// Optional capture of the pre-response implementation, NOT an independent oracle.
final class StyleBaselineTests:XCTestCase {
    func testCaptureReplayableBaseline() throws {
        guard let destination=ProcessInfo.processInfo.environment["LUMERA_BASELINE_OUTPUT"] else {throw XCTSkip("Set LUMERA_BASELINE_OUTPUT to capture a versioned baseline")}
        let renderer=try MetalRenderer()
        var rows=[[String:Any]](), profiles=[[String:Any]]()
        for name in StylePresets.names {
            var p=try StylePresets.make(name);p.id="baseline-"+name
            profiles.append(["name":name,"schemaVersion":p.schemaVersion,"effectSHA256":try p.effectDigest(),"profile":try JSONSerialization.jsonObject(with:JSON.encode(p))])
            for fixture in Fixture.allCases {
                let input=try Fixtures.make(fixture,width:512,height:384)
                let output=try renderer.renderStyle(input,profile:p,seed:42).image
                XCTAssertTrue(output.pixels.allSatisfy(\.isFinite))
                var sum=0.0,sum2=0.0,maxDelta=0.0,gradient=0.0
                for y in 0..<output.height {for x in 0..<output.width {
                    let i=(y*output.width+x)*4,v=Double(output.pixels[i]);sum+=v;sum2+=v*v
                    for c in 0..<3 {maxDelta=max(maxDelta,abs(Double(output.pixels[i+c]-input.pixels[i+c])))}
                    if x>0 {gradient+=abs(v-Double(output.pixels[i-4]))}
                }}
                let n=Double(output.width*output.height),mean=sum/n
                rows.append(["preset":name,"fixture":fixture.rawValue,"width":output.width,"height":output.height,"seed":42,"frameIndex":0,"meanR":mean,"stddevR":sqrt(max(0,sum2/n-mean*mean)),"meanHorizontalDifferenceR":gradient/Double((output.width-1)*output.height),"maxAbsChangeRGB":maxDelta])
                if name=="standard" {XCTAssertLessThanOrEqual(maxDelta,0.00001)}
            }
        }
        let report:[String:Any]=["engineVersion":Profile.engineVersion,"kind":"regression baseline, not independent truth","environment":ProcessInfo.processInfo.operatingSystemVersionString,"profiles":profiles,"metrics":rows]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:destination))
    }
}
