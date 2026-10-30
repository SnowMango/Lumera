import Foundation
import ImagingCore

enum DetailTextureDeveloperCheck {
    static func detail(progress:@Sendable(GenerationProgress)->Void = {_ in})throws->[String:Double] {
        func solve(_ b:MeasurementBundle)throws->GenerationProposal {try DetailSolver.solve(measurements:b,baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init(),progress:progress)}
        var edgeError=0.0,fineError=0.0,softError=0.0,rejected=0.0
        for (size,fine,soft) in [(2048,1.18,0.45),(2560,0.9,0.3)] {
            progress(.init(stage:"准备 \(size) 像素独立细节参考",completed:0))
            let fixture=try DetailReferenceSamples.make(side:size,fineGain:fine,softness:soft);defer{fixture.cleanup()}
            let candidate=try solve(fixture.measurements)
            fineError=max(fineError,abs(candidate.profile.parameters.detail.fineGain-fine));softError=max(softError,abs(candidate.profile.parameters.softening.amount-soft))
            edgeError=max(edgeError,candidate.evidence.compactMap(\.measured).max() ?? .infinity)
            var missing=fixture.measurements;missing.frames[0].curves=[:]
            var sharper=fixture.measurements;for i in sharper.frames.indices where sharper.frames[i].step.role == .target {sharper.frames[i].metrics["mtf50"]=0.5}
            var leaked=fixture.measurements;leaked.frames[0].step.purpose = .validation
            var flat=fixture.measurements;for i in flat.frames.indices {flat.frames[i].metrics["detailRMS"]=0}
            var duplicate=fixture.measurements;duplicate.frames[1].fileDigest=duplicate.frames[0].fileDigest
            var quality=fixture.measurements;quality.frames[0].patches=[]
            var mixed=fixture.measurements;mixed.frames[0].actualConditions.iso=200;mixed.frames[0].step.expectedISO=200
            for bad in [missing,sharper,leaked,flat,duplicate,quality,mixed] {
                do{_=try solve(bad);rejected+=1}catch is CancellationError{throw CancellationError()}catch{}
            }
        }
        let limited=try DetailReferenceSamples.make(side:2048,highFrequency:false);defer{limited.cleanup()}
        do{_=try solve(limited.measurements);rejected+=1}catch is CancellationError{throw CancellationError()}catch{}
        var active=Profile.standard;active.parameters.glow.enabled=true;active.parameters.glow.amount=0.2
        do{_=try DetailSolver.solve(measurements:limited.measurements,baseline:active,options:.init(model:.digital,modules:[.detail],baseline:active),resources:.init());rejected+=1}catch is CancellationError{throw CancellationError()}catch{}
        let poor=try DetailReferenceSamples.make(side:2048,printWidth:8);defer{poor.cleanup()}
        do{_=try solve(poor.measurements);rejected+=1}catch is CancellationError{throw CancellationError()}catch{}
        return ["edgeResponse":edgeError,"fineRecovery":fineError,"softnessRecovery":softError,"rejectAmbiguousDetail":rejected]
    }
    static func texture(progress:@Sendable(GenerationProgress)->Void = {_ in})throws->[String:Double] {
        var varianceError=0.0,amplitudeError=0.0,rejected=0.0
        for size in [256,512] {for seed:UInt64 in [1729,99173,4291] {
            let f=try TextureReferenceSamples.make(sigma:0.02,fixedPattern:true,side:size,seed:seed)
            let stats=try GPUTemporalTexture(device:f.device).measure(f.textures)
            for v in [stats.training.varianceY,stats.validation.varianceY] {varianceError=max(varianceError,abs(v/0.0004-1))}
        }}
        for model in [GenerationModel.digital,.film] {
            let f=try TextureReferenceSamples.files(model:model);defer{f.cleanup()}
            let p=try TextureSolver.solve(measurements:f.measurements,baseline:f.baseline,options:.init(model:model,modules:[.texture],baseline:f.baseline),resources:.init(),progress:progress)
            for brightness in [0.2,0.45,0.7] {
                let sigma=model == .digital ? p.profile.parameters.noise.effectiveSigma(at:brightness):p.profile.parameters.grain.amount*p.profile.parameters.grain.luminanceCurve.value(at:brightness)
                amplitudeError=max(amplitudeError,abs(sigma/0.025-1))
            }
            varianceError=max(varianceError,p.evidence.compactMap(\.measured).max() ?? .infinity)
        }
        let g=TextureReferenceSamples.analyticalGroups(amplitude:0.025)
        var dirty=g;dirty[0].target.training.varianceY=0.000001
        var unseen=g;unseen[1].target.validation.varianceY *= 2
        var compression=g;compression[0].target.training.bands=[0.99,0.009,0.001]
        var chroma=g;chroma[0].target.training.varianceCb=0.01
        for bad in [dirty,unseen,compression,chroma,Array(g.prefix(2))] {
            do{_=try TextureSolver.estimate(groups:bad,model:.digital);rejected+=1}catch is CancellationError{throw CancellationError()}catch{}
        }
        let f=try TextureReferenceSamples.make(sigma:0.02,fixedPattern:false)
        do{_=try GPUTemporalTexture(device:f.device).measure([f.textures[0],f.textures[0],f.textures[2],f.textures[3]]);rejected+=1}catch is CancellationError{throw CancellationError()}catch{}
        return ["variance":varianceError,"amplitudeRecovery":amplitudeError,"rejectAmbiguousTexture":rejected]
    }
}
