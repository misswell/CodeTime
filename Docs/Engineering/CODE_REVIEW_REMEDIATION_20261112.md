# 2026-11-12 Code Review 修复记录

审查基线：`f02b99e`。本轮仍以两个最高约束为准：

1. **原始项目永久只读、单向备份**：备份/扫描只读，恢复只能写入独立目录。
2. **单 Mac + iCloud 验收**：不要求第二台 Mac，多设备能力不作为本次发布已通过项。

## 1. P1 修复

| 审查发现 | 修复 | 回归 |
|---|---|---|
| 底层恢复 API 可通过 `overwriteDestination` 绕过 Service 保护 | 引擎无条件拒绝覆盖恢复；普通恢复必须提供 `sourceRoots`，仅显式 `isDisasterRecovery` 的换机导出可省略 | CT-241、CT-252、CT-264 |
| staging 只按目标路径 + Snapshot 前 8 位生成，可能复用旧目标内容 | staging 身份包含完整 Snapshot ID、目标类型/路径、目标目录摘要；不同目标/快照绝不共享 staging | CT-250 |
| staging 可能是预置符号链接，指向原始项目 | `mkdir` + `lstat` + `O_NOFOLLOW|O_DIRECTORY` 验证；staging 与目标在创建前检查源目录隔离 | CT-251 |
| 恢复 journal 可被预置符号链接重定向 | journal 使用 `O_NOFOLLOW|O_APPEND` 打开 | CT-259 |
| Pack 仅用 `hasPack` 判断，可能引用未完成上传的 Pack | `UploadQueue`、`CloudObjectStoreV3`、`UploadJournalReconciler` 统一使用 `packState`；`.uploading` 等待，`.failed`/`.inaccessible` 停止或重试；已存在 Pack 必须逐字节比较 | CT-260、CT-261 |
| 本地 SQLite ChunkRecord 被无条件当作云端可复用对象 | 备份前探测 pack/object 远端状态；缺失则重新读取原始项目并上传，不可访问则中止；复用文件节点也要求其全部 Chunk 已确认 | CT-253、CT-254 |
| 写入根/项目查询使用 `try? ... ?? []`，数据库错误时 Fail Open | 查询改为 `try await`；项目书签优先，无法解析且路径不存在时停止 | CT-249 |
| 恢复保护根未包含云仓库/镜像根 | `protectedRestoreRoots` 加入仓库、本地镜像、iCloud 根、生命周期目录 | CT-247 |
| `putNode/putManifest/putCommit` 读取已有内容使用 `try?` | 改为严格存在性 + 严格读取；存在但不可读时停止，不覆盖 | 现有 Store/恢复测试 |
| 两个 Store 各自持有租约表 | `CodeTimeService` 创建一个 `LocalCopyLeaseManager` 注入 v3 写/读 Store | CT-216–CT-219、CT-256 |
| 租约状态无限增长、Reader 可饿死 Writer | 空闲状态回收；Writer 优先；释放时先唤醒等待 Writer | CT-255、CT-256 |
| 单机验收 fixture 可当真实证据 | 证据新增 `evidence_kind`；`fixture` 只能用于格式单测，发布门禁只接受 `real` | CT-257 |

## 2. P2 修复

| 项目 | 修复 | 回归 |
|---|---|---|
| 跨进程 Spool 额度不共享 | `upload-locks/spool-quota.lock` 下用 `flock` 串行化“计算额度 + 写 spool” | CT-262 |
| 上传恢复一次最多处理 10,000 条 | 新增 `UploadTaskCursor` + SQLite `(created_at, task_id)` 游标分页；pending/failed/cleanup 均分页处理 | CT-263 |
| 上传成功清理存在两套逻辑 | `drain` 成功路径统一调用 `finish`；删除失败保留 journal 行 | CT-213、CT-214 |
| Search 先加载整棵树再限制 | `forEachFile` 流式遍历，达到 maxFiles 立即停止 | CT-258 |
| Diff 同时驻留两棵完整文件树 | 左侧保留一份 map，右侧流式比较并从左侧删除匹配项，剩余即删除集 | 现有 Adapter Diff 测试 |
| 大任务状态更新只扫描前 5000 条 | `setUploadTaskState`/`setUploadBackoff` 改为按 task_id 精确读取 | CT-263 |

## 3. 门禁与证据

- 全量门禁：`Scripts/regression_gate.sh`，`CODETIME_SCALE_TESTS=1`
- 结果：**363 tests / 0 failures / 3 skipped**
- 索引：`REGRESSION_INDEX.json`，CT-001 … CT-264
- App Debug 构建：**BUILD SUCCEEDED**
- 原始日志：`Docs/Engineering/TestArtifacts/review-remediation-gate-20261112.log`

3 个跳过项仍是人工/规模验收，不代表通过：

- 真实单 Mac iCloud 往返（本机仍受 `NSCocoaErrorDomain 4355` 阻塞）
- CT-037 百万文件压力测试
- CT-044 磁盘写满

## 4. 仍未宣称完成的能力

- 真实 iCloud 单 Mac 上传/重启/驱逐/重下载/恢复证据尚未生成；`fixture` 证据不能通过发布门禁。
- 多设备 GC/恢复能力保留代码，但未在本轮验收中宣称已通过。
- 10 万/100 万文件与 100 GB 规模性能未在本次提交上重新测量；历史数据不能当作当前结果。
