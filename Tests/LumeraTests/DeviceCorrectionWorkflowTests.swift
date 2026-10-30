import XCTest
import ImagingCore
import ImageAnalysis

final class DeviceCorrectionWorkflowTests:XCTestCase {
    func testCLIValidInvalidBatchAndInputProtection() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary=ProcessInfo.processInfo.environment["CCDCLI_BINARY"].map{URL(fileURLWithPath:$0)} ?? root.appendingPathComponent(".build/debug/ccdlab")
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
        func run(_ args:[String]) throws -> Int32 {
            let p=Process();p.executableURL=binary;p.arguments=args;p.currentDirectoryURL=dir
            p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run();p.waitUntilExit();return p.terminationStatus
        }
        let source=try Fixtures.make(.patches,width:64,height:32)
        try ImageCodec.encodeReference(source).write(to:dir.appendingPathComponent("input.png"))
        try JSON.encode(Profile.standard).write(to:dir.appendingPathComponent("style.json"))
        var correction=DeviceCorrection();correction.matrix.values=[0,0,1,0,1,0,1,0,0]
        let data=try JSON.encode(correction);try data.write(to:dir.appendingPathComponent("correction.json"))
        let base=["render","--input","input.png","--profile","style.json","--device-correction","correction.json","--output","out.png","--output-kind","reference"]
        XCTAssertEqual(try run(base),0)
        let manifest=try JSON.load(RenderManifest.self,from:dir.appendingPathComponent("out.png.json"))
        XCTAssertEqual(manifest.correctionDigest,try correction.effectDigest());XCTAssertGreaterThan(manifest.timing?.correctionSeconds ?? 0,0)
        let loaded=try ImageCodec.load(dir.appendingPathComponent("input.png"))
        let expected=try MetalRenderer().render(loaded,style:ResolvedStyle(profile:.standard),correction:correction,request:RenderRequest(input:loaded.descriptor)).image
        let actual=try ImageCodec.load(dir.appendingPathComponent("out.png"))
        XCTAssertLessThanOrEqual(zip(expected.pixels,actual.pixels).map{abs($0-$1)}.max()!,1.1/65535)
        try JSON.encode(["inputs":["input.png"]]).write(to:dir.appendingPathComponent("batch.json"))
        let batch=["batch","--manifest","batch.json","--profile","style.json","--device-correction","correction.json","--output-dir","batch"]
        XCTAssertEqual(try run(batch),0)
        XCTAssertEqual(try JSON.load(RenderManifest.self,from:dir.appendingPathComponent("batch/0001-input.png.json")).correctionDigest,try correction.effectDigest())
        let lutText="LUT_3D_SIZE 2\n0 0 0\n0.5 0 0\n0 0.5 0\n0.5 0.5 0\n0 0 0.5\n0.5 0 0.5\n0 0.5 0.5\n0.5 0.5 0.5\n"
        try Data(lutText.utf8).write(to:dir.appendingPathComponent("look.cube"))
        XCTAssertEqual(try run(["render","--input","input.png","--lut","look.cube","--output","lut-only.png","--output-kind","reference"]),0)
        let lutImage=try ImageCodec.load(dir.appendingPathComponent("lut-only.png"))
        for i in stride(from:0,to:loaded.pixels.count,by:4) {for c in 0..<3 {XCTAssertEqual(lutImage.pixels[i+c],loaded.pixels[i+c]*0.5,accuracy:2.0/65535)}}
        XCTAssertEqual(try run(["render","--input","input.png","--correction-lut","look.cube","--output","correction-lut-only.png"]),0)
        XCTAssertNotEqual(try run(["render","--input","input.png","--lut","missing.cube","--output","missing.png"]),0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent("missing.png").path))
        var broken=correction;broken.matrix.values=[]
        try JSON.encode(broken).write(to:dir.appendingPathComponent("correction.json"))
        try FileManager.default.removeItem(at:dir.appendingPathComponent("out.png"));try FileManager.default.removeItem(at:dir.appendingPathComponent("out.png.json"))
        XCTAssertNotEqual(try run(base),0);XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent("out.png").path))
        XCTAssertNotEqual(try run(batch+["--force"]),0)
        try data.write(to:dir.appendingPathComponent("out.png.json"))
        XCTAssertNotEqual(try run(["render","--input","input.png","--profile","style.json","--device-correction","out.png.json","--output","out.png","--force"]),0)
        XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent("out.png.json")),data)
        XCTAssertEqual(try run(["render","--input","input.png","--profile","style.json","--output","nil.png"]),0)
        XCTAssertEqual(try JSON.load(RenderManifest.self,from:dir.appendingPathComponent("nil.png.json")).correctionDigest,"identity")
    }
}
