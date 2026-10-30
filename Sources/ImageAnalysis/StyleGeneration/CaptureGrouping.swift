import Foundation
import ImagingCore

/// Role and subject are selected once for a batch. EXIF alone cannot identify an unmarked flat field or which device is the reference.
public struct CaptureFile:Sendable {
    public var url:URL,digest:String,role:CaptureRole,target:CaptureTarget,conditions:CaptureConditions
    public init(url:URL,digest:String,role:CaptureRole,target:CaptureTarget,conditions:CaptureConditions) {self.url=url;self.digest=digest;self.role=role;self.target=target;self.conditions=conditions}
}
public enum CaptureGrouping {
    public static func group(files:[CaptureFile],protocol plan:CaptureProtocol,targets:Set<CaptureTarget> = Set(CaptureTarget.allCases))->CaptureSet {
        do {try plan.validate()}catch {return .init(protocolVersion:plan.version,records:[],issues:[error.localizedDescription])}
        var issues=[String](),records=[CaptureRecord](),buckets=[String:[CaptureFile]](),seen=Set<String>()
        for file in files.filter({targets.contains($0.target)}).sorted(by:{$0.url.path<$1.url.path}) {
            guard !file.digest.isEmpty,seen.insert(file.digest).inserted else {issues.append("重复或缺少摘要：\(file.url.lastPathComponent)");continue}
            guard let iso=file.conditions.iso,let shutter=file.conditions.exposureDurationSeconds,iso.isFinite,shutter.isFinite,iso>0,shutter>0 else {issues.append("缺少 ISO/快门：\(file.url.lastPathComponent)");continue}
            let candidates=plan.steps.filter{$0.role==file.role && $0.target==file.target && $0.repeatIndex==0 && abs(log2(iso/$0.expectedISO))<=0.08 && abs(log2(shutter/$0.expectedExposureSeconds))<=0.15}
            guard candidates.count==1 else {issues.append("不能唯一归组：\(file.url.lastPathComponent)，请检查设备角色、素材类型和实际拍摄参数");continue}
            buckets[key(candidates[0]),default:[]].append(file)
        }
        for head in plan.steps.filter({$0.repeatIndex==0 && targets.contains($0.target)}) {
            let expected=plan.steps.filter{key($0)==key(head)}.sorted{$0.repeatIndex<$1.repeatIndex}
            // Fixed lexical order is chosen before any measurements or optimization. Validation never selects the best repeat.
            let found=(buckets[key(head)] ?? []).sorted{$0.url.path<$1.url.path}
            guard expected.count==found.count else {issues.append("\(key(head))：需要 \(expected.count) 张，实际 \(found.count) 张");continue}
            for (step,file) in zip(expected,found) {records.append(.init(url:file.url,fileDigest:file.digest,step:step,actualConditions:file.conditions,issues:[]))}
        }
        return .init(protocolVersion:plan.version,records:records,issues:issues)
    }
    private static func key(_ step:CaptureStep)->String {"\(step.role.rawValue)/\(step.target.rawValue)/\(step.conditionIndex)/\(Int(step.exposureEV))"}
}
