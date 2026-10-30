/// Describes tightly packed LUT sample memory. Float32 uses native byte order.
/// All data uses Lumera's encoded-sRGB to encoded-sRGB SDR contract.
public struct LUTDataDescriptor:Equatable,Sendable {
    public enum Layout:Sendable {case rgbFloat32,rgbaFloat32}
    public enum Order:Sendable {case redFastest,blueFastest}
    public var dimension:Int
    public var layout:Layout
    public var order:Order
    public init(dimension:Int,layout:Layout,order:Order = .redFastest) {
        self.dimension=dimension;self.layout=layout;self.order=order
    }
}
