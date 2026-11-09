import Foundation
import Metal
import CoreImage
import ObjectiveC
import ImagingCore

/// 已完成的独立帧输出，持有结果会继续占用与保留存储对应的预算。
public final class RenderedFrame: @unchecked Sendable {
    /// GPU 路径的独立纹理。分块静态图像导出使用独立的 CPU 像素存储。
    public let texture: MTLTexture?
    /// 分块输出在整帧输出坐标系中的区域。直接 GPU 帧为 nil。
    public let region: CGRect?
    public var width: Int { Int(image.extent.width) }
    public var height: Int { Int(image.extent.height) }
    public let stamp: FrameStamp?
    public let resourceDigest: String
    public let modelID: String
    public let inputID: String
    public let execution: ExecutionProfile
    /// 带输出色彩空间和更新后元数据的图像，像素范围由执行配置决定。
    public let image: CIImage
    /// 此已完成帧实际使用的控制。宿主可复制值用于诊断，不必保留帧纹理，
    /// 也不应为展示重新执行自动响应或推进时间状态。
    public var resolvedControls: ResolvedControls { plan.controls }
    private let plan: FrameRenderPlan
    init(texture: MTLTexture, input: PreparedInput, plan: FrameRenderPlan) {
        self.texture = texture; region = nil; modelID = plan.model.compiled.identity; inputID = input.inputID
        execution = plan.model.execution; self.plan = plan
        stamp = plan.stamp; resourceDigest = plan.model.resourceDigest
        let range: RenderDynamicRange = execution.dynamicRange == .edr ? .edr : .sdr
        var options: [CIImageOption: Any] = [.colorSpace: LumeraRenderer.colorSpace(for: range)]
        if #available(iOS 18, macOS 15, *), range == .edr { options[.contentHeadroom] = 0 }
        image = CIImage(mtlTexture: texture, options: options)!.settingProperties(LumeraImageMetadata.output(input.properties,
            width: texture.width, height: texture.height, depth: execution.precision == .float16 ? 16 : 32, dynamicRange: range))
        retainOutputLease(on: image, lease: plan.lease)
    }
    init(image: CIImage, input: PreparedInput, plan: FrameRenderPlan, region: CGRect) {
        texture = nil; self.region = region; stamp = plan.stamp; resourceDigest = plan.model.resourceDigest
        modelID = plan.model.compiled.identity; inputID = input.inputID; execution = plan.model.execution; self.plan = plan
        self.image = image.settingProperties(LumeraImageMetadata.output(input.properties, width: Int(region.width), height: Int(region.height),
            depth: execution.precision == .float16 ? 16 : 32, dynamicRange: execution.dynamicRange == .edr ? .edr : .sdr))
        retainOutputLease(on: self.image, lease: plan.lease)
    }

}

private var outputLeaseAssociation: UInt8 = 0
/// 图像或纹理可独立于包装对象存活，因此输出对象也持有预算租约。
func retainOutputLease(on object: AnyObject, lease: FrameBudgetLease) {
    objc_setAssociatedObject(object, &outputLeaseAssociation, lease, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}
