import XCTest
import ImagingCore
@testable import ImagingRuntime
final class ObservationValidityTests: XCTestCase {
    func stamp(_ time:Double = 0,_ index:UInt64 = 0)->FrameStamp { .init(streamID:"s",generation:1,index:index,presentationTime:time,duration:0.1) }
    func requirements()->ObservationRequirements {
        var r = ObservationRequirements(); r.features = [.init(id:"mean",statistic:.meanGreen)]
        r.sourceConditions = [.iso,.whiteBalanceTemperatureKelvin]; r.validity.maxAgeFrames = 2; r.validity.maxAgeSeconds = 0.2
        r.validity.sourceChangeTolerances = [.init(axis:.iso,maxCoordinateDelta:1),.init(axis:.whiteBalanceTemperatureKelvin,maxCoordinateDelta:100)]
        return r
    }
    func packet() throws -> FrameObservations {
        var p = FrameObservations(stamp:stamp(),sourceID:"source",calibrationID:"cal",featureDigest:try requirements().featureDigest())
        p.captureConditions.iso = 100; p.captureConditions.whiteBalanceTemperatureKelvin = 5000
        p.features = [.init(id:"mean",value:0.5)]; return p
    }
    func testDelayedPacketRejectsExposureJumpAndWhiteBalanceJump() throws {
        let p = try packet(); var facts = p.captureConditions; facts.iso = 200
        XCTAssertEqual(try ObservationValidity.validate(p,current:.init(stamp:stamp(0.1,1),inputID:"input",sourceID:p.sourceID,calibrationID:p.calibrationID,effectiveRecipeDigest:String(repeating:"a",count:64),captureConditions:facts),requirements:requirements()),p)
        for axis in [ConditionAxis.iso,.whiteBalanceTemperatureKelvin] {
            facts = p.captureConditions; facts[axis] = axis == .iso ? 201 : 5101
            XCTAssertThrowsError(try ObservationValidity.validate(p,current:.init(stamp:stamp(0.1,1),inputID:"input",sourceID:p.sourceID,calibrationID:p.calibrationID,effectiveRecipeDigest:String(repeating:"a",count:64),captureConditions:facts),requirements:requirements()))
        }
    }
    func testNoMixedTimeFeaturePacketAndSameFrameFactsMustMatch() throws {
        let p = try packet(); var facts = p.captureConditions; facts.iso = 101
        XCTAssertThrowsError(try ObservationValidity.validate(p,current:.init(stamp:p.stamp,inputID:"input",sourceID:p.sourceID,calibrationID:p.calibrationID,effectiveRecipeDigest:String(repeating:"a",count:64),captureConditions:facts),requirements:requirements()))
        let result = try ObservationValidity.validate(p,current:.init(stamp:stamp(0.1,1),inputID:"input",sourceID:p.sourceID,calibrationID:p.calibrationID,effectiveRecipeDigest:String(repeating:"a",count:64),captureConditions:facts),requirements:requirements())
        XCTAssertEqual(result.captureConditions.iso,100); XCTAssertEqual(result.stamp,p.stamp)
    }
    func testIdentityAgeMissingAndUnknownFeatureReject() throws {
        let p = try packet()
        for kind in ["source","cal","stream","generation","age","frames","reverse","facts","features"] {
            var q = p; var now = stamp(0.1,1); var source = p.sourceID; var cal = p.calibrationID; var facts = p.captureConditions
            switch kind { case "source":source = "wrong"; case "cal":cal = "wrong"; case "stream":now.streamID = "wrong"; case "generation":now.generation = 2; case "age":now.presentationTime = 0.3; case "frames":now.index = 3; case "reverse":now.presentationTime = -1; case "facts":facts.iso = nil; default:q.features.append(.init(id:"extra",value:0)) }
            XCTAssertThrowsError(try ObservationValidity.validate(q,current:.init(stamp:now,inputID:"input",sourceID:source,calibrationID:cal,effectiveRecipeDigest:String(repeating:"a",count:64),captureConditions:facts),requirements:requirements()),kind)
        }
    }
}
