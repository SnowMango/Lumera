import XCTest
import Foundation
import ImagingCore
final class VerifyStyleCLITests:XCTestCase {
    func testCommandProducesBothReportsAndRefusesExistingDirectory() throws {
        guard let binary=ProcessInfo.processInfo.environment["CCDCLI_BINARY"] else{throw XCTSkip("CLI binary supplied by Scripts/test.sh")}
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:folder)}
        func run()->Int32 {
            let p=Process();p.executableURL=URL(fileURLWithPath:binary);p.arguments=["verify-style","--profile",root.appendingPathComponent("Presets/lumera-standard.json").path,"--fixtures",root.appendingPathComponent("TestMaterials/Lumera-v1").path,"--output",folder.path]
            p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
            do{try p.run();p.waitUntilExit();return p.terminationStatus}catch{return -1}
        }
        XCTAssertEqual(run(),0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.appendingPathComponent("report.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.appendingPathComponent("report.txt").path))
        XCTAssertNotEqual(run(),0)
    }
}
