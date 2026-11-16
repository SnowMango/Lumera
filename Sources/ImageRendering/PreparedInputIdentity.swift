import ImagingCore

/// Configuration identity only: never contains pixels, exposure, frame stamps or execution state.
/// Construction uses the public validated identity algorithms, preserving their exact byte format.
final class PreparedInputIdentity: Sendable {
    let descriptor: SourceDescriptor
    let recipe: EffectiveInputRecipe
    let working: WorkingImageContract
    let recipeDigest: String
    let sourceID: String
    let unqualifiedReferenceID: String

    init(descriptor: SourceDescriptor, recipe: EffectiveInputRecipe, working: WorkingImageContract) throws {
        self.descriptor = descriptor; self.recipe = try recipe.preparingDigest(); self.working = working
        recipeDigest = try self.recipe.digest()
        sourceID = try descriptor.contentIdentity(effectiveRecipeDigest: recipeDigest, working: working)
        unqualifiedReferenceID = try InputCalibration.unqualifiedReferenceIdentity(working: working)
    }
}
