# 手机端发现页实施记录

日期：2026-10-26。版本：0.2.2+4。

## 已确认的范围

- 底部导航为书架、发现、我的。普通发现页只实现界面，不请求普通书源，不生成示例记录。
- 连续点击顶部“发现”五次切换特殊模式，每次点击间隔不超过 800 ms；再次五次切回，重启恢复普通模式。与书架的独立切换方式一致。
- 特殊发现页使用 18mh 关键词搜索，并提供夜社小说列表入口。
- 结果只显示书名和进入阅读的箭头，分类只保留“全部”；接近底部时自动请求下一页，无翻页按钮。
- 夜社只支持其小说详情与章节 HTTPS 网址解析，不实现站内关键词搜索。章节网址直接定位指定章，普通结果入口优先恢复已有阅读位置。
- 成功加载阅读内容后，沿用阅读器保存位置和最近阅读，收藏由用户手动操作。夜社和 18mh 都属于特殊书架分组。
- 普通、18mh、夜社分别保留最多 50 条本地历史，支持删除和清空，不参与设备同步。夜社历史在“最近解析”中展开。
- 用户要求不进行手机 USB 调试或安装，交付可覆盖旧版本的正式包名 APK，由用户自行验收。

## 分步依赖与产物

| 步骤 | 输入 | 实现与输出 | 验证 |
| --- | --- | --- | --- |
| 1 | 现有路由、阅读器、真实网站 HTML | 确定 18mh 当前搜索节点及 `/page/N` 分页，夜社小说、目录及正文节点 | 实际 HTTP 请求，识别到列表、目录和正文 |
| 2 | 网站字段和现有 SQLite 本地元数据 | `DiscoverBook`、`DiscoverBatch`、三个隔离的历史记录接口 | 并发写入串行化、去重、重新创建接口后读取、删除、清空，不产生同步事件 |
| 3 | 数据模型和页面结构 | 搜索与列表解析、网址规范化、分页状态管理 | 严格限定同站同查询下一页，去重、失败重试、丢弃过期查询结果、末页停止 |
| 4 | 规范化的书籍与目标章网址 | 夜社阅读规则、`ReaderOpenRequest`、初始章节入口、特殊书架归类 | 目录剔除字数、正文剔除下一章按钮，指定章节覆盖已有位置，自动最近阅读，不自动收藏 |
| 5 | 数据和阅读接口 | 发现页、夜社入口、结果页、三项导航 | 五次双向切换、普通搜索占位、触底追加、返回阅读列表、大小屏和亮暗主题 |
| 6 | 完整实现 | 回归、在线核验、发布 APK | 见下方验证结果与安装核对 |

## 实现入口

- `mobile/lib/features/discover/data/discover_repository.dart`：搜索解析、历史持久化、分页状态和夜社网址处理。
- `mobile/lib/features/discover/presentation/discover_page.dart`：发现、历史、结果列表和阅读跳转。
- `mobile/lib/app/router.dart`、`mobile/lib/app/shell.dart`：第三个导航分支和阅读请求。
- `mobile/lib/features/reader/presentation/reader_page.dart`：指定章节初次定位，正常续读与后续目录跳转仍使用既有逻辑。
- `mobile/lib/features/reader/data/reader_source.dart`：夜社目录标题去除附带字数。
- `mobile/lib/data/sync_repository.dart`：特殊来源判断。历史复用本地 `sync_meta`，没有改变数据库版本或同步协议。
- `scripts/export_mobile_reader_rules.py`：保留原 14 项规则，再加入手机端夜社规则，重新导出不会丢失夜社。

## 已完成验证

- 完整 `flutter test --no-pub --dart-define=DISCOVER_SCREENSHOTS=true`：85 项通过，2 项按条件跳过。其中发现页在线用例已单独执行，跨语言同步在线用例需要隔离服务票据，本次未运行。
- 单独 `flutter test --no-pub --dart-define=DISCOVER_LIVE=true test/discover_live_test.dart`：通过。18mh 连续两页各 20 本，夜社连续两页各 30 本，两站末页均无下一页；示例小说解析 5 章目录及有效正文，未创建 WebView。
- `flutter analyze --no-pub`：无问题。
- `git diff --check`：通过。
- 界面用例使用合成书名和正文，加载真实字体截图；覆盖 390×844、320×640/200% 字体、844×390 横屏以及暗色模式。截图位于 `artifacts/discover-preview/`。
- 列表采用 Sliver 延迟构建；解析搜索 HTML 在后台 isolate 执行；失败保留当前页重试，滚动回调不会并发重复请求同一页。
- 从测试环境切回 release 时，发布构建使用完整 `flutter build apk --release --target=lib/main.dart --target-platform android-arm64`，不带 `--no-pub`；当前 Flutter SDK 在跳过依赖步骤时也跳过平台插件注册重建，可能残留仅测试使用的注册项，导致 release Java 编译失败。

## 安装更新核对

- 正式包名保持 `com.sorryread.sorryread_mobile`，无 `.dev` 或 `.profile` 后缀。
- `versionCode` 从 3 升至 4，`versionName` 从 0.2.1 升至 0.2.2。
- 沿用工程已有 release 签名配置；交付前使用 `apksigner verify --print-certs` 比较本地旧版和新版证书，使用 `aapt dump badging` 检查包名和版本。
- 本地旧版基准：`artifacts/Sorryread-Android-0.2.1-reader-footer-18mh-arm64.apk`。
- Release 构建完成，交付文件：`artifacts/Sorryread-Android-0.2.2-discover-update-arm64.apk`，123252405 字节（约 117.5 MiB）。
- 新旧 APK 签名均验证通过，证书 SHA-256 一致：`04a63a8c84c5af33ee94f4524914e9e39164581ca990fafa32feee7e2eb8ab4c`。更早的 `Sorryread-Android-0.2.1-arm64.apk` 也使用相同证书。
- `aapt` 确认新版正式包名、versionCode=4、versionName=0.2.2，且不是 debuggable 构建。交付文件 SHA-256：`1aeb70f1232a13981d6dcc0e16338a9103d8de947b269d5dc41cf4f4c914dc23`。
- 机器可读核对报告：`artifacts/discover-update-verification.json`。
- 没有执行卸载、清理手机数据、USB 安装或真机调试。手机上的系统安装过程、真实网络与连续阅读体验由用户验证。
