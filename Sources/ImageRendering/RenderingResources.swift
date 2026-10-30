import Foundation
import Metal
import ImagingCore

/// Single owner for shared rendering shaders. Measurement kernels belong to ImageAnalysis.
public enum RenderingResources {
    public static func makeLibrary(device: MTLDevice, options: MTLCompileOptions? = nil, additionalSource: String = "") throws -> MTLLibrary {
        guard let url=Bundle.module.url(forResource:"Effects",withExtension:"metal",subdirectory:"Resources") else {
            throw LabError.io("Missing camera rendering resources")
        }
        return try device.makeLibrary(source:String(contentsOf:url,encoding:.utf8)+"\n"+additionalSource,options:options)
    }
}
