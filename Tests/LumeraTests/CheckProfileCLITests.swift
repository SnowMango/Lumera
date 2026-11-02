import Foundation
import XCTest

final class CheckProfileCLITests: XCTestCase {
    func testValidAndInvalidProfilesUseCLIExitContract() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = directory.appendingPathComponent("profile.json")
        let sibling = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ccdlab")
        let binary = ProcessInfo.processInfo.environment["CCDCLI_BINARY"].map { URL(fileURLWithPath: $0) } ?? sibling
        let cases: [(String, Int32, String)] = [
            (#"{"schemaVersion":8,"id":"a","name":"A"}"#, 0, ""),
            (#"{"schemaVersion":7,"id":"a","name":"A"}"#, 2, "schemaVersion"),
            (#"{"schemaVersion":8,"id":"a","name":"A","parameters":{"grain":{"typo":1}}}"#, 2, "parameters.grain.typo"),
            (#"{"schemaVersion":8,"id":"a","name":"A","parameters":{"tone":{"curve":{"shape":{"points":{"_0":[{"x":1,"y":1}]}}}}}}"#, 2, "parameters.tone.curve"),
        ]
        for (json, code, path) in cases {
            let bytes = Data(json.utf8)
            try bytes.write(to: profile)
            let process = Process(), error = Pipe()
            process.executableURL = binary
            process.arguments = ["check-profile", "--profile", profile.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, code)
            if !path.isEmpty {
                let diagnostic = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTAssertTrue(diagnostic.contains(path), diagnostic)
            }
            XCTAssertEqual(try Data(contentsOf: profile), bytes)
        }
    }
}
