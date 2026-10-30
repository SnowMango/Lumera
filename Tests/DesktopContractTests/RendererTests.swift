@testable import ImageAnalysis
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ImagingCore
@testable import ImageRendering
final class RendererTests: XCTestCase {
 func testBypassIdentityAndDeterminism() throws {
  let renderer = try MetalRenderer(), input = try Fixtures.make(.ramp, width: 128, height: 64)
  let output = try renderer.renderStyle(input, profile: .standard).image
  XCTAssertLessThan(zip(input.pixels,output.pixels).map { abs($0-$1) }.max()!, 0.00002)
  let a = try renderer.renderStyle(input, profile:TestProfiles.ccd).image
  let b = try renderer.renderStyle(input, profile:TestProfiles.ccd).image
  XCTAssertEqual(a.pixels,b.pixels)
 }
 func testVignetteUsesLinearLightAndDiagonal() throws {
  let renderer = try MetalRenderer(), input = try ImageFrame.solid(width: 257,height: 129,value: 0.5)
  var p = TestProfiles.ccd; p.parameters.detail.enabled=false; p.parameters.glow.enabled=false; p.parameters.noise.enabled=false
  p.parameters.vignette.amountEV=1; p.parameters.vignette.startRadius=0; p.parameters.vignette.falloff=1
  let out = try renderer.renderStyle(input,profile:p).image
  XCTAssertEqual(out.pixels[(64*257+128)*4],0.5,accuracy:0.0001)
  // 0.5 encoded -> 0.214041 linear; one stop -> encoded 0.36078.
  XCTAssertEqual(out.pixels[0],0.36078,accuracy:0.003)
 }
 func testGlowSpreadsLightAndZeroBypasses() throws {
  let renderer = try MetalRenderer(), input = try Fixtures.make(.point,width:512,height:512)
  var p = TestProfiles.ccd; p.parameters.detail.enabled=false; p.parameters.vignette.enabled=false; p.parameters.noise.enabled=false
  p.parameters.glow.amount=0
  let zero = try renderer.renderStyle(input,profile:p).image
  XCTAssertLessThan(zip(input.pixels,zero.pixels).map{abs($0-$1)}.max()!,0.00002)
  p.parameters.glow.amount=0.8
  let glow = try renderer.renderStyle(input,profile:p).image
  XCTAssertGreaterThan(glow.pixels[(256*512+261)*4], input.pixels[(256*512+261)*4])
  XCTAssertLessThan(glow.pixels[(256*512+256)*4], input.pixels[(256*512+256)*4])
 }
 func testNoiseMomentsAndChroma() throws {
  let renderer = try MetalRenderer(), input = try ImageFrame.solid(width:512,height:512,value:0.5)
  var p = TestProfiles.ccd; p.parameters.detail.enabled=false; p.parameters.vignette.enabled=false; p.parameters.glow.enabled=false
  p.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],[0.02,0.02,0.02,0.02,0.02]).map{.init(x:$0,y:$1)}); p.parameters.noise.chromaRatio=0; p.parameters.noise.lumaSigma=2.6
  let out=try renderer.renderStyle(input,profile:p).image
  var values=[Double]()
  for y in 10..<502 { for x in 10..<502 { let i=(y*512+x)*4; values.append(Double(out.pixels[i]-0.5)); XCTAssertEqual(out.pixels[i],out.pixels[i+1],accuracy:1e-6) } }
  let mean=values.reduce(0,+)/Double(values.count), variance=values.map{($0-mean)*($0-mean)}.reduce(0,+)/Double(values.count)
  XCTAssertEqual(mean,0,accuracy:0.0005); XCTAssertEqual(sqrt(variance),0.02,accuracy:0.001)
 }
 func testDetailNeutralAndSharpenLimit() throws {
  let renderer=try MetalRenderer(), input=try Fixtures.make(.edge,width:257,height:129)
  var p=TestProfiles.ccd; p.parameters.vignette.enabled=false; p.parameters.glow.enabled=false; p.parameters.noise.enabled=false
  p.parameters.detail.fineGain=1; p.parameters.detail.midGain=1; p.parameters.detail.sharpenAmount=0
  let neutral=try renderer.renderStyle(input,profile:p).image
  XCTAssertLessThan(zip(input.pixels,neutral.pixels).map{abs($0-$1)}.max()!,0.00002)
  p.parameters.detail.sharpenAmount=1
  let sharp=try renderer.renderStyle(input,profile:p).image
  XCTAssertLessThanOrEqual(zip(input.pixels,sharp.pixels).map{abs($0-$1)}.max()!,0.01501)
 }
 func testCubeRejectsInvalidDomainsAndCounts() throws {
  XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n"))
  XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n"))
  let cube="LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
  let parsed=try CubeLUT.parse(cube); XCTAssertEqual(parsed.size,2)
  var p=Profile.standard;  p.parameters.detail.enabled=false; p.parameters.glow.enabled=false; p.parameters.vignette.enabled=false; p.parameters.noise.enabled=false
  let lut=LUTAsset(name:"identity",cubeText:cube)
  let input=try Fixtures.make(.ramp,width:32,height:8), out=try MetalRenderer().render(input,style:ResolvedStyle(profile:p),resources:.init(lut:lut),request:RenderRequest(input:input.descriptor)).image
  XCTAssertLessThan(zip(input.pixels,out.pixels).map{abs($0-$1)}.max()!,0.00002)
 }
 func testOrientationAndTransparencyAreNormalized() throws {
  var input=try ImageFrame.solid(width:32,height:16,value:0)
  for y in 0..<16 {for x in 0..<32 {let i=(y*32+x)*4;let c:[Float]=y<8 ? (x<16 ? [1,0,0]:[0,1,0]):(x<16 ? [0,0,1]:[1,1,1]);for k in 0..<3{input.pixels[i+k]=c[k]}}}
  let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".tiff")
  defer{try? FileManager.default.removeItem(at:url)}
  let data=NSMutableData(),destination=CGImageDestinationCreateWithData(data,UTType.tiff.identifier as CFString,1,nil)!
  CGImageDestinationAddImage(destination,try ImageCodec.cgImage(input),[kCGImagePropertyOrientation:6] as CFDictionary)
  XCTAssertTrue(CGImageDestinationFinalize(destination));try (data as Data).write(to:url)
  let oriented=try ImageCodec.load(url)
  XCTAssertEqual(oriented.width,16);XCTAssertEqual(oriented.height,32)
  XCTAssertEqual(oriented.pixels[0],0,accuracy:0.005);XCTAssertEqual(oriented.pixels[2],1,accuracy:0.005)
  var transparent=try ImageFrame.solid(width:32,height:32,value:1)
  for i in stride(from:3,to:transparent.pixels.count,by:4){transparent.pixels[i]=0}
  let png=url.deletingPathExtension().appendingPathExtension(".png");defer{try? FileManager.default.removeItem(at:png)}
  try ImageCodec.encode(transparent).write(to:png)
  let black=try ImageCodec.load(png),white=try ImageCodec.load(png,background:[1,1,1])
  XCTAssertEqual(black.pixels[0],0,accuracy:0.00001);XCTAssertEqual(white.pixels[0],1,accuracy:0.00001)
 }
 func testCodecRoundTripAndInvalidFrame() throws {
  XCTAssertThrowsError(try ImageFrame(width:0,height:1,pixels:[]))
  let input=try Fixtures.make(.patches,width:64,height:32)
  let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
  defer{try? FileManager.default.removeItem(at:url)}
  try ImageCodec.encode(input,format:.png).write(to:url)
  let output=try ImageCodec.load(url)
  XCTAssertEqual(output.width,64); XCTAssertEqual(output.height,32)
  XCTAssertLessThan(zip(input.pixels,output.pixels).map{abs($0-$1)}.max()!,0.005)
 }
}
