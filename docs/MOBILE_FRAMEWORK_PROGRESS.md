# Android 页面框架：实施与验证

日期：2026-10-22。本记录对应用户确认的首个页面框架阶段，不代表整个技术方案阶段 0 已完成。

## 范围确认

- Flutter Android 首发，正式工程位于 `mobile/`。
- 书架：三列封面色块和示例书名；保留全部／最近阅读／电脑同步占位。
- 我的：参照参考图保留资料卡、四项统计、电脑同步、常用功能和偏好与其他分组，以卡片和列表块占位。
- 底部仅书架／我的可切换；其余入口不绑定操作。两页右上角均无按钮，书架无导入卡片。
- 不实现阅读、书源、数据库、导入、配对、网络传输或实际同步，不修改桌面业务逻辑和现有用户数据。

开发准备已阅读 `docs/DEVELOPMENT.md`、`docs/CROSS_PLATFORM_DEVELOPMENT.md`、`docs/FLUTTER_TECHNICAL_PLAN.md`、`docs/素若阅读使用说明.txt` 及 `CONTRIBUTING.md`。用户本次确认的范围优先；技术方案中的后续功能不会在本阶段提前实现。

## 顺序与输出

| 步骤 | 输入 | 工作 | 输出及检查 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | 用户确认、开发文档、现有工程 | 核对范围、工具链、桌面基线 | 桌面 Debug 构建 0 警告、0 错误；确认本机 Flutter 和 Android 环境 | 完成 |
| 2 | 工程配置与基线 | 配置 MSBuild 文件隔离及 Git 忽略 | 七类项目项中 mobile/shared 均为 0；桌面发布成功 | 完成 |
| 3 | 隔离配置 | 创建正式 Android 工程，锁定依赖 | Flutter 3.47.7 / Dart 3.13.5；初始 analyze 通过；保留 Gradle Wrapper | 完成 |
| 4 | Android 工程 | 建立主题、卡片与间距 | 公共组件及亮暗颜色角色 | 完成 |
| 5 | 主题与公共组件 | 两项底部导航及返回处理 | 独立导航分支；切页保留滚动位置；从我的返回书架 | 完成 |
| 6 | 导航与组件 | 三列色块书架 | 9 本示例书籍及筛选／同步占位，使用惰性网格 | 完成 |
| 7 | 已有公共组件 | 个人页分组卡片 | 资料、统计、同步及九项功能占位 | 完成 |
| 8 | 两页框架 | 分析、测试、APK 构建、真机与视觉检查 | 分析、5 项 Widget 测试、真机流程及三张截图检查通过，生成普通调试安装包 | 完成 |

## 已验证

- WPF 修改前 `dotnet build ReadAI.csproj -c Debug`：通过，0 警告、0 错误。本机 dotnet SDK 为 10.0.400，工程目标仍为 net8.0-windows。
- 工程隔离后，MSBuild 的 Compile、Page、ApplicationDefinition、Resource、EmbeddedResource、Content、None 项中，`mobile/` 和 `shared/` 项均为 0。原桌面 Resource 项仍有 12 项。
- 隔离后执行 `dotnet publish ReadAI.csproj -c Debug --no-restore -o artifacts/mobile-isolation-desktop -p:SelfContained=false -p:UseAppHost=false`：成功；产物未发现 Dart、APK、JAR、Gradle 或 pubspec 文件。此为独立临时目录的桌面发布验证，未运行会清理已有发布目录的发布脚本，未重新生成 Windows 安装器。
- 页面首次静态分析通过。
- `flutter test`：5 项通过，验证两项导航、滚动位置保留、Android 返回处理、占位点击不导航，以及 320×640 / 200% 字号、深色模式、844×390 横屏下两页滚动无布局异常。
- `flutter build apk --debug`：成功，生成 `mobile/build/app/outputs/flutter-apk/app-debug.apk`。
- 最终 `flutter analyze`：通过，无问题；Dart 格式检查通过。
- Android 17 / API 37 真机执行 `flutter test integration_test/app_smoke_test.dart -d <设备ID>`：1 项通过，验证启动书架、同步占位点击、切换我的、滚动到底部点击占位、返回书架。首次测试脚本滚动后未等待布局，修正为等待稳定并确认目标可点击后重跑，通过且无点击落空警告。
- 真机截图发现浅色主题的自定义文字样式丢失了默认颜色；已改为保留主题排版并明确正文／标题颜色。修复后重新通过静态分析、全部 5 项 Widget 测试和普通 APK 构建。
- 修复后使用 Flutter 官方 `integration_test` 截图接口，在同一台真机执行带截图的完整流程，通过。已逐张核对 `artifacts/mobile-framework/bookshelf.png`、`profile.png`、`profile-options.png`：标题颜色、三列封面、资料统计卡片、功能分组、底部导航和末尾滚动区域正常。截图为真实应用绘制区域，不含系统状态栏，字体采用测试机的系统字体。
- 截图测试后重新以默认 `lib/main.dart` 入口构建普通调试 APK，交付副本为 `artifacts/mobile-framework/Sorryread-Android-0.1.0-framework-debug.apk`，避免后续测试覆盖交付文件。安装包为调试版本，不作为体积或性能基线。
- 另执行 `flutter build apk --release --target-platform android-arm64`：成功，验收副本 `artifacts/mobile-framework/Sorryread-Android-0.1.0-framework-arm64.apk`，17,017,909 字节（约 16.2 MiB），仍使用模板开发签名。APK 元数据确认应用名为素若阅读、版本 0.1.0、仅含 arm64-v8a，compile/target SDK 为 36。该包已在同一台 Android 17 手机上安装并启动，书架 Release 截图 `artifacts/mobile-framework/bookshelf-release.png` 已核对。此为安装包文件大小及启动成功记录，未测安装后大小或正式冷启动性能。

本次未实现数据库或共享协议，不改动桌面业务流程；只调整桌面工程的文件隔离配置。未验证 Windows 安装器、iOS、真机大字号／横屏／深色、冷启动性能、帧率、内存、实际阅读或局域网同步；字号、横屏和深色目前只有 Widget 层检查结果。

## 后续接入位置

- 示例数据集中在 `mobile/lib/features/bookshelf/presentation/demo_books.dart`，后续用书架状态及本地仓储替换；不要把示例记录迁入真实数据库。
- 同步卡片集中在 `mobile/lib/features/sync/presentation/sync_placeholder_card.dart`，后续以已定义的同步状态驱动，不在卡片里启动连接。
- 个人页在 `mobile/lib/features/profile/presentation/profile_page.dart`，各分组条目目前无点击回调。
- 路由在 `mobile/lib/app/router.dart`；两项底部导航保留独立分支，后续阅读页按技术方案加入独立路由。
