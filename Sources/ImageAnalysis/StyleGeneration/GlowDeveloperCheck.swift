import Foundation
import Metal
import ImagingCore

/// Double precision spatial convolution reference, independent of the GPU renderer.
enum GlowDeveloperCheck {
    struct Fixture {var folder:URL,bundle:MeasurementBundle,baseline:Profile;func cleanup(){try? FileManager.default.removeItem(at:folder)}}
    static func fixture(glow:Double=0.25,halation:Double=0.35,sourceRadius:Double=8,targetRadius:Double=8,ghost:Bool=false,clipped:Bool=false,trainingGlow:Double?=nil,background:Double=0.002,ghostOffset:Double=25)throws->Fixture {
        let side=512,n=side*side,center=Double(side-1)/2
        var profile=Profile.standard
        profile.parameters.glow.nearSigma=8;profile.parameters.glow.farSigma=24;profile.parameters.glow.threshold=0.08;profile.parameters.glow.knee=0.03
        profile.parameters.halation.sigma=16;profile.parameters.halation.threshold=0.08;profile.parameters.halation.knee=0.03
        func encoded(_ v:Double)->Double{v<=0.0031308 ? 12.92*v:1.055*pow(v,1/2.4)-0.055}
        func linear(_ v:Double)->Double{v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)}
        func highlight(_ v:Double)->Double{let t=min(1,max(0,(v-0.05)/0.06));return v*t*t*(3-2*t)}
        func blur(_ input:[Double],_ sigma:Double)->[Double] {
            let radius=Int(ceil(sigma*3)),weights=(-radius...radius).map{exp(-0.5*pow(Double($0)/sigma,2))},sum=weights.reduce(0,+)
            var temp=input,out=input
            for y in 0..<side {for x in 0..<side {var v=0.0;for k in -radius...radius{v+=input[y*side+min(side-1,max(0,x+k))]*weights[k+radius]};temp[y*side+x]=v/sum}}
            for y in 0..<side {for x in 0..<side {var v=0.0;for k in -radius...radius{v+=temp[min(side-1,max(0,y+k))*side+x]*weights[k+radius]};out[y*side+x]=v/sum}}
            return out
        }
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        do {
            let plan=try CaptureProtocol(input:.init(id:"a",isoLevels:[100,400,1600],baseExposureSeconds:0.01),target:.init(id:"b",isoLevels:[100,400,1600],baseExposureSeconds:0.01))
            var frames=[FrameMeasurements]()
            for s in plan.steps where s.target == .light {try autoreleasepool {
                let radius=s.role == .input ? sourceRadius:targetRadius
                var source=[Double](repeating:0,count:n)
                for y in 0..<side {for x in 0..<side {
                    let r=hypot(Double(x)-center,Double(y)-center)
                    var v=(background+0.318*(0.5+0.5*erf((radius-r)/0.5)))*pow(2,s.exposureEV)*(1+Double(s.repeatIndex-1)*0.001)
                    if ghost && s.role == .target && hypot(Double(x)-center-ghostOffset,Double(y)-center-10)<4{v+=0.2}
                    if clipped && r<3{v=1}
                    // Actual exported 16-bit reference quantization before subsequent oracle processing.
                    let q=(min(1,max(0,encoded(v)))*65535).rounded()/65535;source[y*side+x]=linear(q)
                }}
                let values:[Float]
                if s.role == .input {values=source.flatMap{let e=Float(encoded($0));return [e,e,e,1]}}
                else {
                    let hi=source.map(highlight),near=blur(hi,2),far=blur(hi,6)
                    let amount=(s.repeatIndex<2 && s.exposureEV != -1) ? (trainingGlow ?? glow):glow
                    let neutral=source.indices.map{source[$0]+amount*(near[$0]*0.75+far[$0]*0.25-hi[$0])}
                    let h=neutral.map(highlight),scatter=blur(h,4)
                    values=source.indices.flatMap{i->[Float] in let halo=max(0,scatter[i]-h[i])*halation;return [1.0,0.2,0.04].map{Float(encoded(neutral[i]+halo*$0))}+[1]}
                }
                let url=folder.appendingPathComponent(s.id+".png"),image=try ImageFrame(width:side,height:side,pixels:values),data=try ImageCodec.encodeReference(image);try data.write(to:url)
                var conditions=CaptureConditions();conditions.iso=s.expectedISO;conditions.exposureDurationSeconds=s.expectedExposureSeconds
                // The light quality patch is a central valid sampling region; strict light-specific geometry is measured from files by the solver.
                let patch=PatchMeasurement(id:"light",kind:.light,mean:[0.2,0.2,0.2],variance:[0.01,0.01,0.01],clippedFraction:0,pixelCount:n)
                frames.append(.init(fileDigest:Digest.data(data),step:s,actualConditions:conditions,width:side,height:side,patches:[patch],sourceURL:url,pose:nil))
            }}
            return .init(folder:folder,bundle:.init(frames:frames,resourceDigests:[:]),baseline:profile)
        }catch{try? FileManager.default.removeItem(at:folder);throw error}
    }
    static func run(progress:@Sendable(GenerationProgress)->Void = {_ in})throws->[String:Double] {
        func solve(_ f:Fixture)throws->GenerationProposal{try GlowSolver.solve(measurements:f.bundle,baseline:f.baseline,options:.init(model:.film,modules:[.glow],baseline:f.baseline),resources:.init(),progress:progress)}
        let good=try fixture();defer{good.cleanup()}
        guard let device=MTLCreateSystemDefaultDevice()else{throw LabError.noMetal}
        let input=try ImageCodec.load(good.bundle.frames.first{$0.step.role == .input}!.sourceURL!),renderer=try MetalRenderer(cacheLimitBytes:128*1024*1024)
        defer{renderer.releaseCaches()}
        let observed=try renderer.renderLightSignature(input,style:ResolvedStyle(profile:.standard),resources:.init(),measurement:GPULightMeasurement(device:device))
        var sums=Array(repeating:[0.0,0,0],count:256),counts=Array(repeating:0.0,count:256)
        let center=Double(input.width-1)/2,radius=128.0
        for y in 0..<input.height {for x in 0..<input.width {
            let dx=Double(x)-center,dy=Double(y)-center,r=hypot(dx,dy)
            guard r<radius else{continue}
            let bin=Int(r/radius*64)*4+(dx>=0 ? 1:0)+(dy>=0 ? 2:0)
            for c in 0..<3 {let v=Double(input.pixels[(y*input.width+x)*4+c]);sums[bin][c] += v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)}
            counts[bin]+=1
        }}
        let expected=sums.enumerated().flatMap{i,v in v.map{$0/max(1,counts[i])}}
        let reduction=zip(expected,observed.rgb).map{abs($0-$1)}.max() ?? .infinity
        let proposal=try solve(good)
        guard abs(proposal.profile.parameters.glow.amount-0.25)<0.03,abs(proposal.profile.parameters.halation.amount-0.35)<0.03 else{throw LabError.measurement("独立扩散参考参数恢复未通过")}
        var accepted=0.0
        for mode in 0..<5 {
            let bad=try fixture(targetRadius:mode==0 ? 16:8,ghost:mode==1 || mode==4,clipped:mode==2,background:mode==3 ? 0.06:0.002,ghostOffset:mode==4 ? 180:25);defer{bad.cleanup()}
            do{_=try solve(bad);accepted+=1}catch is CancellationError{throw CancellationError()}catch{}
        }
        var regression=try fixture(trainingGlow:0.28);defer{regression.cleanup()}
        regression.baseline.parameters.glow.enabled=true;regression.baseline.parameters.glow.amount=0.25
        regression.baseline.parameters.halation.enabled=true;regression.baseline.parameters.halation.amount=0.35
        do{_=try solve(regression);accepted+=1}catch is CancellationError{throw CancellationError()}catch{}
        var absent=good;absent.bundle.frames.removeLast()
        do{_=try solve(absent);accepted+=1}catch is CancellationError{throw CancellationError()}catch{}
        return ["rgbReduction":reduction,"amountRecovery":max(abs(proposal.profile.parameters.glow.amount-0.25),abs(proposal.profile.parameters.halation.amount-0.35)),"radialResponse":proposal.evidence.compactMap(\.measured).max() ?? .infinity,"rejectAmbiguousGlow":accepted]
    }
}
