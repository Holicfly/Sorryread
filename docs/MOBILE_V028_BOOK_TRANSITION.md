# 手机端 0.2.8 开合书动画修复

日期：2026-10-28。版本：0.2.8+10。仅书架收藏、最近阅读的开合转场；阅读器内部 PaperCurlPainter、书架排布和同步数据策略未在本次修改。

## 实现

1. 左书脊为轴，正向 Y 旋转 0～90 度。右侧自由边的齐次 w 小于书脊，透视上更近、更大。透视系数为 0.16 / 封面平面宽度，最大放大限制约 1.19 倍；不超过 90 度，不出现镜像。纸面先画、封面后画。
2. 600ms 开、合时长一致；开书 easeOutCubic，合书 reverseCurve=easeInCubic，使合书也从快到慢沿同一几何路径返回。点击不再等待大图解码。
3. 空闲时预取素材、预渲染可见封面；最多缓存 6 张 768 像素宽封面。未命中或捕获失败时使用静态组件回退，不阻塞点击。动画期间只更新变换矩阵。
4. 打开期间使用稳定空白纸面，最后一个转场帧绘制完成后才挂载 ReaderPage 并开始正文加载。合书捕获已经绘制的纸面图层，固定阅读页尺寸、MediaQuery 和书架系统栏参数，避免正文、工具栏、刘海/系统栏变化导致重排跳位。
5. 原生窗口持续允许刘海区域绘制，SafeArea 继续负责书架的原有避让；阅读切换仅改变系统栏可见性。该项消除了之前首帧约 20ms 的布局峰值。
6. 返回立即 pop；当前阅读位置同步捕获后交给既有保存队列，持久化和转场并行。TransitionRoute.completed 在覆盖层移除后才释放书架冻结，无固定 600ms 延时。

## 自动化与画面

- flutter test：120 通过、4 跳过（原有在线/可选测试）。
- flutter analyze：No issues found。
- book_opening_test.dart 保留并加强：自由边向观察者方向、放大上限、正面不镜像、封面绘制在纸面前、静态封面组件复用、正文延迟挂载、合书冻结、首尾矩阵一致、路由覆盖层完成回调。
- 新增系统栏/窗口尺寸变化期间的回归测试，验证纸面矩阵与阅读页 MediaQuery 不变。
- book_opening_visual_test.dart 输出打开及关闭各 5 帧，位于 artifacts/book-opening-v028/frames。测试环境仍使用测试字体回退，字形不代表实机；这里只核对几何与绘制关系，实机截图中文字正常。
- 实机录屏：artifacts/book-opening-v028/production-animation.mp4；开、合帧条及正式版截图位于同目录。

## 实机性能证据与边界

设备：2509FPN0BC，Android，系统刷新率约 120Hz。独立 .profile 包运行真实 ReaderApp/ReaderPage，正文为 140 段中文固定样本，排除网络波动；原生指针点击及返回触发，没有 WidgetTester 合成时钟。收藏、最近阅读各 4 次开/合，共 16 段转场、1164 帧。

| 指标 | 中位数 | P99 | 最大值 | 超过 16ms |
| --- | ---: | ---: | ---: | ---: |
| UI/build | 0.293ms | 1.547ms | 3.337ms | 0 |
| Raster | 1.001ms | 1.641ms | 9.013ms | 0 |
| FrameTiming totalSpan | 1.886ms | 6.767ms | 16.257ms | 1 |

转场实测约 601.9～610.0ms（含帧边界），无 Flutter 异常。原始数据 device-performance.json；易读摘要 performance-summary.json；采样程序 mobile/test_driver/book_transition_profile.dart，主机操作 measure-phone.py。计时取 Flutter 引擎 FrameTiming，与 DevTools 使用的 UI/Raster 数据来源相同；本次末轮数值来自该原始采样文件，未把它冒称为导出的 DevTools timeline。totalSpan 包含等待/调度，与 UI/Raster 两项耗时分开报告。当前满足该设备样本的 UI/Raster <16ms 目标，不宣称全部中端机或 120Hz 零丢帧。

正式版另用真实本地书籍执行 5 组开合，最近阅读的正文成功显示，并再次进入两次，正文和位置一致。前两次收藏书在截取的 1.6 秒窗口中仍在加载章节，因此不把它们计为网络正文加载成功；加载圈只在打开转场完成后出现。

## 安装与交付

- adb install -r 返回 Success；正式包 com.sorryread.sorryread_mobile，versionCode=10，versionName=0.2.8。
- firstInstallTime 保持 2026-10-26 11:31:07，未卸载正式版。书架确认收藏 3、最近阅读 10、HOLICFLY 配对/连接保留。
- APK：artifacts/Sorryread-Android-0.2.8-book-opening-smooth-update-arm64.apk。
- 大小：123646701 字节；SHA-256：5174a47dc381c509b0d5e4d2045a535112f210a46ac667499a4fbf406453082c。
- 签名证书 SHA-256：04a63a8c84c5af33ee94f4524914e9e39164581ca990fafa32feee7e2eb8ab4c，与前版一致。
- 下载：https://gofile.io/d/3H2sthyi 。浏览器确认文件和 Download 按钮，并完成一次实际下载；下载文件 SHA-256 与本地 APK 相同。云端并非永久存储，不保证长期保留。
