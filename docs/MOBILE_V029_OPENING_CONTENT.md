# 0.2.9 开书期间显示正文与加载态

日期：2026-10-29。最终版本：0.2.9+12。

## 范围

只修改打开期间的纸面内容准备、展示及缓存。与 0.2.8 对照，BookOpeningGeometry、封面渲染代码块、CurvedAnimation 缓动代码完全相同；路由 600ms 开合时长、方向、原有关闭冻结的绘制逻辑保持。没有修改 PaperCurlPainter、书架布局或同步合并策略。

## 最终行为

- ReaderPage 从起帧就挂载，加载在首次依赖建立时启动，与动画并行。删除 book-stable-paper 纯色占位和“完成转场才挂载 reader”的条件。
- 未就绪时，加载控件绘制在纸面内部。纸面右边缘有加载轨道、转圈和文字，随着纸面一起变换，先露出的窄区域也有提示；完成转场后回到既有居中加载状态。
- 首次正文加载使用 ReaderLayout.prepare 的约 1ms 分批排版，完成后立即显示，不等待 AnimationStatus.completed。首次滚动视图直接以目标 initialScrollOffset 进入，避免先画章首再 post-frame 跳到保存位置。
- 正文首次就绪时，在纸面固定坐标中预绘制到图层，再参加动画变换，避免第一次直接以动态缩放比例生成字形。加载圈保持实时绘制；不等待转场完成。该路径参考 Flutter SDK SnapshotWidget 的 detached PaintingContext 方式；关闭仍复用已绘制图层。
- 会话缓存最多保留两个书籍的当前章、已排版 ReaderLayout、精确章内滚动偏移、字体设置和合书纸面的共享图像句柄。重新进入时从第一帧显示同一正文纸面；实际 ReaderPage 同时挂载并完成布局，转场结束时只是展示同一个子树，不二次加载和定位。
- 窗口、安全边距、DPR、文字缩放或更新的同步位置不匹配时，拒绝旧缓存；更改阅读设置会使其他缓存失效。不能比较且位置变化的旧客户端同步记录也会拒绝旧纸面。加载和错误继续使用现有规则。
- 如果上次曾呼出工具栏或退出时仍在内部翻页，不复用截图，避免把工具栏/半页截图带入下次打开；仍复用正确的正文排版。
- 固定打开期间的 MediaQuery 与全尺寸纸面，并将系统栏动画导致的边距变化隔离。保留原有安全边距，不通过将底部边距清零来掩盖重排。实际窗口/字号变化仍在正常阅读状态下处理。
- 合书仍捕获当前阅读面并冻结；额外保留共享图像句柄供下次打开复用，不另做一次 GPU 截图。缓存失效、淘汰及应用容器销毁均释放图像与 TextPainter。

## 验证

- 最终 flutter test：128 通过，4 跳过。
- flutter analyze：No issues found。
- reader_opening_content_test.dart：真实阅读页冷加载首帧提示可见；正文在转场结束前出现；完成不重载；同一次会话再次进入无转圈，复用同一个 ReaderBlock，精确滚动偏移一致；缓存纸面退出后，实际正文 Element 不重建。
- reader_resume_cache_test.dart：两本上限、单次所有权转移、窗口/安全边距/DPR/文字缩放失效、更新或不可比同步位置失效、阅读设置失效与资源释放边界。
- book_opening_test.dart 保留方向、透视上限、绘制层次、静态封面复用、首尾矩阵、关闭冻结、MediaQuery 稳定及路由完成回调断言；将旧的“打开期间不挂载 reader”改成“起帧挂载”。
- book_opening_visual_test.dart：打开/关闭各五帧及慢加载打开五帧，文件在 artifacts/book-opening-v029/frames。正文帧图可以看到露出的纸面已有文字；加载帧图可以看到露出右边缘的提示。测试环境封面默认字体仍有方框，不代表实机字体。

## 10-28 阶段采样（历史记录）

用户断开手机、停止后续实测前，独立 .profile 包采集了 16 段开合、1146 帧：首本目录人为延迟 1200ms 以验证慢加载；中途首次进入另一书籍验证快速加载；其余为会话缓存重开。真实 ReaderPage、140 段中文、文楷 22px、滚动模式、120Hz 设备，数据来自 Flutter FrameTiming；未用测试时钟模拟帧耗时。

| 指标 | 中位数 | P99 | 最大值 | 超过 16ms |
| --- | ---: | ---: | ---: | ---: |
| UI/build | 0.268ms | 3.251ms | 8.450ms | 0 |
| Raster | 1.004ms | 4.599ms | 17.811ms | 1 |
| totalSpan（含调度等待） | 2.331ms | 9.668ms | 123.392ms | 4 |

动画窗口约 601.6～612.2ms。缓存重开的 Raster 最高 9.328ms；另一书首次快速加载正文时约 265ms 处出现 17.811ms 单帧 Raster 峰值。当前不能宣称已完全达成“所有 UI/Raster <16ms”或“实机零丢帧”；原始数据 device-performance.json、摘要 performance-summary.json、采样控制 measurement.log 均保留，未删除不利样本。此前尝试的更早捕获图层、尚未复用合书图像的测量也保留在同目录。

10-28 阶段曾按用户要求断开手机、停止实测；当时没有安装最终正式包或卸载测试版。10-29 用户重新接入设备，明确要求验收后覆盖安装、卸载测试版，并取消下载链接交付。最终记录见下节。

## 10-29 最终实机验收

- 增加书架空闲时仅预读所选字体的设置文件并注册字体，点击不等待预加载。预加载不创建/持有/销毁阅读仓库，避免干扰搜索页面的仓库生命周期。对应增加预加载未完成仍能开书的回归测试。
- 首次开书约 100ms 的 UI 事件循环等待已从最终样本中消除。只有阅读字体被预加载，未预置或下载任何书目/正文。
- 打开正文的首次 paint 直接生成固定坐标图层，修复首次快速加载正文时的 Raster 峰值。没有改变封面、几何、方向、缓动或600ms路由时长。
- 最终测量覆盖慢加载（1200ms目录等待）、首次快速加载（另一书）、收藏与最近阅读缓存重开、反向合书。16 段转场，共 1163 帧，无 Flutter 异常。

| 指标 | 中位数 | P99 | 最大值 | 超过16ms |
| --- | ---: | ---: | ---: | ---: |
| UI/build | 0.262ms | 3.700ms | 6.658ms | 0 |
| Raster | 1.000ms | 4.572ms | 9.176ms | 0 |
| totalSpan | 2.172ms | 8.431ms | 11.233ms | 0 |
| vsyncOverhead | 0.676ms | 2.793ms | 4.577ms | 0 |

该设备这轮样本满足 UI/Raster <16ms 的验收条件，不扩大为全部机型或120Hz零掉帧保证。旧的17ms及更差样本均保留；数据在 artifacts/book-opening-v029/resume-1029/final-performance.json，摘要 final-summary.json，操作日志 prepaint-performance.log。

最终录屏 final-acceptance.mp4，以及 final-cold-strip.jpg、final-warm-strip.jpg、final-fast-strip.jpg 已逐段检查：冷加载露出的纸面有右侧加载提示；缓存重开露出的纸面已有正文；首次快速加载在转场中切换为正文；合书纸面内容稳定，卡片首尾对齐。录屏与计时分开进行，避免录屏开销混入性能数据。128项测试通过、4项跳过；flutter analyze 无问题。

## 安装包与设备交付

最终正式包使用既有包名 com.sorryread.sorryread_mobile、原签名，versionName=0.2.9，versionCode=12。支持从0.2.8+10或0.2.9+11覆盖更新。不上传或提供下载链接，按用户最新要求在本机覆盖安装后清理独立测试包。


- 最终 adb install -r 返回 Success。正式包实测 versionCode=12、versionName=0.2.9；firstInstallTime 仍为 2026-10-26 11:31:07。
- 设备界面确认收藏3、最近阅读10、配对信息保留；正式版再次进入同一本最近阅读，正文和位置恢复正常。证明截图 production-repeat-0.png、production-repeat-1.png；阅读正文区域的两帧哈希一致。
- com.sorryread.sorryread_mobile.profile 卸载返回 Success；pm list packages com.sorryread 仅剩正式包，.dev 未安装。
- 正式安装包：artifacts/Sorryread-Android-0.2.9-opening-content-tested-arm64.apk。
- APK SHA-256：08c2ab25968c71b6f62623da17a42a592ef8b62214bcb9282b15ce123bf224cc。
- 签名证书 SHA-256：04a63a8c84c5af33ee94f4524914e9e39164581ca990fafa32feee7e2eb8ab4c，与旧版一致。
- 本轮最终包未上传云端，没有提供下载链接。
