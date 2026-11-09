# Lumera

Lumera 是基于 Metal 的相机成片质感处理库，提供颜色变换、色调曲线、细节、柔化、暗角、光晕、数码噪点和胶片颗粒处理。风格参数、拍摄条件响应、设备校正与 LUT 资源分别管理。

## 环境要求

- Swift 5.10 或更高版本。
- iOS 17 或 macOS 14 及以上版本。
- GPU 渲染需要支持 Metal 的设备。

## 模块

| 产品 | 职责 |
| --- | --- |
| `ImagingCore` | 纯风格/相机模型、输入声明、编译求值、编辑与时间状态 |
| `ImageRendering` | 输入准备、完整输入统计、资源预算与共享 Metal 效果执行 |
| `ImagingRuntime` | 可选照片/视频协调、背压与决策回放；只依赖 Core 和 Rendering |
| `ImageAnalysis` | 桌面照片编解码、参考渲染、图像测量和风格生成分析 |
| `ccdlab` | 离线命令行工具；对应目标为 `ImagingCLI` |

实时相机接入使用 `ImagingCore` 与 `ImageRendering`，自动照片/视频可增加 `ImagingRuntime`。相机采集、显示、文件管理和交互界面由宿主应用实现。

### Swift Package Manager 接入

在 Xcode 中选择 **File → Add Package Dependencies…**，输入仓库地址：

```text
https://github.com/SnowMango/Lumera.git
```

`v0.2.2` 标签发布后，依赖规则选择 **Up to Next Major Version**，最低版本填写 `0.2.2`。添加到应用目标时，选择 `ImagingCore` 和 `ImageRendering` 产品；在代码中分别使用 `import ImagingCore` 和 `import ImageRendering`，无需 `import Lumera`。

如果宿主项目使用 `Package.swift`，在包的 `dependencies` 中声明仓库，并在目标的 `dependencies` 中添加产品：

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MyCameraFeature",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MyCameraFeature", targets: ["MyCameraFeature"])
    ],
    dependencies: [
        .package(url: "https://github.com/SnowMango/Lumera.git", from: "0.2.2")
    ],
    targets: [
        .target(
            name: "MyCameraFeature",
            dependencies: [
                .product(name: "ImagingCore", package: "Lumera"),
                .product(name: "ImageRendering", package: "Lumera")
            ]
        )
    ]
)
```

## 相机模型与自动成片

开发分支新增 `CameraModel` schema 1；原 `Profile` schema 8 和固定风格入口保留。相机模型描述一个明确的机型、模式及设置组合，包含基础外观、条件响应、编辑权限和时间策略。人工制作模型、结构有效模型和经独立实拍验证的模型是不同状态；演示预设没有具体机型资格。

| 层次 | 职责与边界 |
| --- | --- |
| 离线制作：`ImageAnalysis`、CLI | 固定采样项目和输入参考；矩阵、32 点单调曲线及可选残差 LUT 的前向拟合；条件/时间响应拟合；视觉修订、构建和分项验证 |
| 纯决策：`ImagingCore` | 编译条件表、求值、缺测处理、自动参数时间适应、用户编辑与锁定；无图像解码或 GPU；决策算法不访问文件 |
| 像素执行：`ImageRendering` | 输入准备与独立校正、完整输入统计、预算和资源准备、唯一效果流水线、两档浮点存储及拥有型输出 |
| 可选协调：`ImagingRuntime` | `PhotoProcessor` 串接照片阶段；`CameraSession` 管理视频顺序、背压、取消、重置及回放记录；不包含新的图像算法 |

宿主负责采集、曝光/白平衡控制、显示、视频编码、文件存储和界面。运行应用只需链接 Core、Rendering，并可选择 Runtime；不会链接离线拟合器。HDR 显示/编码仍由宿主完成。

### 输入、照片与视频

`InputAdapter.prepare` 将带明确 `SourceDescriptor`、`InputRecipe` 的 `SourceImage` 转成拥有型 `NormalizedInput`；`InputNormalizer.normalize` 只接受该未校正类型，输出 `PreparedInput`。配方、工作参考、校正内容和源路径分别绑定身份，不能将 HEIF、JPEG、RAW、ProRAW 与实时 YUV 的验证结果相互套用。

- JPEG/HEIF 由调用方解码为正确标记的 CIImage，配方明确选择基础图或系统 gain-map 重建；不自建 gain-map 算法。实时 YUV 使用原始 CVPixelBuffer 颜色附件。
- RAW 默认值由制作者提供，只有明确许可的参数可由用户覆盖；实际后端不支持的控制报错。有效配方记录系统/解码器与实际设置，变化后重新匹配证据。不增加 Lumera 自有降噪。
- 输入校正与目标外观独立。无独立参考时可显式采用未验证的恒等参考，不能称为相机标定或逆 ISP。

```swift
import ImagingCore
import ImageRendering
import ImagingRuntime

let compiled = try CameraModelCompiler.compile(CameraModelCodec.decode(modelData))
let renderer = try LumeraRenderer() // 默认 RGBA16Float；可显式 .float32
let prepared = try ModelPreparer(renderer: renderer).prepare(
    compiled, resources: styleResources, execution: execution)
let photos = try PhotoProcessor(renderer: renderer, working: workingReference,
                                inputResources: calibrationResources)
let result = try await photos.process(source, descriptor: sourceDescriptor,
    recipe: inputRecipe, calibration: inputCalibration, model: prepared,
    edits: EditRequest(), stamp: originalStamp)
// result.frame.image 是完成后的拥有型输出；snapshot 保存完整输入的决策。
let edited = try await photos.render(result.snapshot, edits: userEdits,
                                    region: viewport, execution: execution)
```

`ExecutionProfile` 的输出尺寸、内存预算和最多在途帧数由宿主明确提供。照片区域、分块和导出复用完整输入统计和自动决策；真正裁剪或更换拍摄输入时重新 `process`。从 Float16 预览切换到 Float32 导出会重新读取/显影快照持有的原始源，不能通过提升半精度纹理恢复丢失精度。源 CIImage/CVPixelBuffer 在快照存活期间必须保持不可变；外部 RAW 文件会重新校验字节摘要。重复导出和不同执行精度共用模型预算；更换预算须建立新任务。

`CameraSession.enqueue(preparedInput, stamp:edits:)` 接收已准备好的完整输入。宿主保留采集序号和 PTS，丢帧不重新编号。会话内部按源顺序逐帧提交，自动适应先于用户编辑；`.wait` 有界等待，`.dropUnsubmitted` 只替换尚未提交的帧。过多同时等待的生产者明确报错，宿主应等待 admission 形成背压。输入准备、宿主采集队列和独立旧入口各自需要预算，模型预算不是整个进程 RSS 上限。

同帧模式等待本帧统计；声明的延迟模式使用同一个旧观测包，并按年龄、曝光/色温等事实变化整包校验。失效时进入模型声明的缺测策略，不能拼接旧特征和新元数据。当前完整统计和效果可共享命令缓冲区。延迟模式可能错过尚未发现的场景突变，宿主可通过 `reset(.reset(.sceneCut))` 明确通知。

取消在真实提交边界前生效；已提交帧不会回滚数学历史。GPU 失败、seek 或源变化需要重置，旧代次完成回调不会覆盖新输出。自动回放使用 `DecisionRecord` 和 `DecisionReplay`；最终参数冻结使用 `FrameDecision`。会话记录是有界环，宿主应及时 `takeRecords()` 并检查 `discardedRecordCount`；提交记录不等同于成功成片。解锁同时改变强度、非零视觉偏移或同目标 override 目前明确不支持，需分开提交；没有默默近似该组合。

### 制作、发布与证据

C1 项目按场景/序列分离 train、tune 和 acceptance，保存文件字节摘要、配对、对齐、排除区域、来源配方和实际条件。输入校准只对独立参考拟合；目标拟合固定曝光/WB，先生成矩阵与单调曲线，再由调参集决定是否需要残差 LUT。已有 LUT 始终前向参与，不求逆。合成数据的低误差只验证实现，不能授予真实机型资格。

`ModelBuilder` 是唯一发布构建器；包包含模型 JSON、资源内容、输入配方/校正和身份清单，不包含源照片。制作者通过显式基础外观或响应锚点修订复用 `EditResolver` 的视觉映射，记录幅度、理由和父包摘要；用户 session edits 不自动写回发布包。每次修改都产生新身份并重新验证。

`ModelValidator` 使用独立 acceptance 图像执行完整共享流水线，按真实输出坐标应用对齐和排除区。报告分别记录颜色/明暗、纹理、条件、时间、精度、性能；未测项目为 `insufficient`，不能用单一平均色差覆盖所有项目。报告绑定包、资源、输入项目、配方、目标解码、算法和执行精度；更改样本、模型、阈值或精度后旧报告失效。摘要检测内容变化，不是来源真实性的数字签名。默认开发证据，即使数值通过也不授予实拍资格。

CLI 的 `--settings` JSON 显式提供模型、执行预算、资源文件映射和目标输入配方；拟合时还须选择 `provided`、`identityReference` 或 `fitReference` 输入参考模式。相对资源路径以 settings 文件目录为基准。

```sh
ccdlab camera-model build --project project.json --settings settings.json --output candidate.json
ccdlab camera-model fit --project project.json --settings settings.json --output fitted.json --fit-report fit-report.json
ccdlab camera-model fit --project project.json --settings settings.json --condition-design conditions.json --output conditional.json --fit-report condition-report.json
ccdlab camera-model validate --project project.json --settings settings.json --model fitted.json --output validation.json
ccdlab camera-model replay --model fitted.json --records decisions.json --output replay.json
```

`--condition-design` 对应 `ConditionFitDesign`，显式列出候选条件轴、受控条件和源/目标条件配对；当前自动拟合最多两条 source/target 元数据条件轴，要求足够的独立样本和受控变量；特征驱动响应可手工定义，尚未纳入自动拟合。条件拟合不读取 acceptance 像素。时间拟合通过 `TemporalResponseFitter` API 接收带实际时间戳、采集延迟及不确定度的序列，CLI 回放本身不执行时间拟合。已有文件须显式 `--force`，输入文件不能作为输出覆盖。

Float16 是默认存储格式，着色器计算仍使用 Float32；可显式选择 Float32 存储。合成 HDR 颜色测试测得两者最大通道差约 0.00675（扩展 sRGB 编码输出约 4.24），超过该测试原定质量参考；独立舍入分析能解释误差，但不代表无损或真实相机质量达标。高光精度要求严格的交付应单独验收两档精度。

`DeliverySpecification` 明确设备/系统、输入路径、照片或视频规格、帧率、动态范围、精度、延迟、持续时长、内存和丢帧门槛。`AcceptanceRun` 检查宿主提供的分阶段计时、持续吞吐、端到端延迟、内存与温升记录。当前没有实拍目标包或 iPhone 15 交付性能结论；桌面精度/回归测试不能代替这些验收。

本次不包含 LUT 逆变换、光谱/胶片化学模拟、镜头物理模拟、新增空间/时域降噪、语义识别、局部色调映射、跨风格渐变、HDR 标定或新的高光/色域算法。Glow 仍是唯一 Bloom 类模块。已有 EDR 支持与 SDR 自动拟合保持各自边界。

## 数据模型

| 类型 | 用途 |
| --- | --- |
| `Profile` | 可序列化风格定义，包含基础参数、条件响应和时间策略 |
| `CompiledStyleDefinition` | 经校验并编译的风格定义，用于连续帧处理 |
| `EvaluatedStyle` | 根据拍摄条件与临时调整计算出的有效参数及诊断信息 |
| `ResolvedStyle` | 最终参数的不可变快照，用于固定参数渲染 |
| `DeviceCorrection` | 独立的设备白点与矩阵校正 |
| `LUTAsset` | 独立 LUT 内容、描述和摘要 |
| `CaptureConditions` | ISO、曝光时间、曝光补偿、色温与色调等拍摄条件 |
| `RenderRequest` | 输入声明、整体尺寸策略、效果处理比例与随机序列设置 |

`Profile.standard` 是中性起点。`StylePresets` 提供数码与胶片效果演示，不代表特定相机的标定结果。

配置 JSON 不包含 LUT 样本数据。`DeviceCorrection` 和 `RenderRequest` 也不属于风格配置。配置及资源的选择、存储和关联由调用方管理。

`ResolvedStyle.profileDigest` 标识来源配置的效果定义，`effectiveDigest` 标识按拍摄条件求值后的参数和时间策略。桌面报告的 `renderIdentity` 还包含算法修订、资源和渲染设置。成片缓存键应同时包含输入图像的摘要。

### 配置文件格式

Lumera 0.2.2 使用 Profile JSON schema 8。根对象必填 `schemaVersion`、`id` 和 `name`。`parameters` 缺省时使用中性参数，`responses` 缺省时使用空数组。以下是最小的固定配置。

```json
{
  "schemaVersion": 8,
  "id": "neutral",
  "name": "中性"
}
```

使用 `ProfileCodec.load(from:)` 从文件读取配置，或使用 `ProfileCodec.decode(_:)` 解码字节。`ProfileCodec.encode(_:)` 在输出中写入默认值。输入上限为 16 MiB，嵌套深度上限为 64 层。未知字段、重复键、`null` 和超出范围的参数会产生校验错误。

### 从 schema 7 升级

在仓库根目录构建 `ccdlab`，然后对指定文件运行预检。预检将逐字段变更报告写入标准输出，源文件保持原样。

```sh
swift build -c release --product ccdlab
python3 tools/upgrade_profile_v1_1.py --validator .build/release/ccdlab --input profile-v7.json
```

要生成 schema 8 配置，在同一命令末尾添加 `--apply --output-dir upgraded`。`upgraded` 必须是尚不存在的目录。每份输出都经过 `ccdlab check-profile` 校验。报告中标为 `needsReview` 的配置还需用样图复核颗粒或染色光晕的表现。

## 输入约定

`LumeraRenderer.render` 提供 `MTLTexture`、`CIImage`、`CVPixelBuffer` 同类型输入输出，以及 RAW／ProRAW 文件和数据输入。原有 `TextureEffectEncoder` 接口继续保留。

下表是底层纹理入口的输入约定：调用方通过 `InputDescriptor` 声明输入属性；高层图像入口由内部适配层完成标准化。

| 属性 | 要求 |
| --- | --- |
| 纹理类型 | `.type2D` |
| 像素格式 | `.rgba8Unorm`、`.bgra8Unorm`、`.rgba16Float` 或 `.rgba32Float` |
| 色度与传递函数 | sRGB 色度、sRGB 编码值 |
| 动态范围 | 默认 SDR；`options.dynamicRange = .edr` 时为扩展范围，均为显示参考 |
| 透明度 | 不透明 |
| 方向 | 像素方向已标准化 |
| 尺寸 | 正整数，与 `InputDescriptor` 一致，存储大小计算不溢出 |

EDR 纹理必须使用 `.rgba16Float` 或 `.rgba32Float`，数值为扩展编码 sRGB（包含负值与大于 1 的值），参考白与 SDR 相同。Float16 裸纹理入口还须通过 `RenderOptions.inputValueBounds` / `RenderRequest.inputValueBounds` 声明可信的有限 RGB 范围；调用方负责范围与实际像素一致。未知范围请显式选择 Float32。SDR 裸纹理未声明范围时遵循有限 `0…1` 输入契约。

硬件 `_sRGB` 纹理格式不属于支持范围，以避免重复执行传递函数。`InputDescriptor` 是声明与校验信息，不执行颜色转换，也不会扫描整张纹理来验证像素内容。

使用裸纹理入口时，P3、HLG、PQ、Apple Log 等输入须由调用方先转换到上述约定。仅修改颜色空间标签不构成像素转换。

裸纹理的尺寸和分配受 Metal 设备能力与可用内存约束。大图的 `CIImage` 入口见下文「局部与分块输出」。

### 统一图像 API

```swift
import CoreImage
import CoreVideo
import ImageIO
import ImagingCore
import ImageRendering

let renderer = try LumeraRenderer()
let style = try renderer.prepare(Profile.standard)
var options = RenderOptions(maximumLongEdge: 2048, seed: 42, frameIndex: 0)
options.glowScale = .half

// CIImage → CIImage：GPU 执行完成后返回，输出拥有独立存储。
let styledImage = try await renderer.render(inputImage, style: style, options: options)

// CVPixelBuffer → CVPixelBuffer：默认输出 BGRA8、sRGB SDR、不透明。
let styledBuffer = try await renderer.render(inputBuffer, style: style, options: options)

// MTLTexture → MTLTexture：只编码，不提交或等待 command buffer。
// 必须在同一 command buffer 内使用或复制输出，再提交；完成后池化纹理可被复用。
let styledTexture = try renderer.render(
    inputTexture, style: style,
    inputDescriptor: InputDescriptor(width: inputTexture.width, height: inputTexture.height),
    options: options, commandBuffer: commandBuffer
)
```

三种入口共用 `RenderOptions`：动态范围、整体尺寸、效果比例、随机种子与帧序号均可配置。`prepareCorrection` 和 `correction:` 提供独立设备校正；固定风格可由 `Profile` 或 `ResolvedStyle` 准备。纹理入口还支持 `CompiledStyleDefinition` 和 `FrameStyleParameters` 动态帧参数。

高层图像入口将已标记的 SDR 颜色转换为 sRGB，透明区域合成到黑色背景，范围归一化到整数像素。未标记颜色的 RGB CVPixelBuffer 假定为 sRGB。CIImage 则遵循 Core Image 工作空间语义（此处为扩展线性 sRGB）；从编码像素创建 CIImage 时应附上实际颜色空间，不能靠补充 metadata 改变像素解释。CIImage 输出使用浮点 RGBA 存储（SDR/EDR 均默认 Float16，显式指定 `.float32` 使用 Float32；无法证明半精度安全的组合报错，不自动提升精度），默认 SDR 的 CVPixelBuffer 输出使用 8 位 BGRA，因此不保证保持输入像素格式或位深。支持 BGRA/ARGB、RGBA half/float 及 8/10 位双平面 YCbCr 输入；YCbCr 必须提供可解析的颜色附件。非全帧 clean aperture、非方形像素、隔行和原始传感器缓冲区需要先由调用方适配。

默认 `.sdr` 保留原有行为：在 iOS 18／macOS 15 及以上，已知 headroom 的 HDR 输入通过系统滤镜映射到 SDR；无法可靠判断的 HDR 输入会报错。超出 SDR 色域/范围的颜色在适配边界裁切。

#### EDR 输入与输出

```swift
var options = RenderOptions()
options.dynamicRange = .edr
let renderer = try LumeraRenderer(precision: .float32) // 非恒等 LUT 外推显式选择 Float32
let lut = try LUTImporter.load(url: lutURL) // 默认 automatic：EDR 外推，SDR 裁切
let style = try renderer.prepare(profile, lut: lut)
let output = try await renderer.render(inputImage, style: style, options: options)
```

EDR 模式跳过输入的 SDR 色调映射与颜色裁切，输出编码 **extended sRGB**。`CIImage` 与 `CVPixelBuffer` 使用所选 RGBA 浮点精度，默认 Float16，可显式选择 Float32；EDR PixelBuffer 分别采用 64RGBAHalf / 128RGBAFloat，附件标记实际颜色空间与位深。高层 Float16 入口先通过有界 Float32 临时纹理与 GPU 归约测量完整输入范围，再检查各中间存储阶段；该测量有额外成本，不代表效果被静默升为 Float32。区域/分块共用完整源范围。裸纹理仅在无需处理且输入格式匹配时直接返回输入。该模式不生成 HDR 细节、不调整曝光，也不以当前屏幕 headroom 裁切成片。非有限输入或浮点范围以外的数据不属于支持范围。

LUT 默认外推；色调曲线在 `0…1` 内保持原样，在两端以单位斜率延伸端点偏移，保留扩展高光的亮度差异。噪声和颗粒的亮度权重仍限制在曲线定义范围，最终 RGB 不裁切。柔化、暗角与光晕仍在线性域执行。现有 EV 行为保持不变。

`renderRegion`、`renderTiled` 和动态纹理入口使用相同的 EDR 选项。RAW 入口在 EDR 模式下将 `extendedDynamicRangeAmount` 默认设为 `1`，调用方仍可通过 `configureRAW` 覆盖；实际高光恢复取决于系统解码器与源文件。

输出内容 headroom 在风格处理后未知，不复制输入的亮度统计或 HDR mastering 元数据。显示端负责转换到需要的线性显示空间、启用 EDR 和适配屏幕；视频编码端负责转成目标 PQ/HLG/YCbCr 格式及生成相应元数据。本接口返回像素数据，不是 HDR 文件/视频编码器。

`ImageAnalysis.MetalRenderer` 及离线标定流程仍是 SDR 契约，显式 EDR 请求会报错；应用的 EDR 处理使用 `LumeraRenderer` / `TextureEffectEncoder`。旧的序列化选项和请求没有 `dynamicRange` 字段时按 `.sdr` 解码。

### 局部与分块输出（CIImage）

`renderRegion` 用于可见区域预览，`renderTiled` 用于完整照片导出。

```swift
let crop = try await renderer.renderRegion(inputImage, region: visiblePixelRect, style: style)
let photo = try await renderer.renderTiled(inputImage, style: style, workingMemoryLimit: 128 * 1024 * 1024)
```

`visiblePixelRect` 使用方向归一并应用 `maximumLongEdge` 后的完整画面坐标，须为画面内的整数像素矩形。返回图像的原点为零。两种入口都用完整画面坐标计算颗粒、暗角和光晕，设备校正在整体缩放前执行。

`renderTiled` 的默认 GPU 临时工作预算为 128 MiB。最小分块连同滤波所需的周边像素仍超出预算时，调用会报错。源图、解码器、常驻资源和最终的 CPU 位图另计。

### RAW／Apple ProRAW

```swift
// 内部显影：系统默认拍摄白平衡、完整质量、SDR。
let developed = try await renderer.render(rawURL: rawURL, style: style, options: options)

// 同样支持完整 RAW/DNG 文件 Data；闭包在输出求值前执行，可配置 CIRAWFilter。
let configured = try await renderer.render(
    rawData: rawData, style: style, options: options,
    configureRAW: { filter in
        filter.exposure = 0.5
        filter.neutralTemperature = 5200
    }
)

// 外部显影：Lumera 不重复显影。补充源 metadata，并声明像素已由 RAW 显影器旋正。
guard let filter = CIRAWFilter(imageURL: rawURL),
      let image = filter.outputImage else { throw LabError.unsupported("无法显影 RAW") }
let externallyDeveloped = try await renderer.render(
    image, metadata: filter.properties as? [String: Any], orientation: .up,
    style: style, options: options
)
```

RAW／ProRAW 兼容性取决于系统解码器；不使用内嵌预览作为失败回退。输出是显影后的 CIImage，不是保留 RAW 可编辑能力的 DNG；需另外保存原始文件。`configureRAW` 为本次调用独占配置闭包，不要保留并并发修改 filter。曝光等显影修改不覆盖原始拍摄 EXIF。

### 图像与拍摄元数据

CIImage／CVPixelBuffer 入口自动维护已知元数据。保留支持的 EXIF 拍摄字段（ISO、快门、光圈、拍摄时间、白平衡模式、镜头等）、TIFF 相机/版权信息和 GPS；根据实际输出重写尺寸、方向和颜色。MakerNote、DNG 显影指令、旧缩略图、辅助图像、几何/标定附件及未知私有字段不透传。GPS 会保留，分享前如需去除定位信息应显式移除。

`metadata:` 是可选的 ImageIO 属性字典补充：同名拍摄字段以显式参数为准，未冲突的嵌套字段保留。它不决定输入方向，旧尺寸/颜色也不会覆盖输出事实。默认从图像属性或输入附件读取方向；如果像素已经旋正，传 `orientation: .up`，避免重复旋转。内部 RAW 路径自动处理这一点。

CVPixelBuffer 使用两种传播模式的附件解析输入几何和方向，只将可传播的拍摄字段带到输出；输出重建为 RGB 颜色附件，移除旧 YCbCr 矩阵和 HDR/ICC/gamma 描述。CMSampleBuffer 的时间信息由调用方单独管理。输入在异步调用结束前必须保持有效且不被修改。取消已提交任务时等待 GPU 安全结束再返回取消错误。

高层接口保证返回时的像素和支持的 metadata 一致；后续裁剪、旋转、色彩转换由后续处理步骤更新 metadata。图像编码器需要显式写入返回的 CIImage properties，才会将其保存到文件。裸纹理入口不携带 metadata，需要调用者独立管理。

需要按拍摄条件评估风格时，仍独立提供 `CaptureConditions`；metadata 保留不等于自动执行条件响应。未知拍摄条件保持为空。

## 固定参数渲染

创建渲染器并准备风格后，可复用准备结果处理多帧。以下封装接收调用方创建的设备、输入纹理和 command buffer：

```swift
import Metal
import ImagingCore
import ImageRendering

final class StyleRenderer {
    private let encoder: TextureEffectEncoder
    private let style: PreparedCameraStyle

    init(device: MTLDevice, profile: Profile, lut: LUTAsset? = nil) throws {
        encoder = try TextureEffectEncoder(device: device)
        let resolved = try ResolvedStyle(profile: profile)
        style = try encoder.prepare(resolved, lut: lut)
    }

    func encode(
        input: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let descriptor = InputDescriptor(width: input.width, height: input.height)
        let request = RenderRequest(input: descriptor)
        return try encoder.encode(
            input,
            style: style,
            request: request,
            commandBuffer: commandBuffer
        )
    }
}
```

`encode` 只编码 GPU 工作，不提交或等待 command buffer。调用方应在同一 command buffer 中消费输出，再提交执行。风格或 LUT 改变后重新准备对应资源。

固定参数入口使用最终参数快照。若要将动态风格固定在某次拍摄条件下，调用 `try StyleEvaluator.freeze(profile, conditions: conditions)`，再准备返回的 `Profile`。若每帧都需要按 ISO、快门等条件改变效果，使用下面的动态帧入口。

## 动态帧与条件响应

初始化或切换风格时调用：

1. `StyleEvaluator.compile(profile)` 校验并编译定义。
2. `encoder.prepare(definition, lut: lut)` 准备静态 GPU 资源。

每帧调用 `StyleEvaluator.evaluate`，将结果包装为 `FrameStyleParameters` 后编码：

```swift
func encodeFrame(
    input: MTLTexture,
    encoder: TextureEffectEncoder,
    definition: CompiledStyleDefinition,
    prepared: PreparedStyleDefinition,
    conditions: CaptureConditions,
    request: RenderRequest,
    commandBuffer: MTLCommandBuffer
) throws -> MTLTexture {
    let evaluated = try StyleEvaluator.evaluate(definition, conditions: conditions)
    return try encoder.encode(
        input,
        style: prepared,
        parameters: FrameStyleParameters(evaluated),
        request: request,
        commandBuffer: commandBuffer
    )
}
```

`definition` 与 `prepared` 必须来自同一风格定义；身份不匹配会被拒绝。连续帧不需要重复解析配置、计算配置 JSON 摘要或上传 LUT。

条件响应规则：

- ISO 与曝光时间使用 `log2` 横轴，其余条件使用线性横轴。
- 域外输入夹持到曲线端点。
- 未知条件跳过对应响应，并通过 `EvaluatedStyle.diagnostics` 返回状态。
- 每个目标参数最多绑定一条条件响应。
- `CaptureConditions` 只描述拍摄条件，不会再次施加拍摄曝光或白平衡。
- 色温单位为 K；色调单位为 CIE 1960 uv 的 Duv，不接受厂商 tint 滑块值作为同义量。

`StyleEvaluator.evaluate(..., adjustments:)` 支持独立的 `StyleAdjustments`。手动设置风格曝光或单张照片的临时曝光时，有限数值自动限制在 −10 到 +10 EV。两者相加后的有效范围为 −20 到 +20 EV。导入 JSON 配置时，曝光和其他参数均须通过范围校验。可选白点覆盖对应白点设置；效果倍率按各参数范围处理，达到限制时通过 `adjustmentLimits` 返回信息。临时调整不写入 `Profile`。

## 处理顺序

可选设备校正阶段：

1. sRGB 解码。
2. 线性 Bradford 白点校正。
3. 线性 RGB 3×3 矩阵。
4. sRGB 编码。
5. 校正 LUT。

设备校正完成后应用 `maximumLongEdge` 整体缩放，再进入风格阶段：

1. sRGB 解码，执行曝光、Bradford 白点适应和线性 RGB 矩阵。
2. sRGB 编码，执行风格 LUT、色调曲线、亮度细节与锐化。
3. sRGB 解码，执行柔化、暗角、高光光晕和染色光晕。
4. sRGB 编码，执行数码噪点与胶片颗粒，按请求输出 SDR 或扩展范围图像。

中间颜色运算允许扩展范围；SDR 路径的 LUT 有限域和最终输出裁切不可逆。EDR 路径默认使用 LUT 外推并保留最终扩展值。白点校正使用 CIE xy，不等同于传感器原始通道增益。

### 设备校正

`DeviceCorrection` 包含 `whiteBalance` 和 `matrix`。通过 `encoder.prepareCorrection(correction, lut:)` 准备校正资源，再将结果传入 `encode` 的 `correction` 参数。

校正 LUT 与校正参数独立。设备识别、校正适用条件与配置选择由调用方负责。无有效校正时可省略校正阶段；精确恒等 LUT 仅在前置变换也恒等时可被省略，非恒等变换后的 LUT 仍具有有限域裁切作用。

### 色彩偏移

`parameters.color.shift.redGreen` 与 `yellowBlue` 的范围为 `-1...1`：

- `redGreen`：正值偏红，负值偏绿。
- `yellowBlue`：正值偏黄，负值偏蓝。
- 零值为中性。

线性 RGB 权重为 `[2r + y, -2r + y, -2y]`，减去最大权重后取 2 的幂得到通道增益。增益范围为 `1/32...1`，最大通道比例为 `32:1`。该模型采用通道衰减，强偏移会降低亮度。

偏移在风格白点与矩阵之后、LUT 之前生效，预先合入颜色矩阵，不增加独立 GPU pass，也不修改 `DeviceCorrection`。它是创意通道平衡，不是物理色温或 Duv 校正。

### 曲线

`ResponseCurve` 只保存一种表示：解析函数，或带插值方式的自定义节点。

| 项目 | 支持范围 |
| --- | --- |
| 函数 | 恒定、线性、幂函数、S 形、平滑阈值、钟形 |
| 函数指数 | `0.25...8` |
| 归一化中心 | `0...1` |
| 归一化宽度 | `0.05...1` |
| 节点数 | `2...32` |
| 节点插值 | 线性、保形平滑 |

图像响应横轴固定为 `0...1`，节点横轴的 Float 最小间距为 `1/1024`。色调曲线必须单调，不支持钟形。条件曲线的横轴范围由定义指定。

- `tone.curve`：编码 sRGB 各分量到输出值的映射。
- `noise.curve`：编码亮度到噪点 sigma 的映射；乘以 `noise.gain` 后上限为 `0.1`。
- `grain.luminanceCurve`：编码亮度到颗粒强度倍率的映射，输出范围为 `0...1`。

解析函数直接在 CPU/GPU 求值。`convertedToPoints(axis:)` 是显式的 32 点采样近似，返回平滑节点曲线；不会保留可逆的解析函数表示。编辑器可以自行选择合法的节点数与分布。

### 空间尺度与时间策略

空间参数以完整画面长边 2048 像素为基准。裁剪后的输入视为新的完整画面，分块沿用原画面坐标。

胶片颗粒按输出像素的覆盖面积采样。`grain.amount` 是参考尺度的亮度扰动 RMS，`grain.size` 是自相关降到一半的距离，`grain.roughness` 控制粗尺度成分的方差占比。缩小输出时，每个像素会平均更多颗粒细节。

染色光晕的 `halation.radius` 是扩散核的径向 RMS 半径。三个高斯尺度分别按像素积分并截断到 4σ，各通道的混合权重决定色晕的空间分布。柔化、细节和数码噪声的高斯核截断到 3σ，噪声模糊使用保方差权重。

`Profile.temporalPolicy` 分别控制数码噪点和胶片颗粒：`fixed` 忽略 `frameIndex`；`evolving` 结合 `seed` 与 `frameIndex` 产生可重放序列。默认数码噪点固定、胶片颗粒随帧变化。

## LUT 资源

LUT 的输入和输出约定均为编码 sRGB。`LUTAsset` 独立保存样本与摘要；`content` 可声明 `colorOnly`、`colorAndTone` 或 `unspecified`，该描述不执行颜色空间转换。

`LUTAsset.boundaryPolicy` 与颜色编码独立，支持：

- `.automatic`（默认）：SDR 请求裁切输入坐标，EDR 请求外推。
- `.clamp`：始终将查表坐标限制在 `0…1`，即使输出为 EDR。
- `.extrapolate`：在编码 sRGB 中延伸最近边界网格单元的三线性函数；面、边与角均使用这条规则。输出可以为负或大于 `1`，最终是否裁切由渲染动态范围决定。

外推并非原 LUT 作者定义的 HDR 效果，也不保证等同于 Apple 的外推算法；边界平坦的 LUT 仍可能输出平坦高光，多通道外推也可能放大边界变化。它不是 shaper，本版不支持 shaper 或扩展域 cube 导入。普通 LUT 样本和文件格式仍为原有 `0…1` 约定。

非恒等 LUT 外推（包括 SDR 输出请求）目前拒绝 Float16；调用方须显式选择 Float32。恒等外推与显式 clamp LUT 仍经过逐阶段范围检查。修改越界策略后重新准备资源。源文件/样本摘要保持不变，渲染身份与准备缓存另行区分策略；SDR 默认身份不因新增可选设置而改变。风格 LUT 与设备校正 LUT 均可独立选择策略。

LUT 由调用方加载和管理。需要记录外部资源关联时，分别声明风格 LUT、设备校正与校正 LUT 的 `ResourceReferences`，并用 `RenderResources.validate(against:correction:)` 核对实际资源。

### 原始数值数据

```swift
func importCube(_ data: Data, dimension: Int) throws -> LUTAsset {
    try LUTImporter.load(
        data: data,
        descriptor: LUTDataDescriptor(
            dimension: dimension,
            layout: .rgbaFloat32,
            order: .redFastest
        ),
        name: "Example"
    )
}
```

`LUTDataDescriptor` 要求紧密排列、当前平台字节序的 Float32 数据：

| 字段 | 约束 |
| --- | --- |
| `dimension` | 立方体边长，`2...128` |
| `layout` | `.rgbFloat32` 或 `.rgbaFloat32`；RGB 补 Alpha=1，RGBA 要求 Alpha=1 |
| `order` | `.redFastest`：R 最快、G 次之、B 最慢；或 `.blueFastest`：B 最快、G 次之、R 最慢 |
| 长度 | 精确等于 `dimension³ × 通道数 × 4` 字节 |
| 样本 | 有限数，范围 `0...1` |

128³ RGBA Float32 数据占用 32 MiB。原始数组入口不适用文件入口的 16 MB 限制。

CIColorCube 与 CIColorCubeWithColorSpace 的 cube 数组布局对应 `.rgbaFloat32 + .redFastest`。布局兼容不代表颜色语义相同：接口不接受颜色空间参数，调用方必须确保样本符合编码 sRGB 约定。

原始数组保留为数值样本，不转换为文本；此类资源的 `cubeText` 为空。使用 `validate()` 校验资源，不以 `cubeText` 是否为空判断有效性。资源改名不改变内容摘要。

### 文件与文件字节

支持 `.cube` 文件，以及 512×512、8×8 平铺布局的 PNG LUT。文件入口上限为 16 MB。

- URL：`LUTImporter.load(url)`。
- Cube 文件字节：`LUTImporter.load(data: bytes, format: .cube, name: name)`。
- PNG 文件字节：`LUTImporter.load(data: bytes, format: .tiledPNG, name: name)`。

文件字节入口与原始 RGB/RGBA 数组入口是不同接口。导入、校验和 GPU 准备应在帧循环之外完成。

## 渲染请求与处理分辨率

| 字段 | 默认值 | 含义 |
| --- | --- | --- |
| `dynamicRange` | `.sdr` | `.edr` 保留扩展输入输出；不自动推测范围 |
| `maximumLongEdge` | `nil` | 可选整体缩放；正整数，不放大输入 |
| `previewGlow` | `true` | 为 `false` 时跳过高光光晕和染色光晕，不影响柔化 |
| `glowScale` | `.full` | 高光光晕中间层的每轴比例 |
| `halationScale` | `.full` | 染色光晕中间层的每轴比例 |
| `softeningScale` | `.full` | 柔化中间层的每轴比例 |
| `seed` | `42` | 随机序列种子 |
| `frameIndex` | `0` | 帧序号，配合时间策略使用 |

三个效果比例独立设置，公开枚举 `EffectResolution` 支持 `.full`、`.half`、`.quarter`、`.eighth`、`.sixteenth`，对应每轴 `1`、`1/2`、`1/4`、`1/8`、`1/16`。

```swift
func makePreviewRequest(input: InputDescriptor) -> RenderRequest {
    var request = RenderRequest(input: input, maximumLongEdge: 1280)
    request.glowScale = .eighth
    request.halationScale = .quarter
    request.softeningScale = .half
    return request
}

func makePhotoRequest(input: InputDescriptor) -> RenderRequest {
    RenderRequest(input: input)
}
```

处理比例以整体缩放后的画面为基准，只改变对应效果的中间层，不改变输出尺寸或效果启用状态。修改比例无需重新准备风格或 LUT。调用方应为每帧捕获独立的请求快照。

缩小采用线性 RGB 面积平均；两类光晕先提取高光再缩小。中间层尺寸每轴向上取整且至少保留一个像素，高斯 sigma 按实际缩后宽高分别换算。最终合成直接双线性采样低分辨率层，不读回像素，也不另建全尺寸放大层。

`1/8` 每轴比例对应约 `1/64` 的中间层像素数，不代表总渲染时间同比下降。缩小可能改变细亮源、柔化边缘或窄光晕，尤其在缩后 sigma 小于一个像素时。性能和视觉误差应在目标设备与素材上评估。

引擎不自动区分预览与拍照，也不在导出时恢复全尺寸。需要不同质量策略时，应分别创建请求。离线缓存将三个比例纳入缓存身份，渲染 manifest 记录实际选择。

## GPU 资源生命周期

- 输入纹理、准备后的风格、校正资源和 command buffer 必须属于同一 Metal 设备。
- command buffer 必须尚未 enqueue/commit，且 `retainedReferences = true`。
- 输出可能直接复用输入纹理，也可能使用引擎临时存储。应在同一 command buffer 中消费输出；需要跨帧保留时，将其复制到调用方拥有的纹理。
- 空闲 scratch 缓存最多保留两个 arena，合计不超过 256 MiB。该值不包括在途资源及调用方持有的准备资源，不是进程内存上限。
- `releaseCaches()` 释放空闲缓存，并阻止释放前的在途 arena 在完成后重新进入缓存；不提前释放正在执行的资源。
- SDR/EDR 默认使用 Float16 中间纹理；无法证明安全时明确报错。可在初始化时指定 `RenderingPrecision.float32`，不自动切换。不同精度路径不保证位级一致。
- 实时纹理路径不要求 CPU 像素读回。首次编译、资源分配与稳态帧处理应分别测量。

## 桌面图像处理

`ImageAnalysis` 提供以下入口：

| API | 用途 |
| --- | --- |
| `ImageCodec.load` | 文件解码、系统颜色管理、方向和背景标准化 |
| `MetalRenderer.render` | Float32 参考渲染，返回像素与 manifest |
| `MetalRenderer.renderPreview` | 返回独立持有的 BGRA8 GPU 预览纹理 |
| `ImageCodec.encodePhoto` | 8 位 RGB 成片编码 |
| `ImageCodec.encodeReference` | 16 位 RGB PNG 参考图编码 |

两种渲染入口均接受独立的 `correction` 与 `RenderResources`。RAW 导入保留原生整数尺寸，解码与资源预算由调用方控制。

桌面路径提取部分拍摄条件供计算使用，不提供完整源文件元数据的自动透传。需要保留其他元数据时，应由调用方独立管理。

风格生成分析提供受约束的定位、颜色、细节、纹理、光晕建议和条件响应分析。算法验证与目标相机实拍验证是不同的验收层级；自动生成资格取决于对应验证结果，不能仅凭 GPU 路径一致性判定相机匹配度。

## 错误、诊断与日志

无效参数、输入约定不符、设备不匹配及资源准备失败通过错误返回。调用方还应检查 command buffer 完成状态以处理 GPU 执行错误。

`EvaluatedStyle` 提供条件响应与调整限制诊断。桌面渲染 manifest 提供风格、校正和输入摘要、尺寸、输入假设与阶段耗时。

- `correctionSeconds` 是校正准备与 CPU 编码耗时，包含在 `inputPreparationSeconds` 中，不应重复累加。
- `gpuSeconds` 是整个 GPU command 的耗时，不代表某个效果的独立 GPU 耗时。
- 缓存统计反映引擎管理的资源估算，不等于进程总内存。

库不管理日志文件、应用目录或进程监控定时器。日志存储、轮转及系统日志输出由宿主应用或命令行工具负责。

## 构建与测试

在包目录执行：

```sh
swift build -c release
swift test -c release
```

运行特定测试组可使用 `--filter`：

```sh
swift test -c release --filter CurveFunctionTests
```

GPU 测试需要可用的 Metal 设备。测试结果用于验证参数约束、渲染行为与路径一致性，不代替目标设备的性能测量或相机风格匹配评估。
