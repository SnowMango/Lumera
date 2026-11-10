/// Result of the renderer's precision validation for the supplied input bounds,
/// frame geometry and prepared controls. A safe Float16 assessment concerns
/// storage and arithmetic. Float32 uses the renderer's existing color gain guard.
public enum PrecisionAssessment: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case input
        case colorArithmetic
        case correctionColor
        case correctionLUT
        case resize
        case creativeColor
        case creativeLUT
        case tone
        case spatialAccumulation
        case detail
        case linearOpticalInput
        case softening
        case vignette
        case glow
        case halation
        case finish
        case noise
        case grain
    }

    case safe
    case requiresInputRange
    case unsupported(stage: Stage, reason: String)
}
