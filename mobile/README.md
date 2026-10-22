# 素若阅读 · Android

Flutter 手机端的独立工程，与根目录 WPF 客户端共用一个 Git 仓库。

当前只包含页面框架：底部书架／我的导航，三列示例色块书架，个人资料、统计、电脑同步及设置分组占位。只有底部导航可切换；筛选、书籍、同步、设置均未接入业务。没有书架导入卡片、发现页或右上角功能按钮。示例书籍仅存于内存，不读取桌面数据。

开发前先读 [跨端约定](../docs/CROSS_PLATFORM_DEVELOPMENT.md)、[Flutter 技术方案](../docs/FLUTTER_TECHNICAL_PLAN.md) 和 [本阶段实施与验证](../docs/MOBILE_FRAMEWORK_PROGRESS.md)。

## 工具链

初始化使用 Flutter **3.47.7 stable**（revision `abaf9c523780a608bd46686fd5e53740a07077f8`）、Dart **3.13.5**。使用同版本 SDK 还原工程，依赖由 `pubspec.lock` 锁定。Android 最低 API 26；compile/target SDK 使用该 Flutter 版本的默认值。

Flutter、Android SDK、JDK 安装在仓库外。先通过 `flutter doctor -v` 检查工具链；不要提交 `android/local.properties`、本机路径和密钥。当前 Release 沿用模板调试签名，仅用于本地验收，不用于应用商店发布。

## 构建与检查

在 **mobile/** 下执行；以下命令要求 Flutter 已加入本机 PATH：

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
flutter analyze
flutter test
flutter build apk --debug
flutter run -d <设备ID>
```

真机流程检查：

```powershell
flutter test integration_test/app_smoke_test.dart -d <设备ID>
```

在真机流程检查中保存实际页面截图（写入仓库根目录 `artifacts/mobile-framework/`，不提交到 Git）：

```powershell
flutter drive --driver=test_driver/screenshots.dart --target=integration_test/app_smoke_test.dart --dart-define=CAPTURE_SCREENSHOTS=true -d <设备ID>
```

测试目标会覆盖构建目录中的 APK；交付前重新执行 `flutter build apk --debug`，确保安装包入口为 `lib/main.dart`。

调试包：`build/app/outputs/flutter-apk/app-debug.apk`。

为 arm64 手机生成较小的本地 Release 验收包（沿用开发签名）：

```powershell
flutter build apk --release --target-platform android-arm64
```

产物为 `build/app/outputs/flutter-apk/app-release.apk`。单架构包仅适合相应 CPU 的设备；首次分发前仍须配置正式签名。Debug、Release 包体不可混作同一性能口径。

## 代码入口

| 位置 | 职责 |
| --- | --- |
| `lib/main.dart` | ProviderScope 和应用启动 |
| `lib/app/` | MaterialApp、go_router、两项导航与返回行为 |
| `lib/design_system/` | 亮暗主题、颜色角色、间距、卡片和占位标签 |
| `lib/features/bookshelf/presentation/` | 示例书架、静态筛选与内存示例数据 |
| `lib/features/profile/presentation/` | 个人资料、统计和分组列表占位 |
| `lib/features/sync/presentation/` | 两页共用的电脑同步占位卡片 |
| `test/` | 导航、返回、滚动状态、占位行为和布局边界测试 |
| `integration_test/` | 真机基本流程检查 |

新增业务时沿技术方案逐步增加应用逻辑和仓储层。Widget 不执行 SQL 或同步逻辑；本次不预建空数据库、连接服务或网络客户端。系统深色模式会自动切换主题，“主题外观”条目仍只是占位。

## 官方资料

- [Flutter 工程初始化](https://docs.flutter.dev/reference/create-new-app)
- [flutter_riverpod](https://pub.dev/packages/flutter_riverpod)
- [go_router](https://pub.dev/packages/go_router)
