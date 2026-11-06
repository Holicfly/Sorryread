# 手机端本地书接入说明

电脑通过设备互联提供书目和原文件的双向同步。Flutter 作为发起请求的一端，沿用现有 HTTPS、证书指纹、凭据与重连机制。原文件格式和章节标识见[本地书 v1 契约](../shared/contracts/local-books-v1.md)，当前双端同步使用[目录与移出扩展](../shared/contracts/local-books-lifecycle.md)。

## 实现结构

1. **本机导入与身份**。用系统文件选择器取得 TXT、EPUB、MOBI 的可读流，复制到应用私有目录并计算原字节 SHA-256。以哈希关联书目、原文件和目录。测试同一份文件改名、批量重复导入，以及手动补齐从电脑同步的书目。
2. **解析与阅读**。实现与桌面 v1 相同的解码、拆章和 EPUB 页序，先核对 [共享 TXT 样例](../shared/fixtures/local-books-v1.json) 的哈希、单元标识与正文。用相同的 EPUB、MOBI 原件对照电脑导入后的 `catalogHash`。文字书保存章节索引和章内比例。漫画书按页序纵向展示，以顶部可见页的索引保存进度，页图按可见范围加载。
3. **同步编排**。`mobile/lib/sync_engine/local_book_sync.dart` 在已认证会话中识别 `local-books-lifecycle`。`mobile/lib/data/imported_books.dart` 保存本地书、目录、设备屏蔽和待确认操作，使用按 serverId 保存的独立 revision。先同步待确认移出和重导操作，再拉取书目，最后传输原文件。待传输状态可在 App 重启后重建。
4. **电脑到手机**。从 feed 中找 `hasFile=true` 且本机缺少原件的书目，按 SHA-256 去重后下载。首次从零开始，中断后按本地暂存文件的长度请求 Range。只有响应为 206 且 Content-Range 起点和总长度匹配时才追加。收到 200 时从零重写，收到 404 时等待下一次检查。校验字节数、SHA-256 和目录后提交原件，恢复先前同步到的进度。
5. **手机到电脑**。用 `PUT …/state` 提交书目。若返回 `hasFile=false`，先查询上传偏移，再按不超过 1 MiB 的分块上传。确认偏移达到文件长度后调用 `POST …/finish`。应答丢失、断线或偏移冲突时重新查偏移。收到 422 时清除旧的传输任务状态，检查原件再从零重试。目录冲突需展示双方解析版本或目录不一致，并暂停该书自动合并。
6. **后台重连与界面**。原有 watch 追加 `localBooksAfter`，在首次连接、重连、手动同步及 `localBooksChanged` 时拉取变化。离线先保存本机读写和待同步项。书卡可区分等待文件、传输、校验失败、就绪四类状态。取消配对后取消该会话任务，持久化书目和已校验的原件供本机继续阅读。
7. **书架、阅读和移出**。在发现页选择文件，从书架「本地图书」或「收藏」进入同一阅读器。本地文本沿用阅读设置、开合书动画和翻页，漫画 EPUB 首次默认纵向滚动。漫画的手机内页内位置和双端同步页码分别保存。本地书续读位置独立于最近阅读。单选本地书或多选且全部为本地书时，红色删除按钮在原 Dock 内切换移出范围，所选范围应用于整批书籍。历史总阅读时长继续保留，本机移出后可手动重导同一文件以恢复同步。

## 请求示例

以下示例省略了每个请求通用的 `Authorization: Bearer <credential>`。其中 `<sha>` 和 `<catalogHash>` 均为小写的 64 位十六进制字符串。

```http
GET /v1/local-books?after=0&lifecycle=true
GET /v1/watch?after=42&localBooksAfter=7

PUT /v1/local-books/<sha>/state?epoch=0
Content-Type: application/json

{"sha256":"<sha>","format":"epub","size":1434028,"title":"漫画样例","parserVersion":1,"catalogHash":"<catalogHash>","unitCount":180,"comic":true,"position":{"index":23,"progress":0}}

GET /v1/local-books/<sha>/file?epoch=0
Range: bytes=1048576-

GET /v1/local-books/<sha>/catalog?epoch=0&after=-1
GET /v1/local-books/<sha>/upload?epoch=0
PUT /v1/local-books/<sha>/upload?epoch=0&offset=1048576
Content-Type: application/octet-stream
Content-Length: 385452

<385452 bytes>

POST /v1/local-books/<sha>/finish?epoch=0
```

## 手机端验收

| 场景 | 预期 |
|---|---|
| 电脑批量导入 TXT、图文 EPUB、漫画 EPUB 和文本 MOBI | 手机上出现书卡并自动补齐原文件，文件哈希一致，所有样例均可离线打开。 |
| 手机先导入后联网 | 电脑导入页先显示等待原文件，完整上传后可读，漫画恢复同一页。 |
| 上传或下载中断，关闭应用后重连 | 从已确认的偏移继续，最终两端只各有一份可读原件。 |
| 传输字节错误，或故意改变解析目录 | 文件校验失败可重试。目录不一致时保留已有进度，并提示处理。 |
| 两端分别读到不同章节／页码 | 联网后保留最远位置。同一章比较章内比例。收藏与取消收藏按变更时间合并。 |
| 单端移出，另一端继续读，再手动重导 | 已移出设备保持无书状态，重导时接回对端仍保留的位置。 |
| 双端移除，离线或传输中的旧请求重试 | 下次连接执行移除，旧 epoch 的数据无法写入。 |
| 旧电脑、旧手机、配对撤销 | 旧设备继续走普通书同步。解除配对后停止使用已撤销的凭据访问原文件。 |
