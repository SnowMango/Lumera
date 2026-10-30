import Foundation
import Darwin
public enum SafeFiles {
    /// A same-directory temporary file plus link provides atomic no-clobber semantics.
    public static func write(_ data: Data, to url: URL, overwrite: Bool = false) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".ccdlab-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let code = temporary.path.withCString { src in url.path.withCString { dst in overwrite ? Darwin.rename(src, dst) : Darwin.link(src, dst) } }
        guard code == 0 else { throw LabError.io("无法写入 \(url.lastPathComponent)： \(String(cString: strerror(errno)))") }
    }
}
