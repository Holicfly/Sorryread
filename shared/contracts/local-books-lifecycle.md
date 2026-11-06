# 本地书目录与移出扩展

设备通过 hello 的 `local-books-lifecycle` 能力协商本扩展。本地书仍以原文件 SHA-256 标识。数据请求附带 `epoch`，既有书目从 0 开始。双端移除推进 epoch，旧 epoch 的状态、目录和原文件请求被拒绝。

- `GET /v1/local-books?after=<revision>&lifecycle=true` 返回 `books`、`policies`、`nextRevision`。两类记录共用递增游标。先应用策略，再应用同页书目。
- `GET /v1/local-books/{sha}/catalog?after=-1&epoch=0` 每次返回最多 128 条 `units`，每项含 `index`、`title`、`address`。after 是已接收的最后一个索引，初始值为 -1。用原文件的解析结果验证顺序和 catalogHash 后才采用远端标题。
- `POST /v1/local-books/{sha}/policy` 接收 `{"id":"<32位操作ID>","action":"removeHere","epoch":0}`。动作包括 `removeHere`、`removeBoth`、`resume`。响应含 `applied`、`policy`。手机先发送未确认操作，再拉取目录和文件。操作 ID 用于幂等重试。
- 策略字段为 `sha256`、`revision`、`epoch`、`removed`、`desktopExcluded`、`phoneExcluded`、`resetEpoch`。`resetEpoch` 记录该配对手机需要清除的代次下界，双端移除只针对发起时的配对关系。其他手机只对齐传输代次。任一端设置排除后，双方暂停此书的普通同步；对端保存的文件、进度与收藏继续可用。已移出的一端重新选择同一文件后自动恢复同步。
- 双端移除清理双方副本和进度，并保留当前 epoch 的删除标记。手动重导开启该 epoch 内的新书目。删除、重导和文件提交均按 epoch 校验。
- 手机上传原件前同步书目，分块传输沿用 v1。电脑根据已校验的原件生成目录，双方在可读后共享该目录。同步状态继续保留最远位置。漫画只同步页码。
- 本地书通过导入页／本地图书及收藏访问。续读位置独立保存，最近阅读的投影和传输均排除本地书。
