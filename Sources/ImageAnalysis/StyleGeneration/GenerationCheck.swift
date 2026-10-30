import Foundation
import Metal
import ImagingCore
import ImageRendering

public enum GenerationCheck {
    public static func run(algorithms:[AlgorithmID],fixtures:URL?=nil,progress:@Sendable (GenerationProgress)->Void = {_ in}) async throws -> AlgorithmCheckReport {
        try Task.checkCancellation()
        guard !algorithms.isEmpty,Set(algorithms).count==algorithms.count else {throw LabError.invalid("请选择不重复的自检项目")}
        let start=ProcessInfo.processInfo.systemUptime,total=algorithms.reduce(0){$0+GenerationLimits.cases(for:$1).count}
        var rows=[AlgorithmCaseResult]()
        for id in algorithms {
            try Task.checkCancellation()
            let measured:[String:Double]
            switch id {
            case .independentLUT:measured=try IndependentLUTCheck.measure()
            case .targetDetection:measured=try CaptureDeveloperCheck.detection(fixtures:fixtures ?? GenerationMaterials.folder)
            case .captureQuality:measured=try CaptureDeveloperCheck.quality()
            case .toneColor:measured=try ToneColorDeveloperCheck.measure()
            case .detail:measured=try DetailTextureDeveloperCheck.detail {p in progress(.init(stage:p.stage,completed:p.completed,total:p.total,elapsedSeconds:ProcessInfo.processInfo.systemUptime-start))}
            case .texture:measured=try DetailTextureDeveloperCheck.texture {p in progress(.init(stage:p.stage,completed:p.completed,total:p.total,elapsedSeconds:ProcessInfo.processInfo.systemUptime-start))}
            case .glow:measured=try GlowDeveloperCheck.run {p in progress(.init(stage:p.stage,completed:p.completed,total:p.total,elapsedSeconds:ProcessInfo.processInfo.systemUptime-start))}
            case .conditionResponse:measured=try ConditionDeveloperCheck.run {p in progress(.init(stage:p.stage,completed:p.completed,total:p.total,elapsedSeconds:ProcessInfo.processInfo.systemUptime-start))}
            case .combinedValidation:measured=try CombinedDeveloperCheck.run {p in progress(.init(stage:p.stage,completed:p.completed,total:p.total,elapsedSeconds:ProcessInfo.processInfo.systemUptime-start))}
            }
            for limit in GenerationLimits.cases(for:id) {
                try Task.checkCancellation()
                let value=measured[limit.caseID],status:AlgorithmCheckStatus=value.map{limit.accepts($0) ? .passed:.failed} ?? .insufficient
                rows.append(.init(algorithm:id,caseID:limit.caseID,status:status,measured:value,limit:limit,
                                  detail:value.map{"误差 \($0) \(limit.unit)；限值 \(limit.absoluteTolerance)。有效域：\(limit.validDomain)"} ?? (limit.caseID.hasPrefix("real") ? "缺少实际打印与独立标注相机照片；数字用例通过不能替代实拍验收。":"尚无该算法的完整实现与独立参考证据，不能用于自动修改参数。")))
                progress(.init(stage:id.title,completed:rows.count,total:total,elapsedSeconds:ProcessInfo.processInfo.systemUptime-start))
            }
        }
        return .init(gpu:MTLCreateSystemDefaultDevice()?.name ?? "unavailable",elapsedSeconds:ProcessInfo.processInfo.systemUptime-start,results:rows)
    }
}
/// Analytical inputs, expected channels and exposure formula are independent of the production color transform.
enum IndependentLUTCheck {
    static func cube(_ name:String="same",_ transform:([Double])->[Double])->LUTAsset {
        var lines=["LUT_3D_SIZE 2"]
        for b in 0...1 {for g in 0...1 {for r in 0...1 {lines.append(transform([Double(r),Double(g),Double(b)]).map(String.init(describing:)).joined(separator:" "))}}}
        return LUTAsset(name:name,cubeText:lines.joined(separator:"\n"))
    }
    static func measure() throws -> [String:Double] {
        let renderer=try MetalRenderer(cacheLimitBytes:128*1024*1024);defer{renderer.releaseCaches()}
        let image=try ImageFrame(width:2,height:2,pixels:Array(repeating:[Float](arrayLiteral:0.2,0.4,0.8,1),count:4).flatMap{$0})
        let request=RenderRequest(input:image.descriptor),half=cube{$0.map{$0*0.5}},permutation=cube{[$0[2],$0[1],$0[0]]}
        var result=[String:Double]()
        func error(_ p:Profile = .standard,_ resources:RenderResources = .init(),_ correction:DeviceCorrection?=nil,_ expected:[Double]) throws -> Double {
            let out=try renderer.render(image,style:ResolvedStyle(profile:p),correction:correction,resources:resources,request:request).image
            return zip(out.pixels.prefix(3),expected).map{abs(Double($0)-$1)}.max() ?? 1
        }
        let data=try JSON.encode(Profile.standard)+JSON.encode(DeviceCorrection()),json=String(decoding:data,as:UTF8.self)
        result["serialization"]=["lut","cubeText","sha256","path"].contains{json.contains("\""+$0+"\"")} ? 1:0
        // Float input decimal representation differs from Double by <3e-8; identity is bitwise.
        let identity=try renderer.render(image,style:ResolvedStyle(profile:.standard),request:request).image
        result["none"]=identity.pixels==image.pixels ? 0:1
        result["lutOnly"]=try error(.standard,.init(lut:half),nil,[0.1,0.2,0.4])
        var profile=Profile.standard;profile.parameters.color.matrix.values=[0,1,0,0,0,1,1,0,0]
        let correctionLUT=cube{[$0[2],$0[1],$0[0]]}
        result["combinedOrder"]=try error(profile,.init(lut:permutation,correctionLUT:correctionLUT),nil,[0.8,0.2,0.4])
        let combinedProfile=profile
        profile = .standard;profile.parameters.vignette.enabled=true;profile.parameters.vignette.startRadius=0;profile.parameters.vignette.falloff=1;profile.responses=[.init(target:.vignetteAmount,axis:.iso,operation:.replace,curve:.init(knots:[.init(x:100,y:0),.init(x:400,y:1)]))]
        let definition=try StyleEvaluator.compile(profile)
        guard let runtimeDevice=MTLCreateSystemDefaultDevice(),let queue=runtimeDevice.makeCommandQueue() else {throw LabError.noMetal}
        let runtime=try TextureEffectEncoder(device:runtimeDevice,precision:.float32),prepared=try runtime.prepare(definition,lut:half)
        defer {runtime.releaseCaches()}
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:2,height:2,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage = [.shaderRead,.shaderWrite]
        guard let texture=runtimeDevice.makeTexture(descriptor:descriptor) else {throw LabError.noMetal}
        image.pixels.withUnsafeBytes{texture.replace(region:MTLRegionMake2D(0,0,2,2),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:32)}
        guard let orderCommand=queue.makeCommandBuffer() else {throw LabError.noMetal}
        let ordered=try runtime.encode(texture,style:runtime.prepare(ResolvedStyle(profile:combinedProfile),lut:permutation),correction:runtime.prepareCorrection(nil,lut:correctionLUT),request:request,commandBuffer:orderCommand)
        let orderDone=DispatchSemaphore(value:0);orderCommand.addCompletedHandler{_ in orderDone.signal()};orderCommand.commit();orderDone.wait()
        if let error=orderCommand.error {throw error}
        var orderValues=[Float](repeating:0,count:16)
        orderValues.withUnsafeMutableBytes{ordered.getBytes($0.baseAddress!,bytesPerRow:32,from:MTLRegionMake2D(0,0,2,2),mipmapLevel:0)}
        result["combinedOrder"]=max(result["combinedOrder"] ?? 1,zip(orderValues.prefix(3),[0.8,0.2,0.4]).map{abs(Double($0)-$1)}.max() ?? 1)
        var dynamicError=0.0
        for (iso,ev) in [(100.0,0.0),(400.0,1.0)] {
            var c=CaptureConditions();c.iso=iso
            let evaluated=try StyleEvaluator.evaluate(definition,conditions:c),style=try evaluated.resolvedStyle()
            guard let command=queue.makeCommandBuffer() else {throw LabError.noMetal}
            let gpu=try runtime.encode(texture,style:prepared,parameters:FrameStyleParameters(evaluated),request:request,commandBuffer:command)
            let done=DispatchSemaphore(value:0);command.addCompletedHandler{_ in done.signal()};command.commit();done.wait()
            if let error=command.error {throw error}
            var runtimeValues=[Float](repeating:0,count:16)
            runtimeValues.withUnsafeMutableBytes{gpu.getBytes($0.baseAddress!,bytesPerRow:32,from:MTLRegionMake2D(0,0,2,2),mipmapLevel:0)}
            let out=try renderer.render(image,style:style,resources:.init(lut:half),request:request).image
            let expected=[0.1,0.2,0.4].map {v -> Double in let x=pow((v+0.055)/1.055,2.4)*pow(2,-ev*0.5);return x<=0.0031308 ? 12.92*x:1.055*pow(x,1/2.4)-0.055}
            for values in [out.pixels,runtimeValues] {
                dynamicError=max(dynamicError,zip(values.prefix(3),expected).map{abs(Double($0)-$1)}.max() ?? 1)
            }
        }
        result["dynamic"]=dynamicError
        var invalidHash=half;invalidHash.sha256="bad"
        var invalidContract=half;invalidContract.contract="log-to-linear"
        var accepted=0
        for bad in [invalidHash,invalidContract,LUTAsset(name:"broken",cubeText:"LUT_3D_SIZE 2")] {
            do{_=try error(.standard,.init(lut:bad),nil,[0,0,0]);accepted+=1}catch is CancellationError {throw CancellationError()}catch{}
        }
        result["invalidAsset"]=Double(accepted)
        guard let device=MTLCreateSystemDefaultDevice() else {throw LabError.noMetal}
        let encoder=try TextureEffectEncoder(device:device),first=try encoder.prepare(ResolvedStyle(profile:.standard),lut:half)
        var changed=Profile.standard;changed.parameters.color.exposureEV=1
        _=try encoder.prepare(ResolvedStyle(profile:changed),lut:half)
        var cacheError=encoder.staticResourceStatistics.lutUploads == 1 && encoder.staticResourceStatistics.lutParses == 1 ? 0.0:1.0
        let quarter=cube{$0.map{$0*0.25}}
        _=try encoder.prepare(ResolvedStyle(profile:.standard),lut:quarter)
        if encoder.staticResourceStatistics.lutUploads != 2 {cacheError=1}
        _=first;encoder.releaseCaches()
        cacheError=max(cacheError,try error(.standard,.init(lut:quarter),nil,[0.05,0.1,0.2])>0.0001 ? 1:0)
        result["cacheIdentity"]=cacheError
        return result
    }
}
