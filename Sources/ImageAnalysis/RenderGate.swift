import ImagingCore
import ImageRendering
import Foundation
public struct RenderGate: Sendable {
    private var current: UUID?
    public init() {}
    public mutating func begin()->UUID {let id=UUID();current=id;return id}
    public mutating func cancel(){current=nil}
    public func accepts(_ id:UUID)->Bool {current==id}
}
