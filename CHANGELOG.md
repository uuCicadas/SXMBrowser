# Changelog

All notable local builds of SXM Browser are recorded here.

## Unreleased

- Simplify image measurement markers to solid dots matching their spectrum colors, with a slightly larger dot for the focused spectrum.
- Rename Subtract average + slope to Subtract linear fit and retain small fit residuals when subtracting a large baseline.

## 2.3.0 - 2026-08-26

- Build 85 (2026-11-04): Smooth pane show/hide and image zoom: defer viewport-derived SwiftUI updates while panes animate, build grid items once per data change instead of per layout pass, and composite the single-image canvas and thumbnails with layer-backed views.
- Build 84 (2026-10-26): Move the Single viewer scale bar to the lower-right image corner and remove the mouse-following probe reticle and continuous hover sampling.
- Build 83 (2026-10-26): Remove the Single viewer's upper-right data probe card and restyle its lower-left scale bar as centered white text above a solid white line, without a panel or end caps; retain zoom-aware physical scale lengths.
- Build 82 (2026-10-26): Adopt the approved Blue Violet preview with 5% stronger shadow lightness differences and a further 5% reduction in perceptual chroma relative to Build 81; preserve Plane linear fit as the STM default.
- Build 81 (2026-10-26): Use Plane linear fit by default for STM; stabilize the full-image least-squares fit and preserve small residuals with Double subtraction. Refine Blue Violet with slightly brighter low/mid tones and 3% lower perceptual chroma, preserving monotonic luminance and other palettes.
- Build 80 (2026-10-25): Combine window title and controls into a single compact native toolbar
- Build 79 (2026-10-25): Adopt native customizable toolbars and split panes, organize standard menus, and adapt the window and spectroscopy drawer to smaller sizes
- Build 78 (2026-10-25): Restore the compact system title bar and move pane toggles into the content toolbar
- Build 77 (2026-10-25): Set Blue Violet as the STM default, add optional Deep Blue, and preserve AFM Basic gray
- Build 76 (2026-08-26): Use raw full-range preview defaults and add Nanonis-compatible display processing

## 2.2.0 - 2026-07-25

- Build 75 (2026-07-25): Finalize the v2.2.0 palette replacement release
- Build 74 (2026-07-25): Remove legacy palettes and make Flame the STM default
- Build 73 (2026-07-25): Prepare SXM Browser 2.2.0 release after full automated and manual acceptance
- Build 72 (2026-07-25): Improve keyboard navigation, focus handoff, VoiceOver semantics, and high-contrast selection states
- Build 71 (2026-07-25): add structured Inspector file and scan metadata
- Build 70 (2026-07-25): add adaptive 1-2-5 screen scale bar with pure PNG isolation
- Build 69 (2026-07-25): add request-safe data probe with physical coordinates
- Build 68 (2026-07-25): Add Fit, 100 percent zoom, bounded pan, and responsive viewer controls
- Build 67 (2026-07-25): Add accessible color and line-style spectrum encoding
- Build 66 (2026-07-25): Link spectrum legend, markers, and sidebar focus
- Build 65 (2026-07-25): add persistent collapsible Single spectroscopy drawer
- Build 64 (2026-07-25): add independent Single spectroscopy drawer state
- Build 63 (2026-07-25): retain hidden spectra in canonical groups
- Build 62 (2026-07-25): structure primary and multi-selection actions
- Build 61 (2026-07-25): add window banners and success toasts
- Build 60 (2026-07-25): 建立文件夹与单图 idle、loading、ready、failed 状态和恢复操作
- Build 59 (2026-07-25): 以 120、160 和 220pt 密度自适应网格并同步键盘列步长
- Build 58 (2026-07-25): 为 SXM 与关联 DAT 搜索增加 100ms 防抖、结果计数和 Escape 清空
- Build 57 (2026-07-25): 按 760、900 和 1200 像素切换侧栏与检查器布局
## 2.1.0 - 2026-07-25

- Build 56 (2026-07-25): 准备数据管线、缓存与持久化版本 2.1.0
- Build 55 (2026-07-25): 从精确标签 Bundle 恢复验收并事务发布里程碑源码包
- Build 54 (2026-07-25): 自动复现 Au1110419 到 Au1110420 的迟到渲染回归
- Build 53 (2026-07-25): 按实验类型和标准化列结构隔离谱图与轴偏好
- Build 52 (2026-07-25): 收紧缺失清单、分离头与恢复副本校验边界
- Build 51 (2026-07-25): 使版本与备份检查点支持原子恢复和标准 TSV 清单
- Build 50 (2026-07-25): 新增阶段二严格一键验收入口
- Build 49 (2026-07-25): 建立可复现的 500×512 Apple Silicon 性能门禁
- Build 48 (2026-07-25): enforce the canonical six SXM and eighteen DAT smoke contract
- Build 47 (2026-07-25): route app rendering through the shared coordinator
- Build 46 (2026-07-25): add injectable single-flight render coordinator
- Build 45 (2026-07-25): surface persistent metadata warnings with retry and details
- Build 44 (2026-07-25): add metadata export import preview and atomic apply workflow
- Build 43 (2026-07-25): plan safe metadata imports with stale-state protection
- Build 42 (2026-07-25): define portable strict metadata transfer format
- Build 41 (2026-07-25): persist stable per-group spectrum axes
- Build 40 (2026-07-25): persist per-spectrum visibility without data loss
- Build 39 (2026-07-25): persist manual spectrum associations safely
- Build 38 (2026-07-25): add deterministic tag sorting and typed drag reorder
- Build 37 (2026-07-25): add durable tag rename and delete workflows
- Build 36 (2026-07-25): migrate and persist tags with stable identities
- Build 35 (2026-07-25): connect stable bookmark-backed folder sessions
- Build 34 (2026-07-25): add stable dataset path and session coordination core
- Build 33 (2026-07-25): add safe idempotent legacy tag migration core
- Build 32 (2026-07-25): preserve bookmark and dataset identity across folder moves
- Build 31 (2026-07-25): add atomic application support metadata store
- Build 30 (2026-07-25): add validated versioned dataset metadata models
- Build 29 (2026-07-25): coalesce byte-accounted matrix loads
- Build 28 (2026-07-25): add byte-accounted matrix cache primitives
- Build 27 (2026-07-25): propagate cancellation through parsing and rendering
- Build 26 (2026-07-25): rebin histograms without rerendering images
- Build 25 (2026-07-25): reuse matrix statistics across histogram bins
- Build 24 (2026-07-25): bundle immutable machine-independent palettes
- Build 23 (2026-07-25): keep independent spectroscopy axes per group
- Build 22 (2026-07-25): partition spectra by compatible column schema
- Build 21 (2026-07-25): require complete finite DAT rows
- Build 20 (2026-07-25): surface SXM and DAT scan diagnostics

## 2.0.1 - 2026-07-25

- Build 19 (2026-07-25): prepare reliability and file-safety release 2.0.1
- Build 18 (2026-07-25): verify tagged milestone source archives
- Build 17 (2026-07-25): preserve constant-matrix statistics and midpoint colors
- Build 16 (2026-07-25): add strict Recorded Time sorting with missing values last
- Build 15 (2026-07-25): validate SXM dimensions, byte layout, and MSB storage
- Build 14 (2026-07-25): show exact Trash targets and reconcile partial deletion results
- Build 13 (2026-07-25): gate rendered frames by dataset, file, request, and configuration
- Build 12 (2026-07-25): preserve browser mode during bounded navigation
- Build 11 (2026-07-25): unify sidebar and grid selection within visible files
- Build 10 (2026-07-25): add unified, testable selection state
- Build 9 (2026-07-25): Added Swift Testing infrastructure and a portable all-tests runner.
- Build 8 (2026-07-25): Added automated build-number checkpoints and verified Git Bundle backups.
- Build 7 (2026-07-25): Made project paths, sample discovery, build caches, smoke checks, and benchmarks portable across local workspaces.
