import Foundation
import ImagingCore

public enum GenerationMaterials {
    public static var folder:URL {Bundle.module.url(forResource:"Fixtures",withExtension:nil)!}
    private struct Manifest:Decodable {struct File:Decodable {let name:String,sha256:String};let version:String,kind:String,files:[File]}
    public static func verify(_ folder:URL) throws {
        let data=try Data(contentsOf:folder.appendingPathComponent("manifest.json"))
        guard Digest.data(data)==GenerationLimits.fixtureManifestDigest else {throw LabError.invalid("自检材料清单不是当前冻结版本")}
        let manifest=try JSONDecoder().decode(Manifest.self,from:data)
        guard manifest.version=="style-generation-materials-1",manifest.kind=="synthetic-print-render",Set(manifest.files.map(\.name))==["layout.json","composite.png"] else {throw LabError.invalid("自检材料合同无效")}
        for file in manifest.files {
            guard Digest.data(try Data(contentsOf:folder.appendingPathComponent(file.name)))==file.sha256 else {throw LabError.invalid("自检材料内容已改变："+file.name)}
        }
    }
}
