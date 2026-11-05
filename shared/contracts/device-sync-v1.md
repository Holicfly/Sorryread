# Sorryread LAN Sync v1

仅同局域网，电脑 HTTPS 服务端，手机客户端，双向合并，一对一。UTF-8 JSON，camelCase；设备 ID 为随机 UUID 的 N 格式，序号为非负十进制字符串，时间为 UTC ISO-8601。最大请求 1 MiB，每批最多 128 条操作；不传 SQL、数据库文件、正文、目录、Cookie 或设置。

## 数据与因果关系

Change = `{entityId, group, origin, seq, clock, payload}`。

- entityId：书籍为 `book:` + 旧版 `sourceId|detailUrl` 键；网页／章节为 `url:` + 原始绝对 HTTP(S) URL。保留查询参数、URL 路径大小写与旧键，不按书名合并。
- group：`favorite`、`recent`、`position`。三个字段组分别合并，互不覆盖。
- payload：`kind,title,sourceId,sourceName,detailUrl,chapterUrl,chapterTitle,progress,active,updatedUtc`。kind 为 book/url。progress ∈ [0,1]；favorite/recent 的 active=false 为持续保留的移除标记；position 的 active=false 为明确删除的 URL 位置。
- clock：origin → 十进制序号的版本向量。设备全局序号只在本地事务提交时递增；远端操作不生成新的本地阅读事件。
- 每个字段组的 versions 保留因果上互不支配的候选，负责确认和去重；并发 favorite/recent 中 active=false 优先。URL 的位置删除和冲突规则保持不变。
- 自 Android 0.2.7 / Windows 1.1.10 起，书籍 position 自动保留最远位置：先比较目录 chapterIndex，再比较章内 progress；同内容哈希且两端都提供语义锚点时比较段落和字符。chapterCount 只验证索引，不用于跨版本目录增长时的进度排序。bookProgressChapterUrl 必须绑定到该 chapterUrl，避免误用旧客户端透传的目录元数据。
- 书籍 SyncRecord 增加可选 positionFrontier（最多 64 条原始不可变 SyncChange），与因果 versions 分离。即使较后操作在因果上覆盖了旧操作，也不能删除更远的阅读位置。完整快照必须传输并合并 positionFrontier；重复和已经被因果覆盖的操作仍参与最远位置比较。
- 同章节可直接比较。旧数据缺少目录顺序且章节不同，不猜测 URL 或时间顺序；保留尚不能比较的并发候选供选择，因果先后明确时沿用已知因果顺序。新客户端每次记录都会附带目录索引；等位置优先保留目录元数据，再以因果关系和固定设备／序号规则去重。
- 回看允许停留在较前位置，但不降低已保存的最远进度。仅远端合并确实推进最远位置时才通知正在阅读的界面；手机手势结束后应用，电脑支持当前章节和跨章节恢复。重复快照、本地回看及过时远端位置不触发跳转，接收本身不产生本地进度事件。
- 新策略需要双端均更新。旧客户端能够读取可选 JSON 字段，但不会执行最远位置保护。
- 本地操作和日志、接收操作和游标均在同一数据库事务中提交；只确认连续序号。元数据随 payload 传输，缺失作者和封面不虚构。

## 配对与会话

二维码为 `{type:"sorryread-pair",version:1,serverId,name,endpoints,certificateSha256,token,expiresUtc}`。endpoints 仅为局域网 HTTPS 地址。手机在发送 token 或业务凭据前，固定验证二维码中的证书 SHA-256 指纹。配对 token 仅电脑显示时短时有效，一次使用；电脑有可见确认。正式凭据为每对设备生成的随机令牌，手机系统安全存储保存，电脑只保存令牌哈希。

- `POST /v1/pair`：deviceId/name/token → 电脑确认后返回 credential/serverId。
- 其余路径均需 Bearer credential，鉴别设备及配对代次。
- `GET /v1/hello`：协议版本、serverId、serverSeq、receivedClientSeq。成功说明当前 TLS/身份有效，不代表数据同步完成。
- `POST /v1/push`：按 origin 连续发送手机本地操作。事务提交后返回 receivedClientSeq；重复请求幂等。
- `POST /v1/client-snapshot`：手机在新配对或本地发送日志缺失时，以 seq 创建完整状态上传会话；返回短时 id。
- `POST /v1/client-snapshot/{id}?page=...&complete=...`：按序上传最多 128 条状态／页，末页完整验证并在一个事务内合并全部状态与手机水位；不把缺失实体当删除。上传总量上限 50000 条／32 MiB，有效期五分钟，绑定当前配对。传输失败重开会话，已合并状态可幂等重传。
- `GET /v1/changes?after=...`：电脑本地操作的连续批次，返回 changes/serverSeq。
- 当 hello 的 capabilities 包含 `reading-history`，手机可调用 `GET /v1/reading-history?after=...`。按 revision 升序返回最多 128 条电脑阅读记录。每条记录以电脑、当地日期、书籍 ID、章节 URL 为键，携带累计 milliseconds、最后阅读时间和章节位置。手机在同一事务中覆盖这些键的累计值并保存阅读游标，重试不会重复计时。这个游标独立于书库进度的 serverSeq。支持的客户端可在 `/v1/watch` 传入 readingAfter，电脑在阅读数据有更新时返回 readingChanged。
- `POST /v1/snapshot`：创建一致水位的只含元数据与候选的快照；分页读取，读完后才推进 serverSeq。快照不存在某条记录不代表删除。
- `GET /v1/snapshot/{id}?page=...`：128 条状态／页，受绑定设备身份与有效期约束。
- `POST /v1/disconnect`：仅结束当前会话，保留配对。
- `DELETE /v1/pair`：撤销凭据，保留业务记录，允许重新配对。

手机新配对先上传完整状态（包括以前从其他设备收到的数据），再拉取电脑快照；之后先上传本机待确认操作，再增量拉取。恢复未完成同步从已持久化确认点继续。手机确认后移除已发送操作，完整状态和删除标记仍保留；电脑每 100 次本地提交保留最近约 10000 条本地操作，游标早于可用日志时通过 snapshotRequired 指示重新拉取状态。新配对重新对账，不清除本机收藏和进度。日志不含令牌、正文、私钥和请求头。

配对响应丢失时，同一设备、同一有效 token 可在原二维码有效期内重取同一凭据；电脑只在内存短时保留该响应，磁盘仍只保存凭据哈希。
