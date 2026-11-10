import XCTest
import Foundation
import CoreImage
import Metal
import ImagingCore
@testable import ImageRendering

/// Synthetic numeric comparisons, not measured camera fidelity or phone performance.
/// End-to-end error includes input storage and every selected render stage.
final class PrecisionRegressionTests: XCTestCase {
    private let width = 33, height = 17
    private struct Fixture {
        let id: String
        let rgb: [SIMD3<Float>]
        let parameters: StyleParameters
        let maxError: Double
        let meanError: Double
        var identityHDR = false
    }
    private struct Measurement {
        let pixels: [Float]
        let inputPixels: [Float]

    }
    private func grid(_ value:(Int,Int)->SIMD3<Float>) -> [SIMD3<Float>] {
        (0..<height).flatMap { y in (0..<width).map { x in value(x,y) } }
    }
    private func fixtures() -> [Fixture] {
        let ramp = grid { x,_ in SIMD3(repeating:-0.25 + 4.25 * Float(x)/Float(self.width-1)) }
        var color = StyleParameters()
        color.color.exposureEV = 0.2
        color.color.matrix.values = [1.02,-0.01,-0.01,-0.005,1.01,-0.005,0.01,-0.01,1]
        let dark = grid { x,y in
            let v = 0.00001 + 0.04 * Float(x+y)/Float(self.width+self.height-2)
            return SIMD3(v,v*0.8,v*0.5)
        }
        let patches: [SIMD3<Float>] = [SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(0,0,1),SIMD3(1,1,0),
            SIMD3(1,0,1),SIMD3(0,1,1),SIMD3(0.82,0.57,0.43),SIMD3(0.42,0.25,0.17),SIMD3(0.96,0.79,0.66)]
        let patchGrid = grid { x,y in patches[(x/4+y/6)%patches.count] }
        let pattern = grid { x,y in
            let v:Float = (x/2+y/2)%2 == 0 ? 0.08 : 0.9
            return x == self.width/2 ? SIMD3(1,0.4,0.1) : SIMD3(repeating:v)
        }
        var detail = StyleParameters(); detail.detail.enabled = true
        detail.detail.fineGain = 1.15; detail.detail.midGain = 0.9; detail.detail.sharpenAmount = 0.1
        var layered = color; layered.detail = detail.detail
        layered.glow.enabled = true; layered.glow.amount = 0.12
        layered.glow.nearSigma = 1; layered.glow.farSigma = 3
        layered.halation.enabled = true; layered.halation.amount = 0.08; layered.halation.radius = 2
        let lights = grid { x,y in
            if (x-16)*(x-16)+(y-8)*(y-8) <= 9 { return SIMD3(4,2,1.2) }
            if x%9 == 0 { return SIMD3(1.3,0.5,0.1) }
            let v = Float(x+y)/Float(self.width+self.height-2)*0.3
            return SIMD3(v*0.7,v,v*0.8)
        }
        // Gates are fixed synthetic engineering thresholds, not just-noticeable differences.
        return [
            .init(id:"hdr-identity-ramp",rgb:ramp,parameters:.init(),maxError:0.005,meanError:0.001,identityHDR:true),
            .init(id:"hdr-color-transform",rgb:ramp,parameters:color,maxError:0.005,meanError:0.001),
            .init(id:"dark-gradient",rgb:dark,parameters:color,maxError:0.001,meanError:0.0001),
            .init(id:"saturated-and-skin-like-patches",rgb:patchGrid,parameters:color,maxError:0.005,meanError:0.001),
            .init(id:"detail-checker-edge",rgb:pattern,parameters:detail,maxError:0.005,meanError:0.001),
            .init(id:"color-detail-glow-halation",rgb:lights,parameters:layered,maxError:0.015,meanError:0.003)
        ]
    }
    private func measure(_ fixture:Fixture, precision:ExecutionPrecision) async throws -> Measurement {
        let renderer = try LumeraRenderer(precision:precision == .float16 ? .float16 : .float32)
        var execution = ExecutionProfile(width:width,height:height,budget:.init(maxInFlightFrames:1,maxResidentBytes:64*1024*1024))
        execution.precision = precision; execution.dynamicRange = .edr
        var working = WorkingImageContract(referenceRenditionID:"synthetic-precision-v1")
        working.dynamicRange = .edr; working.valueBounds = .finite(.init(lower:-0.25,upper:4))
        let rgba = fixture.rgb.flatMap { [$0.x,$0.y,$0.z,Float(1)] }
        let image = CIImage(bitmapData:rgba.withUnsafeBytes { Data($0) },bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedSRGB))
        var descriptor = SourceDescriptor(id:fixture.id,path:.processedPhoto); descriptor.recipeID = "ci"
        let recipe = InputRecipe(id:"ci",backend:"coreImage",version:"1",decodedRendition:.baseImage)
        let normalized = try await InputAdapter(renderer:renderer,working:working).prepare(.image(image),descriptor:descriptor,recipe:recipe,execution:execution)
        let input = try await InputNormalizer(renderer:renderer).normalize(normalized,calibration:nil,resources:.init())
        var definition = CameraModel(identity:.init(id:fixture.id,camera:"synthetic",mode:"precision-fixture"))
        definition.compatibility.dynamicRanges = [.edr]
        definition.compatibility.referenceRenditionIDs = [working.referenceRenditionID]
        definition.appearance.parameters = fixture.parameters
        let compiled = try CameraModelCompiler.compile(definition)
        let model = try ModelPreparer(renderer:renderer).prepare(compiled,resources:.init(),execution:execution)
        let stamp = FrameStamp(streamID:"precision-fixture",generation:0,index:17,presentationTime:17.0/30,duration:1.0/30)
        let observations = FrameObservations(stamp:stamp,sourceID:input.sourceID,calibrationID:input.calibrationID,featureDigest:compiled.featureDigest)
        let automatic = try CameraModelEvaluator.evaluate(compiled,context:.init(evaluationStamp:stamp,observations:observations))
        let controls = try EditResolver.resolve(.init(),automatic:automatic,model:compiled)
        let before = renderer.encoder.staticResourceStatistics
        let prepared = model.preparationStatistics
        let plan = try RenderPlanner().plan(controls,input:input,model:model,stamp:stamp,seed:42)
        XCTAssertEqual(try plan.assessPrecision(), .safe)
        let output = try await renderer.render(input,plan:plan)
        let texture = try XCTUnwrap(output.texture)
        XCTAssertEqual(texture.pixelFormat,precision == .float16 ? .rgba16Float : .rgba32Float)
        XCTAssertEqual(output.execution.precision,precision)
        XCTAssertEqual(output.stamp,stamp)
        XCTAssertEqual(texture.width,width); XCTAssertEqual(texture.height,height)
        // Output is independently owned and retained through this separate readback command.
        let bytesPerComponent = precision == .float16 ? 2 : 4
        let rowBytes = ((width*4*bytesPerComponent+255)/256)*256
        let buffer = try XCTUnwrap(renderer.device.makeBuffer(length:rowBytes*height*2,options:.storageModeShared))
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:width,height:height,depth:1),to:buffer,destinationOffset:0,destinationBytesPerRow:rowBytes,destinationBytesPerImage:rowBytes*height)
        blit.copy(from:input.texture,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:width,height:height,depth:1),to:buffer,destinationOffset:rowBytes*height,destinationBytesPerRow:rowBytes,destinationBytesPerImage:rowBytes*height)
        blit.endEncoding(); try await renderer.complete(command)
        var pixels: [Float] = []; pixels.reserveCapacity(width*height*4)
        for y in 0..<height {
            let row = buffer.contents().advanced(by:y*rowBytes)
            for component in 0..<(width*4) {
                pixels.append(precision == .float16 ? Float(Float16(bitPattern:row.load(fromByteOffset:component*2,as:UInt16.self))) : row.load(fromByteOffset:component*4,as:Float.self))
            }
        }
        var inputPixels: [Float] = []
        for y in 0..<height {
            let row = buffer.contents().advanced(by:rowBytes*height+y*rowBytes)
            for component in 0..<(width*4) {
                inputPixels.append(precision == .float16 ? Float(Float16(bitPattern:row.load(fromByteOffset:component*2,as:UInt16.self))) : row.load(fromByteOffset:component*4,as:Float.self))
            }
        }
        withExtendedLifetime(output) {}
        let after = renderer.encoder.staticResourceStatistics
        XCTAssertEqual(after.lutParses,before.lutParses); XCTAssertEqual(after.lutUploads,before.lutUploads)
        XCTAssertEqual(after.lutParses,0); XCTAssertEqual(after.lutUploads,0)
        XCTAssertEqual(model.preparationStatistics.colors,prepared.colors)
        XCTAssertEqual(model.preparationStatistics.halations,prepared.halations)
        XCTAssertEqual(model.preparationStatistics.grains,prepared.grains)
        return .init(pixels:pixels,inputPixels:inputPixels)
    }
    private func decode(_ x:Double) -> Double {
        abs(x) <= 0.04045 ? x/12.92 : (x < 0 ? -1 : 1)*pow((abs(x)+0.055)/1.055,2.4)
    }
    private func encode(_ x:Double) -> Double {
        abs(x) <= 0.0031308 ? x*12.92 : (x < 0 ? -1 : 1)*(1.055*pow(abs(x),1/2.4)-0.055)
    }
    private func storageEnvelope(_ values:ClosedRange<Double>) -> ClosedRange<Double> {
        Double(Float16(values.lowerBound).nextDown)...Double(Float16(values.upperBound).nextUp)
    }
    /// Outward one-half-step intervals at input, color, linear, and final storage.
    /// This bounds numerical storage behavior; it is not a perceptual quality limit.
    private func colorEnvelope(_ input:[Double], parameters:StyleParameters) -> [(ClosedRange<Double>,Double)] {
        let gain = Double(Float(pow(2,parameters.color.exposureEV)))
        let matrix = parameters.color.matrix.values.map { Double(Float($0)) }
        let inputs = input.map { storageEnvelope($0...$0) }
        return (0..<3).map { row in
            var lower = 0.0, upper = 0.0, reference = 0.0
            for channel in 0..<3 {
                let coefficient = matrix[row*3+channel]*gain
                let a = decode(inputs[channel].lowerBound)*coefficient
                let b = decode(inputs[channel].upperBound)*coefficient
                lower += min(a,b); upper += max(a,b)
                reference += decode(input[channel])*coefficient
            }
            let color = storageEnvelope(encode(lower)...encode(upper))
            let linear = storageEnvelope(decode(color.lowerBound)...decode(color.upperBound))
            let final = storageEnvelope(encode(linear.lowerBound)...encode(linear.upperBound))
            return (final,encode(reference))
        }
    }
    func testSyntheticPrecisionErrorAcrossRepresentativePatterns() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        for fixture in fixtures() {
            let half = try await measure(fixture,precision:.float16)
            let full = try await measure(fixture,precision:.float32)
            XCTAssertEqual(half.pixels.count,width*height*4); XCTAssertEqual(full.pixels.count,half.pixels.count)
            XCTAssertTrue(half.pixels.allSatisfy(\.isFinite),fixture.id)
            XCTAssertTrue(full.pixels.allSatisfy(\.isFinite),fixture.id)
            let indices = half.pixels.indices.filter { $0%4 != 3 }
            let errors = indices.map { abs(Double(half.pixels[$0])-Double(full.pixels[$0])) }
            let maximum = try XCTUnwrap(errors.max()), mean = errors.reduce(0,+)/Double(errors.count)
            if fixture.id != "hdr-color-transform" {
                XCTAssertLessThanOrEqual(maximum,fixture.maxError,fixture.id)
                XCTAssertLessThanOrEqual(mean,fixture.meanError,fixture.id)
            }
            for i in half.pixels.indices where i%4 == 3 {
                XCTAssertEqual(half.pixels[i],1,accuracy:0.0001); XCTAssertEqual(full.pixels[i],1,accuracy:0.0001)
            }
            if fixture.identityHDR {
                let channels = indices.map { full.pixels[$0] }
                XCTAssertEqual(try XCTUnwrap(channels.min()),-0.25,accuracy:0.00001)
                XCTAssertEqual(try XCTUnwrap(channels.max()),4,accuracy:0.00001)
                XCTAssertLessThan(half.pixels.min()!,0); XCTAssertGreaterThan(half.pixels.max()!,1)
            }
            // HDR 高光的历史质量参考未达标；这里保留独立数值包络回归，
            // 不把存储误差符合预期解释为视觉质量通过。
            if fixture.id == "hdr-color-transform" {
                for offset in stride(from:0,to:half.pixels.count,by:4) {
                    let fullInput = (0..<3).map { Double(full.inputPixels[offset+$0]) }
                    let halfInput = (0..<3).map { Double(half.inputPixels[offset+$0]) }
                    let predictions = colorEnvelope(fullInput,parameters:fixture.parameters)
                    for channel in 0..<3 {
                        XCTAssertTrue(storageEnvelope(fullInput[channel]...fullInput[channel]).contains(halfInput[channel]),"Input storage exceeds one-step interval")
                        let (interval,reference) = predictions[channel]
                        XCTAssertTrue(interval.contains(Double(half.pixels[offset+channel])),"Half output exceeds independent storage envelope")
                        let referenceError = abs(Double(full.pixels[offset+channel])-reference)
                        XCTAssertLessThanOrEqual(referenceError,max(1,abs(reference))*Double(Float.ulpOfOne)*32,"Float32 disagrees with independent color equations")
                    }
                }
            }
        }
    }
}
