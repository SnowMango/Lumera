import XCTest
import Foundation
import ImagingCore
import ImageAnalysis
final class VerifyStyleCLITests:XCTestCase {
    func testCommandProducesBothReportsAndRefusesExistingDirectory() throws {
        let builtCLI=Bundle(for:Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ccdlab")
        let binary=ProcessInfo.processInfo.environment["CCDCLI_BINARY"] ?? builtCLI.path
        guard FileManager.default.isExecutableFile(atPath:binary) else { throw XCTSkip("ccdlab executable unavailable in the test build") }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let fixtures=root.appendingPathComponent("fixtures"),profile=root.appendingPathComponent("standard.json")
        let folder=root.appendingPathComponent("report")
        try AcceptanceFixtures.write(to:fixtures)
        try ProfileCodec.encode(.standard).write(to:profile)
        func run()->Int32 {
            let p=Process();p.executableURL=URL(fileURLWithPath:binary);p.arguments=["verify-style","--profile",profile.path,"--fixtures",fixtures.path,"--output",folder.path]
            p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
            do{try p.run();p.waitUntilExit();return p.terminationStatus}catch{return -1}
        }
        XCTAssertEqual(run(),0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.appendingPathComponent("report.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.appendingPathComponent("report.txt").path))
        XCTAssertNotEqual(run(),0)
    }
}
