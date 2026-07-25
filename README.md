# SXM Browser

本地工具，用来快速浏览 Nanonis `.sxm` 扫描文件。

## macOS 原生版

应用位于：

```bash
open "./SXM Browser.app"
```

它是 SwiftUI/AppKit 写的本地 macOS 应用，不启动本地网页服务，也不依赖浏览器。构建脚本：

```bash
./scripts/build_native_app.command
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

原生源码在：

```text
native/SXMBrowserNative
```

当前原生版已包含：文件夹导入、按文件名/修改时间排序、缩略图网格、单图自动适配缩放、默认通道/配色/处理规则、channel/正反扫/processing/palette 切换、谱图 `.dat` 全通道解析与 X/Y 通道切换、Inspector 风格 color scale、可拖动 histogram、PNG 导出。

也可以直接把包含 `.sxm` 的文件夹拖到窗口中打开；拖入单个 `.sxm` 文件时，会打开它所在的文件夹并选中该文件。

常用快捷键：

- `Cmd+O`：打开文件夹。
- `Cmd+Option+1`：显示/隐藏左侧文件栏。
- `Cmd+Option+2`：显示/隐藏右侧 Inspector。
- `Cmd+Option+0`：恢复默认布局。
- `Cmd+Shift+E`：导出当前 PNG。

## 已有功能

- 扫描文件夹中的 `.sxm` 文件。
- 按记录时间、修改时间、文件名排序。
- 网格缩略图和单图大图浏览。
- 自动识别恒高模式下的频偏通道。
- 切换 channel、forward/backward、配色、raw/平面处理。
- 默认配色：STM 类通道（Z/Current）用 Gwyddion.net，AFM/PLL 类通道（Frequency Shift/Amplitude/Excitation）用 Basic gray。
- 默认处理：STM 类通道用 Line linear fit，AFM/PLL 类通道用 Raw。
- 解析 `.dat` 谱图文件的全部数据列，并可在右栏为谱图切换 X/Y 通道。
- 右栏提供 Inspector 风格的 Color Scale 和 Histogram：Full/1-99%/σ 色阶、Invert、bins、直方图和 PNG 导出。
- 导出当前配色与处理后的纯 PNG 图，不带标题、坐标轴、scale bar 或色条。

## 性能策略

- 扫描文件夹时只读取 `.sxm` header 和通道元数据，不预加载图像矩阵。
- 图像、直方图和导出只在需要时按文件读取。
- 最近使用的数据文件和 PNG 渲染结果会用有限缓存保留，避免 500 个文件时占用过多内存。
- 网格模式下 Color Scale 和 Histogram 不生效，避免拖动色阶时重绘大量缩略图。
- 性能基准使用确定性大端 SXM 数据和稀疏 payload，避免依赖用户样例、机器路径或占用约 500 MiB 的实际磁盘空间。

## 当前限制

- 第一版只支持 `.sxm`。
- 当前项目只保留原生 macOS 应用；旧 WebUI/Python 服务已移除。
