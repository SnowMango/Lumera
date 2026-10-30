import XCTest
import CoreImage
import CoreVideo
import ImageIO
import ImagingCore
@testable import ImageRendering

final class LumeraRendererTests: XCTestCase {
    func testOptionsForwardEveryExistingRequestField() throws {
        var options = RenderOptions(maximumLongEdge: 10, seed: 91, frameIndex: 7)
        options.previewGlow = false
        options.glowScale = .half
        options.halationScale = .half
        options.softeningScale = .half
        let request = options.makeRequest(input: InputDescriptor(width: 20, height: 12))
        XCTAssertEqual(request.maximumLongEdge, 10)
        XCTAssertEqual(request.seed, 91)
        XCTAssertEqual(request.frameIndex, 7)
        XCTAssertFalse(request.previewGlow)
        XCTAssertEqual(request.glowScale, .half)
        XCTAssertEqual(request.halationScale, .half)
        XCTAssertEqual(request.softeningScale, .half)
        XCTAssertNoThrow(try request.validate())
    }

    func testImageOrientationResizeMetadataAndIndependentLifetime() async throws {
        let renderer = try LumeraRenderer(), style = try renderer.prepare(.standard)
        let exif: [String: Any] = [kCGImagePropertyExifExposureTime as String: 0.01,
            kCGImagePropertyExifISOSpeedRatings as String: [200],
            kCGImagePropertyExifPixelXDimension as String: 8,
            kCGImagePropertyExifMakerNote as String: Data([1, 2])]
        let input = CIImage(color: CIColor(red: 0.4, green: 0.2, blue: 0.1))
            .cropped(to: CGRect(x: 5, y: 7, width: 8, height: 4)).settingProperties([
                kCGImagePropertyOrientation as String: 6,
                kCGImagePropertyExifDictionary as String: exif,
                kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 31.0],
                kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Camera", kCGImagePropertyTIFFOrientation as String: 6],
                kCGImagePropertyDNGDictionary as String: ["obsolete": true]])
        let output = try await renderer.render(input, style: style, options: RenderOptions(maximumLongEdge: 4))
        XCTAssertEqual(output.extent, CGRect(x: 0, y: 0, width: 2, height: 4))
        XCTAssertEqual(output.properties[kCGImagePropertyOrientation as String] as? Int, 1)
        XCTAssertEqual(output.properties[kCGImagePropertyPixelWidth as String] as? Int, 2)
        let result = try XCTUnwrap(output.properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(result[kCGImagePropertyExifExposureTime as String] as? Double, 0.01)
        XCTAssertEqual(result[kCGImagePropertyExifPixelXDimension as String] as? Int, 2)
        XCTAssertNil(result[kCGImagePropertyExifMakerNote as String])
        XCTAssertNil(output.properties[kCGImagePropertyDNGDictionary as String])
        XCTAssertNotNil(output.properties[kCGImagePropertyGPSDictionary as String])
        let before = pixels(output)
        for _ in 0..<3 {
            _ = try await renderer.render(CIImage(color: .white).cropped(to: input.extent), style: style)
        }
        XCTAssertEqual(pixels(output), before)
        XCTAssertEqual(input.properties[kCGImagePropertyOrientation as String] as? Int, 6)
    }

    func testExternalDevelopedImageSupplementDoesNotRotateAgain() async throws {
        let renderer = try LumeraRenderer(), style = try renderer.prepare(.standard)
        let input = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 4))
            .settingProperties([kCGImagePropertyOrientation as String: 6])
        let output = try await renderer.render(input, metadata: [
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifISOSpeedRatings as String: [400]],
            kCGImagePropertyPixelWidth as String: 999], orientation: .up, style: style)
        XCTAssertEqual(output.extent.size, CGSize(width: 8, height: 4))
        XCTAssertEqual(output.properties[kCGImagePropertyPixelWidth as String] as? Int, 8)
        let exif = output.properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], [400])
    }

    func testPixelBufferAttachmentsAndPixels() async throws {
        let renderer = try LumeraRenderer(), style = try renderer.prepare(.standard)
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optional), kCVReturnSuccess)
        let input = try XCTUnwrap(optional)
        CIContext().render(CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.75)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 4)), to: input)
        CVBufferSetAttachment(input, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        CVBufferSetAttachment(input, kCGImagePropertyExifDictionary, [kCGImagePropertyExifISOSpeedRatings: [100]] as CFDictionary, .shouldPropagate)
        CVBufferSetAttachment(input, "private" as CFString, "do not copy" as CFString, .shouldNotPropagate)
        CVBufferSetAttachment(input, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let output = try await renderer.render(input, style: style, options: RenderOptions(maximumLongEdge: 4))
        XCTAssertEqual(CVPixelBufferGetWidth(output), 4)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 2)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_32BGRA)
        XCTAssertNil(CVBufferCopyAttachment(output, "private" as CFString, nil))
        XCTAssertNil(CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil))
        XCTAssertNotNil(CVBufferCopyAttachment(output, kCGImagePropertyExifDictionary, nil))
        XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String, kCVImageBufferTransferFunction_sRGB as String)
        let pixel = pixels(CIImage(cvPixelBuffer: output))
        XCTAssertEqual(pixel[0], 0.25, accuracy: 0.02)
        XCTAssertEqual(pixel[1], 0.5, accuracy: 0.02)
        XCTAssertEqual(pixel[2], 0.75, accuracy: 0.02)
        XCTAssertEqual(pixel[3], 1)
    }

    func testInvalidRAWAndInfiniteImageAreRejected() async throws {
        let renderer = try LumeraRenderer(), style = try renderer.prepare(.standard)
        do { _ = try await renderer.render(rawData: Data("invalid".utf8), style: style); XCTFail("Invalid RAW accepted") } catch {}
        do { _ = try await renderer.render(CIImage(color: .white), style: style); XCTFail("Infinite extent accepted") } catch {}
    }

    func testPixelOrientationAndOpaqueComposition() async throws {
        let renderer = try LumeraRenderer(), style = try renderer.prepare(.standard)
        let bounds = CGRect(x: 0, y: 0, width: 4, height: 2)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds)
        let image = red.composited(over: blue)
        for orientation in [CGImagePropertyOrientation.up, .right, .down, .leftMirrored] {
            let actual = try await renderer.render(image, orientation: orientation, style: style)
            let expected = image.oriented(orientation)
            XCTAssertEqual(actual.extent.size, expected.extent.size)
            let reference = pixels(expected)
            for (a, b) in zip(pixels(actual), reference) { XCTAssertEqual(a, b, accuracy: 0.002) }
        }
        let transparent = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0)).cropped(to: bounds)
        let result = try await renderer.render(transparent, style: style)
        XCTAssertEqual(Array(pixels(result).prefix(4)), [0, 0, 0, 1])
    }

    func testTextureFacadeDoesNotCommitAndPreservesExistingContract() throws {
        let h = try RenderHarness(), renderer = try LumeraRenderer(device: h.device)
        let style = try renderer.prepare(.standard), input = try h.texture(width: 8, height: 4)
        let command = try XCTUnwrap(h.queue.makeCommandBuffer())
        let output = try renderer.render(input, style: style, inputDescriptor: InputDescriptor(width: 8, height: 4), commandBuffer: command)
        XCTAssertTrue(output === input)
        XCTAssertEqual(command.status, .notEnqueued)
        XCTAssertThrowsError(try renderer.render(input, style: style,
            inputDescriptor: InputDescriptor(width: 8, height: 4), options: RenderOptions(maximumLongEdge: 0), commandBuffer: command))
    }

    func testCancelledRenderAndInvalidRAWURL() async throws {
        let renderer = try LumeraRenderer(), style = try renderer.prepare(.standard)
        let input = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 4))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await renderer.render(input, style: style)
        }
        do { _ = try await task.value; XCTFail("Cancelled render returned an image") }
        catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await renderer.render(rawURL: URL(string: "https://example.invalid/photo.dng")!, style: style)
            XCTFail("Remote RAW accepted")
        } catch {}
    }

    func testRealRAWInternalAndExternalDevelopment() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMERA_RAW_TEST_FILE"] else {
            throw XCTSkip("Set LUMERA_RAW_TEST_FILE to exercise a real RAW/ProRAW fixture")
        }
        let url = URL(fileURLWithPath: path), data = try Data(contentsOf: url)
        let renderer = try LumeraRenderer(), style = try renderer.prepare(.standard)
        let options = RenderOptions(maximumLongEdge: 128)
        var configured = false
        let internalImage = try await renderer.render(rawData: data, style: style, options: options, configureRAW: {
            configured = true
            $0.exposure = 0.5
        })
        XCTAssertTrue(configured)
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
        filter.isDraftModeEnabled = false
        filter.extendedDynamicRangeAmount = 0
        filter.exposure = 0.5
        let externalImage = try await renderer.render(try XCTUnwrap(filter.outputImage),
            metadata: filter.properties as? [String: Any], orientation: .up, style: style, options: options)
        XCTAssertEqual(internalImage.extent, externalImage.extent)
        for (a, b) in zip(pixels(internalImage), pixels(externalImage)) { XCTAssertEqual(a, b, accuracy: 0.003) }
        let fromURL = try await renderer.render(rawURL: url, style: style, options: options, configureRAW: { $0.exposure = 0.5 })
        XCTAssertEqual(fromURL.extent, internalImage.extent)
        XCTAssertEqual(fromURL.properties[kCGImagePropertyOrientation as String] as? Int, 1)
    }

    func testP3ColorConversionAndHDRSanitization() async throws {
        let renderer = try LumeraRenderer(), style = try renderer.prepare(.standard)
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let color = try XCTUnwrap(CGColor(colorSpace: p3, components: [0.4, 0.5, 0.6, 1]))
        let input = CIImage(color: CIColor(cgColor: color)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let result = try await renderer.render(input, style: style)
        for (a, b) in zip(pixels(result), pixels(input)) { XCTAssertEqual(a, b, accuracy: 0.002) }
        XCTAssertEqual(result.colorSpace?.name, CGColorSpace.sRGB)
        if #available(iOS 26, macOS 26, *) {
            let hdr = input.settingContentHeadroom(4)
            let mapped = try await renderer.render(hdr, style: style)
            XCTAssertTrue(pixels(mapped).allSatisfy { $0.isFinite && (0...1).contains($0) })
            XCTAssertLessThanOrEqual(mapped.contentHeadroom, 1)
        }
    }

    func testNonSquarePixelBufferRejected() async throws {
        let renderer = try LumeraRenderer(), style = try renderer.prepare(.standard)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let input = try XCTUnwrap(buffer)
        for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
            CVBufferSetAttachment(input, kCVImageBufferPixelAspectRatioKey,
                [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 2, kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1] as CFDictionary, mode)
            do { _ = try await renderer.render(input, style: style); XCTFail("Non-square pixels accepted without conversion") } catch {}
        }
    }

    func testUntaggedCIImageKeepsWorkingSpaceSemantics() async throws {
        let renderer = try LumeraRenderer(), style = try renderer.prepare(.standard)
        let samples: [Float] = [0.5, 0.5, 0.5, 1]
        let data = samples.withUnsafeBytes { Data($0) }
        let untagged = CIImage(bitmapData: data, bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let rendered = try await renderer.render(untagged, style: style)
        XCTAssertEqual(pixels(rendered)[0], 0.735357, accuracy: 0.002)
        let tagged = CIImage(bitmapData: data, bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let filtered = tagged.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0])
        let filteredOutput = try await renderer.render(filtered, style: style)
        XCTAssertEqual(pixels(filteredOutput)[0], 0.5, accuracy: 0.002)
    }

    private func pixels(_ image: CIImage) -> [Float] {
        var result = [Float](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
        result.withUnsafeMutableBytes { CIContext().render(image, toBitmap: $0.baseAddress!, rowBytes: Int(image.extent.width) * 16, bounds: image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
        return result
    }
}
