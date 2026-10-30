import XCTest
import CoreImage
import ImagingCore
@testable import ImageAnalysis

final class PrintedTargetIntegrationTests:XCTestCase {
    private var materials:URL {
        var url=URL(fileURLWithPath:#filePath)
        for _ in 0..<5 {url.deleteLastPathComponent()}
        return url.appendingPathComponent("TestMaterials/StyleGeneration-v1")
    }
    func testPrintedLayoutMatchesCodeAndDetectsRealRaster() throws {
        let fileLayout=try JSON.load(TargetLayout.self,from:materials.appendingPathComponent("layout.json"))
        XCTAssertEqual(fileLayout.markers.map(\.id),TargetLayout.composite.markers.map(\.id))
        for (a,b) in zip(fileLayout.regions,TargetLayout.composite.regions) {
            XCTAssertEqual(a.rect.x,b.rect.x,accuracy:1e-12);XCTAssertEqual(a.rect.y,b.rect.y,accuracy:1e-12)
            XCTAssertEqual(a.rect.width,b.rect.width,accuracy:1e-12);XCTAssertEqual(a.rect.height,b.rect.height,accuracy:1e-12)
        }
        let image=try ImageCodec.load(materials.appendingPathComponent("composite.png"))
        let found=try TargetDetection.detect(image:image)
        for region in TargetLayout.composite.regions {
            let p=region.rect.corners[0],q=found.transform.project(p)
            XCTAssertLessThan(q.distance(to:.init(x:p.x*Double(image.width),y:p.y*Double(image.height))),1.0)
        }
        let stats=try MetalRenderer().renderPatchStatistics(image,style:ResolvedStyle(profile:.standard),transform:found.transform,regions:Array(TargetLayout.composite.regions.prefix(30)))
        for (stat,region) in zip(stats,TargetLayout.composite.regions) {
            for c in 0..<3 {XCTAssertEqual(stat.mean[c],region.printedRGB[c],accuracy:0.012)}
        }
    }
    func testRotationAndMissingMarker() throws {
        let image=try ImageCodec.load(materials.appendingPathComponent("composite.png")),w=image.width,h=image.height
        var rotated=try ImageFrame.solid(width:h,height:w,value:0)
        for y in 0..<h {for x in 0..<w {for c in 0..<4 {rotated.pixels[(x*h+h-1-y)*4+c]=image.pixels[(y*w+x)*4+c]}}}
        let found=try TargetDetection.detect(image:rotated)
        for m in TargetLayout.composite.markers {
            let q=found.transform.project(m.center),expected=TargetPoint(x:Double(h)*(1-m.center.y),y:Double(w)*m.center.x)
            XCTAssertLessThan(q.distance(to:expected),1.0)
        }
        var covered=image
        for y in 0..<h/5 {for x in 0..<w/4 {for c in 0..<3 {covered.pixels[(y*w+x)*4+c]=1}}}
        XCTAssertThrowsError(try TargetDetection.detect(image:covered))
    }
    func testPerspectiveAgainstIndependentCoreImageTransform() throws {
        let image=try ImageCodec.load(materials.appendingPathComponent("composite.png")),w=Double(image.width),h=Double(image.height)
        let ci=CIImage(cgImage:try ImageCodec.cgImage(image))
        let distorted=ci.applyingFilter("CIPerspectiveTransform",parameters:["inputTopLeft":CIVector(x:0.08*w,y:0.95*h),"inputTopRight":CIVector(x:0.90*w,y:0.90*h),"inputBottomRight":CIVector(x:0.95*w,y:0.08*h),"inputBottomLeft":CIVector(x:0.04*w,y:0.04*h)])
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer{try? FileManager.default.removeItem(at:file)}
        try CIContext().writePNGRepresentation(of:distorted.composited(over:CIImage(color:CIColor.white).cropped(to:CGRect(x:0,y:0,width:w,height:h))),to:file,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        let found=try TargetDetection.detect(image:ImageCodec.load(file))
        let unit=[TargetPoint(x:0,y:0),.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)]
        let destination=[TargetPoint(x:0.08*w,y:0.05*h),.init(x:0.90*w,y:0.10*h),.init(x:0.95*w,y:0.92*h),.init(x:0.04*w,y:0.96*h)]
        let expected=try ProjectiveTransform.fit(from:unit,to:destination)
        for region in TargetLayout.composite.regions {
            XCTAssertLessThan(found.transform.project(region.rect.corners[0]).distance(to:expected.project(region.rect.corners[0])),1)
        }
    }
    func testRejectsDamagedDotWithAllCodesVisible() throws {
        let image=try ImageCodec.load(materials.appendingPathComponent("composite.png")),w=image.width,h=image.height
        let marker=TargetLayout.composite.markers[0].center
        let cx=marker.x*Double(w),cy=marker.y*Double(h),r=2.0/210*Double(w)
        for cutoff in [0.0,0.5] {
            var damaged=image
            for y in Int(cy-r-2)...Int(cy+r+2) {for x in Int(cx+cutoff*r)...Int(cx+r+2) {for c in 0..<3 {damaged.pixels[(y*w+x)*4+c]=1}}}
            XCTAssertThrowsError(try TargetDetection.detect(image:damaged))
        }
    }

}
