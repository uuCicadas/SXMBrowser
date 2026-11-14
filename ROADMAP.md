# SXM Browser 项目进展评估与演进规划报告

当前基准：`main` / `codex/sxm-reliability-ui` 分支 `HEAD`（`v2.5.1`，Build 95）  
实测验证：全量 **315 项自动化测试通过**（[`SXMBrowserCoreTests`](native/SXMBrowserNative/Tests/SXMBrowserCoreTests) 69 项 + [`SXMBrowserAppCoreTests`](native/SXMBrowserNative/Tests/SXMBrowserAppCoreTests) 235 项 + [`SXMBrowserNativeUITests`](native/SXMBrowserNative/Tests/SXMBrowserNativeUITests) 11 项，全量运行耗时 `< 1s`），标准样例（6 个 `.sxm` + 18 个 `.dat`）[`SXMBrowserSmoke`](native/SXMBrowserNative/Sources/SXMBrowserSmoke/main.swift#L1-L473) 契约校验与 500×512×512 性能门禁（中位数 `scan 29.173 ms / image 21.460 ms / thumbnail 21.939 ms`）全部通过。

---

## 一、产品定位与核心准则（Product Positioning）

### 1.1 核心定位：纯粹的原生高速数据监看器（Pure Data Monitor）

**SXM Browser** 定位为专注 Nanonis 扫描探针显微实验数据（`.sxm` 扫描图与 `.dat` 点谱）的 **macOS 原生高速只读数据监看与分拣工具**——类似摄影工作流中的 Raw 样片监看台（Photo Mechanic 角色）：服务于实验人员在机台旁实时看片、快速核对物理采集参数、高保真预览原始形貌与谱线，以及高效筛选打标归档。

```mermaid
flowchart LR
    Instrument["Nanonis 实验采集
    (.sxm / .dat 原始落盘)"] --> Monitor["SXM Browser（本项目定位）
    高速只读监看 · 实时跟片 · 筛选打标"]
    Monitor --> Downstream["下游专业分析与制图工具
    (Gwyddion / SpectraFox / Python / Igor)"]
```

### 1.2 明确边界：有所为，有所不为（Non-Goals）

> [!IMPORTANT]
> 为保持代码精简、启动与切图极致轻快、界面纯粹无干扰，项目明确划定以下边界：
> - **不负责论文级排版出图**：不做烧录比例尺、Colorbar 色条、字体标注或谱点叠加的排版合成面板，不做 PDF/SVG/DPI 出版级制图导出（仅保留纯净像素级 sRGB PNG 快速导出供即时沟通）。
> - **不负责修图与重度科学后处理**：不做去划痕（Scar removal）、任意多项式背景修平、2D FFT 滤波与倒空间测量、任意方向高度截线（Line Profile）测量、Savitzky–Golay 平滑或数值微分分峰。
> - **绝不改写原始实验数据**：所有显示增强（如 `Plane linear fit`、`Subtract linear fit`、色阶拉伸）均为内存态实时监看滤镜，原始 `.sxm` / `.dat` 文件保持 100% 只读（仅支持用户显式确认移入系统废纸篓）。

### 1.3 三大演进目标支柱

后续全部开发工作严格收敛并落实到以下三个维度：

1. **数据可靠性（Data Reliability）**：空间方向、物理通道语义与色彩还原零失真；异常/停扫/截断文件安全兜底不崩溃；目录动态变化与元数据持久化严谨无损。
2. **程序性能优化（Performance & Responsiveness）**：消除全局无效重绘与冗余内存驻留；千级文件目录秒级检索、视口缩略图即时出图、单击与分栏拖拽零延迟跟手。
3. **UI 全面美观（Comprehensive UI Aesthetics）**：贯彻 macOS 14+ 原生视觉体系，画面留白克制、信息层级清晰、深浅色模式和谐、微交互细腻统一。

---

## 二、架构基线与已完成项目（Completed Progress）

### 2.1 当前总体架构基线

项目已稳定运行于 **纯原生 macOS 14+ 架构（Swift 6.0 + SwiftUI/AppKit + CoreAnimation + `@Observable`）**，Swift 源码与自动化测试总计 **39,844 行**（涵盖 4 个核心模块与 55 个测试文件 / 315 项测试）：

```mermaid
flowchart TD
    subgraph AppLayer["SXMBrowserNative (Executable Target, 1 文件, 177 LOC)"]
        AppEntry["SXMBrowserNativeApp.swift (@main 入口 / 菜单 / 快捷键 / AppTerminationDelegate)"]
    end

    subgraph UILayer["SXMBrowserNativeUI (Library Target, 31 文件, 12.1k LOC + 6 测试文件)"]
        AppModel["AppModel + Extensions (组合编排与文件操作)"]
        Controllers["@Observable 域控制器
        DatasetSession / ImageViewer / Spectroscopy / ThumbnailPipeline"]
        Views["Views/ 按域模块化视图
        Root / Sidebar / Grid / Inspector / SingleViewer / Spectroscopy"]
        Bridges["NativeBrowserSplitView / InstantClickOverlay / LayerImageView / ScreenScaleBar"]
    end

    subgraph AppCoreLayer["SXMBrowserAppCore (Library Target, 40 模块 + 38 测试文件)"]
        RenderCoord["RenderCoordinator + RenderRequestGate (单飞渲染与防串图)"]
        Cache["MatrixLoadCache + ByteLRUCache + AsyncLimiter (LIFO 门控与缓存)"]
        MetaStore["DatasetMetadataStore + Transfer + ImportPlanner (原子持久化与导入)"]
        DomainState["SelectionState / ScanCoordinateTransform / ViewerTransform / SpectroscopyPresentation"]
    end

    subgraph CoreLayer["SXMBrowserCore (Core Target, 9 模块 + 11 测试文件)"]
        Parsers["SXMParser (.sxm) + SpectroscopyParser (.dat) + POSIXDateParser"]
        Renderer["SXMRenderer (平面/逐行拟合 / Welford 统计 / 箱式下采样 / sRGB 着色)"]
        Palettes["PaletteStore + palettes.json (4 套 257-stop OKLCh 监看调色板)"]
    end

    subgraph Tooling["质量门禁与发布脚本 (scripts/)"]
        Smoke["SXMBrowserSmoke (标准样例契约)"]
        Bench["SXMBrowserBenchmark (500x512x512 性能门禁)"]
        Checkpoints["version / backup / milestone / clean_builds (事务级备份与清理)"]
    end

    AppEntry --> AppModel
    AppEntry --> Views
    Views --> AppModel
    Views --> Controllers
    Views --> Bridges
    AppModel --> Controllers
    AppModel --> RenderCoord
    AppModel --> MetaStore
    AppModel --> DomainState
    ThumbnailPipeline --> Cache
    RenderCoord --> Cache
    RenderCoord --> Renderer
    RenderCoord --> Parsers
    Renderer --> Palettes
    Smoke --> CoreLayer
    Bench --> CoreLayer
```

**已沉淀的核心技术资产**：
- **数值精度保障**：[`planeLinearFit`](native/SXMBrowserNative/Sources/SXMBrowserCore/SXMRender.swift) 与 [`lineLinearFit`](native/SXMBrowserNative/Sources/SXMBrowserCore/SXMRender.swift) 采用坐标归一化与 `Double` 中心化正规方程求解，保留大压电偏置下皮米级原子台阶残差；`statistics` 基于 Welford 在线算法复用统计量。
- **异步防串图与原子存储**：[`RenderCoordinator`](native/SXMBrowserNative/Sources/SXMBrowserAppCore/RenderCoordinator.swift) + [`RenderRequestGate`](native/SXMBrowserNative/Sources/SXMBrowserAppCore/RenderRequestGate.swift) 严格拦截跨数据集/跨文件迟到帧；[`DatasetMetadataStore`](native/SXMBrowserNative/Sources/SXMBrowserAppCore/DatasetMetadataStore.swift) 具备原子写、逐字节读回校验与损坏文件保护。
- **高辨识度科学监看色标**：在 OKLab/OKLCh 感知均匀空间构建并用 SHA-256 指纹锁死 4 套 257-stop 监看调色板（`Dusk Violet`、`Ink Violet`、`Ember`、`Basic gray`）。
- **细粒度 `@Observable` 响应式编排**：[`SXMBrowserNativeUI`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Controllers/AppModel.swift) 通过域控制器隔离状态更新、版本化缓存派生列表、`InstantClickOverlay` 零延迟派发与 LIFO 视口优先缩略图限流，支撑千级文件目录流畅交互。

### 2.2 阶段零（`v2.4.1`–`v2.4.2`）已完成项目清单

截至 Build 93，**原审查报告中的全部 P0 缺陷（5/5）及基础可靠性优化均已交付验收**：

| 原编号 | 类别 | 已完成内容与代码落点 | 完成版本 |
| :--- | :--- | :--- | :--- |
| **D1 (P0)** | 数据可靠性 | **`:SCAN_DIR: up` 空间手性校准**：[`SXMParser.swift`](native/SXMBrowserNative/Sources/SXMBrowserCore/SXMParser.swift) 解码阶段将向上扫描归一化为物理 `+Y` 朝上；[`SXMModels.swift`](native/SXMBrowserNative/Sources/SXMBrowserCore/SXMModels.swift) 改为精确词元匹配；同步统一 [`ScanCoordinateTransform`](native/SXMBrowserNative/Sources/SXMBrowserAppCore/ScanCoordinateTransform.swift) Y 轴映射并补齐回归测试 | `v2.4.1` (Build 92) |
| **D2 (P0)** | 数据可靠性 | **物理通道分类与默认处理校准**：[`SXMModels.swift`](native/SXMBrowserNative/Sources/SXMBrowserCore/SXMModels.swift) 细分为 `.topography` / `.conductanceOrCurrent` / `.afm`，仅形貌高度通道（`Z` / `Height` / `Topography`）默认 `.planeLinear`，电导/电流与 AFM 保持 `.raw`，消除人为梯度伪影 | `v2.4.1` (Build 92) |
| **D3 (P0)** | 可靠性 / 性能 | **全链路显式 sRGB 与线程安全缩略图缩放**：[`SXMRender.swift`](native/SXMBrowserNative/Sources/SXMBrowserCore/SXMRender.swift) 统一绑定 `CGColorSpace.sRGB`，PNG 直出 `NSBitmapImageRep(cgImage:)`；移除后台 `NSImage.lockFocus()`，改为有限值箱式下采样 `downsampleMatrix` + `CGContext` 缩放 | `v2.4.1` (Build 92) |
| **D4 (P0)** | UI 交互 | **`ScaleField` 缓冲输入与 SI 工程后缀解析**：[`InspectorView.swift`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Views/Inspector/InspectorView.swift) 采用 `@FocusState` + `draftText` 隔离输入态，提交/失焦时通过 [`SpectroscopyParser.swift`](native/SXMBrowserNative/Sources/SXMBrowserCore/SpectroscopyParser.swift) `parseEngineeringDouble` 解析 `p`/`n`/`u`/`m` 等后缀与科学计数法 | `v2.4.1` (Build 92) |
| **D5 (P0)** | UI 交互 | **应用内右键 `Open` 与 `Cmd+A` 焦点分流**：右键 `Open` 改为应用内选中并切至 Single 视图；[`AppModel+TagsAndDeletion.swift`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Controllers/AppModel+TagsAndDeletion.swift) `selectAll` 识别 `NSText` 第一响应者优先全选输入框文本 | `v2.4.1` (Build 92) |
| **D6 局部** | 性能优化 | **空搜索词短路优化**：[`DatasetSessionController.swift`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Controllers/DatasetSessionController.swift) 在搜索词为空时直接返回候选集，消除无搜索时的 `O(F × S)` 谱图关联遍历 | `v2.4.1` (Build 92) |
| **D7 局部 (P1)** | 性能 / 并发 | **`AsyncLimiter` 取消安全与缩略图失效完善**：重构 [`AsyncLimiter.swift`](native/SXMBrowserNative/Sources/SXMBrowserAppCore/AsyncLimiter.swift) 消除取消早于入队的挂起竞态；[`ThumbnailPipeline.swift`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Controllers/ThumbnailPipeline.swift) 支持多等待者引用计数取消传播及 `modifiedTime` 缓存键失效 | `v2.4.1` (Build 92) |
| **D8 (P1)** | 可靠性 / 性能 | **`.dat` 大文件/二进制护栏与日期解析缓存**：[`SpectroscopyParser.swift`](native/SXMBrowserNative/Sources/SXMBrowserCore/SpectroscopyParser.swift) 增加 64 MiB 上限与 256 KiB 头部预检（拦截二进制 NUL 与无 `[DATA]` 文件）；新增锁保护的 [`POSIXDateParser.swift`](native/SXMBrowserNative/Sources/SXMBrowserCore/POSIXDateParser.swift) 复用 `DateFormatter` | `v2.4.1` (Build 92) |
| **D10 局部** | UI 美观 / 可靠 | **画布滤波、比例尺阴影、光标栈与删除元数据清理**：`LayerImageView` 启用 `.linear` 缩小滤波消除摩尔纹；`ScreenScaleBar` 增加双层暗色阴影适配亮底；`CursorModifier` 在 `onDisappear` 自动平衡 `NSCursor` 栈；批量删文件合并清缓存并同步清理孤儿 `manualAssociations` 与 `spectrumAxisPreferences` | `v2.4.1` (Build 92) |
| **D11 & D13** | 工程卫生 | **构建缓存治理与文档/分支同步**：新增 [`clean_builds.command`](scripts/clean_builds.command) 清空历史 `.build*` 缓存目录；补齐 [`test_all.command`](scripts/test_all.command) 缓存环境变量；同步更新 [README.md](README.md) | `v2.4.1`–`v2.4.2` |
| **色标精炼** | UI 美观 | **新增 `Ember` 暖铜调色板并收敛色标库**：引入符合经典 STM 审美语汇的 `Ember`（257-stop OKLCh），退役旧 `Flame` 与 `Deep Blue` 并平滑回退历史偏好 | `v2.4.2` (Build 93) |

### 2.3 阶段一（`v2.5.0` / Build 94）架构瘦身与极致性能打磨已完成项目

截至 Build 94，**架构瘦身、内存减半、`@Observable` 模块解耦与极速网格交互全部完成交付**：

| 原编号 | 类别 | 已完成内容与代码落点 | 完成版本 |
| :--- | :--- | :--- | :--- |
| **D9** | 性能 / 瘦身 | **清退死代码并减少 50% 活动大图矩阵内存**：移除 [`RenderCoordinator.swift`](native/SXMBrowserNative/Sources/SXMBrowserAppCore/RenderCoordinator.swift) 中 `ProcessedPayload.source` 与 `ProbePixelValues`，删除废弃文件 `ProbeReading.swift`、`ResponsivePaneLayout.swift` 及残留 `probeReading` / `manuallyAssignedSXMIDBySpectrumID` / `manualTargetPathByDATPath` 状态；抽出 [`ScanCoordinateTransform.swift`](native/SXMBrowserNative/Sources/SXMBrowserAppCore/ScanCoordinateTransform.swift) 专职服务 `.dat` 测量坐标映射 | `v2.5.0` (Build 94) |
| **D6 & D12** | 架构 / 性能 | **模块拆分、`@Observable` 域控制器与派生列表缓存**：通过 [`Package.swift`](native/SXMBrowserNative/Package.swift) 将 UI 编排拆入 `SXMBrowserNativeUI`（保留极薄 `@main` 入口 [`SXMBrowserNativeApp.swift`](native/SXMBrowserNative/Sources/SXMBrowserNative/SXMBrowserNativeApp.swift)）并新增 `@MainActor` 测试目标 [`SXMBrowserNativeUITests`](native/SXMBrowserNative/Tests/SXMBrowserNativeUITests)；将 `AppModel` 迁移为 macOS 14 `@Observable` 组合 [`DatasetSessionController`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Controllers/DatasetSessionController.swift)、[`ImageViewerController`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Controllers/ImageViewerController.swift)、[`SpectroscopyController`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Controllers/SpectroscopyController.swift) 与 [`ThumbnailPipeline`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Controllers/ThumbnailPipeline.swift)；为 `sortedFiles` / `visibleFiles` / `visibleDisplayItems` / `files(forTagID:)` 建立版本号驱动 O(1) 缓存；将原 `Views.swift` 拆分为 `Views/{Root,Sidebar,Grid,Inspector,SingleViewer,Spectroscopy}/` 并抽出 `SidebarStatusFooter` | `v2.5.0` (Build 94) |
| **D7 & D10** | 并发 / 交互 | **视口优先缩略图调度、零延迟单击与后台废纸篓清理**：[`AsyncLimiter.swift`](native/SXMBrowserNative/Sources/SXMBrowserAppCore/AsyncLimiter.swift) 新增 `.lifo` 排队模式并在 [`ThumbnailPipeline.swift`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Controllers/ThumbnailPipeline.swift) 启用（`limit: 4, order: .lifo`）；[`ThumbnailCard.swift`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Views/Grid/ThumbnailCard.swift) 采用 AppKit [`InstantClickOverlay.swift`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Views/Grid/InstantClickOverlay.swift) (`GridCardClickAction.resolve`) 消除双击判定导致的 `~250ms` 单击迟滞；[`AppModel+TagsAndDeletion.swift`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Controllers/AppModel+TagsAndDeletion.swift) 将 `FileManager.default.trashItem` 移至后台执行并引入 `isDeletingFiles` 并发忙锁与跨会话防护 | `v2.5.0` (Build 94) |

---

## 三、现存待优化项盘点（Remaining Debt）

结合“纯粹数据监看器”定位，阶段一完成后代码库中仅余以下待推进至后续版本的功能与体验细节：

| 归属支柱 | 原编号 | 模块 | 现存问题描述 | 处理策略 |
| :--- | :--- | :--- | :--- | :--- |
| **数据可靠性** | **D10 / D12** | `SpectroscopyController` / `SXMBrowserNativeApp` | 缺少 UI 入口解除/重置 `.dat` 手动关联（`.missingManualTarget` 状态无处恢复）；`WindowGroup` 共享会话缺乏多窗口隔离 | 在 `v2.6` 补齐“重置手动关联”入口并实施每窗口独立会话隔离 |
| **UI 美观** | **D10** | `GridBrowserView` / `SingleSpectroscopyDrawer` | 网格开启谱图卡片混排时，上下方向键仅按纯 `.sxm` 数量加减列步长导致跨行错位；[`SingleSpectroscopyDrawer.swift`](native/SXMBrowserNative/Sources/SXMBrowserNativeUI/Views/SingleViewer/SingleSpectroscopyDrawer.swift) 中 `SpectroscopyLegend.==` 仅对比谱线数量，同数量替换时图例漏刷 | 在 `v2.7` 统一基于实际网格项索引计算二维键盘导航，并改为对比可见/全部谱线标识数组 |

---

## 四、后续演进路线图（Roadmap）

摒弃复杂的修图、测量与排版导出包袱后，后续版本聚焦 **“更快、更稳、更好看”** 三阶段递进：

```mermaid
flowchart LR
    Done["已完成: v2.4.1 - v2.5.0
    P0 校准 + 架构瘦身 + @Observable + 视口优先"] --> Next2["阶段二: v2.6 (数据可靠性)
    机台实时看片 + 参数锁定 + 异常/编码兜底"]
    Next2 --> Next3["阶段三: v2.7 (UI 全面美观)
    原生视觉精修 + 采集参数微排版 + 系统级预览"]
```

---

### 阶段一：`v2.5` 架构瘦身与极致性能打磨（已完成：`v2.5.0` Build 94 → `v2.5.1` Build 95）

让应用在承载 **1,000+ 文件实验目录** 时依然保持零掉帧、低内存占用与瞬时点选响应：

- [x] **清退死代码并释放双倍矩阵内存（解决 D9）**
  - 移除 `RenderCoordinator.ProcessedPayload.source`、`ProbePixelValues`、`ProbeReading`、`PixelCoordinate`、`ResponsivePaneLayout` 及 `AppModel` 残留 `probeReading` / `manuallyAssignedSXMIDBySpectrumID` / `manualTargetPathByDATPath` 状态，抽出 `ScanCoordinateTransform` 并降低 **50%** 活动大图矩阵常驻内存。
- [x] **`@Observable` 细粒度状态架构与模块解耦（解决 D6 & D12）**
  - 将 `SXMBrowserNative` 拆分为极薄 `@main` 入口 + `SXMBrowserNativeUI` 库 Target，建立 `SXMBrowserNativeUITests` 单元测试目标。
  - 利用 macOS 14 原生 `@Observable` 宏将 `AppModel` 拆解为职责单一的域控制器（`DatasetSessionController`、`ImageViewerController`、`SpectroscopyController`、`ThumbnailPipeline`），消除跨领域无效重绘。
  - 为 `sortedFiles`、`visibleFiles`、`visibleDisplayItems` 与 `files(forTagID:)` 建立数据版本号驱动的 O(1) 派生缓存。
  - 将原 `Views.swift` 按视图域拆分为 `Root/`、`Sidebar/`、`Grid/`、`SingleViewer/`、`Spectroscopy/`、`Inspector/` 并抽出 `SidebarStatusFooter`。
- [x] **海量网格与文件操作极速响应（深化 D7 & D10）**
  - **视口优先缩略图调度（LIFO / Viewport Priority）**：`AsyncLimiter` 支持 `.lifo` 且 `ThumbnailPipeline` 默认启用。
  - **零延迟单击选中**：通过 AppKit `InstantClickOverlay` (`GridCardClickAction`) 替代双层 `TapGesture`，实现单击立即选中与双击进入 Single 视图。
  - **异步废纸篓清理**：`performDeleteFiles` 将 `FileManager.default.trashItem` 下放至后台执行，并加入 `isDeletingFiles` 并发忙锁及跨会话清理防护。
- [x] **无极直方图拖拽刷新与单窗退出生命周期优化（`v2.5.1`, Build 95）**
  - **关窗即退出**：通过 `@MainActor AppTerminationDelegate`（`NSApplicationDelegate.applicationShouldTerminateAfterLastWindowClosed(_:)`）与 `@NSApplicationDelegateAdaptor` 挂载到 [`SXMBrowserNativeApp`](native/SXMBrowserNative/Sources/SXMBrowserNative/SXMBrowserNativeApp.swift)，关闭最后一个窗口时直接退出应用，不在 Dock 栏残留。
  - **无极实时拖拽色阶**：移除 `updateScale(min:max:)` 的 70 ms 取消重睡防抖，改用同矩阵（`processedKey` 未变）原地保留 `renderedFrame` / `selectedStats`（消除 `"Rendering..."` 闪烁与拖拽手势中断）+ 零等待单飞合并调度（`inFlightCoalescedRequestID` / `hasPendingScaleRender`）+ [`PaletteLookup`](native/SXMBrowserNative/Sources/SXMBrowserCore/PaletteStore.swift) O(1) 均匀网格查表着色与 `Gradient` 色条重绘。

---

### 阶段二：`v2.6` 机台实时监看与全边界数据可靠（核心目标：数据可靠性）

针对机台旁持续采图、半途停扫与跨日序列比对的真实科研现场，做到“数据不漏、状态不乱、异常不崩”：

1. **实验文件夹实时安全监听（Live Folder Watch）**
   - 基于 `FSEventStream` / `DispatchSource` 监听当前目录增删改，结合 [`DatasetInventorySignature`](native/SXMBrowserNative/Sources/SXMBrowserAppCore/DatasetInventorySignature.swift) 执行防抖增量扫描，完整保留已有缩略图缓存、筛选词与标签上下文。
   - **落盘完整性保护（Write-in-progress Guard）**：对 Nanonis 正在写入、字节数尚未达到预期矩阵载荷大小的 `.sxm` / `.dat` 文件自动延后重试，绝不将半写状态误报为损坏或渲染花屏。
   - 提供 **`Cmd+R` 手动刷新** 与工具栏轻量的 **“Follow Latest（自动跟进最新扫描图）”** 开关。
2. **序列监看一致性与元数据闭环**
   - **跨文件监看参数锁定（Lock Channel / Processing / Scale）**：在连续翻看变偏压（Bias series）或变高度（Z-dependent Δf）序列图时，可选锁定当前通道、处理方式与色阶范围，防止每翻一页自动重置导致视觉基准跳变。
   - **元数据自愈与多窗口隔离**：补齐解除/重置 `.dat` 手动关联的菜单入口；将窗口状态改为每窗口独立会话（或明确单窗口模式约束），彻底消除多标签页抢占书签与缩放状态。
3. **更广的只读兼容性与停扫数据真实表达**
   - 在 `SXMParser` 中补齐 `FLOAT LSBFIRST` 与整型 `SCANIT_TYPE` 只读解码校验，覆盖更多控制器配置与第三方转存 `.sxm` 文件。
   - 完善实验中途停扫（Aborted scan）产生的含 `NaN` 矩阵监看策略：明确区分“未采集 `NaN` 区域”与“有效极小值区域”，并增强自动色阶在极端针尖跳变（Tip spike）下的稳健性（新增一键 `2–98%` / 抗离群值色阶预设）。

---

### 阶段三：`v2.7` 原生审美升华与精致视觉体验（核心目标：UI 全面美观）

对标 Apple 原生专业工具（如预览、数码测色计、快捷指令）的视觉水准，打磨每一处像素与动效：

1. **全局视觉语言与画布质感统一**
   - **统一材质与排版韵律**：梳理侧栏、网格卡片、Single 纯净画布、底部谱图抽屉与右侧 Inspector 的背景材质（Vibrancy）、1px 分割线对比度、圆角规范与留白栅格，确保 Dark Mode 与 Light Mode 下均具备通透克制的仪器美感。
   - **`NaN` 未扫描像素优雅底板**：在 Single 画布与网格缩略图中，将停扫文件的 `NaN` 区域渲染为柔和的中性细微棋盘/暗灰底色，替代生硬黑块。
   - **空状态、加载态与诊断反馈重设计**：优化首次启动引导页、空筛选结果占位图、骨架加载过渡与非侵入式状态提示。
2. **核心采集参数高可读性微排版（Inspector 焕新）**
   - 从 `SXMMetadata.header` 结构化提炼实验员看片最核心的物理参数——**偏压（Sample Bias）**、**设定点（Setpoint）**、**扫描范围（Scan Range）**、**反馈模式（恒流/恒高）**、**采集耗时** 与 **`:COMMENT:` 备注**——采用紧凑清晰的键值卡片与等宽数字（`.monospacedDigit()`）排版，并提供干净的可折叠 **Raw Header 快速检索区**。
3. **谱图抽屉与网格微交互精修**
   - 优化谱图抽屉的坐标轴网格线呼吸感、科学计数法刻度对齐、高对比度谱线描边及聚焦点位联动动效；修复 `SpectroscopyLegend.==` 判等逻辑确保图例实时准确刷新。
   - 修正网格混排 `.sxm` 与 `.dat` 谱图卡片时的二维方向键导航，保证键盘上下左右移动严格对齐视觉列。
4. **系统级原生融通体验**
   - 在 [Info.plist](native/SXMBrowserNative/Bundle/Info.plist) 完整注册 `.sxm` / `.dat` 文档类型（UTI）与精致文档图标，支持在 Finder 中双击文件或拖入 Dock 图标直接启动并聚焦对应图像；评估提供轻量级 **macOS Quick Look 预览扩展**，让用户在 Finder 按空格键即可秒看 `.sxm` 预览图。
