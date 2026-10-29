# 手机阅读页实施记录

日期：2026-10-23。范围仅为 mobile/ 阅读功能及书架入口；桌面、同步协议和其他页面保持现有行为。

以上为初版实施范围与下文验证快照；本轮阅读优化及用户另行确认的两端同步改进、最新验证和交付见 [阅读与同步改进实施](READER_SYNC_REFINEMENT.md)。

## 确认的交互

- 点书进入真实阅读，默认隐藏系统栏和工具栏；顶部仅返回和书名。
- 分页模式左／中／右三分区：上一页／切换工具栏／下一页。滚动模式任意点击切换工具栏，不触发翻页。
- 顶栏从上向下、底栏从下向上展开；底部保留上一章、章节内进度条、下一章和目录／夜间／设置。
- 设置为底部面板：阅读窗口亮度、暖色护眼、字号、同一行末尾字体入口、阅读配色、仿真／上下滑动／无动画。
- 无听书、独立字体行、图片背景、其他和自动阅读。底部常驻本机电量和时间。
- 正文按 HTML 段落解析，首行缩进两字，默认行高 1.8、段后距约 0.8 字；变化后以正文字符位置重新定位。
- 默认系统字体；提供宋体、黑体、楷体、思源黑体、霞鹜文楷。方正黑体／方正楷体使用用户本地字体导入，不随包分发无内置授权的文件。

## 依赖顺序

| 步骤 | 输入 | 输出／验证点 |
| --- | --- | --- |
| 1 | 桌面现有书源规则 | 手机目录／正文规则与合成解析样例 |
| 2 | 书架的真实链接 | 目录、正文段落、分页合并及错误重试 |
| 3 | 解析结果 | 私有缓存、阅读设置、语义位置保存 |
| 4 | 书架书籍 | 独立全屏路由、返回、系统栏恢复 |
| 5 | 正文段落 | 按屏幕分页、时间／电量状态栏 |
| 6 | 阅读页 | 点击分区和上下工具栏滑入／滑出 |
| 7 | 工具栏 | 目录、前后章、章节内进度 |
| 8 | 排版与设置 | 底部面板、亮度、护眼、字体、配色 |
| 9 | 排版结果 | 纸张翻页、连续滚动、无动画、位置恢复 |
| 10 | 完整功能 | 分析、测试、Android 构建和设备验证记录 |

## 字体来源

- 宋体：思源宋体；黑体：Noto Sans SC；楷体：霞鹜臻楷。
- 思源黑体：https://github.com/adobe-fonts/source-han-sans
- 霞鹜文楷：https://github.com/lxgw/LxgwWenKai
- 方正许可范围：https://www.foundertype.com/index.php/About/powerbus
- 开源字体按需下载、私有目录缓存；失败保留原字体并可重试，不把下载失败伪装成切换成功。

## 验证结果

- 已从桌面导出 14 个公开阅读规则，增加 CSS 组合与结构索引兼容；保留查询参数，处理多页目录、正文续页、Base64、GBK／GB18030 编码和隐藏内容。
- 分页以实际字体 TextPainter 行度量切片；已检查不同字号、布局宽度和长段落的连续覆盖。位置存储为段落、Unicode 标量偏移和正文哈希，比例作为旧数据兼容兜底。
- 正文与目录缓存位于手机私有 reading/ 目录；设置和本机位置不参与元数据同步。实际阅读动作通过现有 position 记录写回，不因打开目录、调字体或后台接收同步而生成新阅读位置。
- Android 调试构建已通过；设备自动检查确认：电量读取、GB18030 解码、设置保存、选章、位置恢复；真实我的书城网目录 238 项、首章 51 段／2397 个字符，关闭请求后缓存重开成功。此结果只覆盖本次书籍及网络时刻，其他书源未逐一在线验证。
- WPF/MSBuild 的 Compile、Content、Resource、Page、EmbeddedResource、None 实际收集结果中，mobile/ 与 shared/ 项为 0；桌面源代码与同步契约未修改。
- 最终 flutter analyze 无问题；flutter test 40 项通过，1 项需要独立 C# 在线同步服务票据的测试跳过。书架、导航、同步契约、解析、字号／宽度变化、十万字长段落、小屏 200% 字号、夜间及横屏布局均在通过项内。
- 五款开源字体的固定版本文件已实际下载并校验 SHA-256，在主机 Flutter 引擎中验证离线加载和中文排版；没有把主机验证表述为手机已逐一下载选用。方正文件由用户本机导入，未获取、打包或分发字体文件。
- 超长段落按实际行边界拆成不超过约 1200 个 UTF-16 单元的布局块；中间块不增加缩进或段距。连续滚动使用已测量的精确总高度，回归确认章节预加载前后位置不跳动，内存正文窗口最多三章。
- 真机自动检查及七张截图位于 artifacts/reader-phone/，截图使用合成正文；真实书源验证只保存数量和状态。日志为 artifacts/reader-analyze.log、reader-tests.log、reader-drive.log。
- Android Debug／arm64 Release 构建均通过。预览交付文件：artifacts/Sorryread-Android-0.2.1-reader-arm64.apk（38,907,556 字节）；调试检查文件：artifacts/Sorryread-Android-0.2.1-reader-debug.apk。沿用当前开发签名，未更改应用版本或发布流程。
- 集成测试／Debug 后首次使用 --no-pub 构建 Release，遇到自动插件注册文件遗留 integration_test 引用；flutter clean、flutter pub get 后重新构建 Release 已通过，无需修改业务代码或 SDK。测试手机已重新安装正常 main.dart 调试入口，未覆盖正式包、未清除用户数据库。
- 自动检查不能替代用户对卷页手感、主观舒适度和所有站点可用性的验收；本次没有全量书源在线验证和正式性能基准承诺。

复核命令（在 mobile/ 执行）：

```powershell
flutter analyze
flutter test
flutter drive --keep-app-running --driver=test_driver/reader_screenshots.dart --target=integration_test/reader_test.dart --dart-define=CAPTURE_SCREENSHOTS=true --dart-define=RUN_READER_LIVE=true -d <设备ID>
flutter build apk --release --target-platform android-arm64
```

可设置 SORRYREAD_FONT_CHECK_DIR 指向已校验的五款字体文件目录，启用额外字体文件加载检查；未设置时该项按说明跳过，不强制每次测试联网下载。
