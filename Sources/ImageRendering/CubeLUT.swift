import Foundation
import ImagingCore
public struct CubeLUT: Equatable, Sendable {
    public let size: Int
    public let rgba: [Float]
    public static func parse(_ text: String) throws -> CubeLUT {
        guard text.utf8.count <= 16_000_000 else { throw LabError.invalid("LUT 文件超过 16 MB，请使用较小的 3D LUT") }
        var size: Int?, values=[Float](), seenMin=false, seenMax=false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line=raw.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)[0].trimmingCharacters(in:.whitespaces)
            if line.isEmpty {continue}
            let parts=line.split(whereSeparator: \.isWhitespace)
            switch parts[0] {
            case "TITLE": continue
            case "LUT_3D_SIZE":
                guard size == nil, parts.count==2, let n=Int(parts[1]), (2...65).contains(n) else {throw LabError.invalid("3D LUT 每边尺寸必须为 2–65，且只能声明一次")}; size=n
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let isMin=parts[0]=="DOMAIN_MIN", expected:Float=isMin ? 0 : 1
                guard parts.count==4, (!isMin || !seenMin), (isMin || !seenMax), parts.dropFirst().allSatisfy({Float($0)==expected}) else {throw LabError.unsupported("只支持输入范围为 0–1 的 sRGB LUT；Log、HDR 或其他范围的 LUT 需先转换")}
                if isMin {seenMin=true}else{seenMax=true}
            default:
                guard size != nil, parts.count==3 else {throw LabError.unsupported("只支持单个 3D .cube LUT，不支持 1D 或组合 LUT")}
                for p in parts {guard let v=Float(p),v.isFinite,(0...1).contains(v) else {throw LabError.invalid("LUT 输出值必须是 0–1 范围内的有效 SDR 数值")};values.append(v)}
                values.append(1)
                guard values.count <= 65*65*65*4 else {throw LabError.invalid("LUT 数据行过多，请检查尺寸和文件格式")}
            }
        }
        guard let n=size,values.count==n*n*n*4 else {throw LabError.invalid("LUT 数据数量与声明尺寸不符，请检查文件是否完整")}
        return CubeLUT(size:n,rgba:values)
    }
}
