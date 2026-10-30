import Foundation
import ImagingCore

public enum AcceptanceFixture:String,Codable,CaseIterable,Sendable {
    case ramp,steps,patches,flat05,flat18,flat50,flat85,flat95,edge,detail,pointSmall,pointMedium,pointLarge,brightEdge,noise
    public var method:String {
        switch self {
        case .ramp,.steps:return "D01-tone"
        case .patches:return "D02-color"
        case .flat05,.flat18,.flat50,.flat85,.flat95:return "D03-flat"
        case .edge,.detail:return "D04-detail"
        case .pointSmall,.pointMedium,.pointLarge,.brightEdge:return "D05-glow"
        case .noise:return "D06-noise"
        }
    }
}
public struct FixtureRegion:Codable,Equatable,Sendable {
    public var name:String
    public var x:Int,y:Int,width:Int,height:Int
}
public struct FixtureImage:Codable,Equatable,Sendable {
    public var kind:AcceptanceFixture,file:String,sha256:String,method:String
    public var width:Int,height:Int,bitDepth:Int
    public var colorSpace:String,transfer:String,alpha:String
    public var generation:[String:String]
    public var regions:[FixtureRegion]
    public var expected:String
}
public struct FixtureAsset:Codable,Equatable,Sendable {public var file:String,sha256:String,purpose:String}
public struct FixtureManifest:Codable,Equatable,Sendable {
    public var version="lumera-acceptance-v1"
    public var generator="AcceptanceFixtures-v1"
    public var images:[FixtureImage]
    public var assets:[FixtureAsset]
}
/// Digital QA materials, not photographed charts and not colorimetric certification.
public enum AcceptanceFixtures {
    public static let width=2048,height=1536
    public static func make(_ kind:AcceptanceFixture,width:Int=2048,height:Int=1536,seed:UInt64=42) throws -> ImageFrame {
        var frame=try ImageFrame.solid(width:width,height:height,value:0)
        var rng=ReferenceRandom(seed:seed)
        let colors:[[Double]]=[[0,0,0],[1,1,1],[0.18,0.18,0.18],[0.5,0.5,0.5],[0.8,0.2,0.1],[0.1,0.7,0.2],[0.1,0.2,0.8],[0.8,0.7,0.1],[0.1,0.7,0.7],[0.7,0.1,0.7],[0.65,0.45,0.32],[0.3,0.45,0.6]]
        for y in 0..<height {
            if y%64==0 {try Task.checkCancellation()}
            for x in 0..<width {
                var c=[Double](repeating:0,count:3)
                let nx=Double(x)/Double(max(1,width-1)),ny=Double(y)/Double(max(1,height-1))
                switch kind {
                case .ramp:c=Array(repeating:nx,count:3)
                case .steps:c=Array(repeating:Double(min(20,x*21/width))/20,count:3)
                case .patches:c=colors[min(2,y*3/height)*4+min(3,x*4/width)]
                case .flat05:c=Array(repeating:0.05,count:3)
                case .flat18:c=Array(repeating:0.18,count:3)
                case .flat50:c=Array(repeating:0.5,count:3)
                case .flat85:c=Array(repeating:0.85,count:3)
                case .flat95:c=Array(repeating:0.95,count:3)
                case .edge:
                    // Hard, pixel-centre sampled edge at exactly 5 degrees from vertical.
                    let d=Double(x)+0.5-Double(width)/2-(Double(y)+0.5-Double(height)/2)*tan(5 * .pi/180)
                    c=Array(repeating:d<0 ? 0.15:0.85,count:3)
                case .detail:
                    c=Array(repeating:0.5+0.18*sin(2 * .pi*nx*16)+0.12*cos(2 * .pi*ny*48)+0.05*sin(2 * .pi*(nx+ny)*128),count:3)
                case .pointSmall,.pointMedium,.pointLarge:
                    let radius:Double=kind == .pointSmall ? 2:(kind == .pointMedium ? 8:24)
                    let linear:Double=kind == .pointSmall ? 0.3:(kind == .pointMedium ? 0.7:1)
                    let inside=hypot(Double(x)+0.5-Double(width)/2,Double(y)+0.5-Double(height)/2)<=radius*Double(width)/2048
                    c=Array(repeating:inside ? AcceptanceReference.encode(linear):0,count:3)
                case .brightEdge:c=Array(repeating:nx<0.5 ? 0:AcceptanceReference.encode(0.9),count:3)
                case .noise:c=Array(repeating:min(1,max(0,0.5+0.02*rng.normal())),count:3)
                }
                let i=(y*width+x)*4
                frame.pixels[i]=Float(c[0]);frame.pixels[i+1]=Float(c[1]);frame.pixels[i+2]=Float(c[2])
            }
        }
        frame.provenance=["kind":"digital acceptance fixture","fixture":kind.rawValue,"version":"lumera-acceptance-v1","seed":String(seed)]
        return frame
    }
    private static func regions(for kind:AcceptanceFixture,central:FixtureRegion)->[FixtureRegion] {
        switch kind {
        case .ramp:return [.init(name:"中央完整渐变（包含黑白端点）",x:0,y:736,width:2048,height:64)]
        case .steps:return (0..<21).map {i in .init(name:"阶梯 \(i)，编码值 \(Double(i)/20)",x:Int((Double(i)+0.5)*2048/21)-16,y:704,width:32,height:128)}
        case .patches:return (0..<12).map {i in .init(name:"色块第 \(i/4+1) 行第 \(i%4+1) 列",x:(i%4)*512+192,y:(i/4)*512+192,width:128,height:128)}
        case .flat50:return [central,.init(name:"暗角中心",x:992,y:736,width:64,height:64),.init(name:"暗角左上",x:0,y:0,width:64,height:64),.init(name:"暗角右上",x:1984,y:0,width:64,height:64),.init(name:"暗角左下",x:0,y:1472,width:64,height:64),.init(name:"暗角右下",x:1984,y:1472,width:64,height:64)]
        default:return [central]
        }
    }
    /// Writes into a new directory only; partial failure is cleaned, existing data is never changed.
    @discardableResult public static func write(to directory:URL) throws -> FixtureManifest {
        guard !FileManager.default.fileExists(atPath:directory.path) else {throw LabError.io("测试材料目录已存在；请选择新目录，避免覆盖")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var complete=false
        defer {if !complete {try? FileManager.default.removeItem(at:directory)}}
        var entries=[FixtureImage](),assets=[FixtureAsset]()
        for kind in AcceptanceFixture.allCases {
            try autoreleasepool {
                let image=try make(kind),data=try ImageCodec.encodeReference(image),file="digital/"+kind.rawValue+".png"
                try SafeFiles.write(data,to:directory.appendingPathComponent(file))
                let region=FixtureRegion(name:"中心选区（避开画面边缘）",x:768,y:512,width:512,height:512)
                var generation=["domain":"encoded sRGB except explicitly linear bright sources","seed":"42","method":kind.method]
                var expected="见 Lumera-测试定义.md 的 "+kind.method
                switch kind {
                case .ramp:generation["formula"]="R=G=B=x/2047";expected="首列0、末列1，单调；PNG 量化 ≤0.5/65535"
                case .steps:generation["formula"]="R=G=B=min(20,floor(x*21/2048))/20"
                case .patches:generation["RGB row-major"]="0,0,0;1,1,1;.18,.18,.18;.5,.5,.5;.8,.2,.1;.1,.7,.2;.1,.2,.8;.8,.7,.1;.1,.7,.7;.7,.1,.7;.65,.45,.32;.3,.45,.6"
                case .edge:generation["angleDegreesFromVertical"]="5";generation["encodedLevels"]="0.15,0.85";generation["sampling"]="hard edge at pixel centers, no optical blur"
                case .detail:generation["formula"]=".5+.18*sin(2*pi*nx*16)+.12*cos(2*pi*ny*48)+.05*sin(2*pi*(nx+ny)*128)"
                case .pointSmall,.pointMedium,.pointLarge:
                    generation["radiusAt2048"] = kind == .pointSmall ? "2":(kind == .pointMedium ? "8":"24")
                    generation["linearLevel"] = kind == .pointSmall ? "0.3":(kind == .pointMedium ? "0.7":"1")
                case .brightEdge:generation["linearLevels"]="0,0.9"
                case .noise:generation["distribution"]="Box-Muller N(0.5,0.02^2), SplitMix64 seed42; monochrome";expected="中心均值 0.5，sigma 0.02；统计界限见 D06；不是相机噪点真值"
                default:generation["encodedLevel"]=String(image.pixels[0]);expected="空间恒定；用于暗角和随机质感残差测量"
                }
                entries.append(FixtureImage(kind:kind,file:file,sha256:Digest.data(data),method:kind.method,width:width,height:height,bitDepth:16,colorSpace:"sRGB",transfer:"IEC sRGB",alpha:"none (RGB)",generation:generation,regions:regions(for:kind,central:region),expected:expected))
            }
        }
        for (name,scale) in [("identity",1.0),("linear-encoded-gain",0.8)] {
            var text="TITLE \"Lumera digital QA \(name)\"\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
            for b in 0...1 {for g in 0...1 {for r in 0...1 {text+="\(Double(r)*scale) \(Double(g)*scale) \(Double(b)*scale)\n"}}}
            let file="luts/"+name+".cube",data=Data(text.utf8)
            try SafeFiles.write(data,to:directory.appendingPathComponent(file))
            assets.append(.init(file:file,sha256:Digest.data(data),purpose:"encoded RGB → encoded RGB × \(scale); not exposure or device calibration"))
        }
        // Separate seeds allow independent statistical repetitions; no per-image RNG reseeding by row.
        for seed:UInt64 in [43,44,45] {
            let data=try autoreleasepool {try ImageCodec.encodeReference(make(.noise,seed:seed))},file="developer/noise-seed-\(seed).png"
            try SafeFiles.write(data,to:directory.appendingPathComponent(file))
            assets.append(.init(file:file,sha256:Digest.data(data),purpose:"D06-noise; same generator, seed \(seed), 2048×1536 16-bit RGB sRGB; development only"))
        }
        let manifest=FixtureManifest(images:entries,assets:assets)
        try SafeFiles.write(JSON.encode(manifest),to:directory.appendingPathComponent("manifest.json"))
        complete=true;return manifest
    }
}
/// Independent Double reference arithmetic. Never calls rendering code or StyleEvaluator.
public enum AcceptanceReference {
    /// Independent Double reference; no call into the production curve sampler.
    public static func curve(_ x:Double,definition:ResponseCurve)->Double {
        guard let f=definition.function else {
            let k=definition.knots.map{($0.x,$0.y)}
            return definition.interpolation == .smooth ? monotone(x,knots:k):linear(x,knots:k)
        }
        let t=min(1,max(0,(x-f.xLower)/(f.xUpper-f.xLower))),fraction:Double
        switch f.family {
        case .constant:fraction=0
        case .linear:fraction=t
        case .power:fraction=pow(t,f.exponent)
        case .sigmoid:
            let a=tanh(-2*f.exponent*f.center),b=tanh(2*f.exponent*(1-f.center))
            fraction=(tanh(2*f.exponent*(t-f.center))-a)/(b-a)
        case .threshold:
            let z=min(1,max(0,(t-(f.center-f.width/2))/f.width))
            fraction=3*z*z-2*z*z*z
        case .bell:fraction=exp(-pow(t-f.center,2)/(2*f.width*f.width))
        }
        return f.start+(f.end-f.start)*fraction
    }
    public static func decode(_ x:Double)->Double {x<=0.04045 ? x/12.92:pow((x+0.055)/1.055,2.4)}
    public static func encode(_ x:Double)->Double {x<=0.0031308 ? x*12.92:1.055*pow(x,1/2.4)-0.055}
    public static func exposure(_ x:Double,ev:Double)->Double {min(1,max(0,encode(decode(x)*pow(2,ev))))}
    public static func linear(_ x:Double,knots:[(Double,Double)])->Double {
        guard let a=knots.first,let z=knots.last else{return .nan}
        if x<=a.0{return a.1};if x>=z.0{return z.1}
        for i in 1..<knots.count where x<=knots[i].0 {let a=knots[i-1],b=knots[i];return a.1+(b.1-a.1)*(x-a.0)/(b.0-a.0)}
        return z.1
    }
    public static func monotone(_ x:Double,knots:[(Double,Double)])->Double {
        guard knots.count>=2 else{return .nan}
        if x<=knots[0].0{return knots[0].1};if x>=knots.last!.0{return knots.last!.1}
        let h=(1..<knots.count).map{knots[$0].0-knots[$0-1].0}
        let d=(1..<knots.count).map{(knots[$0].1-knots[$0-1].1)/h[$0-1]}
        var m=[d[0]]
        for i in 1..<(knots.count-1) {
            let w1=2*h[i]+h[i-1],w2=h[i]+2*h[i-1]
            m.append(d[i-1]*d[i]<=0 ? 0:(w1+w2)/(w1/d[i-1]+w2/d[i]))
        }
        m.append(d.last!)
        let i=(1..<knots.count).first{knots[$0].0>=x}!-1,t=(x-knots[i].0)/h[i]
        // Horner polynomial, independent of the shader's basis expansion.
        let a=2*knots[i].1-2*knots[i+1].1+h[i]*(m[i]+m[i+1])
        let b = -3*knots[i].1+3*knots[i+1].1-h[i]*(2*m[i]+m[i+1])
        let y=((a*t+b)*t+h[i]*m[i])*t+knots[i].1
        return min(max(knots[i+1].1,knots[i].1),max(min(knots[i+1].1,knots[i].1),y))
    }
    public static func vignetteEV(x:Double,y:Double,width:Int,height:Int,amount:Double,start:Double,falloff:Double)->Double {
        let r=min(1,hypot(x-Double(width)*0.5,y-Double(height)*0.5)/hypot(Double(width)*0.5,Double(height)*0.5))
        let t=min(1,max(0,(r-start)/(1-start)))
        return amount*pow(t*t*(3-2*t),falloff)
    }
    /// Direct scalar convolution, deliberately separate from GPU kernel tables/separable passes.
    public static func gaussian(_ source:[Double],width:Int,height:Int,sigma:Double)->[Double] {
        if sigma<0.08{return source}
        let radius=Int(ceil(3*sigma));var output=source
        for y in 0..<height {for x in 0..<width {
            var total=0.0,weight=0.0
            for j in -radius...radius {for i in -radius...radius {
                let w=exp(-Double(i*i+j*j)/(2*sigma*sigma));weight+=w
                total+=w*source[min(height-1,max(0,y+j))*width+min(width-1,max(0,x+i))]
            }}
            output[y*width+x]=total/weight
        }}
        return output
    }
}
private struct ReferenceRandom {
    var state:UInt64
    init(seed:UInt64){state=seed}
    mutating func uniform()->Double {
        state &+= 0x9e3779b97f4a7c15;var z=state
        z=(z^(z>>30)) &* 0xbf58476d1ce4e5b9;z=(z^(z>>27)) &* 0x94d049bb133111eb;z ^= z>>31
        return (Double(z>>11)+0.5)/9007199254740992
    }
    mutating func normal()->Double {sqrt(-2*log(uniform()))*cos(2 * .pi*uniform())}
}
