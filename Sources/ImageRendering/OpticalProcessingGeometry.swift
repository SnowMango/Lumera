import ImagingCore

/// Continuous internal geometry; public requests expose only tested resolution choices.
package struct OpticalProcessingGeometry {
    package let width:Int,height:Int
    package let scaleX:Double,scaleY:Double
    package init(width:Int,height:Int,scale:Double) throws {
        _=try ImageDimensions.pixelCount(width:width,height:height)
        guard scale.isFinite,scale>0,scale<=1 else {throw LabError.invalid("效果处理比例必须大于 0 且不超过 1")}
        self.width=max(1,Int((Double(width)*scale).rounded(.up)))
        self.height=max(1,Int((Double(height)*scale).rounded(.up)))
        scaleX=Double(self.width)/Double(width);scaleY=Double(self.height)/Double(height)
    }
}
