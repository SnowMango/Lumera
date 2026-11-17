# Lumera 参数输入与连续帧优化验证记录

日期：2026-11-17。状态：SDK 实施完成；普通 LumeraCapture 当前预览配置的真机无明显劣化验收通过，已就绪。自动曝光测量宿主保持撤回。

## 当前普通预览验收结论

依据用户最新确认，以当前真机性能无明显劣化作为就绪条件，不要求必须测得提升。参数输入处理、内部计算写入整理及四项优化均已实施；本次普通 LumeraCapture 预览对照通过，可以就绪。修改纳入本地提交，未推送。

本次使用原始 RuntimeRenderer 行为，未注入自动曝光、响应或参数编辑。基线与当前普通应用均检查为不包含 `LumeraBenchmark`；临时宿主源码与原始 RuntimeRenderer 字节一致。原始 LumeraApp 的远程依赖配置未修改。

同一 iPhone 17 Pro、Debug、EDR/Float16、1206×1608、30 fps，相同当前预览配置，基线/当前交替采集。共采集四组，首组基线存在 Serious→Fair 热状态变化，仅作参考；正式结论使用第 2、3、4 组，六个窗口全程均为 Fair，每窗 30 秒。

| 组次 | 版本 | CPU 样本 ms/帧 | 呈现请求数 | 呈现间隔 p95 ms | GPU active ms/帧 | Metal 峰值 bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 2 | 基线 | 5.1722 | 900 | 41.7394 | 2.6998 | 103645184 |
| 2 | 当前 | 4.9044 | 900 | 41.7831 | 2.7055 | 103645184 |
| 3 | 基线 | 5.2022 | 900 | 42.0264 | 2.7167 | 103645184 |
| 3 | 当前 | 5.0278 | 900 | 41.3752 | 2.7645 | 103645184 |
| 4 | 基线 | 5.2867 | 900 | 41.7257 | 2.7644 | 103645184 |
| 4 | 当前 | 4.9222 | 900 | 41.6665 | 2.7222 | 103645184 |

三组中位数：CPU **5.2022 → 4.9222 ms/帧**；GPU active **2.7167 → 2.7222 ms/帧**（约 +0.2%，未见有意义的增加）；呈现间隔 p95 **41.7394 → 41.6665 ms**；Metal 峰值均为 **103645184 bytes（98.84375 MiB）**。六窗均为 900 次呈现请求，约 30 fps，1800 次 GPU 命令提交；Metal command error 表均无错误。

六窗归约 Buffer 分配事件为基线每窗 2700、当前每窗 0；总 Buffer 分配事件从 4500 降为 1800。当前版输入身份命中链中的 JSON CPU 样本和无效果输入颜色变换 CPU 样本均为 0，与代码路径核对一致。命令数及内存未增加，未以降低帧率换取 CPU 降幅。

本结论针对普通 LumeraCapture 的当前预览配置。呈现间隔不是相机到显示的端到端延迟；没有使用撤回的自动场景结果补充此结论。四项缺少 RAW fixture 的测试、真实 GPU 故障注入和多 GPU 硬件测试未执行，不属于本次当前预览无明显劣化的放行依据。

设备最终保留使用当前本地 SDK 的普通 LumeraCapture，无测量启动参数。当前 SDK 源码 SHA-256 为 `af83e13bde3891ed9f9fcb1ff8e77af9dfd93b5c7d10730ea8eb8c0f22abd04d`，与 483 项回归、0 失败、4 跳过时一致；本次普通真机构建及 `git diff --check` 通过。

证据目录：`/tmp/lumera-runtime-optimization/`。主汇总 `ordinary-summary.json`；trace 使用 `ordinary-{baseline,current}-{2,3,4}-1.trace`；CPU/GPU 分析为同名 `.json`，资源事件为 `-resources.json`，热状态/错误为 `-health.json`。执行记录为 `logs/ordinary-comparison.log`、`logs/ordinary-extra.log`。脚本 `ordinary_compare.py`、`ordinary_extra.py` 只安装/启动普通应用并采样，不修改参数或宿主行为。

## 修改基线

- 分支：`codex/runtime-input-optimization`；起始 HEAD：`9bec924cccfc0fbfffcebc4ae123f36718b4aa15`。
- 基线包含本轮开始前已存在的可选参数诊断修改，不能将此前删除强制诊断的收益归入本轮。
- 基线快照：`/tmp/lumera-runtime-optimization/baseline-source.tar`。
- 本轮完成本地提交，未推送。原始 LumeraApp/LumeraCapture 的远程依赖配置保持原状，设备测量使用独立宿主副本。

## 实现结果

| 项目 | 行为 |
| --- | --- |
| 参数输入 | `ParameterInput.accept/update/curve/adaptationPolicy` 与 `decodeChecked` 由调用方显式使用；变化字段及关联组在副本上处理，失败原子回滚 |
| 内部计算 | `writeComputed` 分离计算结果写入与输入诊断；适配策略摘要、每帧适配及矩阵/曲线插值不重复扫描创作范围 |
| 输入颜色 | `inputEdit` 在颜色变换准备前判断是否产生效果 |
| 输入身份 | 单条缓存按 UTF-8、浮点位模式及完整配置字段判断命中；失配沿用原摘要算法 |
| 静态配置 | 每个 `PreparedStyleModel` 保留当前派生配置；当前输入范围、帧序列及租约独立绑定 |
| 范围 Buffer | 按层、精确长度和存储模式租用；接入共享预算、空闲回收、代际和关闭处理 |

范围 Buffer 的 CPU 读回与 GPU 使用分别持有同一租约。读回成功或终止错误后只保存结果，清除 Buffer/command 引用；提前调用 resolve 不放弃所有权。配置准备遇到预算不足时回收同一账本各所有者的空闲范围 Buffer 后重试。资源池设备在编码前匹配。

仍采用独立分配的路径：未传入持久 `ProcessingResources` 的内部独立范围测量。没有另建 renderer 全局池。Core Image、相机和 Metal 驱动自身分配不属于本轮范围池。

## 参数处理边界

| 原路径 | 本轮处理 |
| --- | --- |
| 完整 `StyleParameters/Profile/StyleModel` 诊断 | 显式诊断或受控输入入口；执行不恢复完整扫描 |
| 固定 AdaptationPolicy 规则 | 显式输入诊断；摘要只随规则变化失效 |
| 内部标量、矩阵、曲线计算结果 | 直接写入；保留计算形状和无法表示的结果错误 |
| 输入编辑权限、强度混合、锁定冲突 | 现有编辑功能契约；不作为完整参数诊断的替代物 |
| LUT 凸组合、实际资源身份和输入绑定 | 保留实际资源/运算契约 |
| 当前像素范围、Float16 可表示性、GPU 状态与存储容量 | 保留执行时实际数据和资源处理 |

`update` 不诊断未修改字段；detail/glow 半径顺序仍由调用方显式完整诊断报告。公开可写属性保留兼容性，绕过受控输入后的数据由调用方负责。

## 本机回归

命令：

```sh
swift test --filter 'ImagingCoreTests|ImageRenderingTests|ImagingRuntimeTests|DesktopContractTests|GrainReferenceTests|GrainSamplingTests'
git diff --check
```

最终回归：483 项，0 失败，4 项因未设置有效 `LUMERA_RAW_TEST_FILE` 跳过。分组为核心 130、渲染 233、运行时 71、桌面契约 44、颗粒参考/采样 5。日志：`/tmp/lumera-runtime-optimization/logs/final-integration.log`。

新增覆盖包括输入原子回滚、声明域/有效域、非有限值、身份 Unicode/正负零语义、静态配置复用与编辑失效、当前帧独立所有权、Buffer 预热复用、GPU 完成但未读回、重复解析、尺寸混用、同命令多票据、预算收缩、共享账本回收、未提交命令销毁及关闭。

独立审查发现并修复三项资源问题：已解析票据保留未记账存储、资源池设备未匹配、空闲 Buffer 阻挡可负担的配置准备。前两类所有权/预算回归在修复前失败、修复后通过；设备身份检查测试覆盖不同 registryID。没有多 GPU 硬件实测，也没有注入真实 GPU 故障。

## 已撤回的自动测量记录（不作验收依据）

- 应用：LumeraCapture；设备 iPhone 17 Pro，iOS 26.5.2，Metal 设备 A19 Pro。
- Debug 构建；1206×1608 输入；30 fps；EDR/Float16；相同相机视场。
- 宿主分别位于 `/tmp/lumera-runtime-optimization/harness-{baseline,parameters,final}`，均为本地 SDK 引用。
- baseline：本轮开始前工作区；parameters：仅参数输入及计算写入整理；final：四项优化及资源审查修复全部启用。
- 持续编辑：输入事件每秒 30 次修改颜色曝光。parameters/final 在事件边界显式调用 `ParameterInput.update`；baseline 保持直接赋值。没有将输入处理方法插入渲染调用。
- 动态响应：目标曝光条件按相同周期变化，驱动 `color.exposureEV`，带 0.1 秒适配时间常数。
- CPU：Metal System Trace 的 Time Profiler 权重之和除以呈现请求数；每个 35 秒 trace 分析 `[2,32)` 的 30 秒窗口。CPU 样本不是墙钟处理时长，也不是独立函数独占时间。
- 呈现间隔与延迟分开。延迟使用相机 CMSampleBuffer PTS 到 `CAMetalDrawable.presentedTime`；忽略 presentedTime=0 的回调，从首个有效呈现后取稳定窗口。此指标不包含光学输入至传感器的延迟，也不是输入到光子的物理测量。
- GPU active 使用所选进程顶层 GPU 区间的时间并集；单纯区间求和另存，不用于宣称 GPU 利用率。
- 温度记录采用 `ProcessInfo.thermalState`。同一矩阵按 baseline → parameters → final 交替采集。

### 动态场景启动错误修正

首版测量宿主在动态响应已经安装后，延迟 2 秒才首次提供目标曝光，导致 `Missing observation for color.exposureEV`。LumeraCapture 因此显示“风格模型取景失败，正在显示原片”。根因为测量宿主缺少首帧观测，不是 SDK 参数范围拒绝。

已将动态目标曝光在首帧前初始化为 0，并增加持久错误记录。旧动态 trace 移至 `/tmp/lumera-runtime-optimization/invalid-dynamic-startup`，不用于性能验收；动态场景重新采集。

## 资源事件诊断证据（不等于整体性能验收）

首轮有效固定/编辑场景，30 秒、900 次呈现请求：

| 场景 | 基线归约 Buffer 分配事件 | 最终归约 Buffer 分配事件 | 总 Buffer 分配事件 | Metal 分配峰值 |
| --- | ---: | ---: | --- | --- |
| 固定参数 | 2700 | 0 | 4500 → 1800 | 两者均 103645184 bytes |
| 持续编辑 | 2700 | 0 | 4500 → 1800 | 两者均 167411712 bytes |

剩余 Buffer 事件来自其他调用路径，不能写成全应用没有每帧 Buffer 分配。Texture 事件包含纹理视图，不等于新的底层纹理存储。SDK 账本多计入的约 0.125 MiB 是已池化归约存储，实际 Metal 分配峰值没有相应增加。

## 测量撤回与恢复

动态测试先出现 `Missing observation for color.exposureEV`，初始化首帧输入后，持续编辑测试又出现 `Unsupported override: color.exposureEV`。第二次错误出现在 baseline 测量版，该 SDK 不包含本轮四项优化。自动定时器向当前模型发送曝光覆盖，而正常模型更新可替换覆盖权限，二者产生冲突。

自动改曝光属于实施中自行增加的宿主行为，未列为方案中的具体修改，经用户指出后已撤回。三个临时宿主的 RuntimeRenderer 均恢复原始源码；自动测量启动脚本已禁用，含自动逻辑的测试应用构建产物已删除。原始 LumeraApp/LumeraCapture 项目源码及远程 SDK 配置未修改。设备已安装并启动使用本地最终 SDK 的普通 LumeraCapture，不带测量启动参数。

三场景矩阵不作为最终 CPU、帧率或延迟验收依据。原始 trace 保留用于故障追溯，不以单窗口结果声明优化百分比或性能验收通过。另有一段采样包含预览流和 LUT 重建，保存在 `configuration-transition`，不能混入稳定帧对比。

SDK 修改现按明确提交指令纳入本地提交。后续验证仅使用普通 LumeraCapture 的既有功能，不新增自动参数修改或改变宿主功能。四项 RAW fixture 测试、真实 GPU 故障和多 GPU 硬件验证仍未执行。随后完成的普通预览验收见本文开头，撤回的自动矩阵仍不采用。
