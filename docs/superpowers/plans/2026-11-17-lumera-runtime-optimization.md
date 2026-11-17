# Lumera 参数范围与连续帧 CPU 优化 Implementation Plan

> **For agentic workers:** 使用 superpowers:executing-plans 按任务实施；每项独立验证。复选框按实际证据更新，未勾选项目不视为完成。

**Goal:** 在参数输入和修改位置提供范围处理，避免执行阶段重复验证，并完成输入颜色、输入身份、静态准备和范围归约 Buffer 四项优化。

**Architecture:** 显式参数诊断保持可选；受控输入入口处理外部值，内部计算只处理实际变化值，渲染消费计算结果。静态准备扩展已有准备对象；每帧输入事实和资源租约独立绑定。范围归约 Buffer 接入现有预算和资源回收机制。

**Tech Stack:** Swift、ImagingCore、ImageRendering、ImagingRuntime、Metal、Core Image、XCTest、Metal System Trace。

**Spec:** 本文“需求与设计决定”“性能验收”是本计划的规格。参考 Gloe `docs/superpowers/plans/2026-11-17-lumera-static-render-preparation.md` 的历史证据，不采用其强制静态校验及校验凭据设计。

日期：2026-11-17。状态：Task 1–6 实施完成；受影响套件 483 项、0 失败、4 项缺少 RAW fixture 跳过；Task 7 按用户最新确认的“当前真机无明显劣化即可”完成普通 LumeraCapture 预览验收，已就绪。自动曝光测量宿主保持撤回。详细证据见 `docs/benchmarks/2026-11-17-runtime-optimization-results.md`。

## Global Constraints

- SDK 修改范围为 Lumera；全部真机验证统一使用 LumeraCapture，包括基线采集、参数成本单独验收、四项优化的阶段 A/B 及最终验收。LumeraCapture 仅调整验证所需的 SDK 引用、测试配置和测量支持，不改造无关功能。
- 参数范围处理允许合理成本，但不能明显增加稳定 CPU 开销或影响帧率、延迟。
- 不在求值、规划、渲染准备、编码和提交入口恢复整套参数验证；不引入 validated token、skipValidation 或运行时“已校验”状态查询。
- 参数处理不新增逐帧全量扫描、JSON 编码或锁。缓存和资源池复用现有锁原语，不持锁执行重计算或等待 GPU。
- 当前像素范围测量、EDR/Float16 数值处理、设备绑定、命令状态、预算、取消和输出生命周期保持原有语义。这些工作不承担风格参数范围诊断。
- 不新增依赖、不自动提交、推送、发布或修改历史版本说明。保留已有未提交修改。
- 只增加能验证行为、错误传播或所有权的测试；性能不使用单元测试墙钟断言。
- 参数范围调整单独验收，四项优化分别对比，不能用优化收益掩盖范围处理的性能退化。

## 需求与设计决定

### 1. 参数范围处理的位置

| 数据 | 处理位置与频率 | 后续行为 |
| --- | --- | --- |
| 外部基础参数 | 创建、导入或明确更新时 | 原样交给后续计算，不重新全量扫描 |
| 交互标量 | 发生编辑时，仅处理改变字段 | 允许有限值限幅，并返回调整诊断 |
| 白点、矩阵、曲线、权重 | 整组替换时 | 成功后一次发布，失败保留原值 |
| 响应定义、适配策略及固定编辑定义 | 显式配置输入时 | 编译派生数据；每帧不重复诊断固定规则 |
| 动态结果 | 产生该结果的计算中 | 必要的限幅融合到计算；不再调用外部输入验证方法 |
| 固定参数执行 | 不做参数范围验证 | 直接使用当前配置及准备结果 |

`StyleParameters.validate`、`Profile.validate`、`StyleModelCompiler.validate` 等完整诊断继续可选。增加显式受控输入方法，不在普通编解码或执行入口暗中调用它们。

兼容策略：本阶段保留现有公开可写值类型和原始编解码接口。受控入口保证其返回时的参数符合对应规则；调用方随后直接修改 `public var` 可以绕过该保证，执行层不为此补查。彻底禁止自由赋值属于源码兼容性改造，不纳入此次性能优化。

比较过的路径：只保留全量 validate 无法覆盖修改时的范围处理；给全部属性增加 didSet 会把内部计算也接入重复检查，且白点/曲线受赋值顺序影响；将全部类型改成私有存储的强类型值影响现有调用面。此次采用显式受控更新、内部计算直接写入的兼容方案。

### 2. 范围与错误语义

- 标量声明范围及有效范围以 `ParameterDescriptor` / `ParameterSpecification` 为唯一来源，禁止在新入口另抄一份常量表。基础曝光为 −10…10 EV，计算后的风格曝光使用既有 −20…20 EV。
- 严格输入遇到越界值返回带字段路径的错误；交互入口只对有限标量限幅。NaN、无穷大均返回错误，不替换为默认值。
- 矩阵、白点、曲线、权重整组处理。交互限幅不自动重排曲线、不修复矩阵长度、不静默归一化任意权重；这些数据不符合声明时拒绝整次更新。
- 颗粒 roughness 的 0…1 属于混合比例语义。矩阵 −4…4 等现有创作范围用于显式严格输入及诊断，不扩散成执行限制。
- detail/glow 的半径顺序作为现有完整诊断规则保留；普通字段更新不连带修改另一个未编辑半径。实际分块已使用实际半径计算支持区域。
- 白点 xy 整组验证 x>0、y>0、x+y<1；两个分量同时更新时按最终组合处理，失败不写入任何分量。
- 关闭的效果不会因为执行阶段扫描其未使用参数而失败。调用方主动要求完整输入诊断时，可以检查关闭效果的配置。

### 3. 缓存与资源边界

- 输入身份采用与现有编码相容的字段比较：字符串比较 UTF-8 内容，Double 比较位模式，数组保留顺序，可选项保留 nil 区别。缓存命中不生成 JSON；失配沿用现有摘要算法，保持持久身份兼容。
- 静态准备保存实际派生结果，不保存校验状态。复用现有 `PreparedExecutionPlan` 的颜色、曲线、颗粒、光晕数据，不重建同类缓存。
- 静态配置按实际解析参数、权重、输入编辑、输入格式/几何、执行尺寸/比例、精度/动态范围和设备匹配。seed、时间戳和当前像素范围不进入静态键。
- `FrameRenderPlan`、当前输入、预算 lease、workingSet、claim、输出和观测不能跨帧复用。命中静态配置后仍使用当前帧范围进行实际精度运算。
- Buffer 按当前归约层需要逐个获取，区分 private/shared 存储。优先精确长度复用，避免大容量缓存项超出当前工作集估算；不预取整套最大尺寸 Buffer。
- Buffer 驻留费用只在所有者账本中计一次；工作集仍计入当前实际使用的容量。空闲缓存同样占驻留预算，清理后释放费用。

## 已有工作与基线

当前工作区已移除正常流程中的整套强制参数诊断，尚未提交。本次计划基于该工作区，不恢复删除的调用。

上一轮相关本机回归：465 项，0 失败，4 项缺少 RAW fixture 跳过。日志 `/tmp/lumera-optional-validation-verification.log`。此结果不代表本计划已验证。

历史定位样本：iPhone 17 Pro、iOS 26.5.2、Gloe Debug、16 秒、480 呈现帧、3891 ms CPU 样本。颜色前缀准备约 42 ms，输入身份约 73 ms，规划约 136 ms，请求准备约 63 ms，范围 Buffer 分配约 41 ms。调用栈包含子调用，存在重叠，不能相加预测收益。上述 Gloe 数据仅作历史定位参考。真正对照基线须使用 LumeraCapture，从当前移除强制诊断的版本重新采集；不跨应用比较性能降幅。

## Review Focus

- 绕过受控入口的旧代码仍可直接运行；不能为保证范围而在 RenderPlanner/FrameEncoder 中偷偷补回扫描。Task 1、2 验证。
- 曝光基础域与有效域不同；编辑失败应原子回滚，白点组更新不能依赖赋值顺序。Task 1 验证。
- Unicode 等价字符串、正负零、RAW 后端/设置变化不能误命中旧输入身份。Task 4 验证。
- 静态命中时像素范围变亮、动态响应改变或模型切换，不能沿用旧范围、旧参数或旧 lease。Task 5 验证。
- GPU 完成但 CPU 尚未读回、任务取消或命令未提交，Buffer 都不能提前复用、永久泄漏或重复归还。Task 6 验证。

## 执行顺序

`Task 0 基线 → Task 1 参数输入 → Task 2 执行路径整理 → 参数成本单独验收 → Task 3 无效果颜色 → Task 4 输入身份 → Task 5 静态准备 → Task 6 Buffer 池 → Task 7 整体验收`

Task 3、4、6 在技术上独立；按上述顺序实施和测量便于归因。Task 5 依赖 Task 2 的参数边界和 Task 3 的颜色前缀行为。

### Task 0：冻结当前行为与测量基线

**Files:** 当前工作区 diff；新增 `docs/benchmarks/2026-11-17-runtime-optimization-results.md`。

**Interfaces:** 不修改 SDK API；产出后续各阶段使用的基线记录。

- [x] 记录当前 HEAD、未提交差异、构建配置及相关回归结果，避免把上一轮修改归入新优化。
- [x] 使用 LumeraCapture 接入当前本地 Lumera SDK，完成真机构建、签名安装与运行；固定 EDR、模型、输入尺寸、目标帧率与场景，核实实际运行的 SDK 路径和内容，避免误用远程已发布版本。记录原有依赖配置，验收后按交付约定恢复。
- [ ] 采集稳定固定参数、持续滑杆编辑、动态响应三类基线；分别记录初始化和配置切换阶段。
- [ ] 保存 trace、构建信息和测量脚本参数到结果文档。没有可用设备时明确记录真机验收未完成，继续独立代码任务，不以本机测试代替性能结论。

### Task 1：提供显式参数输入和原子更新

**Files:** 新增 `Sources/ImagingCore/ParameterInput.swift`、`Tests/ImagingCoreTests/ParameterInputTests.swift`；修改 `ParameterSpecification.swift`、`ProfileCodec.swift`、`StyleModelCodec.swift`、`README.md`。

**Interfaces（已实现）:**

```swift
public enum ParameterValueDomain { case base, effective }
public enum ParameterRangeBehavior { case reject, clamp }
public enum ParameterInput {
    public static func accept(_ parameters: StyleParameters,
        domain: ParameterValueDomain = .base) throws -> StyleParameters
    public static func update(_ changes: [ControlOverride],
        parameters: inout StyleParameters, lutWeights: inout [ResourceWeight],
        domain: ParameterValueDomain = .base,
        behavior: ParameterRangeBehavior = .reject) throws -> [ControlDiagnostic]
    public static func curve(_ value: ResponseCurve,
        kind: ImageResponseKind) throws -> ResponseCurve
    public static func adaptationPolicy(_ value: AdaptationPolicy) throws -> AdaptationPolicy
}
// ProfileCodec / StyleModelCodec 分别返回原有 Profile / StyleModel。
public static func decodeChecked(_ data: Data) throws -> Profile // ProfileCodec
public static func decodeChecked(_ data: Data) throws -> StyleModel // StyleModelCodec
```

`accept` 是明确选择的完整输入检查；`update` 只处理变化字段及其关联组，在副本上成功后提交。noise/grain 曲线使用 `curve(_:kind:)`，不为非可绑定字段扩张响应目标注册表。`decodeChecked` 使用现有完整诊断，普通 `decode` 保持结构解码。行为策略仅存在于输入 API，不传入执行层。

- [x] 增加 `testRejectAndClampUseDeclaredDomain`：grain.roughness=2 在 reject 下失败且旧值不变，在 clamp 下写入 1 并返回调整诊断；基础曝光 15 拒绝，有效域 15 接受。
- [x] 增加 `testNonfiniteAndGroupedUpdatesAreAtomic`：NaN/∞ 拒绝；白点两分量按最终组合检查；9 系数矩阵和 LUT 权重组更新中任一失败不产生部分写入。
- [x] 增加 `testChangedFieldDoesNotScanDisabledEffects`：关闭颗粒且旧 roughness=2，仅修改曝光成功；显式 accept 仍能报告旧颗粒错误。
- [x] 增加 `testCheckedDecodeIsExplicit`：原始 decode 保留诊断范围外的参数，decodeChecked 拒绝；不改变原有曝光属性处理语义。
- [x] 运行 `swift test --filter 'ParameterInputTests|OptionalParameterValidationTests|ProfileCodecTests|StyleModelContractTests'`，确认新增行为在实现前不成立，再实现上述接口。
- [x] 更新 README，说明输入策略、原子更新、兼容入口的保证范围；运行同一组测试至通过。

**交付:** 调用方可在参数产生处选择范围处理，执行入口不要求使用这些方法。

### Task 2：分离外部输入处理与内部计算写入

**Files:** `Sources/ImagingCore/StyleModelCompiler.swift`（ControlAccess/ControlInterpolation）、`StyleModelEvaluator.swift`、`StyleEvaluator.swift`、`AdaptationReducer.swift`、`EditResolver.swift`、`EditRequest.swift`；按实际调用涉及 `Sources/ImageRendering/PreparedGrain.swift`、`ColorTransform.swift`。测试扩展 `OptionalParameterValidationTests.swift`、`StyleModelEvaluationTests.swift`、`AdaptationReducerTests.swift`、`EditResolverTests.swift`、`Tests/ImageRenderingTests/ModelRenderPlanTests.swift`。

**Interfaces:** 使用 Task 1 的显式输入入口；新增模块内部 `ControlAccess.writeComputed(_:target:parameters:lutWeights:) throws`，参数类型与现有 apply 相同但不接受验证策略，不调用 ParameterSpecification.validate。它只完成目标分派、形状匹配及写入。原有公开 apply 可继续作为显式外部值处理接口，内部计算不调用它。

- [x] 列出执行调用链中剩余范围诊断，分别标注固定定义、外部变更、动态计算、当前资源/图像事实；在结果文档记录去向。
- [x] 增加 `testComputedWritesDoNotRevalidateUnchangedParameters` 与适配连续帧回归，覆盖未变参数、变化参数、history/lock 和最终像素结果。
- [x] 将内部求值、适配及编辑计算切换到 writeComputed；标量加法/倍率融合既有有效范围限幅，保持诊断与锁定优先级，不在结果生成后再全量检查。
- [x] 移除 AdaptationReducer 每帧对固定 policy 的重复诊断，以及 AdaptationPolicy.digest 内的隐式诊断；显式输入/validate 负责报告固定规则问题。摘要缓存只按规则修改失效。
- [x] ControlInterpolation 的矩阵/曲线输入与结果不重复执行创作范围诊断；保留实际插值所需的形状处理。内部历史不反复扫描同一控制值的声明范围。
- [x] 将 PreparedGrain 等位置的参数声明范围处理交给输入入口；计算过程中无法表示的结果仍按该功能的计算失败返回，不新增事后参数遍历。保留旧原始入口的明确计算错误，禁止引入数组越界或数值转换陷阱。
- [x] 运行 `swift test --filter 'ImagingCoreTests|ModelRenderPlanTests|PrecisionRegressionTests|FrameProcessingSessionTests'`。检查参数有效域、动态曲线、权重、锁定冲突与取消恢复结果。
- [ ] 对比 Task 0 与 Task 2，单独验收参数范围处理的性能；达到后文退化调查条件时先定位，不继续用后续优化抵消结果。

**交付:** 外部输入范围处理不出现在稳定执行调用栈；动态变化只支付生成该值的局部成本。

### Task 3：跳过无效果输入颜色准备

**Files:** `Sources/ImageRendering/PreparedDeviceCorrection.swift`；扩展 `Tests/ImageRenderingTests/ModelRenderPlanTests.swift`。

**Interfaces:** 保持 `PreparedDeviceCorrection.inputEdit(_:device:) throws -> PreparedDeviceCorrection?`，保持 RenderPlanner 公共签名。

- [ ] 增加 `testIdentityInputEditNeedsNoColorPreparation` 和切换测试：零曝光、相同源/目标白点返回 nil；非零曝光/WB 返回实际前缀；恢复默认后前缀消失，像素恢复基准。
- [x] 将 response.isActive 判断前移到 ColorTransform.prepare 之前。此处不增加范围检查，不改变显式 clamp LUT 的语义。
- [x] 运行 `swift test --filter 'ModelRenderPlanTests|ExecutionPlanTests|DeviceCorrectionRenderTests'`，核对实际筛选到的测试列表，不能把空匹配当作覆盖。
- [ ] 采样验证无输入编辑时 inputEdit 下不再出现 ColorTransform.prepare。记录有编辑和无编辑两种成本。

**交付:** 无效果前缀直接返回；非零编辑的结果保持一致。

### Task 4：消除输入身份命中前的 JSON 编码

**Files:** `Sources/ImageRendering/InputAdapter.swift`；扩展 `Tests/ImageRenderingTests/InputIdentityReuseTests.swift`、`InputRecipeTests.swift`。

**Interfaces:** 保持 `inputIdentity(descriptor:recipe:) throws -> PreparedInputIdentity`。IdentityKey 改为值字段快照，增加私有 `matches(descriptor:recipe:) -> Bool`；缓存保持单条。PreparedInputIdentity 与所有持久摘要算法不改。

- [x] 扩展既有 signed-zero/Unicode 测试，对 descriptor、declared recipe、有效 settings、backend/decoder version 的各身份字段逐项变更，与无缓存独立计算的摘要比较。
- [x] 保留纹理、像素范围、captureConditions 每帧更新的测试：身份复用不能复用图像或拍摄事实。
- [x] 实现字段比较：String.utf8.elementsEqual、Double.bitPattern、枚举/可选项/有序数组逐项比较；不使用整对象普通 Equatable 代替编码语义。
- [x] 命中直接返回缓存。失配计算 PreparedInputIdentity，成功后发布；失败不污染旧项。复用 identityLock，不在锁内执行 JSON 编码和摘要；并发失配允许有界的重复准备，每次返回对应输入的结果。
- [x] 运行 `swift test --filter 'InputIdentityReuseTests|InputRecipeTests|InputPreparationTests'`。
- [x] 采样稳定命中路径，确认 inputIdentity 不再调用 JSON.encode；核对总 CPU 和分配，避免字段比较制造新的 Data/字符串数组。

**交付:** 相同输入配置不再为判断命中而序列化；身份内容与旧算法一致。

### Task 5：复用静态渲染准备结果

**Files:** 新增 `Sources/ImageRendering/PreparedRenderConfiguration.swift`；修改 `PreparedStyleModel.swift`、`RenderPlanner.swift`、`FrameRenderPlan.swift`、`PreparedProcessingRequest.swift`、`ModelProcessingResources.swift`，按需扩展 `PreparedExecutionPlan.swift`。测试扩展 `ExecutionPlanTests.swift`、`ModelRenderPlanTests.swift`、`RenderResourceIdentityTests.swift`、`Tests/ImagingRuntimeTests/FrameProcessingSessionTests.swift`。

**Interfaces:** 新增内部不可变 `PreparedRenderConfiguration`，保存所选 style/LUT 混合、输入颜色前缀、资源形状和固定输出几何。由 `PreparedStyleModel.renderConfiguration(for controls: ResolvedControls, input: PreparedInput) throws -> PreparedRenderConfiguration` 获取；输入仅用于提取静态依赖，不被配置持有。FrameRenderPlan 增加内部配置引用，公共入口不变。

- [x] 增加连续帧行为测试：相同参数、不同输入像素和 stamp/seed，静态准备复用且图像/随机时序使用当前帧。
- [ ] 增加配置变更测试：曝光/WB、LUT 权重、曲线、空间尺度和效果开关逐项修改后，下一帧采用新结果；动态响应不能被“编辑未变”误判为静态。
- [x] 按设计中的完整静态依赖形成值键；每个 PreparedStyleModel 只保存当前配置。替换后旧在途计划可以继续持有旧配置，不无限保存历史键。
- [x] 使用现有缓存锁原语保护引用读写，命中只做短比较；重计算在锁外，失败不发布不完整配置。直接 RenderPlanner 调用及并发调用与会话使用同一语义。
- [x] 使用已有 PreparedExecutionPlan 取得派生数据；缓存 LUT 混合和输入前缀，PreparedProcessingRequest 复用静态 shape，重新绑定当前 request。不得复制旧 inputValueBounds。
- [x] 保持每帧独立 lease、workingSet、claim 和当前输入/设备绑定；不缓存当前帧精度判断结论。配置准备不调用参数范围诊断。
- [x] 运行 `swift test --filter 'ExecutionPlanTests|ModelRenderPlanTests|RenderResourceIdentityTests|PrecisionRegressionTests|FrameProcessingSessionTests'`，覆盖范围突变、并发、失败后恢复、取消及重复提交。
- [ ] 对比静态与动态两类模型的 CPU/分配，确认命中收益超过键比较和同步成本。动态持续失配时内存有界，不能明显退化。

**交付:** 静态派生结果跨帧复用，当前帧数据及资源所有权保持独立。

### Task 6：池化输入范围归约 Buffer

**Files:** 新增 `Sources/ImageRendering/ProcessingBufferStorage.swift`；修改 `ProcessingResources.swift`、`ProcessingResourceLedger.swift`、`InputRangeReadback.swift`、`HalfInputPreparation.swift`、`LumeraRenderer+Images.swift`、`InputNormalizer.swift`、`PhotoRegionSource.swift`、`RealtimeInputPreparer.swift`。测试扩展 `InputRangeReductionTests.swift`、`HalfInputPreparationTests.swift`、`ProcessingBudgetTests.swift`、`ProcessingLifetimeTests.swift`，新增 `InputRangeBufferPoolTests.swift`。

**Interfaces:** 新增内部 `ProcessingResources.acquireRangeBuffer(length: Int, options: MTLResourceOptions) throws -> ProcessingBufferLease`；lease 持有实际 buffer 与驻留 charge。InputRangeReducer 的 encode/encodeHalfPreparation 增加默认 nil 的内部 `resources: ProcessingResources?`，沿已有输入资源所有者传递。`InputNormalizer.normalize(..., bounded:)` 增加内部默认 nil 的 `processingResources: ProcessingResources?`，由 RealtimeInputPreparer 传入既有 inputResources；名称与 ModelResourceSet 参数区分。PhotoRegionSource 的范围测量传入其 prepare 已收到的 resources；HalfInputPreparation 传入其现有 owner。`measureInputRange` 增加内部默认 nil 的 resources 参数；没有跨调用所有者时维持独立分配，不另建无预算的 renderer 全局缓存。

- [x] 增加 `testWarmReductionReusesBuffers`：固定尺寸、相同存储模式、前次 GPU 与读回均完成后，实际分配数停止增长；范围结果与未池化路径一致。
- [x] 增加 `testCPUReadbackPinsResultBuffer`：GPU 完成但未 resolve 的结果不可复用；多个 ticket 和在途帧不共享可写存储。
- [x] 使用精确 length/options 取空闲项，缺少时按需分配；分配前预留账本费用，再按实际 allocatedSize 调整。接入现有 idleBytes、trim、close、策略收缩及代际回收。
- [x] 各中间层 lease 保留至 GPU 完成；最终 shared lease 同时由读回状态持有。InputRangeReadback 的可复制值包装共享一次解析状态，resolve 将 NumericBounds 或错误缓存，重复 resolve 不读取已回池内存。
- [x] 完成回调释放 GPU 使用权，读回完成或 ticket 放弃释放 CPU 使用权，二者结束后回池。GPU 失败、未提交命令销毁及部分编码失败都有释放路径，避免 command/lease 相互强持有。
- [x] 将已有持有 ProcessingResources 的 Half、PhotoRegionSource 范围测量和 RealtimeInputPreparer 校正调用接入；measureInputRange 按调用方实际提供的所有者决定是否复用。独立无池路径行为保持一致；结果文档列出仍无资源所有者的入口，不能宣称所有 makeBuffer 已消失。
- [ ] 添加尺寸切换、池满、预算收缩、取消、GPU 错误、未提交命令销毁、多块批次及重复 resolve 测试。复用容量仍计入 TileWorkingSet；跨所有者缓存不得绕过预算。
- [x] 运行 `swift test --filter 'InputRangeBufferPoolTests|InputRangeReductionTests|HalfInputPreparationTests|ProcessingBudgetTests|ProcessingLifetimeTests|InputTexturePoolTests'`。
- [ ] 对比预热后的 makeBuffer 次数、归约 CPU、驻留峰值和延迟；首次扩容单列。范围算法和线程调度形状保持不变。

**交付:** 支持资源池的输入路径按实际需要租用归约 Buffer，按 GPU/CPU 双重生命周期归还。

### Task 7：整体验收和文档交付

**Files:** `README.md`、本计划、Task 0 的性能结果文档；确有新公共 API 时补使用示例，不改写 v0.5.1 历史发布说明。

- [x] 执行受影响套件：`swift test --filter 'ImagingCoreTests|ImageRenderingTests|ImagingRuntimeTests|DesktopContractTests|GrainReferenceTests|GrainSamplingTests'`；记录实际数量与跳过原因，提供 RAW fixture 后补相应测试。
- [x] 执行 `git diff --check`，检查正常路径无整套参数诊断回流、无输入身份命中序列化、无旧帧范围复用。
- [ ] 依照下节使用 LumeraCapture 完成真机最终 A/B，记录阶段单项结果与整体结果。测试通过不等于性能通过。
- [ ] 文档说明参数输入保证边界、配置更新时机、Buffer 生命周期及未覆盖路径。逐项更新计划状态，不自动提交或推送。当前仓库忽略 docs 路径，发布或提交时按届时授权明确纳入文档，不能把本地文件存在当作已进入版本控制。

## 性能验收

“不明显影响性能”是验收目标。以下数值是实施用的建议调查门槛，不是已经测得的结果或固定降幅承诺。

1. 所有真机 A/B 均使用 LumeraCapture，保持宿主代码及测试配置一致，仅替换待比较的 SDK 版本。同设备、同构建类型、同模型/资源/尺寸/帧率、同场景与热状态，A/B 交替各至少 3 个稳定窗口，每窗 30 秒；初始化和切换另录。先用当前移除强制诊断的版本作为 A。
2. 参数范围处理完成后单独比较 A 与 B，不混入四项优化。固定配置、持续编辑、动态响应分别报告 CPU 时间/呈现帧、总 CPU、呈现数、掉帧、端到端 p50/p95 延迟与内存。
3. 若 CPU 时间/呈现帧的重复测量中位数上升超过 3%，或 p95 延迟增加超过 0.3 ms，进入退化调查；同时对照基线自身波动。未超过门槛但出现可重复掉帧或新增卡顿同样不通过。波动过大时增加交替样本，不直接宣称无退化。
4. 四项优化分别记录目标调用次数/分配事件和绝对 CPU。静态配置预热后无效果颜色准备不执行、身份命中不编码 JSON、静态派生结果不重建、已归还的同规格归约 Buffer 不再重复创建。
5. 配置频繁变化和多帧在途可以发生准备或扩容，但驻留有界，取消/错误恢复不退化；不以降低帧率或积累多帧换取较低 CPU。
6. 记录 GPU active、命令数和纹理/Buffer 驻留，确认没有将 CPU 成本转移成明显 GPU 或内存退化。给出 trace 路径、构建信息和可复现条件。

## 本轮不实施

Task 包装合并、GPU 命令提交架构重构、宿主直方图和 UI 调度。四项优化完成并重新定位后另行评估。

## 实施补充记录

- Task 3 的改动为无效果分支前移，沿用输入编辑及像素回归并以调用栈验证成本移除；没有创建只验证实现分支位置的测试。
- Task 5 的静态复用与当前帧隔离由 `testStaticConfigurationRebindsCurrentFrameAndInvalidatesEdits` 及现有动态颜色、资源身份、精度、取消/提交测试覆盖。
- Task 6 增加 `InputRangeBufferPoolTests`，包含共享所有者预算回收与读回后物理存储释放回归；真实 GPU 故障注入和多 GPU 硬件验证未执行，不能将错误状态代码审查等同于设备实测。
- 测量宿主首版动态测试缺少首帧目标曝光，触发 `Missing observation for color.exposureEV`。已初始化首帧输入并重新采集；旧动态结果排除。未将此宿主配置错误修改成 SDK 的默认回退值。
- 本轮按明确提交指令纳入本地 Git；不推送。仅将本计划及验收记录显式加入原本被忽略的 docs 路径。

- 范围纠正：撤回自动曝光定时器及注入响应，普通 LumeraCapture 已恢复；自动矩阵结果不作为最终验收。后续仅使用宿主既有功能验证，不新增自动参数修改。

## 当前就绪状态

| 交付项 | 状态 |
| --- | --- |
| 可选参数输入、原子更新及计算写入分离 | 已实施，回归通过 |
| 无效果输入颜色准备跳过 | 已实施，普通真机调用栈核对 |
| 输入身份命中免 JSON 编码 | 已实施，普通真机调用栈核对 |
| 静态渲染配置复用、当前帧独立绑定 | 已实施，复用/失效/所有权回归通过 |
| 范围归约 Buffer 池化 | 已实施，所有权/预算回归及真机分配事件核对 |
| 当前普通 LumeraCapture 无明显性能劣化 | 三组同热状态 A/B 通过，已就绪 |

最新验收范围替代原计划的三场景自动化验收步骤：仅使用普通 LumeraCapture 现有行为，不新增自动参数编辑。旧清单未勾选的扩展测量不被表述为已执行，不阻断此次按最新标准放行。未执行 RAW fixture、多 GPU 硬件或真实 GPU 故障注入。按明确指令完成本地提交，不推送或发布。
