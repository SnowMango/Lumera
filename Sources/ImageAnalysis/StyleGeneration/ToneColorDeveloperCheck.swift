import Foundation
import ImagingCore

enum ToneColorDeveloperCheck {
    static func measure() throws ->[String:Double] {
        func solve(_ bundle:MeasurementBundle,_ resources:GenerationResources = .init()) throws ->GenerationProposal {
            try ToneColorSolver.solve(measurements:bundle,baseline:.standard,options:.init(model:.digital,modules:[.toneColor],baseline:.standard),resources:resources)
        }
        let good=try ColorReferenceSamples.make(),candidate=try solve(good)
        var colorError=candidate.evidence.compactMap(\.measured).max() ?? .infinity
        var matrixError=zip(candidate.profile.parameters.color.matrix.values,ColorReferenceSamples.matrix).map{abs($0-$1)}.max()!
        var toneError=max(abs(candidate.profile.parameters.tone.curve.value(at:0.25)-0.20),abs(candidate.profile.parameters.tone.curve.value(at:0.75)-0.80))
        let neutral=try solve(ColorReferenceSamples.make(neutral:true))
        matrixError=max(matrixError,zip(neutral.profile.parameters.color.matrix.values,ColorMatrix3x3().values).map{abs($0-$1)}.max()!)
        var perturbed=good
        for i in perturbed.frames.indices where perturbed.frames[i].step.role == .target {for j in perturbed.frames[i].patches.indices {for c in 0..<3 {perturbed.frames[i].patches[j].mean[c]+=Double((i+j+c)%3-1)*0.0001}}}
        let stable=try solve(perturbed)
        colorError=max(colorError,stable.evidence.compactMap(\.measured).max() ?? .infinity)
        matrixError=max(matrixError,zip(stable.profile.parameters.color.matrix.values,ColorReferenceSamples.matrix).map{abs($0-$1)}.max()!)
        toneError=max(toneError,abs(stable.profile.parameters.tone.curve.value(at:0.25)-0.20),abs(stable.profile.parameters.tone.curve.value(at:0.75)-0.80))
        var single=good;single.frames.removeAll{$0.step.exposureEV != 0}
        var grey=good;for i in grey.frames.indices {for j in grey.frames[i].patches.indices where grey.frames[i].patches[j].kind == .color {grey.frames[i].patches[j].mean=[0.4,0.4,0.4]}}
        var clipped=good;clipped.frames[0].patches[0].clippedFraction=0.2
        var noHoldout=good;noHoldout.frames.removeAll{$0.step.purpose == .validation}
        var duplicate=good;duplicate.frames.append(good.frames[0])
        var unseenFailure=good
        for i in unseenFailure.frames.indices where unseenFailure.frames[i].step.role == .target && unseenFailure.frames[i].step.conditionIndex==1 {
            for j in unseenFailure.frames[i].patches.indices {unseenFailure.frames[i].patches[j].mean=unseenFailure.frames[i].patches[j].mean.map{min(0.95,$0+0.05)}}
        }
        var falseAccepts=0.0
        for bad in [single,grey,clipped,noHoldout,duplicate,unseenFailure,try ColorReferenceSamples.make(exposureGain:1.4)] {
            do{_=try solve(bad);falseAccepts+=1}catch is CancellationError {throw CancellationError()}catch{}
        }
        do{_=try solve(good,.init(rendering:.init(lut:IndependentLUTCheck.cube{$0})));falseAccepts+=1}catch is CancellationError {throw CancellationError()}catch{}
        var noHigh=good;noHigh.frames.removeAll{$0.step.conditionIndex==2}
        var leaked=good;for i in leaked.frames.indices where leaked.frames[i].step.conditionIndex != 1 {leaked.frames[i].step.purpose = .training}
        var varying=good;varying.frames[0].patches[0].variance=[0.0016,0.0016,0.0016]
        var malformed=good;malformed.frames[0].step.exposureEV=1e100
        for bad in [noHigh,leaked,varying,malformed] {
            do{_=try solve(bad);falseAccepts+=1}catch is CancellationError {throw CancellationError()}catch{}
        }
        for index in 0..<3 {
            var fixed=Profile.standard
            if index==0 {fixed.parameters.color.exposureEV=0.5}
            if index==1 {fixed.parameters.color.shift.redGreen=0.1}
            if index==2 {fixed.parameters.color.whiteBalance.destination = .init(x:0.35,y:0.35)}
            do{_=try ToneColorSolver.solve(measurements:good,baseline:fixed,options:.init(model:.digital,modules:[.toneColor],baseline:fixed),resources:.init());falseAccepts+=1}catch is CancellationError {throw CancellationError()}catch{}
        }
        return ["patchPixelValidation":try pixelValidation(),"heldOutColor":colorError,"canonicalMatrix":matrixError,"anchoredTone":toneError,"rejectAmbiguousColor":falseAccepts]
    }
    private static func pixelValidation() throws ->Double {
        let w=1400,h=2000
        var image=try ImageFrame.solid(width:w,height:h,value:0)
        for y in 0..<h {for x in 0..<w {for c in 0..<3 {image.pixels[(y*w+x)*4+c] = (x+y)%2==0 ? 0.21:0.29}}}
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer{try? FileManager.default.removeItem(at:file)}
        let data=try ImageCodec.encodeReference(image);try data.write(to:file)
        var frame=try ColorReferenceSamples.make().frames.first{$0.step.role == .input}!
        frame.width=w;frame.height=h;frame.fileDigest=Digest.data(data);frame.sourceURL=file
        frame.pose = .init(coefficients:[Double(w),0,0,0,Double(h),0,0,0,1])
        let pair=ColorPatchPair(group:frame.step.pairKey,id:"gray-0",kind:.gray,input:[0.25,0.25,0.25],target:[0.082,0.082,0.082],training:false)
        var profile=Profile.standard;profile.parameters.tone.enabled=true
        profile.parameters.tone.curve = .init(knots:[.init(x:0,y:0),.init(x:0.25,y:0.05),.init(x:0.5,y:0.5),.init(x:0.75,y:0.8),.init(x:1,y:1)])
        let renderer=try MetalRenderer(cacheLimitBytes:128*1024*1024);defer{renderer.releaseCaches()}
        let actual=try ToneColorSolver.predictions([pair],profile:profile,renderer:renderer,frames:[frame])[0]
        // Half 0.21, half 0.29: independent piecewise linear result = (0.042+0.122)/2.
        return actual.map{abs($0-0.082)}.max()!
    }

}
