import XCTest
import Metal
import ImagingCore
@testable import ImageRendering

final class EffectPipelineTests:XCTestCase {
    func testStagesMatchEncoderForActiveStyle() throws {
        let h=try RenderHarness(precision:.float32),input=try h.texture(width:41,height:29)
        let style=try ResolvedStyle(profile:StylePresets.make("film-demo"))
        let color=try ColorTransform.prepare(style.parameters.color)
        let geometry=RenderGeometry(fullWidth:41,fullHeight:29,area:CGRect(x:0,y:0,width:41,height:29),sourceWidth:41,sourceHeight:29,sourceArea:CGRect(x:0,y:0,width:41,height:29))
        let request=RenderRequest(input:InputDescriptor(width:41,height:29))
        let command=try XCTUnwrap(h.queue.makeCommandBuffer())
        let arena=Arena(device:h.device);arena.configure(width:41,height:29,limit:nil,format:.rgba32Float)
        let backend=RealtimeEffectBackend(arena:arena,pipelines:h.encoder.pipelines,commandBuffer:command,geometry:nil,frameGeometry:geometry)
        let frame=EffectFrame(executionPlan:PreparedExecutionPlan(parameters:style.parameters,color:color),parameters:style.parameters,color:color,curves:PreparedResponseCurves(style.parameters),lut:nil,lutBoundaryPolicy:.automatic,correction:nil,temporal:style.temporalPolicy,request:request,geometry:geometry)
        let pipeline=EffectPipeline(backend:backend,frame:frame)
        let output=try pipeline.encodeSuffix(pipeline.encodePrefix(pipeline.prepareInput(input)))
        command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
        let actual=RenderHarness.read(output)
        let expected=RenderHarness.read(try h.encode(input,h.encoder.prepare(style),request))
        XCTAssertEqual(actual,expected)
    }
}
