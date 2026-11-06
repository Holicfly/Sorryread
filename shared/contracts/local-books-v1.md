# 本地书同步 v1

当前手机端在此传输和解析约定上使用[目录与移出扩展](local-books-lifecycle.md)。

在设备互联已配对的局域网 HTTPS 连接内使用。电脑在 `GET /v1/hello` 中声明 `local-books-v1` 后，手机才调用本地书接口。本地书有独立的 revision 游标，普通书仍使用既有的 serverSeq。

## 文件身份和阅读位置

- 文件字节的 SHA-256 小写十六进制是唯一标识。支持 `txt`、`epub`、`mobi`。原文件名可用于首次命名，同一文件改名后仍是同一本书。
- 桌面书库标识为 `local|https://local.sorryread.invalid/<sha256>`。阅读单元使用 `https://local.sorryread.invalid/<sha256>/<index>`，索引从零开始。这些 URL 仅供标识。
- 文本使用章节和章内比例。纯图片 EPUB 按 spine 和文档内图片顺序编号，每张图片对应一个阅读单元。混排 EPUB 保留同一单元内文字与图片的顺序。漫画同步页码，`progress` 固定为 0。
- `catalogHash` 是按顺序以 LF 连接单元标识后的 UTF-8 SHA-256。只有双方的解析版本、目录哈希及单元数一致才合并进度。
- 书目允许先于原文件抵达。只有完整文件校验通过且目录解析成功后才能打开。再次导入同一文件或补齐传输时恢复已有进度。

## 传输

手机定期拉取变化的书目，并按本机缺失情况拉取已就绪的原文件。手机本地新增的书目先提交给电脑，再分块上传原文件。上传中断后查询电脑已持久化的偏移，下载中断后从手机已持久化的偏移继续。完成前文件只保存在暂存区，服务端校验文件长度和 SHA-256，再解析、安装和发布就绪状态。

全部接口使用原设备互联的证书指纹校验和配对 Bearer 凭据。状态请求使用 JSON，上传分块和下载使用二进制。单书上限为 200 MiB，最多 25,000 个阅读单元。

| 方法和路径 | 行为 |
|---|---|
| `GET /v1/local-books?after=0` | 按 revision 递增返回最多 128 个书目的当前状态。响应为 `{"books":[...],"nextRevision":"..."}`。客户端从 `0` 初始化，使用上一页的 `nextRevision` 继续，直到结果少于 128 条。revision 是十进制字符串，可能跳号。 |
| `GET /v1/local-books/{sha}/state` | 返回当前状态，未知书目为 404。 |
| `PUT /v1/local-books/{sha}/state` | 提交下文的 `state` 对象，返回合并后的记录。请求须有 Content-Length，JSON 不超过 16 KiB。相同请求可重试，目录不匹配为 409 `catalog_mismatch`。 |
| `GET /v1/local-books/{sha}/file` | 可用时返回原文件。续传发送 `Range: bytes=<offset>-`，客户端根据 206 和 Content-Range 校验后再追加。无可用文件为 404。 |
| `GET /v1/local-books/{sha}/upload` | 返回 `{"offset":0,"hasFile":false}` 形式的对象。`offset` 是同一配对设备在电脑上已经保存的字节数，已就绪时等于文件总大小。 |
| `PUT /v1/local-books/{sha}/upload?offset=0` | 带 Content-Length 的 1 到 1,048,576 字节原始分块。成功返回更新后的偏移。偏移不一致返回 409 和当前 `offset`，可据此重试。超过声明大小为 400，超过单块上限为 413，暂存区空间不足为 507。 |
| `POST /v1/local-books/{sha}/finish` | 长度、SHA-256 和解析均通过后返回就绪记录。尚未传完返回 409 及当前偏移。SHA-256 或解析失败返回 422，暂存文件清除后偏移重置为 0。目录不匹配返回 409 `catalog_mismatch`。已安装时重复调用仍返回就绪记录。 |
| `GET /v1/watch?after=<serverSeq>&localBooksAfter=<revision>` | 本地书有变化时提前唤醒并带 `localBooksChanged:true`，然后拉取本地书 feed。普通书、阅读时长仍走原有协议。 |

记录结构为 `{"revision":"1","hasFile":true,"state":{...}}`。`hasFile` 表示当前服务端文件可用。客户端以自己的落库结果表示本机文件状态。

| state 字段 | 值与合并规则 |
|---|---|
| `sha256`, `format`, `size`, `title` | 文件哈希、扩展名（小写且不带点）、原文件字节数、显示书名。书名去掉首尾空白，最长 512 UTF-16 码元。第一次接受的书名用于本机展示。 |
| `parserVersion`, `catalogHash`, `unitCount`, `comic` | 解析版本固定为 1，目录 SHA-256、阅读单元总数、是否采用漫画连续阅读模式。相同哈希但这些值或文件格式、长度不一致时拒绝合并。 |
| `position` | `null` 或 `{"index":3,"progress":0.42}`。先比较单元索引，再比较同单元比例，保留最远位置。漫画 `progress` 为 0。 |
| `favoriteChangedUtc`, `favorite` | ISO 8601 时间戳或 null、收藏状态。时间较新的优先，同一时间取消优先。 |
| `recentChangedUtc`, `recent` | 最近阅读的变更时间与状态，合并规则与收藏相同。 |

上传暂存按配对设备和 SHA-256 隔离，单块持久化后才回复偏移。重新连接可继续查询偏移。暂存超过七天未更新的文件可回收，客户端以服务端返回的偏移为准。

## 解析坐标

TXT 依次检查 UTF-8、UTF-16LE、UTF-16BE 的 BOM，文件无 BOM 时先严格解码 UTF-8，再尝试严格 GB18030。将 CRLF 和 CR 统一为 LF。匹配独占一行、去除首尾空白后少于 30 个 UTF-16 码元的「第…章／回／节／卷／部／册」标题，数字范围见桌面实现。标题行与紧接的 LF 不计入该章正文。第一个标题前为「前言」。没有标题时依次命名「第N章」。

正文每 5,000 个 UTF-16 码元切分，优先在分段后半段的最后一个 LF 之后切分。边界不能拆开代理对。跳过裁剪后为空的段落。长章节的各段使用「原标题 第N部分」。单元标识为 `txt:<start>:<end>`，start 含、end 不含，均为裁剪前相对归一化全文的 UTF-16 偏移。MOBI 先解压和提取纯文本，再使用同一拆章器，标识前缀改为 `mobi`。MOBI v1 读取无 DRM 的 MOBI 旧版正文，支持不压缩、PalmDOC 和 HUFF/CDIC。

EPUB 以 package spine 的 itemref 原始零基序号为主，跳过 `linear="no"`。在容器内部解析相对路径与百分号转义，清单中的 nav／NCX 用于命名。一个含文字的 spine 文档形成 `epub:<spineIndex>` 单元，正文按 DOM 顺序保留文本块和图片块。纯图片文档每个有效图片形成一个单元，标识为 `epub:<spineIndex>:image:<imageOrdinal>:<escapedArchivePath>`。imageOrdinal 是该文档内有效图片的零基序号，路径按 URI component 规则对 UTF-8 字节转义，包含路径分隔符。支持 XHTML img、SVG image 包装的内嵌栅格图和 spine 直接引用的 JPEG、PNG、GIF、BMP、TIFF。纯图片、声明 `pre-paginated` 且包含纯图片单元，或纯图片单元数至少为文字单元数三倍且包含图片的 EPUB 进入漫画模式。
