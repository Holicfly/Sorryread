# 阅读全屏、底部渐隐与书架菜单

日期：2026-10-27。目标版本：0.2.3+5。

## 用户确认的范围

1. 正文到屏幕底部逐渐融入当前阅读背景，底部信息不跟随淡出。
2. 保留左电量、中章节名、右时间的排列，压低信息栏高度。
3. 正文直通顶部，不预留状态栏／刘海避让；呼出后的操作菜单仍保留已有安全区定位。
4. 顶部菜单“添加到书架”执行收藏，“已在书架”执行取消收藏。
5. 使用用户提供的 `D:\ideai\素材\APP图标\素若阅读_APP图标_64x64_透明.png` 替换 Android 启动图标。
6. 不进行 USB 或真机测试，不上传云端；仅生成本地可覆盖更新的发布 APK。

## 步骤与依赖

| 步骤 | 输入 | 输出 | 验证 |
| --- | --- | --- | --- |
| 1 | 原有阅读布局、收藏接口、指定 PNG | 确定阅读区域、渐隐和信息栏尺寸 | 核对原有顶部最小 24 dp、底部间距 10 dp 与现有收藏接口 |
| 2 | 第 1 步尺寸 | 顶部间距 0、28 dp 渐隐区域、默认 16 dp 信息栏、底部间距 2 dp | 三种模式、亮暗背景、大字体，分页正文不落入遮罩 |
| 3 | 原有收藏数据 | 菜单显示实际状态并调用 `setFavorite` | 添加、取消、重复点击、外部数据刷新、退出再进入 |
| 4 | 指定原图 | 保存工程内母图及五档密度资源 | 核对 48/72/96/144/192 像素和解码像素 |
| 5 | 前四步结果 | 完整回归、截图、release APK | 静态分析、测试、Android 编译及包名／版本／签名核对 |

## 实现说明

- `reader_bottom_fade.dart` 只绘制底部小范围背景渐变，不使用整屏离屏 ShaderMask。
- 连续滚动正文可进入渐隐带；信息栏在渐变上方单独绘制，不影响清晰度与交互。
- 分页正文排版截止于渐隐带上方，带内显示下一页的开头预览；下一页仍完整显示该部分，因此不会因渐隐漏读当前页末行。仿真翻页动画期间不显示预览。
- 顶部手动内边距清零。Android 原生桥 `readerFullscreen` 在阅读时开启 cutout 绘制，退出时还原原有设置；API 30+ 使用 ALWAYS，API 28–29 使用 SHORT_EDGES。
- API 30+ 同时通过原生 `WindowInsetsController` 隐藏系统栏，支持边缘滑动临时呼出，退出阅读时恢复系统栏。这样在新 target SDK 下不只依赖 Flutter 旧的 immersiveSticky 模式。[Android 沉浸模式文档](https://developer.android.com/develop/ui/views/layout/immersive)、[cutout 文档](https://developer.android.com/develop/ui/views/layout/display-cutout)。
- 收藏状态选择性订阅书架数据中的布尔值，不因每次阅读位置变化重建阅读页；操作期间防止重复提交，失败保留原状态并提示。
- 图标生成脚本为 `scripts/generate_mobile_launcher_icons.py`，需 Pillow；原图备份为 `mobile/assets/branding/app_icon.png`。只按 Android 密度缩放，保留原图样式和透明度。

## 验证边界

- Widget 用例模拟顶部 44 dp、底部 24 dp 安全区，确认正文仍从 y=0 开始；覆盖仿真、滚动、无动画三种模式与亮暗背景。
- 新增收藏用例覆盖添加／取消、快速点击、仓库状态变化和阅读页重新进入；同时保留现有发现页及阅读器回归。
- 截图使用合成正文和工程内中文字体，路径为 `artifacts/reader-polish-preview/`。
- 原生窗口策略仅进行源码检查和 Android 构建验证。按照用户要求，没有在手机上安装、卸载、USB 调试或操作现有数据。

## 当前验证结果

- 完整 `flutter test --no-pub --dart-define=READER_POLISH_SCREENSHOTS=true`：94 项通过、2 项条件性在线测试跳过；本次未修改网络解析，因此没有重复在线抓取测试。
- `flutter analyze --no-pub`：无问题；`git diff --check` 通过。
- 指定图标母图像素逐一比对一致，五档资源为 RGBA、48/72/96/144/192 像素。
- 已查看亮暗模式渐隐及收藏菜单截图，分页本页正文保留完整，信息栏位于渐隐区下方。
- Release 构建成功：`artifacts/Sorryread-Android-0.2.3-reader-fullscreen-update-arm64.apk`，123349681 字节（约 117.6 MiB）。
- 通过 `aapt` 核对正式包名 `com.sorryread.sorryread_mobile`、versionCode=5、versionName=0.2.3；APK 不是 debuggable 构建。
- `apksigner verify` 通过，新旧包证书 SHA-256 一致：`04a63a8c84c5af33ee94f4524914e9e39164581ca990fafa32feee7e2eb8ab4c`，符合覆盖安装条件。
- 交付 APK SHA-256：`76ef1b82c3d3d58d815bd3ecdd94dea38dc91c35499ea3dd1319a04f847c0603`。报告：`artifacts/reader-polish-verification.json`。
- APK 内五档 launcher 图标已实际解包，核对尺寸、透明度及显示像素与工程资源一致。
