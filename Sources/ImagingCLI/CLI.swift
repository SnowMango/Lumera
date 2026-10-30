import ImageAnalysis
import Foundation
import ImagingCore
import ImageRendering
import Darwin

private struct Arguments {
    var values:[String:String]=[:]
    var force=false
    init(_ args:[String],allowed:Set<String>) throws {
        var i=0
        while i<args.count {
            let key=args[i]
            if key=="--force" {guard !force else{throw LabError.invalid("Duplicate --force")};force=true;i+=1;continue}
            guard allowed.contains(key),i+1<args.count,values[key]==nil,!args[i+1].hasPrefix("--") else {throw LabError.invalid("Unknown, duplicated or incomplete option: \(key)")}
            values[key]=args[i+1];i+=2
        }
    }
    func required(_ key:String) throws -> String {guard let value=values[key] else{throw LabError.invalid("Missing \(key)")};return value}
    func url(_ key:String) throws -> URL {URL(fileURLWithPath:try required(key))}
}
private struct Batch:Codable {var inputs:[String]}
@main struct ImagingCLI {
    static func main() async {
        let args=Array(CommandLine.arguments.dropFirst())
        let task=Task.detached {try run(args)}
        signal(SIGINT,SIG_IGN)
        let interrupt=DispatchSource.makeSignalSource(signal:SIGINT,queue:.global());interrupt.setEventHandler{task.cancel()};interrupt.resume()
        do {try await task.value;interrupt.cancel()}
        catch {interrupt.cancel();FileHandle.standardError.write(Data(("CCDLab: \(error.localizedDescription)\n").utf8));exit(error is CancellationError ? 130:(error as? LabError)?.exitCode ?? 1)}
    }
    static func emit<T:Encodable>(_ value:T) throws {FileHandle.standardOutput.write(try JSON.encode(value));FileHandle.standardOutput.write(Data([10]))}
    static func save<T:Encodable>(_ value:T,_ url:URL,_ force:Bool) throws {try SafeFiles.write(JSON.encode(value),to:url,overwrite:force)}
    static func protect(_ output:URL,_ inputs:[URL]) throws {
        let path=output.resolvingSymlinksInPath().standardizedFileURL.path
        guard !inputs.contains(where:{$0.resolvingSymlinksInPath().standardizedFileURL.path==path}) else {throw LabError.invalid("Refusing to overwrite an input file")}
    }
    static func render(_ source:URL,_ destination:URL,_ profile:Profile,_ correction:DeviceCorrection?,_ longEdge:Int?,_ reference:Bool,_ force:Bool,_ renderer:MetalRenderer,_ protected:[URL],_ background:[Double],_ resources:RenderResources) throws -> RenderManifest {
        let sidecar=destination.appendingPathExtension("json")
        try protect(destination,protected);try protect(sidecar,protected)
        let format:OutputFormat
        switch destination.pathExtension.lowercased(){case "png":format = .png;case "jpg","jpeg":format = .jpeg;case "tif","tiff":format = .tiff;default:throw LabError.invalid("Output extension must be png, jpg or tiff")}
        guard !reference || destination.pathExtension.lowercased()=="png" else{throw LabError.invalid("Reference output requires PNG")}
        if !force,FileManager.default.fileExists(atPath:destination.path) || FileManager.default.fileExists(atPath:sidecar.path){throw LabError.io("Output or diagnostic sidecar already exists")}
        let image=try ImageCodec.load(source,background:background)
        let result=try renderer.render(image,style:StyleEvaluator.evaluate(StyleEvaluator.compile(profile),conditions:image.captureConditions).resolvedStyle(),correction:correction,resources:resources,request:RenderRequest(input:image.descriptor,maximumLongEdge:longEdge))
        let data=try reference ? ImageCodec.encodeReference(result.image):ImageCodec.encodePhoto(result.image,format:format)
        try Task.checkCancellation();try SafeFiles.write(data,to:destination,overwrite:force);try save(result.manifest,sidecar,force)
        return result.manifest
    }
    static func run(_ input:[String]) throws {
        guard let command=input.first,command != "--help",command != "help" else {
            print("""
            Lumera — offline camera texture renderer (schema 7)
            preset export --name standard|digital-demo|film-demo --output profile.json
            verify-style --profile profile.json --fixtures acceptance-kit [--conditions conditions.json] --output new-report-directory
            fixtures --output acceptance-kit
            fixtures --output-dir fixtures [--size 512] (legacy development fixtures)
            render --input image [--profile profile.json] --output result.png [--output-kind photo|reference] [--long-edge 1280] [--background 0,0,0] [--device-correction correction.json] [--lut look.cube] [--correction-lut correction.cube]
            batch --manifest inputs.json [--profile profile.json] --output-dir results [--output-kind photo|reference] [--device-correction correction.json] [--lut look.cube] [--correction-lut correction.cube]
            photo: 8-bit RGB; reference: 16-bit RGB PNG. Render/batch also write diagnostic JSON sidecars.
            Old fit, validate and measure session commands are retired. No legacy JSON migration.
            Overwrite requires --force; input files are always protected.
            """);return
        }
        if ["fit","validate","measure"].contains(command){throw LabError.unsupported("旧会话拟合/验证流程已停用；请使用手动工作台。新的识别与估计流程尚未实现。")}
        var remaining=Array(input.dropFirst());let allowed:Set<String>
        switch command {
        case "preset":guard remaining.first=="export" else{throw LabError.invalid("Expected preset export")};remaining.removeFirst();allowed=["--name","--output"]
        case "fixtures":allowed=["--output","--output-dir","--size"]
        case "verify-style":allowed=["--profile","--fixtures","--conditions","--output"]
        case "render":allowed=["--input","--profile","--output","--output-kind","--long-edge","--background","--device-correction","--lut","--correction-lut"]
        case "batch":allowed=["--manifest","--profile","--output-dir","--output-kind","--device-correction","--lut","--correction-lut"]
        default:throw LabError.invalid("Unknown command: \(command)")
        }
        let a=try Arguments(remaining,allowed:allowed)
        switch command {
        case "preset":try save(StylePresets.make(a.values["--name"] ?? "standard"),a.url("--output"),a.force)
        case "verify-style":
            guard !a.force else{throw LabError.invalid("验收报告需新目录，不支持--force")}
            let destination=try a.url("--output")
            guard !FileManager.default.fileExists(atPath:destination.path) else{throw LabError.io("验收输出目录已存在，请选择新目录")}
            let profile=try JSON.load(Profile.self,from:a.url("--profile"))
            let conditions: [CaptureConditions]
            if let path=a.values["--conditions"] {conditions=try JSON.load([CaptureConditions].self,from:URL(fileURLWithPath:path))}
            else {var iso=CaptureConditions();iso.iso=400;conditions=[CaptureConditions(),iso]}
            let report=try StyleAcceptance.run(profile:profile,conditions:conditions,fixtures:a.url("--fixtures"))
            // mkdir is exclusive even if another process creates the directory while measuring.
            guard mkdir(destination.path,0o755)==0 else{throw LabError.io("无法创建新的验收目录")}
            try SafeFiles.write(JSON.encode(report),to:destination.appendingPathComponent("report.json"))
            try SafeFiles.write(Data(report.summary.utf8),to:destination.appendingPathComponent("report.txt"))
            print(report.summary)
            if report.results.contains(where:{$0.status == .failed}) {throw LabError.invalid("标准验收存在失败项，详见已保存报告")}
        case "fixtures":
            if let path=a.values["--output"] {
                guard a.values["--output-dir"] == nil,a.values["--size"] == nil,!a.force else {throw LabError.invalid("标准材料使用固定尺寸和新目录；不允许混用 --output-dir、--size 或 --force")}
                try emit(AcceptanceFixtures.write(to:URL(fileURLWithPath:path)));return
            }
            guard let size=Int(a.values["--size"] ?? "512"),(64...2048).contains(size) else{throw LabError.invalid("Fixture size must be 64...2048")}
            let folder=try a.url("--output-dir")
            for kind in Fixture.allCases {try Task.checkCancellation();try SafeFiles.write(ImageCodec.encodeReference(Fixtures.make(kind,width:size,height:size)),to:folder.appendingPathComponent(kind.rawValue+".png"),overwrite:a.force)}
            try emit(["kind":"synthetic","output":folder.path])
        default:
            let kind=a.values["--output-kind"] ?? "photo"
            guard ["photo","reference"].contains(kind) else{throw LabError.invalid("Invalid --output-kind")}
            let profileURL=a.values["--profile"].map{URL(fileURLWithPath:$0)}
            let profile=try profileURL.map{try JSON.load(Profile.self,from:$0)} ?? .standard,renderer=try MetalRenderer()
            defer{renderer.releaseCaches()}
            let correctionURL=a.values["--device-correction"].map{URL(fileURLWithPath:$0)}
            let correction=try correctionURL.map{try JSON.load(DeviceCorrection.self,from:$0)}
            if let correction {
                try correction.validate()
                var color=ColorResponse();color.whiteBalance=correction.whiteBalance;color.matrix=correction.matrix
                _=try ColorTransform.prepare(color)
            }
            let lutURL=a.values["--lut"].map{URL(fileURLWithPath:$0)},correctionLUTURL=a.values["--correction-lut"].map{URL(fileURLWithPath:$0)}
            let resources=RenderResources(lut:try lutURL.map{try LUTImporter.load($0)},correctionLUT:try correctionLUTURL.map{try LUTImporter.load($0)})
            let correctionInputs=[profileURL,correctionURL,lutURL,correctionLUTURL].compactMap{$0}
            if command=="render" {
                let source=try a.url("--input"),long=a.values["--long-edge"].flatMap(Int.init)
                if a.values["--long-edge"] != nil,long == nil{throw LabError.invalid("Invalid --long-edge")}
                let parts=(a.values["--background"] ?? "0,0,0").split(separator:",",omittingEmptySubsequences:false)
                let background=parts.compactMap{Double($0)}
                guard parts.count==3,background.count==3 else{throw LabError.invalid("Background requires three numbers")}
                try emit(render(source,a.url("--output"),profile,correction,long,kind=="reference",a.force,renderer,[source]+correctionInputs,background,resources))
            } else {
                let manifest=try a.url("--manifest"),batch=try JSON.load(Batch.self,from:manifest),folder=try a.url("--output-dir")
                guard !batch.inputs.isEmpty,batch.inputs.count<=1000 else{throw LabError.invalid("Batch requires 1–1000 inputs")}
                let inputs=batch.inputs.map{path in path.hasPrefix("/") ? URL(fileURLWithPath:path):manifest.deletingLastPathComponent().appendingPathComponent(path)}
                var results=[RenderManifest]()
                for (i,path) in inputs.enumerated(){
                    try Task.checkCancellation()
                    FileHandle.standardError.write(Data("\(i+1)/\(inputs.count) \(path.lastPathComponent)\n".utf8))
                    let out=folder.appendingPathComponent(String(format:"%04d-",i+1)+path.deletingPathExtension().lastPathComponent+".png")
                    results.append(try render(path,out,profile,correction,nil,kind=="reference",a.force,renderer,inputs+[manifest]+correctionInputs,[0,0,0],resources))
                }
                try emit(results)
            }
        }
    }
}
