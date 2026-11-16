# SXM Browser — Windows 版（.NET 10 + Avalonia UI）

**SXM Browser Windows 版（`v2.6.0`）** 是面向 Nanonis 扫描探针显微镜（STM / AFM）实验的高速、严格只读 `.sxm` 扫描图像与 `.dat` 谱学检视器，1:1 对齐 macOS 原版 `v2.6.0` 的科学解析引擎、图像处理精度、交互工作流与元数据交换格式，并支持在 macOS 上直接交叉编译产出零依赖 Windows `win-x64` 便携分发包。

---

## 核心定位与设计原则

1. **严格只读实验数据目录**：打开任何 `.sxm` / `.dat` 文件夹时，**绝不向用户数据目录写入**任何隐藏文件、缓存或旁车元数据。
2. **原生 Windows Fluent 现代界面的科学视觉对齐**：
   - 采用 Avalonia UI `11.2.3` `FluentTheme`，完整复用并 1:1 映射 macOS `AppTheme` 科学深/浅色令牌（如网格舞台 `#1A1B1D / #F1F3F4`、`MissingDataBackdrop` `NaN` 透传棋盘格、28 种 Okabe-Ito 色盲友好曲线样式）。
   - 默认随系统切换深浅色主题，亦可通过顶部菜单 **`View -> Appearance`**（`Follow System` / `Light` / `Dark`）手动覆盖并持久化。
3. **内置 Gwyddion 官方默认 STM 配色**：
   - 新增官方 `Gwyddion.net` 默认色表（界面名称 **`Gwyddion`**），设为 **Windows 版 STM 通道（形貌 `Topography` / 电流与电导 `ConductanceOrCurrent`）默认检视配色**；
   - AFM / PLL 通道（如 `OC_M1_Freq._Shift`、`Δf`）默认使用 **`Basic gray`**；
   - 同时保留 **`Dusk Violet`**、**`Ink Violet`**、**`Ember`**、**`Basic gray`** 共 5 套完整色标，可在工具栏 **`STM:`** 色带选择器及 Inspector 中实时无闪烁切换。
4. **无极实时直方图与对比度调节**：
   - 在 Single View 下拖拽直方图 `Min` / `Max` 手柄或中段滑动窗口时，采用帧合并调度（Coalescing），保持当前已渲染矩阵与直方图不清空、不闪烁 `"Rendering..."`；
   - 支持 **Full / 1-99% / 2.5σ / Manual** 快速预设与 SI 单位输入（如 `-120p`、`2.5n`、`1.4µ`）。
5. **macOS ↔ Windows 元数据 100% 互通**：
   - 本地持久化位于 `%LOCALAPPDATA%\SXM Browser\`（`metadata-v1.json` 与 `preferences-v1.json`，非 Windows 开发环境隔离存储于 `~/.local/share/SXM Browser/`）；
   - 通过 **`File -> Export Metadata…` / `Import Metadata…`** 读写标准 **`com.sxmbrowser.dataset-metadata` (v1)** 格式，与 macOS `v2.6.0` 逐字节兼容，并支持标签、手动 `.dat` 关联、隐藏曲线与坐标轴偏好的冲突策略预览导入。

---

## 目录结构

```text
sxm-browser-windows/
├── SXMBrowser.sln                 # .NET 10 解决方案
├── Directory.Build.props          # 统一 net10.0、v2.6.0 版本与离线编译配置
├── nuget.config                   # 本地隔离 NuGet 缓存路径 (.nuget/packages)
├── README.md                      # 本文档
├── src/
│   ├── SXMBrowser.Core/           # 纯科学核心（零 UI 依赖）
│   │   ├── Resources/palettes.json# Gwyddion + 4 套原版校准色标
│   │   ├── SXMParser.cs           # Nanonis .sxm 头与 32 位大端矩阵解析、SCAN_DIR 归一化
│   │   ├── SpectroscopyParser.cs  # .dat 解析、SI 单位、6 级智能选轴、Schema 指纹
│   │   ├── SXMRenderer.cs         # PlaneLinear/Line 处理、Welford 统计、直方图、着色
│   │   ├── PngCodec.cs            # 显式 sRGB/gAMA/cHRM PNG 编解码
│   │   └── PaletteStore.cs        # 非均匀与均匀色标插值引擎
│   ├── SXMBrowser.AppCore/        # 会话、并发、缓存、元数据与科学坐标系
│   │   ├── AsyncLimiter.cs        # FIFO/LIFO 有界并发闸门
│   │   ├── MatrixLoadCache.cs     # 单飞去重 + 字节成本 LRU 缓存
│   │   ├── RenderCoordinator.cs   # UI 亲和渲染编排与陈旧请求丢弃
│   │   ├── DatasetMetadata*.cs    # 原子写入/校验/回滚存储与 v1 导出导入计划器
│   │   └── ViewerTransform.cs / ScaleBar.cs / ScientificPlotTicks.cs / AdaptiveGridLayout.cs
│   └── SXMBrowser.Desktop/        # Avalonia UI Windows 桌面应用
│       ├── Services/              # 偏好设置存储、SHFileOperationW 回收站、WriteableBitmap 桥接
│       ├── Theme/                 # AppTheme 深/浅色令牌与 SI 科学格式化器
│       ├── Controllers/           # AppModel 状态机、ThumbnailPipeline（LIFO 260px 缩略图）
│       ├── Controls/              # HistogramControl、SpectroscopyPlotControl、SingleImageCanvasControl
│       └── Views/                 # MainWindow、BrowserToolbar、SidebarView、GridBrowserView、SingleImageView、InspectorView、Dialogs
├── tools/
│   ├── SXMBrowser.Smoke/          # 标准样本 (example-graph) 契约验证工具
│   └── SXMBrowser.Benchmark/      # 500×512×512 SXM 扫描与渲染性能门禁工具
├── tests/
│   └── SXMBrowser.Tests/          # xUnit + Avalonia.Headless 全套单元与 UI 回归测试
├── scripts/
│   ├── test_all.sh                # 一键执行全部 14 项单元与无头 UI 测试
│   ├── smoke_check.sh             # 一键对标 example-graph 冒烟验证
│   ├── benchmark.sh               # 一键运行性能延迟门禁测试
│   └── publish_windows.sh         # 在 macOS 上交叉发布 win-x64 绿色便携目录与 ZIP 包
└── dist/                          # 本地发布的 Windows 免安装成品目录（不入 Git）
    ├── SXMBrowser-win-x64/
    └── SXMBrowser-win-x64-v2.6.0.zip
```

---

## Windows 部署与使用说明

### 1. 免安装便携版运行（推荐）
1. 将本目录下的 [`dist/SXMBrowser-win-x64-v2.6.0.zip`](file:///Users/wuziyou/Documents/Project/SXMBrowser/sxm-browser-windows/dist/SXMBrowser-win-x64-v2.6.0.zip) 复制到 **Windows 10 / 11 (x64)** 电脑；
2. 解压至任意目录（例如 `D:\Tools\SXMBrowser-win-x64`）；
3. **无需提前安装 .NET Runtime**，直接双击 **`SXMBrowser.exe`** 即可启动。

> [!TIP]
> 也可以将待检视的实验文件夹直接拖拽到 **SXM Browser** 窗口内打开，或通过命令行传入目录路径：`SXMBrowser.exe "D:\Data\2026-STM"`。

### 2. 删除与资源管理器集成
- **安全删除**：通过右键菜单或 `Delete` 键删除 `.sxm` 文件时，Windows 版调用系统原生 `shell32.dll` (`SHFileOperationW` + `FOF_ALLOWUNDO`) 将文件移入 **Windows 回收站**，误删可随时还原；且保存在本机的标签及元数据记录不会被盲目销毁。
- **在资源管理器中定位**：右键或通过 **`File -> Show in Explorer`** 即可在 `explorer.exe` 中高亮选中对应文件。

### 3. 本地数据路径
- **元数据与标签库**：`%LOCALAPPDATA%\SXM Browser\metadata-v1.json`
- **界面与配色偏好**：`%LOCALAPPDATA%\SXM Browser\preferences-v1.json`

---

## 常用快捷键一览

| 快捷键 | 功能 |
| --- | --- |
| `Ctrl+O` | 打开实验文件夹 |
| `Ctrl+Shift+R` | 重新扫描当前文件夹 |
| `Ctrl+1` / `Ctrl+2` | 切换 **Grid** 网格视图 / **Single** 单图检视视图 |
| `Enter` / `Esc` | 网格中进入单图视图 / 从单图返回网格（或清除选择） |
| `方向键` / `Shift+方向键` | 二维网格焦点移动 / 范围多选；单图模式 `←` / `→` 切换上一张 / 下一张 |
| `Ctrl+A` | 全选当前可见扫描文件 |
| `Ctrl+F` | 聚焦文件名 / 关联 `.dat` 搜索过滤框 |
| `Ctrl+0` / `Ctrl+9` | 单图缩放到适应窗口 (`Fit`) / `100%` 像素等大 |
| `Ctrl++` / `Ctrl+-` / `鼠标滚轮` | 以指针为中心放大 / 缩小（`>100%` 自动切换最近邻清晰显示像素晶格） |
| `Ctrl+Alt+S` / `Ctrl+Alt+I` | 显示或隐藏左侧边栏 (`Sidebar`) / 右侧检视面板 (`Inspector`) |
| `Ctrl+Shift+E` | 导出当前渲染与色标的 `sRGB` PNG 图像 |
| `Delete` | 将选中 `.sxm` 文件安全移入回收站 |

---

## 在 macOS 上开发、验证与交叉打包

本仓库已将全部 NuGet 与 `win-x64` 运行时依赖缓存在 `.nuget/packages/`，支持完全离线编译与发布：

```zsh
# 1. 运行全套单元测试与 Avalonia 无头 UI 回归测试（需先恢复或在本机常规终端执行）
./sxm-browser-windows/scripts/test_all.sh

# 2. 对标官方 example-graph 样本执行解析与渲染冒烟检查
./sxm-browser-windows/scripts/smoke_check.sh

# 3. 执行 500×512×512 扫描与首图/缩略图性能基准门禁测试
./sxm-browser-windows/scripts/benchmark.sh

# 4. 交叉发布零依赖 Windows x64 便携目录与 ZIP 压缩包至 dist/
./sxm-browser-windows/scripts/publish_windows.sh
```
