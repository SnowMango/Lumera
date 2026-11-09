import XCTest
@testable import ImagingCore

final class ParameterSpecificationTests: XCTestCase {
    func testRegistryPreservesLegacyLimits() throws {
        for descriptor in ParameterDescriptor.all {
            let specification = try ParameterSpecification.lookup(descriptor.id)
            XCTAssertEqual(specification.baseRange, descriptor.baseRange)
            XCTAssertEqual(specification.effectiveRange, descriptor.effectiveRange)
            XCTAssertEqual(specification.unit, descriptor.unit)
        }
        XCTAssertEqual(try ParameterSpecification.lookup("noise.gain").allowedOperations, [.multiply])
        XCTAssertEqual(try ParameterSpecification.lookup("glow.amount").allowedOperations, [.replace, .multiply, .add])
        XCTAssertFalse(try ParameterSpecification.lookup("color.matrix.0").legacyBindable)
    }

    func testTypedBlocksHaveUnambiguousShape() throws {
        XCTAssertEqual(try ParameterSpecification.lookup("color.matrix").shape, .matrix3x3)
        XCTAssertEqual(try ParameterSpecification.lookup("tone.curve").shape, .curve)
        XCTAssertEqual(try ParameterSpecification.lookup("style.lutWeights").shape, .resourceWeights)
        XCTAssertThrowsError(try ParameterSpecification.lookup("unrecognized.parameter"))
    }

    func testRegistryRejectsDuplicateIdentifiers() throws {
        let specification = try ParameterSpecification.lookup("glow.amount")
        XCTAssertThrowsError(try ParameterSpecification.validateRegistry([specification, specification]))
        XCTAssertNoThrow(try ParameterSpecification.validateRegistry(ParameterSpecification.all))
    }
}
