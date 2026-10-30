import Foundation
import ImagingCore
import ImageRendering

public enum AlgorithmID:String,Codable,CaseIterable,Sendable {
    case independentLUT,targetDetection,captureQuality,toneColor,detail,texture,glow,conditionResponse,combinedValidation
    public var title:String {switch self {
    case .independentLUT:return "配置与 LUT 独立输入"
    case .targetDetection:return "目标板定位"
    case .captureQuality:return "拍摄质量与归组"
    case .toneColor:return "明暗与颜色建议"
    case .detail:return "细节与柔化联合估计"
    case .texture:return "噪点或颗粒估计"
    case .glow:return "亮源扩散估计"
    case .conditionResponse:return "拍摄条件响应"
    case .combinedValidation:return "独立照片组合验证"
    }}
}
public enum AlgorithmCheckStatus:String,Codable,Sendable {case passed,failed,insufficient,skipped}
public struct GenerationProgress:Sendable {
    public var stage:String,completed:Int,total:Int?,elapsedSeconds:Double
    public init(stage:String,completed:Int,total:Int?=nil,elapsedSeconds:Double=0) {self.stage=stage;self.completed=completed;self.total=total;self.elapsedSeconds=elapsedSeconds}
}
public struct AlgorithmCaseResult:Codable,Equatable,Sendable {
    public var algorithm:AlgorithmID,caseID:String,status:AlgorithmCheckStatus,measured:Double?,limit:GenerationLimit,detail:String
}
public struct AlgorithmCheckReport:Codable,Equatable,Sendable {
    public var reportVersion=1,engineVersion=Profile.engineVersion,algorithmVersion=GenerationLimits.algorithmVersion,limitsVersion=GenerationLimits.version
    public var materialDigest=GenerationLimits.materialDigest,seed:UInt32=1729,os=ProcessInfo.processInfo.operatingSystemVersionString,gpu:String
    public var elapsedSeconds:Double,results:[AlgorithmCaseResult]
    public var summary:String {results.map {"\($0.status.rawValue) · \($0.algorithm.title) / \($0.caseID)\n\($0.detail)"}.joined(separator:"\n\n")}
}
/// Developer integration gate. A report cannot qualify a missing case, stale model or skipped algorithm.
public struct GenerationEligibility:Sendable {
    public let algorithms:Set<AlgorithmID>
    public init(report:AlgorithmCheckReport,required:[AlgorithmID]) throws {
        guard !required.isEmpty,report.reportVersion==1,report.engineVersion==Profile.engineVersion,
              report.algorithmVersion==GenerationLimits.algorithmVersion,report.limitsVersion==GenerationLimits.version,
              report.materialDigest==GenerationLimits.materialDigest,report.seed==1729 else {throw LabError.invalid("自动算法自检证据缺失或版本已失效")}
        for id in required {
            let limits=GenerationLimits.cases(for:id),rows=report.results.filter{$0.algorithm==id}
            guard GenerationLimits.implemented.contains(id),rows.count==limits.count,Set(rows.map(\.caseID)).count==rows.count else {throw LabError.invalid("\(id.title) 尚未通过完整自检")}
            for limit in limits {
                guard let row=rows.first(where:{$0.caseID==limit.caseID}),row.status == .passed,row.limit==limit,
                      let measured=row.measured,limit.accepts(measured) else {throw LabError.invalid("\(id.title) 自检指标未通过：\(limit.caseID)")}
            }
        }
        algorithms=Set(required)
    }
}
/// These resources are caller-owned and deliberately not Codable.
public struct GenerationResources:Sendable {
    public var rendering:RenderResources
    public init(rendering:RenderResources = .init()) {self.rendering=rendering}
    public var digests:[String:String] {
        var result=[String:String]();if let lut=rendering.lut {result["creativeLUT"]=lut.sha256};if let lut=rendering.correctionLUT {result["correctionLUT"]=lut.sha256};return result
    }
}
public enum GenerationModel:String,Codable,Sendable {case digital,film}
public struct GenerationOptions:Sendable {
    public var model:GenerationModel,modules:Set<AlgorithmID>,baseline:Profile
    public var conditionIndex:Int=0
    public init(model:GenerationModel,modules:Set<AlgorithmID>,baseline:Profile,conditionIndex:Int=0) {self.model=model;self.modules=modules;self.baseline=baseline;self.conditionIndex=conditionIndex}
}
public struct GenerationProposal:Sendable {
    public var profile:Profile,evidence:[AlgorithmCaseResult],unresolved:[String],resourceDigests:[String:String]
    /// Only combined validation may set this flag. Per-module evidence is kept separately.
    public var validationPassed:Bool=false
    public var validatedModules:Set<AlgorithmID>=[]
    public var sourceISO:Double?=nil
    public init(profile:Profile,evidence:[AlgorithmCaseResult],unresolved:[String],resourceDigests:[String:String],validationPassed:Bool=false,validatedModules:Set<AlgorithmID>=[],sourceISO:Double?=nil) {
        self.profile=profile;self.evidence=evidence;self.unresolved=unresolved;self.resourceDigests=resourceDigests
        self.validationPassed=validationPassed;self.validatedModules=validatedModules;self.sourceISO=sourceISO
    }
}
