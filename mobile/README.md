# 素若阅读 · Android

Flutter 手机端独立工程，与根目录 WPF 客户端共用一个 Git 仓库。当前版本 0.2.1，包含书架／我的页面，以及单设备局域网同步。手机阅读页尚未开放；资料、统计和其余设置继续占位。

开发前阅读 [跨端约定](../docs/CROSS_PLATFORM_DEVELOPMENT.md)、[技术方案](../docs/FLUTTER_TECHNICAL_PLAN.md)。本阶段的步骤、范围和验证记录见 [同步实施记录](../docs/DEVICE_SYNC_IMPLEMENTATION.md)，数据协议见 [Sync v1](../shared/contracts/device-sync-v1.md)。

## 使用

1. 两端接入可互通的局域网，打开新版电脑应用。
2. 电脑打开“设置 → 设备互联 → 二维码展示”。
3. 手机从书架或我的进入“与电脑同步”，点击“连接新设备”，允许相机权限并扫码。
4. 在电脑上确认连接，手机安全保存配对身份并自动双向对账。之后打开应用会自动连接；电脑复用保存的端口，IP／端口变化时手机通过 mDNS 的地址列表重新发现。前台失败重试间隔最多 30 秒。
5. 可点击“立即同步”和“查看同步记录”。“断开连接”保留配对，仅暂停本次运行；“重新连接”或下次启动恢复。“删除当前连接设备”撤销配对并保留阅读数据，可再连接新设备。电脑二维码窗口也可解除旧配对。

默认同步收藏、最近阅读、所有网页／章节阅读位置和相应移除操作，不传正文、目录文件、封面、设置、书签或笔记。书架已移除演示数据，展示真实同步元数据，继续使用三列封面色块。真正并发的阅读位置保留候选，需在同步页或电脑设备窗口选择。

前台自动对账；Android 后台任务按系统条件约十五分钟起调度，恢复前台补齐。电脑需保持运行；系统终止应用后不保证实时同步。连接受网络隔离、VPN 路由和 Windows 防火墙影响，请按系统提示允许该程序在可信私有网络访问，不必关闭防火墙或对公网映射端口。

## 工具链与构建

Flutter **3.47.7 stable**、Dart **3.13.5**，Android 最低 API 26。依赖由 pubspec.lock 锁定；SDK/JDK 在仓库外，禁止提交 local.properties、配对信息或签名私钥。Windows 下 Pub 缓存和工程位于不同盘时，已关闭不兼容的 Kotlin 增量路径缓存。

在 mobile/ 执行：

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release --target-platform android-arm64
```

产物为 build/app/outputs/flutter-apk/app-debug.apk、app-release.apk。Release 当前沿用开发签名，仅供本地验收；正式分发需配置正式签名。不要把测试目标 APK 当作应用交付，测试后重新构建 lib/main.dart。

## 测试

Debug 使用独立包名 com.sorryread.sorryread_mobile.dev，Release 仍为 com.sorryread.sorryread_mobile。测试脚本的 PackageName 参数默认指向 .dev。测试目标仅安装到开发包，避免覆盖正式应用的数据。flutter drive 默认在结束后卸载目标应用，验收命令显式使用 --keep-app-running；清理时只卸载本次创建的 .dev 测试包。

```powershell
flutter test integration_test/app_smoke_test.dart -d <设备ID>
flutter drive --keep-app-running --driver=test_driver/screenshots.dart --target=integration_test/app_smoke_test.dart --dart-define=CAPTURE_SCREENSHOTS=true -d <设备ID>
```

默认真机检查：两项导航、空书架、同步布局、原生摄像头启动、私有 SQLite 重开、安全存储读写和原生发现启动／停止。出现系统相机询问时在手机上允许。测试使用独立数据库和安全存储键，不导入用户业务数据。截图写到仓库 artifacts/device-sync-phone/。

显式设置 RUN_LIVE_SYNC=true 可测试真实 HTTPS、同步书籍、断开／启动恢复／删除配对；需要隔离 C# 测试服务端和新鲜二维码数据。test/sync_live_test.dart 通过 SORRYREAD_SYNC_TICKET 环境变量读取隔离服务票据，可在 Windows 验证跨语言冲突闭环。integration_test/lan_probe_test.dart 使用实际局域网地址，不允许回环地址，专门用于区分 USB 转发与无线网络联调。详细启动方式见实施记录。

扫码入口启动成功、图片解码、实际拿手机扫描屏幕是不同证据，测试报告分别记录。

## 代码入口

| 位置 | 职责 |
| --- | --- |
| lib/app/ | 启动、依赖注入、路由、两项导航 |
| lib/design_system/ | 亮暗主题、颜色角色、卡片 |
| lib/data/ | Drift／SQLite、原子事务、完整状态、待发送操作、日志 |
| lib/sync_engine/ | JSON 契约、因果合并、证书固定、双向同步 |
| lib/core/ | 原生局域网发现、Android 后台任务 |
| lib/features/bookshelf/ | 实际书架和收藏／最近阅读操作 |
| lib/features/profile/ | 资料、统计及设置占位 |
| lib/features/sync/ | 状态控制器、扫码、同步页、记录与冲突 |
| test/、integration_test/ | 共享契约、布局、持久化和真机检查 |

Widget 不直接执行 SQL 或网络同步；生产数据库通过后台连接打开。手机配对凭据由系统安全存储保护，Android 禁止应用数据备份。
