@testable import ImageAnalysis
import XCTest
import ImagingCore
import ImageRendering
final class WorkflowTests:XCTestCase {
 func testCLIExportRenderAndNoOverwrite() throws {
  let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let binary=ProcessInfo.processInfo.environment["CCDCLI_BINARY"].map {URL(fileURLWithPath:$0)}
    ?? root.appendingPathComponent(".build/debug/ccdlab")
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:dir)}
  func run(_ args:[String]) throws -> Int32 {
   let process=Process();process.executableURL=binary;process.arguments=args;process.currentDirectoryURL=dir
   process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
   try process.run();process.waitUntilExit();return process.terminationStatus
  }
  XCTAssertEqual(try run(["preset","export","--name","standard","--output","profile.json"]),0)
  XCTAssertTrue(FileManager.default.fileExists(atPath:dir.appendingPathComponent("profile.json").path))
  XCTAssertNotEqual(try run(["preset","export","--output","profile.json"]),0)
  try ImageCodec.encode(Fixtures.make(.patches,width:64,height:32)).write(to:dir.appendingPathComponent("input.png"))
  XCTAssertEqual(try run(["render","--input","input.png","--profile","profile.json","--output","out.png"]),0)
  XCTAssertTrue(FileManager.default.fileExists(atPath:dir.appendingPathComponent("out.png.json").path))
  XCTAssertEqual(try run(["render","--input","input.png","--profile","profile.json","--output","input.png","--force"]),2)
  XCTAssertEqual(try run(["render","--typo","yes"]),2)
  XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent("out.png"))[24],8)
  XCTAssertEqual(try run(["render","--input","input.png","--profile","profile.json","--output","reference.png","--output-kind","reference"]),0)
  XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent("reference.png"))[24],16)
  for command in ["fit","validate","measure"] {XCTAssertEqual(try run([command]),3)}
  for name in ["digital-demo","film-demo"] {
   XCTAssertEqual(try run(["preset","export","--name",name,"--output",name+".json"]),0)
   XCTAssertEqual(try run(["render","--input","input.png","--profile",name+".json","--output",name+".png"]),0)
   _=try ImageCodec.load(dir.appendingPathComponent(name+".png"))
  }
  try Data("{\"inputs\":[\"input.png\"]}".utf8).write(to:dir.appendingPathComponent("batch.json"))
  XCTAssertEqual(try run(["batch","--manifest","batch.json","--profile","profile.json","--output-dir","batch"]),0)
 }
}
