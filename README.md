# SXM Browser 工作区总览

本工作区用于开发与维护 **SXM Browser（`v2.6.0`）** 的双平台原生客户端——一款面向扫描探针显微镜（SPM / STM / AFM）实验的高速、只读 Nanonis `.sxm` 扫描图像与 `.dat` 谱学浏览工具，现同时包含 **macOS 原生版（Swift 6）** 与 **Windows 独立迁移版（.NET 10 + Avalonia UI）**。

---

## 目录分类说明

| 目录 / 文件 | 定位 | 说明 | 是否纳入 Git |
| --- | --- | --- | --- |
| [`sxm-browser-macos/`](./sxm-browser-macos) | **macOS 原生版（Swift 6）** | 原版 macOS 客户端、AppKit UI、`SXMBrowserCore` / `SXMBrowserAppCore`、性能基准与发版脚本 | 已纳入仓库 |
| [`sxm-browser-windows/`](./sxm-browser-windows) | **Windows 迁移版（C# / Avalonia 11）** | 跨平台桌面客户端、核心解码与科学渲染引擎、单元测试与打包脚本 | 已纳入仓库（`dist/` 与 `.nuget/` 本地忽略） |
| `examples/` | **实验与验证数据集** | 包含 `Au111*.sxm` 扩展样本及 `examples/example-graph/` 标准验证集（6 个 `.sxm` 与 18 个 `.dat`），供双端冒烟校验与测试读取（只读） | 本地保留（已在 `.gitignore` 中排除） |
| [`README.md`](./README.md) | **仓库总览文档** | 当前文件：说明项目目录结构、双平台互通特性与快速跳转 | 根仓库说明文档 |

> [!NOTE]
> **双端目录隔离与数据只读保护原则**：`sxm-browser-macos/` 与 `sxm-browser-windows/` 在同一仓库内采用物理隔离的子目录结构，互不干扰编译环境；双端客户端**绝不会向**实验数据文件夹写入任何隐藏文件或元数据文件。

---

## 双平台特性与数据互通

1. **1:1 科学算法对齐**：
   - `.sxm`（32 位大端浮点、`:SCAN_DIR: up/down` 垂直标准化、`Fwd/Bwd` 水平翻转、通道智能分类）与 `.dat` 多列谱学解析；
   - 双精度面线性拟合（`PlaneLinear`）、行扣除/求导（`LineMean` / `LineSlope` / `LineLinear` / `LineDerivative`）、`NaN` 透传棋盘格底图与显式 `sRGB` PNG 导出。
2. **STM 默认配色说明**：
   - **macOS 原版**：默认采用 `Dusk Violet`；
   - **Windows 迁移版**：内置并新增官方 **Gwyddion 默认配色（`Gwyddion.net`，界面显示名 `Gwyddion`）** 作为 **STM 通道（形貌 / 电流 / 电导）默认检视配色**，同时保留 `Dusk Violet`、`Ink Violet`、`Ember`、`Basic gray` 供实时切换；AFM / PLL 通道在双平台均默认使用 `Basic gray`。
3. **macOS ↔ Windows 元数据 100% 兼容**：
   - 两个平台共享完全一致的便携交换格式 **`com.sxmbrowser.dataset-metadata` (v1)**：可在一个平台上通过 `File -> Export Metadata…` 导出数据集标签、手动 `.dat/.sxm` 关联、隐藏谱线状态和坐标轴偏好 JSON 文件，并在另一平台无损预览与合并导入。

---

## 快速导航

- 查阅 macOS 原生版架构、特性与构建说明：[**`sxm-browser-macos/README.md`**](./sxm-browser-macos/README.md)
- 查阅 Windows 版本详细架构、功能操作、配色与绿色打包部署指南：[**`sxm-browser-windows/README.md`**](./sxm-browser-windows/README.md)
- Windows 本地绿色打包输出目录（本地忽略，发版请置于 GitHub Releases）：`sxm-browser-windows/dist/`
