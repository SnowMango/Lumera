import Foundation
import ImagingCore

/// Canonical relative color model: a near-identity linear RGB matrix with sum=3,
/// plus a monotone encoded-RGB curve anchored at 0, 0.5, 1. Exposure/WB/shift stay fixed.
/// The anchors intentionally exclude free global exposure compensation; outside this domain, refuse.
public enum ToneColorSolver {
    public static func solve(measurements:MeasurementBundle,baseline:Profile,options:GenerationOptions,resources:GenerationResources) throws -> GenerationProposal {
        try Task.checkCancellation();try baseline.validate()
        guard options.modules.contains(.toneColor),resources.digests==measurements.resourceDigests,
              resources.rendering.lut==nil,resources.rendering.correctionLUT==nil else {throw LabError.measurement("此颜色模型需要独立的无 LUT 测量；已有 LUT 的反演可辨识性尚未验收，保留原颜色设置")}
        guard baseline.parameters.color.exposureEV==0,baseline.parameters.color.whiteBalance.source==baseline.parameters.color.whiteBalance.destination,baseline.parameters.color.shift==ColorShift() else {throw LabError.measurement("现有风格包含固定曝光、白平衡或色彩偏移；此规范化颜色模型不能自动覆盖这些设置")}
        let pairs=try ToneColorMeasurement.pairs(measurements),training=pairs.filter(\.training),validation=pairs.filter{!$0.training}
        var curve=ResponseCurve.identity,matrix=ColorMatrix3x3().values
        // The normal equations are only 10x10; image/patch acquisition stays on GPU.
        for _ in 0..<32 {
            try Task.checkCancellation()
            var normal=Array(repeating:Array(repeating:0.0,count:10),count:10),rhs=Array(repeating:0.0,count:10)
            for pair in training {
                let x=pair.input.map(GenerationMath.linear),y=pair.target.map{GenerationMath.linear(invert(curve,$0))}
                for c in 0..<3 {for j in 0..<3 {rhs[c*3+j]+=x[j]*y[c];for k in 0..<3 {normal[c*3+j][c*3+k]+=x[j]*x[k]}}}
            }
            for i in 0..<9 {normal[i][9]=1;normal[9][i]=1};rhs[9]=3
            matrix=Array(try GenerationMath.solve(normal,rhs).prefix(9))
            var rows=[[Double]](),values=[Double]()
            for pair in training where pair.kind == .gray {
                let rgb=transform(pair.input,matrix:matrix)
                for c in 0..<3 {
                    let x=rgb[c];guard x.isFinite,(0...1).contains(x) else {throw LabError.measurement("颜色变换超出未裁切范围")}
                    let weights=toneWeights(x);rows.append(weights.0);values.append(pair.target[c]-weights.1)
                }
            }
            let y=try GenerationMath.leastSquares(rows:rows,values:values)
            guard (0.05...0.45).contains(y[0]),(0.55...0.95).contains(y[1]) else {throw LabError.measurement("明暗关系超出固定中灰锚点模型；请先检查曝光配对，不能用自由曝光吞掉差异")}
            let next=ResponseCurve(knots:[.init(x:0,y:0),.init(x:0.25,y:y[0]),.init(x:0.5,y:0.5),.init(x:0.75,y:y[1]),.init(x:1,y:1)])
            let change=max(abs(next.value(at:0.25)-curve.value(at:0.25)),abs(next.value(at:0.75)-curve.value(at:0.75)))
            curve=next;if change<1e-9 {break}
        }
        for i in 0..<9 {
            guard (i%4==0 ? 0.6...1.4 : -0.25...0.25).contains(matrix[i]) else {throw LabError.measurement("所需颜色矩阵超出已验收的近恒等范围；不自动生成大幅通道抵消")}
        }
        var candidate=baseline;candidate.parameters.color=ColorResponse();candidate.parameters.color.matrix.values=matrix
        candidate.parameters.tone.enabled=true;candidate.parameters.tone.curve=curve
        try candidate.validate()
        // Render reduced color measurements through the actual GPU color/tone path.
        // Each texel is one measured patch mean, not a resized source photograph.
        var colorOnly=Profile.standard;colorOnly.parameters.color=candidate.parameters.color;colorOnly.parameters.tone=candidate.parameters.tone
        let renderer=try MetalRenderer(cacheLimitBytes:128*1024*1024);defer{renderer.releaseCaches()}
        let output=try predictions(pairs,profile:colorOnly,renderer:renderer,frames:measurements.frames)
        var baselineColor=Profile.standard;baselineColor.parameters.color=baseline.parameters.color;baselineColor.parameters.tone=baseline.parameters.tone
        let baselineOutput=try predictions(pairs,profile:baselineColor,renderer:renderer,frames:measurements.frames)
        var worst=[String:Double](),baselineWorst=[String:Double](),trainMaximum=0.0
        for (i,pair) in pairs.enumerated() {
            let error=zip(output[i],pair.target).map{abs($0-$1)}.max()!
            if pair.training {trainMaximum=max(trainMaximum,error)} else {
                worst[pair.group]=max(worst[pair.group] ?? 0,error)
                baselineWorst[pair.group]=max(baselineWorst[pair.group] ?? 0,zip(baselineOutput[i],pair.target).map{abs($0-$1)}.max()!)
            }
        }
        guard !validation.isEmpty,trainMaximum<=0.015 else {throw LabError.measurement("训练关系不符合固定中灰/近恒等颜色模型，可能存在曝光差、局部处理或不可辨识映射")}
        let limit=GenerationLimits.cases(for:.toneColor).first{$0.caseID=="heldOutColor"}!
        var evidence=[AlgorithmCaseResult]()
        for group in worst.keys.sorted() {
            let error=worst[group]!
            guard limit.accepts(error),error<=(baselineWorst[group] ?? 0)+0.0001 else {throw LabError.measurement("\(group)：独立颜色验证失败（最大通道差 \(error)），不自动应用或用该组重选参数")}
            evidence.append(.init(algorithm:.toneColor,caseID:group,status:.passed,measured:error,limit:limit,detail:"独立中档/重复帧及固定色样留出；encoded sRGB 最大通道差。"))
        }
        return .init(profile:candidate,evidence:evidence,unresolved:["相对颜色等效建议，不推断目标相机的白点或内部参数；固定中灰与曝光锚点不自动补偿拍摄曝光差。","此版本无 LUT 反演资格；超出近恒等矩阵与固定中灰单调曲线的关系需人工调整。"],resourceDigests:resources.digests,validatedModules:[.toneColor])
    }
    private static func invert(_ curve:ResponseCurve,_ y:Double)->Double {
        var low=0.0,high=1.0
        for _ in 0..<32 {let mid=(low+high)/2;if curve.value(at:mid)<y {low=mid}else{high=mid}}
        return (low+high)/2
    }
    private static func toneWeights(_ x:Double)->([Double],Double) {
        if x<0.25 {return ([4*x,0],0)}
        if x<0.5 {return ([2-4*x,0],0.5*(4*x-1))}
        if x<0.75 {return ([0,4*x-2],0.5*(3-4*x))}
        return ([0,4-4*x],4*x-3)
    }
    private static func transform(_ rgb:[Double],matrix:[Double])->[Double] {
        let x=rgb.map(GenerationMath.linear)
        return (0..<3).map{r in GenerationMath.encoded((0..<3).reduce(0.0){$0+matrix[r*3+$1]*x[$1]})}
    }
    static func predictions(_ pairs:[ColorPatchPair],profile:Profile,renderer:MetalRenderer,frames:[FrameMeasurements]=[]) throws ->[[Double]] {
        let pixels:[Float]=pairs.flatMap {pair -> [Float] in pair.input.map{Float($0)}+[Float(1)]}
        let image=try ImageFrame(width:pairs.count,height:1,pixels:pixels)
        let result=try renderer.render(image,style:ResolvedStyle(profile:profile),request:RenderRequest(input:image.descriptor)).image
        var predictions=pairs.indices.map{i in (0..<3).map{Double(result.pixels[i*4+$0])}}
        let indices=Dictionary(grouping:pairs.indices,by:{pairs[$0].group})
        for frame in frames where frame.step.role == .input && frame.step.target == .composite {
            guard let url=frame.sourceURL else {continue}
            try Task.checkCancellation()
            try autoreleasepool {
                guard let pose=frame.pose,let group=indices[frame.step.pairKey] else {throw LabError.measurement("缺少原始照片定位信息")}
                let image=try ImageCodec.load(url)
                guard image.width==frame.width,image.height==frame.height,image.provenance["fileSHA256"]==frame.fileDigest else {throw LabError.measurement("原始照片已变化，请重新测量")}
                let stats=try renderer.renderPatchStatistics(image,style:ResolvedStyle(profile:profile),transform:pose,regions:Array(TargetLayout.composite.regions.prefix(30)))
                let byID=Dictionary(uniqueKeysWithValues:stats.map{($0.id,$0)})
                for i in group {
                    guard let patch=byID[pairs[i].id],patch.pixelCount>=256,patch.clippedFraction<=0.01 else {throw LabError.measurement("候选在原始色块内产生裁切或无有效像素")}
                    predictions[i]=patch.mean
                }
                renderer.releaseCaches()
            }
        }
        return predictions
    }
}
