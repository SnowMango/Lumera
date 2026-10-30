import Foundation
import ImagingCore

public enum AcceptanceStatus:String,Codable,Sendable {case passed,failed,insufficient,measured}
public struct AcceptanceResult:Codable,Sendable {
    public let effect:String,conditionIndex:Int,longEdge:Int,status:AcceptanceStatus
    public let metrics:[String:Double],limits:[String:Double],explanation:String
}
public struct AcceptanceReport:Codable,Sendable {
    public var version="lumera-style-acceptance-v1"
    public let profileDigest:String,fixtureDigest:String,engineVersion:String,system:String
    public let conditions:[CaptureConditions],evaluations:[[ResponseDiagnostic]],results:[AcceptanceResult]
    public let method:String
}
/// Offline digital engine checks. Isolates effects after shared condition evaluation.
/// It does not certify that a preset matches a particular physical camera.
public enum StyleAcceptance {
    public static func run(profile:Profile,conditions:[CaptureConditions],fixtures:URL) throws -> AcceptanceReport {
        guard !conditions.isEmpty,conditions.count<=100 else {throw LabError.invalid("标准验收需要1–100组条件")}
        let manifestData=try Data(contentsOf:fixtures.appendingPathComponent("manifest.json"))
        let manifest=try JSONDecoder().decode(FixtureManifest.self,from:manifestData)
        guard manifest.version=="lumera-acceptance-v1",manifest.generator=="AcceptanceFixtures-v1",
              Set(manifest.images.map(\.kind))==Set(AcceptanceFixture.allCases),manifest.images.count==AcceptanceFixture.allCases.count else {throw LabError.invalid("标准材料版本或清单不完整")}
        for file in manifest.images.map({($0.file,$0.sha256)})+manifest.assets.map({($0.file,$0.sha256)}) {
            guard !file.0.hasPrefix("/"),!file.0.split(separator:"/").contains(".."),
                  Digest.data(try Data(contentsOf:fixtures.appendingPathComponent(file.0)))==file.1 else {throw LabError.invalid("测试材料摘要不匹配："+file.0)}
        }
        let definition=try StyleEvaluator.compile(profile),renderer=try MetalRenderer()
        var results=[AcceptanceResult](),evaluations=[[ResponseDiagnostic]]()
        for (conditionIndex,condition) in conditions.enumerated() {
            let evaluated=try StyleEvaluator.evaluate(definition,conditions:condition),p=evaluated.parameters
            evaluations.append(evaluated.diagnostics)
            for width in [720,1280,2048] {
                try Task.checkCancellation()
                try autoreleasepool {
                    let scale=Double(width)/2048
                    func record(_ effect:String,_ metrics:[String:Double],_ limits:[String:Double],_ status:AcceptanceStatus,_ explanation:String) {
                        results.append(.init(effect:effect,conditionIndex:conditionIndex,longEdge:width,status:status,metrics:metrics,limits:limits,explanation:explanation))
                    }
                    func render(_ input:ImageFrame,_ parameters:StyleParameters,seed:UInt32=42) throws -> ImageFrame {
                        var request=RenderRequest(input:input.descriptor);request.seed=seed
                        return try renderer.render(input,style:ResolvedStyle(parameters:parameters,profileDigest:definition.identity,temporalPolicy:evaluated.temporalPolicy),request:request).image
                    }
                    // Spatially constant in y: independent 1D convolution is the exact 2D Gaussian reference.
                    // Full long edge preserves engine scale; 8-row strips avoid enormous CPU reference convolutions.
                    func strip(_ values:[Double]) throws -> ImageFrame {
                        var pixels=[Float]();pixels.reserveCapacity(width*8*4)
                        for _ in 0..<8 {for v in values {pixels += [Float(v),Float(v),Float(v),1]}}
                        return try ImageFrame(width:width,height:8,pixels:pixels)
                    }
                    func blur(_ values:[Double],_ sigma:Double)->[Double] {
                        AcceptanceReference.gaussian(values,width:width,height:1,sigma:sigma)
                    }
                    let ramp=try strip((0..<width).map{Double($0)/Double(width-1)})
                    var isolated=StyleParameters();isolated.tone=p.tone
                    let tone=try render(ramp,isolated)
                    var error=0.0,minimumStep=1.0
                    for x in 0..<width {
                        let input=Double(ramp.pixels[x*4]),expected=p.tone.isActive ? AcceptanceReference.curve(input,definition:p.tone.curve):input
                        error=max(error,abs(Double(tone.pixels[x*4])-expected))
                        if x>0 {minimumStep=min(minimumStep,Double(tone.pixels[x*4]-tone.pixels[(x-1)*4]))}
                    }
                    record("tone",["maxAbs":error,"minimumStep":minimumStep],["maxAbs":0.0002,"minimumStep":-0.000002],error<=0.0002 && minimumStep >= -0.000002 ? .passed:.failed,"编码sRGB灰阶；独立Double函数/节点插值参考，包含黑白端点。")
                    let edge=try strip((0..<width).map{$0<width/2 ? 0.15:0.85})
                    let linear=(0..<width).map{AcceptanceReference.decode(Double(edge.pixels[$0*4]))}
                    for effect in ["softening","detail","glow","halation"] {
                        isolated=StyleParameters();var expected=linear
                        if effect=="softening" {
                            isolated.softening=p.softening
                            if p.softening.isActive {let b=blur(linear,p.softening.sigma*scale);expected=zip(linear,b).map{$0*(1-p.softening.amount)+$1*p.softening.amount}}
                        } else if effect=="detail" {
                            isolated.detail=p.detail
                            let encoded=(0..<width).map{Double(edge.pixels[$0*4])};expected=encoded
                            if p.detail.isActive {
                                let fine=blur(encoded,p.detail.fineSigma*scale),mid=blur(encoded,p.detail.midSigma*scale)
                                expected=encoded.indices.map{mid[$0]+p.detail.fineGain*(encoded[$0]-fine[$0])+p.detail.midGain*(fine[$0]-mid[$0])}
                                if p.detail.sharpenAmount>0 {
                                    let b=blur(expected,p.detail.sharpenSigma*scale)
                                    expected=expected.indices.map { i in
                                        let diff=expected[i]-b[i],gate=smooth(abs(diff),p.detail.threshold,max(p.detail.threshold*2,1e-6))
                                        return expected[i]+min(p.detail.maxAdjustment,max(-p.detail.maxAdjustment,diff*p.detail.sharpenAmount*gate))
                                    }
                                }
                            }
                        } else {
                            let active=effect=="glow" ? p.glow.isActive:p.halation.isActive
                            let threshold=effect=="glow" ? p.glow.threshold:p.halation.threshold,knee=effect=="glow" ? p.glow.knee:p.halation.knee
                            if effect=="glow" {isolated.glow=p.glow}else{isolated.halation=p.halation}
                            if active {
                                let hi=linear.map{$0*smooth($0,threshold-knee,threshold+knee)}
                                if effect=="glow" {
                                    let a=blur(hi,p.glow.nearSigma*scale),b=blur(hi,p.glow.farSigma*scale)
                                    expected=linear.indices.map{linear[$0]+p.glow.amount*(a[$0]*(1-p.glow.farWeight)+b[$0]*p.glow.farWeight-hi[$0])}
                                } else {
                                    let b=blur(hi,p.halation.sigma*scale)
                                    expected=linear.indices.map{linear[$0]+p.halation.amount*p.halation.red*max(0,b[$0]-hi[$0])}
                                }
                            }
                        }
                        let output=try render(edge,isolated)
                        error=0
                        for x in 0..<width {error=max(error,abs(Double(output.pixels[(4*width+x)*4])-min(1,max(0,effect=="detail" ? expected[x]:AcceptanceReference.encode(expected[x])))))}
                        record(effect,["redChannelMaxAbs":error,"scale":scale],["maxAbs":0.0002],error<=0.0002 ? .passed:.failed,"独立Double卷积、纵向恒定亮边；细节在编码sRGB域，其余光学效果在线性光域；与相同归一化尺度比较。染色光晕此项检查红色分量；不代表任意场景主观相似度。")
                    }
                    isolated=StyleParameters();isolated.vignette=p.vignette
                    let flat=try ImageFrame.solid(width:width,height:width*3/4,value:0.5),vignette=try render(flat,isolated)
                    var evError=0.0
                    for y in stride(from:0,to:flat.height,by:max(1,flat.height/20)) {for x in stride(from:0,to:width,by:max(1,width/20)) {
                        let v=p.vignette,xx=Double(x)+0.5+Double(width)*(0.5-v.centerX),yy=Double(y)+0.5+Double(flat.height)*(0.5-v.centerY)
                        let expected=v.isActive ? AcceptanceReference.vignetteEV(x:xx,y:yy,width:width,height:flat.height,amount:v.amountEV,start:v.startRadius,falloff:v.falloff):0
                        let measured = -log2(AcceptanceReference.decode(Double(vignette.pixels[(y*width+x)*4]))/AcceptanceReference.decode(0.5))
                        evError=max(evError,abs(expected-measured))
                    }}
                    record("vignette",["maxEVError":evError],["maxEVError":0.02],evError<=0.02 ? .passed:.failed,"4:3均匀平场，像素中心径向采样，线性亮度比转EV。")
                    for effect in ["noise","grain"] {
                        isolated=StyleParameters()
                        if effect=="noise" {isolated.noise=p.noise;isolated.noise.chromaRatio=0} else {isolated.grain=p.grain;isolated.grain.chroma=0}
                        let source=try ImageFrame.solid(width:width,height:256,value:0.5)
                        var sum=0.0,squares=0.0,count=0,adjacent=0.0,pairs=0,referenceError=0.0
                        for seed:UInt32 in [42,43,44,45] {
                            let output=try render(source,isolated,seed:seed)
                            for y in 32..<224 {for x in 32..<(width-32) {
                                let index=(y*width+x)*4,r=Double(output.pixels[index])-0.5
                                sum+=r;squares+=r*r;count+=1
                                adjacent+=r*(Double(output.pixels[index-4])-0.5);pairs+=1
                                if effect=="grain",x%97==0,y%37==0 {
                                    let size=max(0.5,p.grain.size*scale)
                                    let amplitude=p.grain.isActive ? p.grain.amount*AcceptanceReference.curve(0.5,definition:p.grain.luminanceCurve):0
                                    let expected=0.5+amplitude*GrainReference.value(x:(Double(x)+0.5)/size,y:(Double(y)+0.5)/size,seed:seed,roughness:p.grain.roughness)
                                    referenceError=max(referenceError,abs(Double(output.pixels[index])-min(1,max(0,expected))))
                                }
                            }}
                        }
                        let expected:Double,radius:Double
                        if effect=="noise" {expected=p.noise.isActive ? min(0.1,AcceptanceReference.curve(0.5,definition:p.noise.curve)*p.noise.gain):0;radius=ceil(3*p.noise.lumaSigma*scale)}
                        else {expected=p.grain.isActive ? p.grain.amount*AcceptanceReference.curve(0.5,definition:p.grain.luminanceCurve):0;radius=ceil(2.5*max(0.5,p.grain.size*scale))}
                        let n=Double(count),mean=sum/n,sigma=sqrt(max(0,squares/n-mean*mean)),effective=n/pow(1+2*radius,2)
                        let meanLimit=5*expected/sqrt(effective)+0.000002,sigmaLimit=expected*5/sqrt(2*max(1,effective-1))+0.000002
                        let status:AcceptanceStatus = effect=="grain" ? (referenceError<=0.0002 ? .passed:.failed) : effective<1000 ? .insufficient:(abs(mean)<=meanLimit && abs(sigma-expected)<=sigmaLimit ? .passed:.failed)
                        record(effect,["meanResidual":mean,"sigma":sigma,"expectedSigma":expected,"effectiveSamples":effective,"requestedSizePixels":effect=="grain" ? p.grain.size*scale:p.noise.lumaSigma*scale,"effectiveSizePixels":effect=="grain" ? max(0.5,p.grain.size*scale):p.noise.lumaSigma*scale,"samplingLimited":effect=="grain" && p.grain.size*scale<0.5 ? 1:0,"independentGrainMaxAbs":referenceError,"lag1Correlation":squares>0 ? adjacent/Double(pairs)/(squares/n):0],["meanAbs":meanLimit,"sigmaAbsError":sigmaLimit,"grainMaxAbs":0.0002],status,"中性0.5平场，4种子，关闭彩色分量隔离明暗统计；相关性降低有效样本数。颗粒实际尺度下限0.5px，samplingLimited=1表示受采样限制；颗粒通过依据为独立Double格点参考的抽样最大误差，不以sigma判定；报告一像素相关性，尚不认证完整频谱。噪点有效样本<1000标条件不足。")
                    }
                    isolated=p
                    let combined=try render(ramp,isolated)
                    let finite=combined.pixels.allSatisfy{$0.isFinite && (0...1).contains($0)}
                    record("combined",["finiteInRange":finite ? 1:0],[:],finite ? .measured:.failed,"全效果组合只检查数值有效性；任意LUT/颜色矩阵的美学目标需要独立参考，不以此项宣称通过。")
                    renderer.releaseCaches()
                }
            }
        }
        return AcceptanceReport(profileDigest:definition.identity,fixtureDigest:Digest.data(manifestData),engineVersion:Profile.engineVersion,system:ProcessInfo.processInfo.operatingSystemVersionString,conditions:conditions,evaluations:evaluations,results:results,method:"核验v1材料摘要；按同一生成定义制作720/1280/2048长边解析派生图。光学为纵向恒定8行亮边、暗角为4:3平场、随机效果为256行平场。float32，seed42–45，frame0。逐效果隔离，不是相机复刻准确率。")
    }
    private static func smooth(_ x:Double,_ lo:Double,_ hi:Double)->Double {let t=min(1,max(0,(x-lo)/(hi-lo)));return t*t*(3-2*t)}
}

extension AcceptanceReport {
    public var summary:String {
        let failed=results.filter{$0.status == .failed}.count,insufficient=results.filter{$0.status == .insufficient}.count
        return "标准图验收 · \(results.filter{$0.status == .passed}.count)项通过 / \(failed)项失败 / \(insufficient)项条件不足 / \(results.filter{$0.status == .measured}.count)项仅测量\n" +
            "配置摘要：\(profileDigest)\n\(method)\n\n" + results.map { row in
                let fields=row.metrics.sorted{$0.key<$1.key}.map{"\($0.key)=\(String(format:"%.6g",$0.value))"}.joined(separator:", ")
                return "[\(row.status.rawValue)] 条件\(row.conditionIndex+1) / \(row.longEdge)px / \(row.effect)\n\(fields)\n\(row.explanation)"
            }.joined(separator:"\n\n")+"\n\n完整频谱、真实相机匹配度和iPhone性能未由本报告验证。"
    }
}
