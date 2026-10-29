# Android 0.2.7 / Windows 1.1.10 开合书动画与最远进度同步

## 本轮范围

1. 仅书架收藏、最近阅读的开合书动画：封面保持书籍长宽比例，放大同时沿左侧书脊打开，正文逐步展开；600 ms 同一路径反向合书，返回原书架格子。提前解码大封面，动画完成时保留 ReaderPage 状态，避免重新加载。
2. 双端书籍位置按最远位置保留，主动回看不降低已保存同步位置。目录索引先于章内比例；相同正文哈希下使用段落／字符锚点。不以更新时间或全书百分比判断远近，目录新增章节不降低旧位置排序。
3. 同步因果 heads 和 positionFrontier 分开持久化，因果上更晚的回看事件不能清掉较远历史位置。快照、重复消息、重启恢复均保留最远位置；收藏、最近阅读删除与网页位置删除规则不变。
4. 只有远端真正推进位置才驱动当前正文更新，支持当前章与跨章；手机拖动结束后应用。过时或重复位置、本机回看不触发跳转。WPF 普通与透明窗口共用更新逻辑。
5. 可选字段空值按缺省值比较，避免 C# JSON 往返补 null 被手机误判为变更身份冲突。其他有效载荷内容变化仍拒绝。

旧记录不同章节缺少目录坐标时，不从 URL 猜测顺序；保留无法比较的并发候选，因果先后明确时沿用原有因果顺序。新保存的双端书籍位置都会绑定章节目录。双端均需升级才能完整执行新规则。

## 验证

- Flutter 全套 117 项通过、4 项条件跳过；最后的动画状态保持修改后，开合书与阅读页面专项 15 项通过。最终 flutter analyze 无问题。
- 两端共用契约用例验证：离线 40% 对较晚 31%、因果上较晚的回看、较后章节对较高章内比例、目录章节数增长、同时观察双端后的回看；正反操作顺序均收敛。
- Dart 仓储验证完整快照／重复消息／替换设备恢复最远历史、回看无新操作、仅推进时通知。
- C# DeviceSync 契约／数据库／HTTPS／退出／配对／端口／窗口重连检查通过；主机缺少 ASP.NET Core 8 运行时，测试以 DOTNET_ROLL_FORWARD=Major 在已装 .NET 10 运行。交付 Windows 包是自包含 .NET 8。
- WPF SearchHistory 界面回归 532 条断言通过，包含真实 MainWindow 当前章／跨章跟随、更早时间但更远位置、回看保持数据库最远位置、无进度接收回声。
- 实际 C# HTTPS 服务与 Dart 客户端通信：手机离线 40%、电脑后来 31%、重连两端保持 40%，重复请求／回看不回退，变化通知、断开与重连通过。
- 手机 84aa696e / 2509FPN0BC：adb install -r 成功从 0.2.6+8 更新到 0.2.7+9，firstInstallTime 保持 2026-10-26 11:31:07。收藏 3、最近阅读 10、配对及阅读位置保留。实际从收藏打开《少年王》，恢复第 131 章，返回原书架；开合动画录屏在 artifacts/reader-open-sync-review/phone-opening-closing.mp4，读取该应用错误日志未见异常。检测到手机切至其他界面后停止触控；未向用户书籍人为写入 31%／40% 等合成进度，也未替换用户电脑上正在运行的旧应用。

## 交付

- APK：artifacts/Sorryread-Android-0.2.7-book-open-farthest-sync-update-arm64.apk
- APK 下载：https://gofile.io/d/sp3JaHiB
- APK SHA256：A04CED83C63665CA67E7011C6EC4FFD91FBEDA84B02C7C5439A6B7474D1144B0
- APK 包名 com.sorryread.sorryread_mobile，versionCode 9；更新签名 SHA256 04a63a8c84c5af33ee94f4524914e9e39164581ca990fafa32feee7e2eb8ab4c，与上一版一致。
- Windows 安装程序：artifacts/Sorryread-Setup-1.1.10-x64.exe
- Windows 下载：https://gofile.io/d/Xdgs4pcw
- Windows SHA256：E8A5827A363906CBA85F2A4AB0DFF005E453793A090D05E5A811156351ACDE0D
- Windows 从独立 artifacts/Windows-1.1.10-farthest-sync 发布目录打包，未清理含用户 Data 的旧 publish/Sorryread。
- 云端上传返回的大小和 MD5 与本地一致；公开页面核对文件名与下载操作。未声称完成整包回下载校验。
