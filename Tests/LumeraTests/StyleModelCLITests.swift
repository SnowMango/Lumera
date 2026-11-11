import XCTest
import Foundation
import ImagingCore
import ImageAnalysis

final class StyleModelCLITests: XCTestCase {
    struct Settings: Encodable {
        var model: StyleModel
        let execution: ExecutionProfile
        var resources: [String:String] = [:]
        let targetSource: SourceDescriptor
        let targetRecipe: InputRecipe
    }
    func run(_ args: [String]) throws -> Int32 {
        let sibling = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ccdlab")
        let process = Process()
        process.executableURL = ProcessInfo.processInfo.environment["CCDCLI_BINARY"].map { URL(fileURLWithPath: $0) } ?? sibling
        process.arguments = ["model"] + args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); return process.terminationStatus
    }
    func setup(_ directory: URL) throws -> (CalibrationProject, Settings, URL, URL) {
        var source = SourceDescriptor(id: "input", path: .processedPhoto); source.recipeID = "ci"
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
        let p = CalibrationProject(id: "fixture", target: .init(id: "manual", name: "test"), source: source,
            inputRecipe: recipe, working: .init(referenceRenditionID: "fixture"), samples: [])
        let settings = Settings(model: .init(identity: p.target), execution: .init(width: 4, height: 4,
            budget: .init(maxInFlightFrames: 1, maxResidentBytes: 32 * 1024 * 1024)), targetSource: source, targetRecipe: recipe)
        let projectURL = directory.appendingPathComponent("project.json"), settingsURL = directory.appendingPathComponent("settings.json")
        try JSON.encode(p).write(to: projectURL); try JSON.encode(settings).write(to: settingsURL)
        return (p, settings, projectURL, settingsURL)
    }
    func testBuildValidateReplayRoundTripAndOverwriteProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_,_,project,settings) = try setup(directory), output = directory.appendingPathComponent("package.json")
        let build = ["build", "--project", project.path, "--settings", settings.path, "--output", output.path]
        XCTAssertEqual(try run(build), 0)
        let package = try JSONDecoder().decode(StyleModelPackage.self, from: Data(contentsOf: output))
        XCTAssertEqual(package.manifest.derivation, .manual)
        XCTAssertNoThrow(try package.load())
        XCTAssertNotEqual(try run(build), 0)
        XCTAssertEqual(try run(build + ["--force"]), 0)
        let design = directory.appendingPathComponent("conditions.json")
        let designBytes = Data("{}".utf8)
        try designBytes.write(to: design)
        XCTAssertNotEqual(try run(build + ["--condition-design", design.path, "--force"]), 0)
        XCTAssertNotEqual(try run(["fit", "--project", project.path, "--settings", settings.path,
            "--condition-design", design.path, "--output", design.path, "--force"]), 0)
        XCTAssertEqual(try Data(contentsOf: design), designBytes)

        let original = try Data(contentsOf: settings)
        XCTAssertNotEqual(try run(["build", "--project", project.path, "--settings", settings.path, "--output", settings.path, "--force"]), 0)
        XCTAssertEqual(try Data(contentsOf: settings), original)
        let reportURL = directory.appendingPathComponent("report.json")
        XCTAssertEqual(try run(["validate", "--project", project.path, "--settings", settings.path, "--model", output.path, "--output", reportURL.path]), 0)
        let report = try JSONDecoder().decode(ModelValidationReport.self, from: Data(contentsOf: reportURL))
        XCTAssertTrue(report.measuredDomains.isEmpty)
        XCTAssertTrue(report.domains.allSatisfy { $0.status == .insufficient })
        let records = directory.appendingPathComponent("records.json"), replay = directory.appendingPathComponent("replay.json")
        try JSON.encode([DecisionRecord]()).write(to: records)
        XCTAssertEqual(try run(["replay", "--model", output.path, "--records", records.path, "--output", replay.path]), 0)
        XCTAssertNotEqual(try run(["replay", "--model", output.path, "--records", records.path, "--output", records.path, "--force"]), 0)
        XCTAssertNotEqual(try run(["replay", "--model", output.path, "--records", records.path, "--output", replay.path, "--mode", "frozen", "--force"]), 0)
    }
    func testMissingResourceStaleProjectAndInsufficientFitReject() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (p,s,project,settings) = try setup(directory), output = directory.appendingPathComponent("package.json")
        let build = ["build", "--project", project.path, "--settings", settings.path, "--output", output.path]
        var bad = s; bad.model.appearance.resources = [.init(id: "missing", sha256: String(repeating: "a", count: 64), dimension: 2)]
        try JSON.encode(bad).write(to: settings)
        XCTAssertNotEqual(try run(build), 0)
        try JSON.encode(s).write(to: settings)
        XCTAssertEqual(try run(build), 0)
        let changed = CalibrationProject(id: "other", target: p.target, source: p.source, inputRecipe: p.inputRecipe, working: p.working, samples: [])
        try JSON.encode(changed).write(to: project)
        XCTAssertNotEqual(try run(["validate", "--project", project.path, "--settings", settings.path, "--model", output.path, "--output", directory.appendingPathComponent("report.json").path]), 0)
        try JSON.encode(p).write(to: project)
        XCTAssertNotEqual(try run(["fit", "--project", project.path, "--settings", settings.path, "--output", directory.appendingPathComponent("fit.json").path]), 0)
    }
}
