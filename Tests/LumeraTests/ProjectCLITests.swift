import Foundation
import XCTest
import ImagingCore
import ImageAnalysis

final class ProjectCLITests: XCTestCase {
    private func run(_ args: [String]) throws -> Int32 {
        let sibling = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ccdlab")
        let process = Process()
        process.executableURL = ProcessInfo.processInfo.environment["CCDCLI_BINARY"].map { URL(fileURLWithPath: $0) } ?? sibling
        process.arguments = ["project"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
    func testCheckWritesIncompleteReportAndProtectsInputAndExistingOutput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var source = SourceDescriptor(id: "source", path: .processedPhoto); source.recipeID = "recipe"
        let project = CalibrationProject(id: "project", target: .init(id: "target", name: "standard"),
                                         source: source, inputRecipe: .init(id: "recipe", backend: "test", version: "1"),
                                         working: .init(referenceRenditionID: "reference"), samples: [])
        let input = dir.appendingPathComponent("project.json"), output = dir.appendingPathComponent("report.json")
        let bytes = try JSONEncoder().encode(project); try bytes.write(to: input)
        let args = ["check", "--project", input.path, "--output", output.path]
        XCTAssertEqual(try run(args), 0)
        let report = try JSONDecoder().decode(CalibrationCheckReport.self, from: Data(contentsOf: output))
        XCTAssertEqual(report.status, .incomplete)
        XCTAssertTrue(report.baselines.allSatisfy { $0.value == nil })
        XCTAssertNotEqual(try run(args), 0)
        XCTAssertEqual(try run(args + ["--force"]), 0)
        XCTAssertNotEqual(try run(["check", "--project", input.path, "--output", input.path, "--force"]), 0)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        XCTAssertNotEqual(try run(args + ["--unknown", "value"]), 0)
    }
    func testRelativeSamplePathsAndSymlinkInputsAreProtected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("sample".utf8), sampleURL = dir.appendingPathComponent("sample.bin")
        try bytes.write(to: sampleURL)
        let file = CalibrationFile(path: "sample.bin", sha256: Digest.data(bytes), byteCount: bytes.count)
        let referenceURL = dir.appendingPathComponent("reference.bin"), referenceBytes = Data("reference".utf8)
        try referenceBytes.write(to: referenceURL)
        let reference = CalibrationFile(path: "reference.bin", sha256: Digest.data(referenceBytes), byteCount: referenceBytes.count)
        let sample = CalibrationSample(id: "sample", input: file, target: file, reference: reference, sceneID: "scene", split: .train)
        var source = SourceDescriptor(id: "source", path: .processedPhoto); source.recipeID = "recipe"
        let project = CalibrationProject(id: "project", target: .init(id: "target", name: "standard"), source: source,
                                         inputRecipe: .init(id: "recipe", backend: "test", version: "1"), working: .init(referenceRenditionID: "reference"), samples: [sample])
        let input = dir.appendingPathComponent("project.json"), output = dir.appendingPathComponent("report.json")
        try JSONEncoder().encode(project).write(to: input)
        XCTAssertEqual(try run(["check", "--project", input.path, "--output", output.path]), 0)
        let alias = dir.appendingPathComponent("alias.bin")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sampleURL)
        XCTAssertNotEqual(try run(["check", "--project", input.path, "--output", alias.path, "--force"]), 0)
        XCTAssertEqual(try Data(contentsOf: sampleURL), bytes)
        XCTAssertNotEqual(try run(["check", "--project", input.path, "--output", referenceURL.path, "--force"]), 0)
        XCTAssertEqual(try Data(contentsOf: referenceURL), referenceBytes)
    }
}
