import Foundation
import ImagingCore
import ImageRendering

/// 已校准输入与目标外观的一对对齐颜色，均为 [0, 1] 编码 SDR RGB。
public struct ColorSamplePair: Sendable {
    public let input:[Double],target:[Double]
    public let weight:Double
    public let isGray:Bool
    public let split:CalibrationSplit
    public let sceneID:String
    public let sequenceID:String?
    public init(input:[Double],target:[Double],weight:Double=1,split:CalibrationSplit,sceneID:String,sequenceID:String?=nil,isGray:Bool=false) {
        self.input=input;self.target=target;self.weight=weight;self.split=split;self.sceneID=sceneID;self.sequenceID=sequenceID;self.isGray=isGray
    }
}
/// 给定编码 RGB 样本和候选外观，按原样本顺序预测输出 RGB。
public protocol AppearancePredicting {
    func predict(_ inputs:[[Double]],parameters:StyleParameters,residual:LUTSampleGrid?) throws -> [[Double]]
}
/// 将固定 LUT 与候选残差合成为运行时可用的资源。
public protocol AppearanceLUTBaking {
    var fixedLUTDigest:String? { get }
    func combinedAsset(residual:LUTSampleGrid?) throws -> LUTAsset?
}
/// 全局外观、可选残差资源与数值诊断。若有误差，为归一化编码 RGB 最大通道绝对误差。
public struct AppearanceFitResult: Sendable {
    public var appearance:AppearanceDefinition
    public let residual:LUTSampleGrid?
    public let generatedLUT:LUTAsset?
    /// 生成 LUT 应按此 ID 合并到调用方资源集中。中性编辑或适应策略仍可能引用原有资源。
    public var generatedLUTResourceID:String? {
        guard let asset=generatedLUT else { return nil }
        return appearance.lutWeights.first(where:{ weight in
            appearance.resources.contains { $0.id == weight.resourceID && $0.sha256 == asset.sha256 }
        })?.resourceID
    }
    public let trainMaximumError:Double?
    public let tuneMaximumError:Double?
    public let converged:Bool
    public let iterations:Int
    public var unresolved:[String]
    public let algorithmVersion:String
    public let options:AppearanceFitOptions
    public let curveDiagnostics:MonotoneCurveFitter.Diagnostics?
    public let residualIterations:Int
    public var inputIdentity:String?
    public var datasetIdentity:String?
    public var projectDigest:String? = nil
    public var consumedSampleIDs:[String] = []
    public var fullSceneValidationPending:Bool = true
}
/// 拟合全局颜色矩阵、色调曲线及可选残差 LUT。空间或随机效果需要独立整场景数据。
public struct AppearanceFitter {
    /// 使用训练颜色对估计参数，调优数据仅用于评估和残差模型选择。验收样本只参与分组隔离检查。
    public static func fit(samples:[ColorSamplePair],baseline:StyleParameters,options:AppearanceFitOptions,
                           predictor:any AppearancePredicting) throws -> AppearanceFitResult {
        try options.validate();try baseline.validate()
        guard !baseline.detail.isActive,!baseline.softening.isActive,!baseline.vignette.isActive,!baseline.glow.isActive,
              !baseline.halation.isActive,!baseline.noise.isActive,!baseline.grain.isActive else {
            throw LabError.unsupported("Reduced-color fitting cannot identify spatial/random appearance effects")
        }
        var groups=[String:CalibrationSplit]()
        for sample in samples {
            if sample.split != .acceptance {
            guard sample.input.count==3,sample.target.count==3,(sample.input+sample.target).allSatisfy({$0.isFinite && (0...1).contains($0)}),
                  sample.weight.isFinite,sample.weight>0,!sample.sceneID.isEmpty else { throw LabError.invalid("Invalid aligned color samples") }
            }
            guard !sample.sceneID.isEmpty else { throw LabError.invalid("Missing sample group identity") }
            for group in ["scene:"+sample.sceneID] + (sample.sequenceID.map({["sequence:"+$0]}) ?? []) {
                if let previous=groups[group],previous != sample.split { throw LabError.invalid("Color sample groups cannot cross splits") }
                groups[group]=sample.split
            }
        }
        let train=samples.filter{$0.split == .train},tune=samples.filter{$0.split == .tune}
        guard !train.isEmpty,train.count+tune.count<=options.maximumSamples else { throw LabError.invalid("Missing training data or appearance sample budget exceeded") }
        var parameters=baseline,residual:LUTSampleGrid?,unresolved=[String](),iterations=0,converged=false
        var toneDiagnostics:MonotoneCurveFitter.Diagnostics?,residualIterations=0
        func result(trainError:Double?,tuneError:Double?,asset:LUTAsset?) -> AppearanceFitResult {
            var appearance=AppearanceDefinition();appearance.parameters=parameters
            return .init(appearance:appearance,residual:residual,generatedLUT:asset,trainMaximumError:trainError,tuneMaximumError:tuneError,
                         converged:converged,iterations:iterations,unresolved:unresolved,algorithmVersion:"appearance-forward-v1",options:options,curveDiagnostics:toneDiagnostics,residualIterations:residualIterations,inputIdentity:nil,datasetIdentity:nil)
        }
        // 先检查样本能否区分独立矩阵方向，以免阻尼掩盖秩不足。
        do { _=try GenerationMath.leastSquares(rows:train.map{$0.input.map(GenerationMath.linear)},values:train.map{$0.target[0]}) }
        catch { unresolved.append("Input colors do not identify independent matrix channels");return result(trainError:nil,tuneError:nil,asset:nil) }
        let targetVariation=(0..<3).map { c in (train.map{$0.target[c]}.max() ?? 0)-(train.map{$0.target[c]}.min() ?? 0) }.max() ?? 0
        guard targetVariation>1e-8 else {
            unresolved.append("Constant/dark/clipped targets do not identify a matrix and tone decomposition")
            return result(trainError:nil,tuneError:nil,asset:nil)
        }
        let maximumWeight=train.map(\.weight).max()!
        let scaled=train.map{($0.weight/maximumWeight)*($0.isGray ? options.grayWeight:1)}
        let total=scaled.reduce(0,+),weights=scaled.map{$0/total}
        func prediction(_ pairs:[ColorSamplePair],_ p:StyleParameters,_ lut:LUTSampleGrid?=nil) throws -> [[Double]] {
            let predicted=try predictor.predict(pairs.map(\.input),parameters:p,residual:lut)
            guard predicted.count==pairs.count,predicted.allSatisfy({$0.count==3 && $0.allSatisfy(\.isFinite)}) else { throw LabError.measurement("Invalid forward appearance prediction") }
            return predicted
        }
        func loss(_ values:[[Double]]) -> Double {
            zip(train.indices,weights).reduce(0) { sum,item in
                sum+item.1*(0..<3).reduce(0){$0+pow(values[item.0][$1]-train[item.0].target[$1],2)}
            }
        }
        func matrixSystem(_ p:StyleParameters,_ output:[[Double]],_ lut:LUTSampleGrid?=nil) throws -> (normal:[[Double]],rhs:[Double]) {
            // 只扰动九个矩阵系数，曝光、白平衡和 LUT 在估计导数时固定。
            let h=0.001
            var derivatives=[[[Double]]]()
            for parameter in 0..<9 {
                var perturbed=p
                let old=p.color.matrix.values[parameter]
                let delta=old+h<=4 ? h:-h
                perturbed.color.matrix.values[parameter]=old+delta
                let shifted=try prediction(train,perturbed,lut)
                derivatives.append(train.indices.map { row in (0..<3).map { (shifted[row][$0]-output[row][$0])/delta } })
            }
            var normal=[[Double]](repeating:[Double](repeating:0,count:9),count:9),rhs=[Double](repeating:0,count:9)
            for s in train.indices { for c in 0..<3 { for j in 0..<9 {
                let jac=derivatives[j][s][c]
                rhs[j] += weights[s]*jac*(train[s].target[c]-output[s][c])
                for k in 0..<9 { normal[j][k] += weights[s]*jac*derivatives[k][s][c] }
            } } }
            return (normal,rhs)
        }
        var current=try prediction(train,parameters),objective=loss(current)
        for iteration in 1...options.maxIterations {
            try Task.checkCancellation();let oldObjective=objective
            var (normal,rhs)=try matrixSystem(parameters,current)
            do { _=try GenerationMath.solve(normal,[Double](repeating:0,count:9)) }
            catch {
                unresolved.append("The forward response does not identify independent matrix directions")
                return result(trainError:nil,tuneError:nil,asset:nil)
            }
            for j in 0..<9 { normal[j][j] += 1e-5+options.regularization*1e-3 }
            let step=try GenerationMath.solve(normal,rhs)
            var scale=1.0
            for _ in 0..<12 {
                var candidate=parameters
                candidate.color.matrix.values=(0..<9).map{min(4,max(-4,parameters.color.matrix.values[$0]+scale*step[$0]))}
                let output=try prediction(train,candidate),proposed=loss(output)
                if proposed<=objective { parameters=candidate;current=output;objective=proposed;break }
                scale *= 0.5
            }
            // 关闭色调阶段以取得实际前向链路的色调输入，再拟合单调曲线。
            var noTone=parameters;noTone.tone.enabled=false
            let preTone=try prediction(train,noTone)
            var curveSamples=[MonotoneCurveFitter.Sample]()
            for s in train.indices { for c in 0..<3 {
                curveSamples.append(.init(x:min(1,max(0,preTone[s][c])),y:train[s].target[c],weight:weights[s]))
            } }
            let curve:MonotoneCurveFitter.Result
            do {
                curve=try MonotoneCurveFitter.fit(samples:curveSamples,regularization:options.regularization,
                                                 maxIterations:options.maxIterations,tolerance:options.convergenceTolerance)
            } catch {
                unresolved.append("Tone observations are numerically unidentifiable: \(error)")
                return result(trainError:nil,tuneError:nil,asset:nil)
            }
            var curved=parameters;curved.tone.enabled=true;curved.tone.curve=curve.curve
            let curvedOutput=try prediction(train,curved),curvedLoss=loss(curvedOutput)
            if curvedLoss<=objective { parameters=curved;current=curvedOutput;objective=curvedLoss;toneDiagnostics=curve.diagnostics }
            iterations=iteration
            if objective<options.convergenceTolerance*options.convergenceTolerance ||
                abs(oldObjective-objective)<=options.convergenceTolerance*max(oldObjective,1e-8) { converged=true;break }
        }
        let matrixConverged=converged
        func maximum(_ values:[[Double]],_ pairs:[ColorSamplePair])->Double {
            pairs.indices.reduce(0){max($0,zip(values[$1],pairs[$1].target).map{abs($0-$1)}.max() ?? 0)}
        }
        var tuneOutput=try prediction(tune,parameters)
        let baseTune=tune.isEmpty ? nil:maximum(tuneOutput,tune)
        if options.residualEnabled,let baseTune,baseTune>options.residualTrigger {
            // 矩阵可能已裁掉部分色域。额外比较固定原矩阵的分解，避免要求 LUT 恢复丢失的信息。
            var candidates:[(parameters:StyleParameters,curve:MonotoneCurveFitter.Diagnostics?)]=[(parameters,toneDiagnostics)]
            if parameters.color.matrix != baseline.color.matrix {
                var prior=parameters;prior.color.matrix=baseline.color.matrix;prior.tone.enabled=false
                let priorInput=try prediction(train,prior)
                var observations=[MonotoneCurveFitter.Sample]()
                for s in train.indices { for c in 0..<3 {
                    observations.append(.init(x:min(1,max(0,priorInput[s][c])),y:train[s].target[c],weight:weights[s]))
                } }
                let curve=try MonotoneCurveFitter.fit(samples:observations,regularization:options.regularization,
                                                    maxIterations:options.maxIterations,tolerance:options.convergenceTolerance)
                prior.tone.enabled=true;prior.tone.curve=curve.curve;candidates.append((prior,curve.diagnostics))
            }
            var residualConverged=true
            for candidateRecord in candidates {
                let candidate=candidateRecord.parameters
                var noTone=candidate;noTone.tone.enabled=false
                let pre=try prediction(train,noTone)
                let observations=train.indices.map { ResidualLUTFitter.Sample(input:pre[$0].map{min(1,max(0,$0))},target:train[$0].target,weight:weights[$0]) }
                for dimension in options.residualDimension == 33 ? [17,33]:[17] {
                    let fit=try ResidualLUTFitter.fit(samples:observations,tone:candidate.tone.isActive ? candidate.tone.curve:.identity,
                                                    dimension:dimension,regularization:options.regularization,maxIterations:options.maxIterations,tolerance:options.convergenceTolerance)
                    let proposed=try prediction(tune,candidate,fit.grid)
                    let previous=maximum(tuneOutput,tune),next=maximum(proposed,tune)
                    if next<previous*0.95 {
                        parameters=candidate;residual=fit.grid;tuneOutput=proposed;residualConverged=fit.converged
                        toneDiagnostics=candidateRecord.curve;residualIterations=fit.iterations
                    }
                    if next<=options.residualTrigger { break }
                }
            }
            if residual==nil { unresolved.append("Tune data did not support a residual LUT") }
            else if !residualConverged { converged=false;unresolved.append("Residual iteration budget reached without convergence") }
        } else if tune.isEmpty { unresolved.append("No tune split; residual model selection remains disabled") }
        if let diagnostics=toneDiagnostics {
            if !diagnostics.converged { converged=false;unresolved.append("Tone curve iteration budget reached without convergence") }
            if !diagnostics.unmeasuredIntervals.isEmpty { unresolved.append("Tone values outside the observed interval are regularized extensions, not measured coverage") }
        }
        if !matrixConverged { unresolved.append("Matrix/curve iteration budget reached without convergence") }
        current=try prediction(train,parameters,residual)
        let chosenSystem=try matrixSystem(parameters,current,residual)
        do { _=try GenerationMath.solve(chosenSystem.normal,[Double](repeating:0,count:9)) }
        catch {
            converged=false
            unresolved.append("The chosen forward response does not identify independent matrix directions")
        }
        let asset=try (predictor as? any AppearanceLUTBaking)?.combinedAsset(residual:residual)
        if residual != nil && asset==nil { unresolved.append("Numerical residual only; production LUT baking and GPU validation required") }
        return result(trainError:maximum(current,train),tuneError:tune.isEmpty ? nil:maximum(tuneOutput,tune),asset:asset)
    }
}

/// 通过共享 Metal 参考渲染链路预测颜色并合成 LUT。调用方持有渲染器并串行使用。
public final class ReferenceAppearancePredictor: AppearancePredicting, AppearanceLUTBaking {
    private let renderer:MetalRenderer
    private let fixed:LUTAsset?
    private let fixedGrid:LUTSampleGrid?
    public var fixedLUTDigest:String? { fixed?.sha256 }
    public init(renderer:MetalRenderer,fixedLUT:LUTAsset?=nil) throws {
        self.renderer=renderer;fixed=fixedLUT
        if let fixedLUT {
            try fixedLUT.validate()
            guard fixedLUT.boundaryPolicy != .extrapolate else { throw LabError.unsupported("Appearance composition requires bounded SDR fixed LUT sampling") }
            let cube=try fixedLUT.decodedCube()
            fixedGrid=try .init(dimension:cube.size,samples:cube.rgba.enumerated().filter{$0.offset%4 != 3}.map(\.element))
        } else { fixedGrid=nil }
    }
    public func combinedAsset(residual:LUTSampleGrid?) throws -> LUTAsset? {
        guard let residual else { return fixed }
        guard let fixedGrid else { return try residual.asset() }
        let dimension=max(fixedGrid.dimension,residual.dimension)
        let identity=try LUTSampleGrid.identity(dimension:dimension)
        var samples=[Float]();samples.reserveCapacity(identity.samples.count)
        for i in Swift.stride(from:0,to:identity.samples.count,by:3) {
            let coordinate=(0..<3).map{Double(identity.samples[i+$0])}
            samples += try residual.sample(fixedGrid.sample(coordinate)).map(Float.init)
        }
        return try LUTSampleGrid(dimension:dimension,samples:samples).asset(name:"fixed-plus-residual")
    }
    public func predict(_ inputs:[[Double]],parameters:StyleParameters,residual:LUTSampleGrid?) throws -> [[Double]] {
        guard !inputs.isEmpty else { return [] }
        let asset=try combinedAsset(residual:residual)
        var output=[[Double]]();output.reserveCapacity(inputs.count)
        for start in Swift.stride(from:0,to:inputs.count,by:4096) {
            let chunk=Array(inputs[start..<min(inputs.count,start+4096)])
            let frame=try ImageFrame(width:chunk.count,height:1,pixels:chunk.flatMap{$0.map(Float.init)+[1]})
            let rendered=try renderer.render(frame,style:ResolvedStyle(parameters:parameters),resources:.init(lut:asset),request:.init(input:frame.descriptor)).image
            output += chunk.indices.map { i in (0..<3).map{Double(rendered.pixels[i*4+$0])} }
        }
        return output
    }
}
