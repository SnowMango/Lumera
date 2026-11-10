import Foundation
import ImagingCore
import ImageRendering

/// A single immutable source revision and its input development and calibration contract.
/// Create a new handle when pixels, source geometry, metadata or development behavior change.
/// Caller-backed CIImage, CVPixelBuffer, Data and metadata must remain immutable while retained.
/// Retaining a pixel buffer keeps it out of its pool but does not prevent caller mutation.
public final class PhotoSource: @unchecked Sendable {
    public let revision = UUID()
    public let descriptor: SourceDescriptor
    public let recipe: InputRecipe
    public let working: WorkingImageContract
    public let calibration: InputCalibration?
    public let rawOverrides: [RAWOverride]
    public let rawConfiguration: RAWDevelopmentConfiguration?
    public var inputDevelopment: SourceImage.InputDevelopment { lease.source.inputDevelopment }
    public var canRedevelopRAW: Bool { inputDevelopment == .rawDevelopment }
    let lease: PhotoSourceLease
    let inputResources: ModelResourceSet
    let recipeID: String
    let workingID: String
    let calibrationID: String

    init(_ source: SourceImage, descriptor: SourceDescriptor, recipe: InputRecipe, working: WorkingImageContract,
         calibration: InputCalibration?, inputResources: ModelResourceSet, rawOverrides: [RAWOverride], rawConfiguration: RAWDevelopmentConfiguration?) throws {
        try Task.checkCancellation()
        try InputAdapter.validateRAWRequest(source, descriptor: descriptor, recipe: recipe, rawOverrides: rawOverrides, rawConfiguration: rawConfiguration)
        try descriptor.validate()
        self.descriptor = descriptor
        self.recipe = recipe
        self.working = working
        self.calibration = calibration
        self.rawOverrides = rawOverrides
        self.rawConfiguration = rawConfiguration
        struct RecipeBinding: Encodable {
            let declaredDigest: String
            let overrides: [RAWOverride]
            let externalDigest: String?
        }
        recipeID = try Digest.data(JSON.encode(RecipeBinding(declaredDigest: recipe.digest(), overrides: rawOverrides,
                                                           externalDigest: rawConfiguration?.identity.digest())))
        workingID = try working.digest()
        calibrationID = try calibration?.digest() ?? InputCalibration.unqualifiedReferenceIdentity(working: working)
        let resourceIDs = Set(calibration?.resources.map(\.id) ?? [])
        self.inputResources = try ModelResourceSet(luts: inputResources.luts.filter { resourceIDs.contains($0.key) })
        lease = try PhotoSourceLease(source)
    }
}
