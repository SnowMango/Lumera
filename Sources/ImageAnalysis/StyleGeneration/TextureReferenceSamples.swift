import Foundation
import Metal
import ImagingCore

/// Independent Double normal generator and fixed sinusoidal paper pattern.
/// No runtime shader hash, noise generator, fitter or renderer generates these expectations.
enum TextureReferenceSamples {
    struct Fixture {let device:MTLDevice,textures:[MTLTexture]}
    static func make(sigma:Double,fixedPattern:Bool,side:Int=512,seed:UInt64=1729)throws->Fixture {
        guard let device=MTLCreateSystemDefaultDevice() else {throw LabError.noMetal}
        var state=seed
        func uniform()->Double {state=state &* 6364136223846793005 &+ 1442695040888963407;return (Double(state>>11)+0.5)/9007199254740992}
        func normal()->Double {sqrt(-2*log(uniform()))*cos(2 * .pi * uniform())}
        var textures=[MTLTexture]()
        for _ in 0..<4 {
            var pixels=[Float](repeating:1,count:side*side*4)
            for y in 0..<side {for x in 0..<side {
                let paper=fixedPattern ? 0.09*sin(Double(x)*0.12)+0.03*Double(y)/Double(side):0
                let value=Float(0.45+paper+sigma*normal()),i=(y*side+x)*4
                pixels[i]=value;pixels[i+1]=value;pixels[i+2]=value
            }}
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:side,height:side,mipmapped:false);d.storageMode = .shared;d.usage=[.shaderRead]
            guard let t=device.makeTexture(descriptor:d) else {throw LabError.noMetal}
            pixels.withUnsafeBytes{t.replace(region:MTLRegionMake2D(0,0,side,side),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:side*16)};textures.append(t)
        }
        return .init(device:device,textures:textures)
    }
    static func analyticalGroups(amplitude:Double)->[TextureCondition] {
        let bands=[0.15,0.3,0.55]
        func temporal(_ mean:Double,_ variance:Double)->TemporalTexture {
            let v=TextureMoments(varianceY:variance,bands:bands)
            return .init(mean:mean,training:v,validation:v,lagSpread:0,fixedVariance:0.004)
        }
        return zip([-1.0,0,1],[0.2,0.45,0.7]).map{ev,mean in
            .init(exposureEV:ev,input:temporal(mean,0.0001),target:temporal(mean,0.0001+amplitude*amplitude),unit:temporal(mean,0.0004))
        }
    }
}

extension TextureReferenceSamples {
    struct FileFixture {
        var folder:URL,measurements:MeasurementBundle,baseline:Profile
        func cleanup(){try? FileManager.default.removeItem(at:folder)}
    }
    static func files(model:GenerationModel,seed:UInt64=9341,allConditions:Bool=false,middleMultiplier:Double=1)throws->FileFixture {
        let side=512,folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        do {
            var state=seed
            func uniform()->Double {state=state &* 6364136223846793005 &+ 1442695040888963407;return (Double(state>>11)+0.5)/9007199254740992}
            func normal()->Double {sqrt(-2*log(uniform()))*cos(2 * .pi * uniform())}
            var baseline=Profile.standard;baseline.parameters.noise.chromaRatio=0;baseline.parameters.grain.chroma=0;baseline.parameters.grain.size=8
            let plan=try CaptureProtocol(input:.init(id:"oracle-input",isoLevels:[100,400,1600],baseExposureSeconds:0.01),target:.init(id:"oracle-target",isoLevels:[100,400,1600],baseExposureSeconds:0.01))
            var frames=[FrameMeasurements]()
            for step in plan.steps where step.target == .flat && (allConditions || step.conditionIndex==0) {
              try autoreleasepool {
                let mean=step.exposureEV == -1 ? 0.2:(step.exposureEV == 0 ? 0.45:0.7)
                // Two independently sampled Gaussian grids, interpolated in Double.
                var grids=[[Double]]();let gridSide=300
                if model == .film && step.role == .target {for _ in 0..<2 {grids.append((0..<(gridSide*gridSide)).map{_ in normal()})}}
                func field(_ x:Double,_ y:Double,_ grid:[Double])->Double {
                    let ix=Int(floor(x)),iy=Int(floor(y)),fx=x-floor(x),fy=y-floor(y),u=fx*fx*(3-2*fx),v=fy*fy*(3-2*fy)
                    let weights=[(1-u)*(1-v),u*(1-v),(1-u)*v,u*v]
                    let values=[grid[iy*gridSide+ix],grid[iy*gridSide+ix+1],grid[(iy+1)*gridSide+ix],grid[(iy+1)*gridSide+ix+1]]
                    return zip(values,weights).reduce(0){$0+$1.0*$1.1}/sqrt(weights.reduce(0){$0+$1*$1})
                }
                var pixels=[Float](repeating:1,count:side*side*4)
                for y in 0..<side {for x in 0..<side {
                    var value=mean+0.01*sin(Double(x)*0.12)+0.003*normal()
                    if step.role == .target {
                        let n:Double
                        if model == .digital {n=normal()}
                        else {
                            let u=(Double(x)+0.5)/2,v=(Double(y)+0.5)/2
                            n=(0.65*field(u,v,grids[0])+0.35*field(u*0.4+13.7,v*0.4+29.1,grids[1]))/sqrt(0.65*0.65+0.35*0.35)
                        }
                        let amplitude=allConditions ? (0.02+Double(step.conditionIndex)*0.005)*(step.conditionIndex==1 ? middleMultiplier:1):0.025
                        value += amplitude*n
                    }
                    let i=(y*side+x)*4;for c in 0..<3 {pixels[i+c]=Float(value)}
                }}
                let image=try ImageFrame(width:side,height:side,pixels:pixels),data=try ImageCodec.encodeReference(image),url=folder.appendingPathComponent(step.id+".png")
                try data.write(to:url)
                var c=CaptureConditions();c.iso=step.expectedISO;c.exposureDurationSeconds=step.expectedExposureSeconds
                frames.append(.init(fileDigest:Digest.data(data),step:step,actualConditions:c,width:side,height:side,patches:[.init(id:"flat",kind:.flat,mean:[mean,mean,mean],variance:[0.0008,0.0008,0.0008],clippedFraction:0,pixelCount:side*side)],sourceURL:url,pose:nil))
              }
            }
            return .init(folder:folder,measurements:.init(frames:frames,resourceDigests:[:]),baseline:baseline)
        } catch {try? FileManager.default.removeItem(at:folder);throw error}
    }
}
