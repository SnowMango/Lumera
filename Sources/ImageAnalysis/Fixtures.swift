import ImageRendering
import Foundation
import ImagingCore
public enum Fixture: String, CaseIterable, Codable, Sendable { case ramp, patches, edge, texture, flat, point, steps }
public enum Fixtures {
    public static func make(_ kind: Fixture, width:Int=1024,height:Int=768) throws -> ImageFrame {
        var image=try ImageFrame.solid(width:width,height:height,value:0.5)
        let colors:[[Float]]=[[0.1,0.1,0.1],[0.8,0.8,0.8],[0.8,0.2,0.1],[0.15,0.65,0.25],[0.1,0.3,0.8],[0.85,0.65,0.1]]
        for y in 0..<height { for x in 0..<width {
            let i=(y*width+x)*4; var rgb=[Float](repeating:0.5,count:3)
            switch kind {
            case .flat: break
            case .ramp: rgb=Array(repeating:Float(x)/Float(max(1,width-1)),count:3)
            case .steps: rgb=Array(repeating:Float(min(7,x*8/width))/7,count:3)
            case .patches: rgb=colors[min(5,x*6/width)]
            case .edge:
                let d=Double(x)-Double(width)/2-(Double(y)-Double(height)/2)*0.08
                rgb=Array(repeating:Float(0.15+0.7/(1+exp(-d/0.7))),count:3)
            case .point:
                let d=hypot(Double(x-width/2),Double(y-height/2));rgb=Array(repeating:d<=2 ? 1:0,count:3)
            case .texture:
                let v=0.5+0.16*sin(Double(x)*0.7)+0.12*cos(Double(y)*0.23)+0.07*sin(Double(x+y)*1.31)
                rgb=Array(repeating:Float(v),count:3)
            }
            image.pixels[i]=rgb[0];image.pixels[i+1]=rgb[1];image.pixels[i+2]=rgb[2]
        }}
        image.provenance=["kind":"synthetic", "fixture":kind.rawValue,"color":"encoded sRGB"]
        return image
    }
}
