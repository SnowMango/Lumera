import XCTest
import ImagingCore
import ImageRendering
import ImageAnalysis

final class EDRBoundaryTests: XCTestCase {
    func testSDRAnalysisRejectsEDRInsteadOfSilentlyClipping() throws {
        let renderer = try MetalRenderer()
        let image = try ImageFrame.solid(width: 4, height: 4, value: 0.5)
        var request = RenderRequest(input: image.descriptor); request.dynamicRange = .edr
        let style = try ResolvedStyle(profile: .standard)
        XCTAssertThrowsError(try renderer.render(image, style: style, request: request))
        XCTAssertThrowsError(try renderer.renderPreview(image, style: style, request: request))
    }

    func testDesktopExplicitLUTPolicyMatchesNativeAndInvalidatesPrefix() throws {
        let renderer = try MetalRenderer()
        let image = try ImageFrame.solid(width: 4, height: 4, value: 0.75)
        var profile = Profile.standard; profile.parameters.color.exposureEV = 2
        let style = try ResolvedStyle(profile: profile)
        let request = RenderRequest(input: image.descriptor)
        var lines = ["LUT_3D_SIZE 2"]
        for b in 0...1 { for g in 0...1 { for r in 0...1 {
            lines.append("\(Double(r)*0.25) \(Double(g)*0.25) \(Double(b)*0.25)")
        } } }
        var lut = LUTAsset(name: "quarter", cubeText: lines.joined(separator: "\n"))
        let clamped = try renderer.render(image, style: style, resources: .init(lut: lut), request: request)
        lut.boundaryPolicy = .extrapolate
        let extended = try renderer.render(image, style: style, resources: .init(lut: lut), request: request)
        XCTAssertEqual(clamped.image.pixels[0], 0.25, accuracy: 0.001)
        XCTAssertGreaterThan(extended.image.pixels[0], 0.3)
        XCTAssertNotEqual(clamped.manifest.renderIdentity, extended.manifest.renderIdentity)
    }
}
