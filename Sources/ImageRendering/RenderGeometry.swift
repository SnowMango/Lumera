import Foundation
import ImagingCore

/// Coordinates follow texture rows. The Core Image adapter maps texture row zero to CI y=0.
struct RenderGeometry {
    let fullWidth: Int, fullHeight: Int, originX: Int, originY: Int
    let sourceWidth: Int, sourceHeight: Int, sourceX: Int, sourceY: Int
    let width: Int, height: Int

    init(fullWidth: Int, fullHeight: Int, area: CGRect, sourceWidth: Int, sourceHeight: Int, sourceArea: CGRect) {
        self.fullWidth = fullWidth; self.fullHeight = fullHeight
        originX = Int(area.minX); originY = Int(area.minY)
        width = Int(area.width); height = Int(area.height)
        self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        sourceX = Int(sourceArea.minX); sourceY = Int(sourceArea.minY)
    }

    func opticalGrid(_ resolution: EffectResolution) -> OpticalGrid {
        let divisor = resolution.rawValue
        let columns = (fullWidth + divisor - 1) / divisor
        let rows = (fullHeight + divisor - 1) / divisor
        let startX = originX * columns / fullWidth, startY = originY * rows / fullHeight
        let endX = ((originX + width) * columns + fullWidth - 1) / fullWidth
        let endY = ((originY + height) * rows + fullHeight - 1) / fullHeight
        return OpticalGrid(width: endX - startX, height: endY - startY, x: startX, y: startY,
            scaleX: Double(columns) / Double(fullWidth), scaleY: Double(rows) / Double(fullHeight))
    }
}

struct OpticalGrid {
    let width: Int, height: Int, x: Int, y: Int
    let scaleX: Double, scaleY: Double
}
