import XCTest
import ImagingCore
@testable import ImageAnalysis
final class CaptureQualityTests:XCTestCase {
    func testGPURegionStatisticsAgainstIndependentDoubleReference() throws {
        var image=try ImageFrame.solid(width:128,height:96,value:0)
        var expected=[Double](repeating:0,count:3),square=expected
        for y in 0..<96 {for x in 0..<128 {for c in 0..<3 {
            let value=Float(0.2+0.6*Double((x*13+y*7+c*23)%101)/100)
            image.pixels[(y*128+x)*4+c]=value
            if (32..<96).contains(x) && (24..<72).contains(y) {expected[c]+=Double(value);square[c]+=Double(value)*Double(value)}
        }}}
        let region=TargetRegion(id:"patch",kind:.gray,rect:.init(x:0.25,y:0.25,width:0.5,height:0.5),printedRGB:[])
        let transform=ProjectiveTransform(coefficients:[128,0,0,0,96,0,0,0,1])
        let actual=try MetalRenderer().renderPatchStatistics(image,style:ResolvedStyle(profile:.standard),transform:transform,regions:[region])[0]
        XCTAssertEqual(actual.pixelCount,64*48)
        for c in 0..<3 {
            let mean=expected[c]/Double(64*48),variance=square[c]/Double(64*48)-mean*mean
            XCTAssertEqual(actual.mean[c],mean,accuracy:1e-6);XCTAssertEqual(actual.variance[c],variance,accuracy:1e-6)
        }
    }
    func testQualityRejectsClippingGlareMissingAndWrongConditions() throws {
        let p=try CaptureProtocol(input:.init(id:"a",isoLevels:[100,400,1600],baseExposureSeconds:0.01),target:.init(id:"b",isoLevels:[100,400,1600],baseExposureSeconds:0.01))
        let step=p.steps[0]
        var conditions=CaptureConditions();conditions.iso=step.expectedISO;conditions.exposureDurationSeconds=step.expectedExposureSeconds
        var patches=TargetLayout.composite.regions.map {PatchMeasurement(id:$0.id,kind:$0.kind,mean:[0.4,0.4,0.4],variance:[0.0001,0.0001,0.0001],clippedFraction:0,pixelCount:1000)}
        XCTAssertTrue(CaptureQuality.evaluate(patches:patches,conditions:conditions,step:step).isEmpty)
        XCTAssertFalse(CaptureQuality.evaluate(patches:patches,conditions:.init(),step:step).isEmpty)
        conditions.iso=800;XCTAssertFalse(CaptureQuality.evaluate(patches:patches,conditions:conditions,step:step).isEmpty);conditions.iso=step.expectedISO
        patches[0].clippedFraction=0.1;XCTAssertFalse(CaptureQuality.evaluate(patches:patches,conditions:conditions,step:step).isEmpty)
        patches[0].clippedFraction=0;patches[0].variance=[0.1,0.1,0.1];XCTAssertFalse(CaptureQuality.evaluate(patches:patches,conditions:conditions,step:step).isEmpty)
    }
    func testRequiresExactUniqueRegionSetAndFiniteContract() throws {
        let plan=try CaptureProtocol(input:.init(id:"a",isoLevels:[100,400,1600],baseExposureSeconds:0.01),target:.init(id:"b",isoLevels:[100,400,1600],baseExposureSeconds:0.01))
        var step=plan.steps[0],c=CaptureConditions();c.iso=step.expectedISO;c.exposureDurationSeconds=step.expectedExposureSeconds
        let valid=TargetLayout.composite.regions.map{PatchMeasurement(id:$0.id,kind:$0.kind,mean:[0.4,0.4,0.4],variance:[0,0,0],clippedFraction:0,pixelCount:1000)}
        var wrongKind=valid;wrongKind[0].kind = .light
        var unknown=valid;unknown[0].id="unknown"
        var invalidFraction=valid;invalidFraction[0].clippedFraction = -1
        for bad in [Array(valid.prefix(12)),Array(repeating:valid[0],count:valid.count),wrongKind,unknown,invalidFraction] {
            XCTAssertFalse(CaptureQuality.evaluate(patches:bad,conditions:c,step:step).isEmpty)
        }
        step.expectedISO = .nan
        XCTAssertFalse(CaptureQuality.evaluate(patches:valid,conditions:c,step:step).isEmpty)
        XCTAssertThrowsError(try CaptureProtocol(input:.init(id:"a",isoLevels:[1,2,3],baseExposureSeconds:.greatestFiniteMagnitude),target:plan.target))
    }

}
