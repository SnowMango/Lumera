/// Per-axis resolution of an effect's intermediate layer, relative to the current render frame.
public enum EffectResolution:Int,Codable,CaseIterable,Sendable {
    case full=1,half=2,quarter=4,eighth=8,sixteenth=16
    public var scale:Double {1/Double(rawValue)}
}
