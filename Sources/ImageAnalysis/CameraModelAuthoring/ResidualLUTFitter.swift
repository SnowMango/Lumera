import Foundation
import ImagingCore
import ImageRendering

/// 存储编码 RGB 的绝对输出值，红轴变化最快。按夹紧坐标执行三线性插值。
public struct LUTSampleGrid: Equatable, Sendable {
    public let dimension: Int
    public let samples: [Float]
    public init(dimension: Int, samples: [Float]) throws {
        guard (2...128).contains(dimension), samples.count == dimension*dimension*dimension*3,
              samples.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw LabError.invalid("Invalid encoded RGB LUT grid") }
        self.dimension = dimension; self.samples = samples
    }
    public static func identity(dimension: Int) throws -> Self {
        guard (2...128).contains(dimension) else { throw LabError.invalid("Invalid LUT dimension") }
        var values=[Float](); values.reserveCapacity(dimension*dimension*dimension*3)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            values += [Float(r)/Float(dimension-1),Float(g)/Float(dimension-1),Float(b)/Float(dimension-1)]
        } } }
        return try .init(dimension:dimension,samples:values)
    }
    static func basis(_ input:[Double], dimension:Int) throws -> [(Int,Double)] {
        guard input.count==3,input.allSatisfy(\.isFinite) else { throw LabError.invalid("LUT input must be finite RGB") }
        let p=input.map { min(1,max(0,$0))*Double(dimension-1) }
        let lo=p.map { min(dimension-2,Int(floor($0))) }
        let f=(0..<3).map { p[$0]-Double(lo[$0]) }
        var result=[(Int,Double)]()
        for b in 0...1 { for g in 0...1 { for r in 0...1 {
            result.append((((lo[2]+b)*dimension+lo[1]+g)*dimension+lo[0]+r,
                           (r==0 ? 1-f[0]:f[0])*(g==0 ? 1-f[1]:f[1])*(b==0 ? 1-f[2]:f[2])))
        } } }
        return result
    }
    public func sample(_ input:[Double]) throws -> [Double] {
        let basis=try Self.basis(input,dimension:dimension)
        return (0..<3).map { c in basis.reduce(0) { $0+Double(samples[$1.0*3+c])*$1.1 } }
    }
    public func asset(name:String="appearance-residual") throws -> LUTAsset {
        let bytes=samples.withUnsafeBytes { Data($0) }
        var asset=try LUTImporter.load(data:bytes,descriptor:.init(dimension:dimension,layout:.rgbFloat32),name:name)
        asset.boundaryPolicy = .clamp; asset.content = .colorOnly
        return asset
    }
}
/// 在固定色调曲线之前拟合有界 3D LUT，用于补偿全局外观的剩余误差。
public enum ResidualLUTFitter {
    public struct Sample: Sendable {
        public let input:[Double],target:[Double]
        public let weight:Double
        public init(input:[Double],target:[Double],weight:Double=1) { self.input=input;self.target=target;self.weight=weight }
    }
    public struct Result: Sendable { public let grid:LUTSampleGrid; public let iterations:Int; public let converged:Bool }
    /// 通过冻结色调曲线传播正向梯度，每个样本只影响其插值单元的八个角点。平滑项约束相对恒等 LUT 的位移。
    public static func fit(samples:[Sample],tone:ResponseCurve,dimension:Int=17,regularization:Double=1e-3,
                           maxIterations:Int=100,tolerance:Double=1e-6) throws -> Result {
        guard [17,33].contains(dimension),!samples.isEmpty,samples.count<=100_000,
              regularization.isFinite,regularization>=0,regularization<=1e6,(1...1000).contains(maxIterations),
              tolerance.isFinite,tolerance>0,tolerance<1 else { throw LabError.invalid("Invalid bounded residual fit") }
        try tone.validate(kind:.tone)
        for sample in samples {
            guard sample.input.count==3,sample.target.count==3,(sample.input+sample.target).allSatisfy({$0.isFinite && (0...1).contains($0)}),
                  sample.weight.isFinite,sample.weight>0 else { throw LabError.invalid("Invalid residual sample") }
        }
        let identity=try LUTSampleGrid.identity(dimension:dimension)
        let base=identity.samples.map(Double.init),count=base.count
        let maxWeight=samples.map(\.weight).max()!,sum=samples.reduce(0){$0+$1.weight/maxWeight}
        let weights=samples.map { ($0.weight/maxWeight)/sum }
        let stencils=try samples.map { try LUTSampleGrid.basis($0.input,dimension:dimension) }
        var edges=[(Int,Int)]()
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let i=(b*dimension+g)*dimension+r
            if r+1<dimension { edges.append((i,i+1)) }
            if g+1<dimension { edges.append((i,i+dimension)) }
            if b+1<dimension { edges.append((i,i+dimension*dimension)) }
        } } }
        let smooth=regularization/Double(max(1,edges.count)),ridge=max(regularization*1e-3,1e-10)/Double(count)
        func objective(_ values:[Double]) -> Double {
            var loss=0.0
            for s in samples.indices { for c in 0..<3 {
                let v=stencils[s].reduce(0){$0+values[$1.0*3+c]*$1.1}
                loss += weights[s]*pow(tone.value(at:v)-samples[s].target[c],2)/2
            } }
            for (a,b) in edges { for c in 0..<3 {
                let delta=(values[a*3+c]-base[a*3+c])-(values[b*3+c]-base[b*3+c])
                loss += smooth*delta*delta/2
            } }
            for i in 0..<count { loss += ridge*pow(values[i]-base[i],2)/2 }
            return loss
        }
        var values=base,loss=objective(base),converged=false,iterations=0
        for iteration in 1...maxIterations {
            try Task.checkCancellation()
            var gradient=[Double](repeating:0,count:count),diagonal=[Double](repeating:ridge,count:count)
            for i in 0..<count { gradient[i]=ridge*(values[i]-base[i]) }
            for s in samples.indices { for c in 0..<3 {
                let v=stencils[s].reduce(0){$0+values[$1.0*3+c]*$1.1}
                let h=1e-5,low=max(0,v-h),high=min(1,v+h)
                let derivative=(tone.value(at:high)-tone.value(at:low))/max(1e-12,high-low)
                let error=tone.value(at:v)-samples[s].target[c]
                for (vertex,w) in stencils[s] {
                    let i=vertex*3+c,jacobian=derivative*w
                    gradient[i] += weights[s]*error*jacobian
                    diagonal[i] += weights[s]*jacobian*jacobian
                }
            } }
            for (a,b) in edges { for c in 0..<3 {
                let ia=a*3+c,ib=b*3+c,delta=(values[ia]-base[ia])-(values[ib]-base[ib])
                gradient[ia] += smooth*delta;gradient[ib] -= smooth*delta
                diagonal[ia] += smooth;diagonal[ib] += smooth
            } }
            var step=0.5,accepted:[Double]?,nextLoss=loss
            for _ in 0..<12 {
                let next=(0..<count).map { min(1,max(0,values[$0]-step*gradient[$0]/max(diagonal[$0],1e-14))) }
                let proposed=objective(next)
                if proposed<=loss+1e-16 { accepted=next;nextLoss=proposed;break }
                step *= 0.5
            }
            iterations=iteration
            guard let next=accepted else { break }
            let movement=zip(values,next).map { abs($0-$1) }.max()!
            values=next;loss=nextLoss
            if movement<=tolerance { converged=true;break }
        }
        return .init(grid:try .init(dimension:dimension,samples:values.map(Float.init)),iterations:iterations,converged:converged)
    }
}
