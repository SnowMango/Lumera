import XCTest
import ImagingCore
@testable import ImageAnalysis
final class GenerationCoordinatorTests:XCTestCase {
    func testImportReadsMetadataAndDigestWithoutRendering()throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png");defer{try? FileManager.default.removeItem(at:url)}
        let data=try ImageCodec.encodeReference(ImageFrame.solid(width:32,height:32,value:0.3));try data.write(to:url)
        let file=try GenerationInputReader.read(url,role:.input,target:.composite)
        XCTAssertEqual(file.digest,Digest.data(data));XCTAssertNil(file.conditions.iso)
        XCTAssertEqual(file.role,.input);XCTAssertEqual(file.target,.composite)
    }
    func testIncompleteEligibilityBlocksBeforeOpeningAnyPhoto()async throws {
        let report=try await GenerationCheck.run(algorithms:[.independentLUT]),eligibility=try GenerationEligibility(report:report,required:[.independentLUT])
        do {
            _=try await GenerationCoordinator.generate(captures:ConditionDeveloperCheck.captures(),baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init(),eligibility:eligibility)
            XCTFail("Incomplete qualification cannot generate")
        }catch{XCTAssertTrue(error.localizedDescription.contains("自检资格"),error.localizedDescription)}
    }
    func testSelectedModulesDoNotRequireUnusedPhotoFamilies()throws {
        let all=try ConditionDeveloperCheck.captures(),plan=try CaptureProtocol(input:.init(id:"a",isoLevels:[100,400,1600],baseExposureSeconds:0.01),target:.init(id:"b",isoLevels:[200,800,3200],baseExposureSeconds:0.01))
        let files=all.records.filter{$0.step.target == .composite}.map{CaptureFile(url:$0.url,digest:$0.fileDigest,role:$0.step.role,target:$0.step.target,conditions:$0.actualConditions)}
        let set=CaptureGrouping.group(files:files,protocol:plan,targets:[.composite])
        XCTAssertTrue(set.canMeasure);XCTAssertEqual(set.records.count,54)
    }
    func testEmptyOrMalformedCaptureSetCannotPrepare()throws {
        XCTAssertThrowsError(try GenerationPreparation.prepare(captures:.init(protocolVersion:"old",records:[],issues:[]),resources:.init()))
    }
    func testRestoredCandidateAlsoRequiresCurrentQualificationBeforeDecode()async throws {
        let report=try await GenerationCheck.run(algorithms:[.independentLUT]),eligibility=try GenerationEligibility(report:report,required:[.independentLUT])
        let candidate=GenerationProposal(profile:.standard,evidence:[],unresolved:[],resourceDigests:[:],validatedModules:[.detail])
        do {
            _=try await GenerationCoordinator.revalidate(candidate:candidate,captures:ConditionDeveloperCheck.captures(),baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init(),eligibility:eligibility)
            XCTFail("Restoration cannot grant eligibility")
        }catch{XCTAssertTrue(error.localizedDescription.contains("自检资格"),error.localizedDescription)}
    }
}
