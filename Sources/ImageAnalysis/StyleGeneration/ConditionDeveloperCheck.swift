import Foundation
import ImagingCore

enum ConditionDeveloperCheck {
    static func captures()throws->CaptureSet {
        let plan=try CaptureProtocol(input:.init(id:"a",isoLevels:[100,400,1600],baseExposureSeconds:0.01),target:.init(id:"b",isoLevels:[200,800,3200],baseExposureSeconds:0.01))
        // Axis-only protocol fixture; physical file validation is separate and uses the real flat files below.
        return .init(protocolVersion:plan.version,records:plan.steps.map{s in
            var c=CaptureConditions();c.iso=s.expectedISO;c.exposureDurationSeconds=s.expectedExposureSeconds
            return .init(url:URL(fileURLWithPath:"/fixture/"+s.id),fileDigest:s.id,step:s,actualConditions:c,issues:[])
        },issues:[])
    }
    static func run(progress:@Sendable(GenerationProgress)->Void = {_ in})throws->[String:Double] {
        let f=try TextureReferenceSamples.files(model:.digital,allConditions:true);defer{f.cleanup()}
        var endpoints=[GenerationProposal]()
        for condition in [0,2] {
            endpoints.append(try TextureSolver.solve(measurements:f.measurements,baseline:f.baseline,options:.init(model:.digital,modules:[.texture],baseline:f.baseline,conditionIndex:condition),resources:.init(),progress:progress))
        }
        let axisCaptures=try captures(),p=try ConditionResponseSolver.solve(proposals:endpoints,captures:axisCaptures,baseline:f.baseline)
        let report=try CombinedValidation.run(proposal:p,baseline:f.baseline,measurements:f.measurements,resources:.init(),progress:progress)
        guard report.passed else{throw LabError.measurement("独立中间 ISO 图像验证失败："+report.rows.filter{$0.status != .passed}.map(\.detail).joined(separator:"；"))}
        var accepted=0.0
        var missing=axisCaptures;missing.records.removeAll{$0.step.conditionIndex==1}
        var duplicates=endpoints;duplicates[1].sourceISO=duplicates[0].sourceISO
        var targetAxis=endpoints;targetAxis[1].sourceISO=3200
        for (proposals,captures) in [(endpoints,missing),(duplicates,axisCaptures),(targetAxis,axisCaptures),(Array(endpoints.prefix(1)),axisCaptures)] {
            do{_=try ConditionResponseSolver.solve(proposals:proposals,captures:captures,baseline:f.baseline);accepted+=1}catch is CancellationError{throw CancellationError()}catch{}
        }
        let nonmonotone=try TextureReferenceSamples.files(model:.digital,allConditions:true,middleMultiplier:1.4);defer{nonmonotone.cleanup()}
        // No re-fit after looking at the withheld middle: this deliberately fails.
        let bad=try CombinedValidation.run(proposal:p,baseline:f.baseline,measurements:nonmonotone.measurements,resources:.init(),progress:progress)
        if bad.passed {accepted+=1}
        return ["heldOutCondition":report.rows.filter{$0.caseID.hasPrefix("flat-1-") && $0.caseID.hasSuffix("方差")}.compactMap(\.measured).max() ?? .infinity,"rejectUnsupportedAxis":accepted]
    }
}
