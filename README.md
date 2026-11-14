# SXM Browser

本地 macOS 原生工具，用来快速浏览与检查 Nanonis `.sxm` 扫描图像及 `.dat` 点谱文件。

## macOS 原生版

本地构建产物与系统安装位置：

```bash
open "./SXM Browser.app"
# 或从系统应用程序菜单启动（打包同步后）：
open "/Applications/SXM Browser.app"
```

它是 SwiftUI/AppKit 写的本地 macOS 应用，不启动本地网页服务，也不依赖浏览器。常用脚本：

```bash
./scripts/build_native_app.command   # 构建并签名 Release App (./SXM Browser.app)
ditto "./SXM Browser.app" "/Applications/SXM Browser.app" # 同步至系统应用程序目录
./scripts/test_all.command           # 运行全量单元测试
./scripts/clean_builds.command       # 清理过期 .build-* / .build-cache-*（加 --all 清理全部）
```

阶段二完整验收使用单一入口：

```bash
./scripts/validate_stage2.command \
  --sample-dir "/path/to/example-graph"
```

不传参数时只会检查仓库父目录中的 `example-graph`，不会回退到其他样例目录。
该入口依次执行平台检查、全量测试、Debug 与 Release/App 构建、App 包检查、
标准样例 Smoke，以及固定 500 个 512×512 文件的性能门槛；任一步失败都会返回非零状态。

使用仓库外的标准样例执行可靠性 Smoke：

```bash
cd native/SXMBrowserNative
swift run -c release SXMBrowserSmoke \
  --canonical-sample "/path/to/example-graph"
```

该检查要求样例精确包含 6 个标准 SXM 和 18 个标准 DAT 文件，并会验证所有
SXM payload、默认矩阵、谱图数据、内置调色板以及首图渲染。检查不再猜测当前
目录中的样例位置；缺少文件、存在解析问题或关键结果为空时都会返回非零状态。

原生性能快速检查：

```bash
cd native/SXMBrowserNative
swift run -c release SXMBrowserBenchmark \
  --files 500 \
  --width 512 \
  --height 512 \
  --trials 5 \
  --max-scan-ms 1000 \
  --max-image-ms 100 \
  --max-thumbnail-ms 100
```

基准会在本机临时目录生成可复现的 500 个 512×512 SXM 文件；fixture 生成与
校验不计入时间。扫描、未缓存首图和未缓存首缩略图各预热一次后采样 5 次，
输出全部样本和中位数，并在任一中位数超过门槛时返回非零状态。性能门槛仅在
Apple Silicon、macOS 14+ 的 Release 构建中执行。

## 版本与备份检查点

每个可独立测试和回退的逻辑修改使用一次检查点流程：

```bash
./scripts/version_checkpoint.command "修改摘要"
# 运行对应测试，并精确暂存、提交本次逻辑修改
./scripts/backup_checkpoint.command "已通过的测试摘要"
```

版本脚本会同时预生成并校验 `Info.plist` 与 `CHANGELOG.md`，确认上一提交已有
可验证 Bundle 后才发布构建号；重复执行不会再次递增。备份脚本只接受已提交、
非 detached HEAD、测试摘要非空且清单为标准 TSV 的状态。Bundle 会先在事务
目录验证，再通过可恢复收据发布；异常中断后重新运行备份脚本会先完成已有事务，
不会重复创建记录。锁只会自动回收本机上能够确认原进程已退出的记录，其他锁应
先人工检查，不能直接删除。

旧清单的字面 `\t` 分隔符只通过显式迁移处理：

```bash
./scripts/migrate_backup_manifest.command --check
./scripts/migrate_backup_manifest.command --apply
```

`--check` 只校验并报告，不修改清单；`--apply` 会先在备份根目录永久保存一份
按原始 SHA-256 命名的逐字节副本，再原子发布标准 TSV。正常备份不会隐式迁移
旧清单。检查点脚本的临时仓库故障与恢复测试可单独运行：

```bash
./scripts/tests/checkpoint_workflow_test.command
```

语义版本 annotated tag、包含该精确 tag object 的 Bundle 和标准样例都准备好后，
使用恢复演练生成里程碑源码包：

```bash
./scripts/milestone_checkpoint.command \
  v2.5.0 \
  --sample-dir "/path/to/example-graph"
```

脚本会从标准清单自动选择最后一个包含相同 annotated tag object 的 Bundle，
克隆后执行完整文件系统检查、tag checkout 和阶段二验收，再从恢复仓库的 tag
生成不含构建物、App、缓存、样例或旧备份的源码 ZIP。ZIP 和清单使用同一套
可恢复事务发布；中断后重新执行会先完成原事务，不会生成重复记录。

原生源码在：

```text
native/SXMBrowserNative
```

包含 4 个核心代码目标：`SXMBrowserCore`（解析 / 数值拟合 / sRGB 渲染 / 调色板）、`SXMBrowserAppCore`（缓存 / 并发门控 / 元数据持久化）、`SXMBrowserNativeUI`（`@Observable` 域控制器与模块化视图）与 `SXMBrowserNative`（轻量 `@main` 入口），以及 `SXMBrowserSmoke`、`SXMBrowserBenchmark` 验收工具。架构基线与后续演进路线见 [ROADMAP.md](ROADMAP.md)。

当前原生版已包含：文件夹与 `.sxm` 文件拖放导入、按文件名/记录时间/修改时间排序、侧栏右键应用内 `Open`、缩略图网格、单图自适应缩放、`:SCAN_DIR: up` 纵向方向归一化、按通道类型区分的默认配色与处理规则、channel/正反扫/processing/全局 STM 调色板切换、全链路 sRGB 色彩管理、谱图 `.dat` 全通道解析与 X/Y 通道切换、标签与数据集元数据持久化及导入导出、Inspector 风格 Color Scale（支持 SI 单位与科学计数法）、可拖动 Histogram、纯 PNG 导出。

也可以直接把包含 `.sxm` 的文件夹拖到窗口中打开；拖入单个 `.sxm` 文件时，会打开它所在的文件夹并选中该文件。在侧栏右键条目选择 `Open`，可直接在应用内切换至 Single 大图视图。

常用快捷键：

- `Cmd+O`：打开文件夹。
- `Cmd+F`：聚焦左侧文件名搜索框（同时匹配 `.sxm` 与关联 `.dat`，支持 100 ms 防抖与 `Escape` 清空）。
- `Cmd+A`：焦点位于搜索框或数值输入框时全选文本；否则全选当前可见 `.sxm` 文件。
- `Cmd+Delete`：将选中的 `.sxm` 文件移入废纸篓（确认后执行，并同步清理标签、手动谱图关联与轴偏好元数据）。
- `Cmd+Option+1`：显示/隐藏左侧文件栏。
- `Cmd+Option+2`：显示/隐藏右侧 Inspector。
- `Cmd+Option+0`：恢复默认布局。
- `Cmd+Shift+E`：导出当前 PNG。

## 已有功能

- 扫描文件夹中的 `.sxm` 文件与 `.dat` 谱图文件，支持按记录时间、修改时间、文件名排序，支持与 `.sxm`、关联 `.dat` 搜索联动。
- 网格缩略图（自适应密度 120 / 160 / 220 pt）和单图大图浏览。
- 标准 File / Edit / View 菜单与可定制的原生紧凑工具栏，窗口标题和控制按钮在顶部同一行显示；工具栏提供全局 STM 预览调色板选择器与聚合缩放预设菜单（Fit、100% 等）。
- 原生可拖动分栏；窗口变窄时自动收起侧栏，放大后恢复，手动显隐和宽度偏好独立保存。
- 轻量交互动效：手动侧栏显隐、网格/单图切换、缩略图悬停与选中、标签和谱图面板展开、通知提示使用短过渡；遵循 macOS“减少动态效果”，图像操作与分栏拖动保持实时响应。
- 内容区支持最小 680×480 点；Single 下方折叠谱图抽屉随可用高度收缩，避免挤占主图。
- Single 图像渲染与缩略图、工具栏调色板色块、PNG 导出全链路采用显式 **sRGB** 色彩空间；Single 主图采用线性缩小过滤 + 最近邻放大以消除缩放摩尔纹；右下角自适应 `1-2-5` 比例尺带柔和暗色描边阴影，在亮色或反转背景上仍清晰可读。
- 自动在解码阶段对 `:SCAN_DIR: up` 扫描矩阵执行纵向翻转归一化，使物理 `+Y` 方向始终朝上，并与 `.dat` 测量点位坐标保持一致。
- 自动识别恒高模式下的频偏通道；支持切换 channel、forward/backward、配色及多种非线性/线性处理（`Raw`、`Subtract average`、`Subtract slope`、`Subtract linear fit`、`Differentiate`、`Plane linear fit`），不改写原始 SXM 文件。
- 按通道类别设置默认配色与处理：
  - **Topography（`Z` / `Height` / `Topography`）**：默认 **Dusk Violet** + `Plane linear fit`（`Double` 精度全图最小二乘平面拟合扣除）。
  - **Conductance / Current（`Current`、`dI/dV`、`LI Demod` 等）**：默认 **Dusk Violet** + `Raw`，避免对非高度通道误做平面扣底。
  - **AFM / PLL（`Frequency Shift`、`Amplitude`、`Excitation`、`Phase`）**：默认 **Basic gray** + `Raw`。
  - 可选配色包括 **Dusk Violet**、**Ink Violet**、**Ember** 与 **Basic gray**。
- 解析 `.dat` 谱图文件的全部数据列，可在右栏按实验类型与列结构组切换并持久化 X/Y 轴、可见性与手动 SXM 关联；图上以彩色实心圆点标示测量位置并与当前聚焦谱图联动。
- 支持基于安全域书签的数据集标签管理（重命名、删除、拖拽排序、原子元数据存储及导出/预览/安全导入）。
- 右栏提供 Inspector 风格的 Color Scale 和 Histogram：`Full` / `1-99%` / `σ` 色阶、`Invert`、bins、直方图与纯 PNG 导出；色阶输入框支持科学计数法及 `p`、`n`、`u`、`µ`、`m`、`k`、`M`、`G` 等 SI 单位后缀，输入过程中不会被后台状态刷新覆盖。
- 导出当前配色与处理后的纯 PNG 图，不带标题、坐标轴、scale bar 或色条。

## 性能策略

- 采用 `SXMBrowserNativeUI` 模块分层与 macOS 14 `@Observable` 细粒度域控制器（`DatasetSessionController`、`ImageViewerController`、`SpectroscopyController`、`ThumbnailPipeline`），配合版本号缓存的 `sortedFiles` 与 `visibleFiles` 派生列表，消除无关视图树广播重绘与单帧重复排序。
- 扫描文件夹时只读取 `.sxm` header 和通道元数据，不预加载图像矩阵。
- `.dat` 谱图解析采用 64 MiB 文件上限与 256 KiB 头部预检（在整文件读取前过滤二进制 NUL 与异常大文件），并使用锁保护的共享 `POSIXDateParser` 避免高频分配 `DateFormatter`。
- 图像、直方图和导出只在需要时按文件读取；`RenderCoordinator.ProcessedPayload` 仅保留处理后显示矩阵与统计量，降低 50% 活动大图矩阵内存占用；大尺寸缩略图（> 2× 目标尺寸）在全矩阵完成处理与自适应色阶计算后再执行支持有限值的箱式下采样，并在 sRGB `CGContext` 中完成线程安全缩放。
- 缩略图调度采用视口优先的后进先出并发门控（`AsyncLimiter(limit: 4, order: .lifo)`）与多等待者引用计数取消；网格卡片通过 AppKit `InstantClickOverlay` 实现零延迟单击选中与双击进入 Single 视图；批量移入废纸篓操作在后台执行并带并发忙锁保护。
- 最近使用的数据文件、缩略图与 PNG 渲染结果采用有界缓存，在文件删除或修改时间变化时准确失效。
- 网格模式下 Color Scale 和 Histogram 不生效，避免拖动色阶时重绘大量缩略图。
- 性能基准使用确定性大端 SXM 数据和稀疏 payload，避免依赖用户样例、机器路径或占用约 500 MiB 的实际磁盘空间。

## 当前限制

- 当前支持 Nanonis 大端序单精度浮点（`FLOAT MSBFIRST`）`.sxm` 扫描文件与 ASCII `.dat` 点谱文件（`.dat` 单文件上限 64 MiB）；暂不支持 `.3ds` 网格谱及整型/小端序 `.sxm` 编码。
- 原生应用需要 Apple Silicon 与 macOS 14 或更高版本；旧 WebUI/Python 服务已移除。
