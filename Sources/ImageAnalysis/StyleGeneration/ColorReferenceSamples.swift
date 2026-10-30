import Foundation
import ImagingCore

/// Developer-only analytical oracle: no production rendering, curves or color transform calls.
/// Values represent digital camera patch observations, NOT printed RGB reflectances.
enum ColorReferenceSamples {
    static let matrix:[Double]=[1.08,-0.03,0.02,-0.02,0.97,0.02,0.01,0.02,0.93] // sum=3; permits neutral tint without a free gain
    static func decode(_ v:Double)->Double {v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)}
    static func encode(_ v:Double)->Double {v<=0.0031308 ? 12.92*v:1.055*pow(v,1/2.4)-0.055}
    static func tone(_ v:Double)->Double {
        if v<0.25{return 0.8*v};if v<0.5{return 0.20+1.2*(v-0.25)}
        if v<0.75{return 0.5+1.2*(v-0.5)};return 0.80+0.8*(v-0.75)
    }
    static func make(exposureGain:Double=1,neutral:Bool=false) throws ->MeasurementBundle {
        let plan=try CaptureProtocol(input:.init(id:"source",isoLevels:[100,400,1600],baseExposureSeconds:0.01),target:.init(id:"target",isoLevels:[80,320,1250],baseExposureSeconds:0.0125))
        let colors:[[Double]]=[[0.65,0.25,0.3],[0.2,0.6,0.3],[0.3,0.25,0.65],[0.65,0.55,0.3],[0.55,0.25,0.6],[0.25,0.6,0.55],[0.5,0.4,0.3],[0.7,0.55,0.4],[0.4,0.55,0.3],[0.3,0.4,0.55],[0.55,0.4,0.5],[0.6,0.5,0.3],[0.4,0.2,0.25],[0.25,0.4,0.3],[0.3,0.2,0.45],[0.45,0.4,0.3],[0.4,0.25,0.45],[0.3,0.45,0.5]]
        let frames=plan.steps.filter{$0.target == .composite}.map{s -> FrameMeasurements in
            let patches=TargetLayout.composite.regions.map{region -> PatchMeasurement in
                var rgb:[Double]
                if region.kind == .gray {let index=Int(region.id.split(separator:"-").last!)!;let v=0.14+0.065*Double(index);rgb=[v,v,v]}
                else if region.kind == .color {rgb=colors[Int(region.id.split(separator:"-").last!)!]}
                else {rgb=[0.4,0.4,0.4]}
                rgb=rgb.map{encode(decode($0)*pow(2,s.exposureEV*0.3))}
                if s.role == .target && !neutral {
                    let linear=rgb.map(decode)
                    rgb=(0..<3).map{r in tone(encode((0..<3).reduce(0.0){$0+matrix[r*3+$1]*linear[$1]}*exposureGain))}
                }
                return .init(id:region.id,kind:region.kind,mean:rgb,variance:[0,0,0],clippedFraction:0,pixelCount:1000)
            }
            var conditions=CaptureConditions();conditions.iso=s.expectedISO;conditions.exposureDurationSeconds=s.expectedExposureSeconds
            return .init(fileDigest:"analytical-"+s.id,step:s,actualConditions:conditions,width:2000,height:2800,patches:patches,pose:nil)
        }
        return .init(frames:frames,resourceDigests:[:])
    }
}
