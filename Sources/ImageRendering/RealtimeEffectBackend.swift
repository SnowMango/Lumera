import Foundation
import Metal
import ImagingCore

/// 在单个命令缓冲区内调度效果，区域内核沿用整帧及光学网格坐标。
final class RealtimeEffectBackend: EffectPipelineBackend {
    let arena: Arena
    let pipelines:[String:MTLComputePipelineState]
    let commandBuffer:MTLCommandBuffer
    let geometry:RenderGeometry?
    let frameGeometry:RenderGeometry
    var grid:OpticalGrid?
    init(arena:Arena,pipelines:[String:MTLComputePipelineState],commandBuffer:MTLCommandBuffer,geometry:RenderGeometry?,frameGeometry:RenderGeometry) {
        self.arena=arena;self.pipelines=pipelines;self.commandBuffer=commandBuffer;self.geometry=geometry;self.frameGeometry=frameGeometry
    }
    var noise:EffectNoiseField<MTLTexture>? { get { arena.noise } set { arena.noise=newValue } }
    func texture(_ surface:MTLTexture)->MTLTexture { surface }
    func release(_ surface:MTLTexture) { arena.release(surface) }
    func clearNoise() { arena.clearNoise() }
    func opticalGeometry(_ resolution:EffectResolution,frame:RenderGeometry)->OpticalGrid {
        let value=frame.opticalGrid(resolution);grid=value;return value
    }
    func pass(_ name:String,_ source:MTLTexture,_ extras:[MTLTexture]=[],_ parameters:[Float]=[0],size:(Int,Int)?=nil,weights:MTLBuffer?=nil,lut:MTLTexture?=nil,lutTextures:[MTLTexture]=[]) throws -> MTLTexture {
            let result=try arena.take(width:size?.0 ?? source.width,height:size?.1 ?? source.height)
            let regionOptical = geometry != nil && (name == "opticalReduce" || name.hasSuffix("CombineReduced"))
            let regional = regionOptical || (geometry != nil && ["vignette", "randomField", "resizeLinear"].contains(name))
            let functionName = regional ? name + "Region" : name
            guard let state=pipelines[functionName],let encoder=commandBuffer.makeComputeCommandEncoder() else {throw LabError.io("无法创建 风格渲染 GPU 任务")}
            encoder.setComputePipelineState(state)
            encoder.setTexture(source,index:0);encoder.setTexture(result,index:1)
            for (i,texture) in extras.enumerated(){encoder.setTexture(texture,index:i+2)}
            if let lut { encoder.setTexture(lut,index:2) }
            for (i, texture) in lutTextures.enumerated() { encoder.setTexture(texture, index: i + 2) }
            parameters.withUnsafeBytes{encoder.setBytes($0.baseAddress!,length:$0.count,index:0)}
            if regional {
                let g = frameGeometry
                var values = [Float(g.originX), Float(g.originY), Float(g.fullWidth), Float(g.fullHeight)]
                if regionOptical, let grid {
                    values += [Float(grid.scaleX), Float(grid.scaleY), Float(grid.x), Float(grid.y),
                               Float((Double(g.fullWidth)*grid.scaleX).rounded()), Float((Double(g.fullHeight)*grid.scaleY).rounded())]
                } else if name == "resizeLinear" {
                    values += [Float(g.sourceWidth), Float(g.sourceHeight), Float(g.sourceX), Float(g.sourceY)]
                }
                values.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length:$0.count, index:2) }
            }
            if let weights {encoder.setBuffer(weights,offset:0,index:1)}
            encoder.dispatchThreads(MTLSize(width:result.width,height:result.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
            encoder.endEncoding();return result
        }
    func blur(_ source:MTLTexture,_ sigma:Double,noise:Bool=false,scaleX:Double=1,scaleY:Double=1,integrated:Bool=false) throws -> MTLTexture {
            func axis(_ input:MTLTexture,_ radius:Double,_ direction:Float) throws -> MTLTexture {
                if !integrated && radius<0.08{return input}
                let (kernel,weights)=try arena.kernel(sigma:Float(radius),noise:noise,integrated:integrated)
                return try pass("gaussianPrepared",input,[],[Float(kernel.radius),direction,kernel.denominator,noise ? 1:0],weights:weights)
            }
            let x=try axis(source,sigma*scaleX,0),y=try axis(x,sigma*scaleY,1)
            if x !== source && x !== y {arena.release(x)}
            return y
        }
}

    /// 一个编码任务独占其工作区，待命令完成后才可能进入空闲池。
    final class Arena: @unchecked Sendable {
        let device:MTLDevice
        var textures:[MTLTexture]=[]
        var busy=Set<ObjectIdentifier>()
        private var kernels:[UInt64:(PreparedGaussianKernel,MTLBuffer)]=[:]
        var kernelCount:Int {kernels.count}
        var kernelBytes:Int {kernels.values.reduce(0){$0+$1.1.length}}
        var noise:EffectNoiseField<MTLTexture>?
        var format:MTLPixelFormat = .rgba16Float
        private var configuration:[Int]=[]
        var byteCount:Int {textures.reduce(0){$0+$1.width*$1.height*(format == .rgba32Float ? 16:8)}}
        func configure(width:Int,height:Int,limit:Int?,format:MTLPixelFormat) {
            let key=[width,height,limit ?? 0,Int(format.rawValue)]
            if key != configuration {clearNoise();textures.removeAll();busy.removeAll();configuration=key}
            self.format=format
        }
        let workingSet: TileWorkingSet?
        init(device:MTLDevice, workingSet: TileWorkingSet? = nil){self.device=device; self.workingSet = workingSet}
        func take(width:Int,height:Int) throws -> MTLTexture {
            try TextureDimensions.validate(width:width,height:height,device:device)
            if let texture=textures.first(where:{$0.width==width && $0.height==height && !busy.contains(ObjectIdentifier($0))}) {
                busy.insert(ObjectIdentifier(texture));return texture
            }
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
            descriptor.storageMode = .shared;descriptor.usage=[.shaderRead,.shaderWrite]
            let estimate = workingSet == nil ? 0 : device.heapTextureSizeAndAlign(descriptor: descriptor).size
            try workingSet?.reserve(estimate)
            guard let texture=device.makeTexture(descriptor:descriptor) else {throw LabError.io("相机风格图像处理内存不足")}
            try workingSet?.reserve(max(0, texture.allocatedSize - estimate))
            textures.append(texture);busy.insert(ObjectIdentifier(texture));return texture
        }
        func kernel(sigma:Float,noise:Bool,integrated:Bool) throws -> (PreparedGaussianKernel,MTLBuffer) {
            let key=UInt64(sigma.bitPattern)*4+(integrated ? 2 : (noise ? 1 : 0))
            if let cached=kernels[key] {return cached}
            // Bound retained weights when the user continuously edits a style or dimensions change.
            if kernels.count>=32 {kernels.removeAll(keepingCapacity:true)}
            let value=try PreparedGaussianKernel(sigma:sigma,noise:noise,integrated:integrated)
            // 大半径权重可能超过 setBytes 的 4 KiB 上限，改用缓冲区绑定。
            let length = value.weights.count * MemoryLayout<Float>.stride
            let estimate = workingSet == nil ? 0 : device.heapBufferSizeAndAlign(length: length, options: .storageModeShared).size
            try workingSet?.reserve(estimate)
            guard let buffer=value.weights.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}) else {throw LabError.io("无法分配模糊权重")}
            try workingSet?.reserve(max(0, buffer.allocatedSize - estimate))
            kernels[key]=(value,buffer);return (value,buffer)
        }
        func release(_ texture:MTLTexture){busy.remove(ObjectIdentifier(texture))}
        func clearNoise(){
            if let noise {release(noise.luma);release(noise.chroma)}
            noise=nil
        }
        func reset(){
            busy.removeAll()
            // Cached fields remain reserved while other passes reuse the scratch textures.
            if let noise {busy.insert(ObjectIdentifier(noise.luma));busy.insert(ObjectIdentifier(noise.chroma))}
        }
    }
