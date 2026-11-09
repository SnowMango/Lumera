import XCTest
import ImagingCore
@testable import ImageAnalysis

final class GenerationCoordinatorDependencyTests:XCTestCase {
    private func eligibility(_ ids:[AlgorithmID])throws->GenerationEligibility {
        let rows=ids.flatMap { id in GenerationLimits.cases(for:id).map { AlgorithmCaseResult(algorithm:id,caseID:$0.caseID,status:.passed,measured:0,limit:$0,detail:"test evidence") } }
        return try GenerationEligibility(report:.init(gpu:"test",elapsedSeconds:0,results:rows),required:ids)
    }
    func testInvalidEligibilityDoesNotCreateContext() async throws {
        var calls=0
        do {
            _=try await GenerationCoordinator.generate(captures:.init(protocolVersion:"capture-draft-1",records:[],issues:[]),baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init(),eligibility:eligibility([.independentLUT]),makeContext:{ calls += 1; throw LabError.noMetal })
            XCTFail("Insufficient qualification must reject")
        } catch { XCTAssertEqual(calls,0) }
    }
    func testContextConstructionFailureDoesNotProduceProposal() async throws {
        var calls=0
        let ids=Array(GenerationCoordinator.requiredAlgorithms(for:[.detail]))
        do {
            _=try await GenerationCoordinator.generate(captures:.init(protocolVersion:"capture-draft-1",records:[],issues:[]),baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init(),eligibility:eligibility(ids),makeContext:{ calls += 1; throw LabError.noMetal })
            XCTFail("No proposal without execution resources")
        } catch { XCTAssertEqual(calls,1) }
    }
    func testStageBoundaryRejectsReplacedFileEvenWithOriginalModificationDate() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer{try? FileManager.default.removeItem(at:url)}
        let old=try ImageCodec.encodeReference(ImageFrame.solid(width:8,height:8,value:0.2));try old.write(to:url)
        let date=try XCTUnwrap(FileManager.default.attributesOfItem(atPath:url.path)[.modificationDate] as? Date)
        var frame=try ColorReferenceSamples.make().frames[0];frame.sourceURL=url;frame.width=8;frame.height=8;frame.fileDigest=Digest.data(old)
        let images=GenerationImages();_=try images.load(frame)
        try ImageCodec.encodeReference(ImageFrame.solid(width:8,height:8,value:0.6)).write(to:url)
        try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:url.path)
        images.releaseCaches()
        XCTAssertThrowsError(try images.load(frame))
    }
}
