import Foundation
import CoreImage
import ImagingCore

/// Runs the same detector, grouping and GPU measurement used by acquisition.
/// Geometric expectations come from page dimensions and independently solved constants, not the detector's fit.
enum CaptureDeveloperCheck {
    static func detection(fixtures:URL) throws -> [String:Double] {
        try GenerationMaterials.verify(fixtures)
        let image=try ImageCodec.load(fixtures.appendingPathComponent("composite.png")),w=image.width,h=image.height
        var maximum=0.0,falseAccepts=0.0
        func check(_ frame:ImageFrame,expected:(TargetPoint)->TargetPoint) throws {
            let found=try TargetDetection.detect(image:frame)
            for region in TargetLayout.composite.regions {for p in region.rect.corners {
                maximum=max(maximum,found.transform.project(p).distance(to:expected(p)))
            }}
        }
        try check(image){.init(x:$0.x*Double(w),y:$0.y*Double(h))}
        try Task.checkCancellation()
        try autoreleasepool {
            var rotated=try ImageFrame.solid(width:h,height:w,value:0)
            for y in 0..<h {for x in 0..<w {for c in 0..<4 {rotated.pixels[(x*h+h-1-y)*4+c]=image.pixels[(y*w+x)*4+c]}}}
            try check(rotated){.init(x:Double(h)*(1-$0.y),y:Double(w)*$0.x)}
        }
        try Task.checkCancellation()
        try autoreleasepool {
            let width=Double(w),height=Double(h),ci=CIImage(cgImage:try ImageCodec.cgImage(image))
            let transformed=ci.applyingFilter("CIPerspectiveTransform",parameters:["inputTopLeft":CIVector(x:0.08*width,y:0.95*height),"inputTopRight":CIVector(x:0.90*width,y:0.90*height),"inputBottomRight":CIVector(x:0.95*width,y:0.08*height),"inputBottomLeft":CIVector(x:0.04*width,y:0.04*height)])
            let canvas=CIImage(color:CIColor.white).cropped(to:CGRect(x:0,y:0,width:width,height:height))
            let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
            defer{try? FileManager.default.removeItem(at:file)}
            try CIContext().writePNGRepresentation(of:transformed.composited(over:canvas),to:file,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            try check(ImageCodec.load(file)) {p in
                let denominator=0.10465116279069757*p.x-0.10465116279069761*p.y+1
                return .init(x:width*(0.9141860465116279*p.x-0.04418604651162793*p.y+0.08)/denominator,y:height*(0.06046511627906976*p.x+0.8095348837209303*p.y+0.05)/denominator)
            }
        }
        var covered=image
        for y in 0..<h/5 {for x in 0..<w/4 {for c in 0..<3 {covered.pixels[(y*w+x)*4+c]=1}}}
        do{_=try TargetDetection.detect(image:covered);falseAccepts+=1}catch is CancellationError {throw CancellationError()}catch{}
        let dot=TargetLayout.composite.markers[0].center,cx=dot.x*Double(w),cy=dot.y*Double(h),r=2.0/210*Double(w)
        for cutoff in [0.0,0.5] {
            var damaged=image
            for y in Int(cy-r-2)...Int(cy+r+2) {for x in Int(cx+cutoff*r)...Int(cx+r+2) {for c in 0..<3 {damaged.pixels[(y*w+x)*4+c]=1}}}
            do{_=try TargetDetection.detect(image:damaged);falseAccepts+=1}catch is CancellationError {throw CancellationError()}catch{}
        }
        let original=TargetLayout.composite.markers.map{DetectedMarker(id:$0.id,center:.init(x:$0.center.x*Double(w),y:$0.center.y*Double(h)))}
        var wrong=original;wrong[0].id="LM0C0"
        var cropped=original;cropped[0].center.x = -1
        for invalid in [wrong,cropped,Array(original.dropLast()),original+[original[0]]] {
            do {_=try TargetDetection.resolve(markers:invalid,layout:.composite,width:w,height:h);falseAccepts+=1}catch{}
        }
        return ["geometry":maximum,"rejectInvalidBoard":falseAccepts]
    }
    static func quality() throws -> [String:Double] {
        let plan=try CaptureProtocol(input:.init(id:"input",isoLevels:[100,400,1600],baseExposureSeconds:0.01),target:.init(id:"target",isoLevels:[80,320,1250],baseExposureSeconds:0.02))
        let files=plan.steps.map {s -> CaptureFile in
            var c=CaptureConditions();c.iso=s.expectedISO;c.exposureDurationSeconds=s.expectedExposureSeconds
            return .init(url:URL(fileURLWithPath:"/self-check/"+s.id),digest:s.id,role:s.role,target:s.target,conditions:c)
        }
        var falseAccepts=0.0
        if !CaptureGrouping.group(files:files,protocol:plan).canMeasure {falseAccepts+=1}
        var wrong=files;wrong[0].role = .target
        var missingMetadata=files;missingMetadata[0].conditions.iso=nil
        for invalid in [Array(files.dropLast()),files+[files[0]],wrong,missingMetadata] {
            if CaptureGrouping.group(files:invalid,protocol:plan).canMeasure {falseAccepts+=1}
        }
        let step=plan.steps[0];var c=CaptureConditions();c.iso=step.expectedISO;c.exposureDurationSeconds=step.expectedExposureSeconds
        let valid=TargetLayout.composite.regions.map{PatchMeasurement(id:$0.id,kind:$0.kind,mean:[0.4,0.4,0.4],variance:[0.0001,0.0001,0.0001],clippedFraction:0,pixelCount:1000)}
        if !CaptureQuality.evaluate(patches:valid,conditions:c,step:step).isEmpty {falseAccepts+=1}
        var clipped=valid;clipped[0].clippedFraction=0.1
        var glare=valid;glare[0].variance=[0.1,0.1,0.1]
        var wrongKind=valid;wrongKind[0].kind = .light
        var negativeFraction=valid;negativeFraction[0].clippedFraction = -1
        for invalid in [clipped,glare,Array(valid.prefix(12)),Array(repeating:valid[0],count:valid.count),wrongKind,negativeFraction] {
            if CaptureQuality.evaluate(patches:invalid,conditions:c,step:step).isEmpty {falseAccepts+=1}
        }
        if CaptureQuality.evaluate(patches:valid,conditions:.init(),step:step).isEmpty {falseAccepts+=1}
        var frame=try ImageFrame.solid(width:128,height:96,value:0)
        var sum=[Double](repeating:0,count:3),square=sum
        for y in 0..<96 {for x in 0..<128 {for channel in 0..<3 {
            let value=Float(0.2+0.6*Double((x*13+y*7+channel*23)%101)/100);frame.pixels[(y*128+x)*4+channel]=value
            if (32..<96).contains(x) && (24..<72).contains(y) {sum[channel]+=Double(value);square[channel]+=Double(value)*Double(value)}
        }}}
        let region=TargetRegion(id:"reference",kind:.gray,rect:.init(x:0.25,y:0.25,width:0.5,height:0.5),printedRGB:[])
        let renderer=try MetalRenderer(cacheLimitBytes:128*1024*1024);defer{renderer.releaseCaches()}
        let measured=try renderer.renderPatchStatistics(frame,style:ResolvedStyle(profile:.standard),transform:.init(coefficients:[128,0,0,0,96,0,0,0,1]),regions:[region])[0]
        var maximum=0.0
        for channel in 0..<3 {
            let mean=sum[channel]/3072,variance=square[channel]/3072-mean*mean
            maximum=max(maximum,abs(measured.mean[channel]-mean),abs(measured.variance[channel]-variance))
        }
        return ["patchStatistics":maximum,"rejectUnsafeCapture":falseAccepts]
    }
}
