# CodeTime 2.0 全仓库可靠性修复与加固 — 实施报告

本报告对应任务书 `CodeTime 2.0 全仓库可靠性修复与加固实施任务书.md`。所有结论来自仓库内代码与真实执行的测试；未完成的真实环境验收在文末明确标记 **NOT RUN / BLOCKED**，不折算为通过。

## 1. 结论摘要

| 项 | 结果 |
|---|---|
| 单元/集成/故障注入测试 | 295 tests / 0 failures / 3 skipped（`CODETIME_SCALE_TESTS=1`） |
| 回归索引 | CT-001 … CT-196，193 required |
| 编译与测试命令 | `Scripts/regression_gate.sh` |
| 真实双 Mac iCloud 验收 | **NOT RUN**（PLA/签名账号/第二台 Mac 均不可用） |
| 100 GB 全随机数据 | **NOT RUN**（本机可用空间不足） |
| 100 万文件 v3 全量备份 | **NOT RUN**（本轮未生成百万文件数据集） |
| 100k × 1 KiB v3 复测 | 36.6 s 备份，538 MB 峰值 RSS，287 MB 本地 DB；未达到 350 MB 目标，已如实记录 |

## 2. P0：GC 先安全、再释放空间

代码：`CloudGarbageCollector.swift`、`CloudObjectStoreV3.swift`、`GCSafety.swift`、`CodeTimeService.swift`。

- **严格枚举**：`DirectoryEnumerationResult` 区分“目录不存在”和“不可读”；任何枚举/读取失败立即中止，不把 I/O 错误当成空命名空间。
- **持久化 GC Epoch**：计划写入 `v3/gc/epochs/<id>.json`，冻结候选集合、保留版本、`planDigest`、所需设备与宽限时间；崩溃后继续同一计划。
- **设备确认**：其他设备的 ack 只能由该设备写入；有设备记录但未确认时不得删除。未知但命名空间存在的设备按保守策略阻塞。
- **两阶段删除**：Ack + 宽限期 → 隐藏 commit（不销毁）→ 从所有可见/隐藏 commit 重建引用图 → 按 manifest/node/pack/object 顺序删除 → 校验 → 移除隐藏 commit 与墓碑。
- **失败关闭**：引用图不完整、存在暂存上传/发布中快照、租约不可用、任何删除/校验失败都停止并保留数据；`failed` Epoch 可重试。
- **跨进程租约**：备份/恢复/验证持共享 `flock`，GC/迁移持独占；iCloud 不被当作原子 CAS。

证据：CT-163、CT-194、CT-195、CT-196、CT-188、CT-189。

## 3. 远端完整性必须真正读取云端

代码：`RemoteIntegrityVerifier.swift`、`CloudRestoreEngine.swift`、`CloudEngineV3CoreTests.swift`。

- `RemoteIntegrityVerifier` 只通过 `CloudObjectSource` 读取真实云端字节，绕过 `DiskChunkCache`；本地缓存/SQLite 行/文件存在都不参与 `verified` 判定。
- 对象状态区分 `verified / absent / corrupted / inaccessible`；不可访问抛出而不是报缺失。
- Pack 校验包括魔数/版本/内容哈希/头部长度/index 边界/重复/重叠/对象 ID 与 AEAD 明文哈希。
- 恢复策略新增 `cachePreferred / remoteOnly / verifyRemote`；全量校验使用 `remoteOnly`。

证据：CT-183、CT-184、CT-185。

## 4. 对象格式与加密

- 对象格式 v2：公开头只保留 magic/version/compression/keyVersion/originalSize/nonce；明文 SHA-256 移入 AEAD 体内。`keyVersion` 参与 HKDF info，v1 对象仍可解码。
- 同 Object ID 的并发写入通过 `ObjectRegistry.reserve` 与上传租约收敛到一个 writer；失败方复用已存在对象，不产生第二份随机 nonce 密文。

证据：CT-148、CT-149、CT-193。

## 5. 文件一致性与取消

- `FileIdentity` 包含 device/inode/size/mtime(ns)/ctime(ns)/resourceIdentifier；不支持稳定身份时保守重读。
- 读取使用 `open(O_RDONLY|O_NOFOLLOW|O_CLOEXEC)` + 同一 fd 的 `fstat` 前后校验；路径替换/删除会重试，超过次数报 `unstableFile`。
- 保留每日至少一次全内容重读。
- 取消从 `CodeTimeService` → `CloudFirstEngineAdapter` → 扫描/分块/Pack/节点/Manifest/Commit 全链路传递；取消后不再调度新文件、不发布 commit、已上传对象与 spool 保留。
- 扫描器不再全局跳过 Package；特殊文件（FIFO/socket/device）跳过并报告；符号链接目标读取失败标记扫描不完整，不再生成空目标。

证据：CT-153、CT-154、CT-168。

## 6. 跨设备快照发现

- `SnapshotFormatResolver` 以远端 commit 为格式权威：V3 → CloudRestoreEngine，V2/Kopia → legacy，Unknown → 明确拒绝。
- 本地存在 v3 发布记录但远端无 commit 时抛 `commitMissing`，绝不降级为 Kopia。
- 新增持久化远端快照索引（device/format/commitHash/manifestHash/rootNodeID/status/lastVerifiedAt），支持首次发现、增量刷新、失效重建。
- 设备列表带 TTL、强制刷新、失败保留上次成功列表；前台/刷新快照时主动刷新。
- 两服务实例测试覆盖：B 发现 A → 恢复 → B 新版本 → A 不重启发现并读取 B 版本。

证据：CT-169、CT-170、CT-171、CT-172。

## 7. Runtime 与 iCloud 生命周期

- `RuntimeConfigurationFingerprint` 覆盖存储模式、引擎模式、容器、本地镜像、书签哈希、设备 ID、缓存预算、Spool 预算；变化时重建 Store/Queue/Source/Adapter，旧实例不再混用。
- `CloudAccessCoordinator` 统一读写/上传确认/回读哈希/本地副本释放；Node、Manifest、Commit、Object、Pack 全部走同一路径。
- 上传确认使用严格 tracker：缺失元数据、非 ubiquitous、上传错误、超时都报错，不当成“已上传”。
- 哈希不一致禁止驱逐；驱逐失败通过 observer 上报，UI 可显示“云端已备份，本地空间待释放”。

证据：CT-173、CT-174、CT-175、CT-176。

## 8. UploadQueue / Spool

- 先写 spool 再上传，确认后才删除；删除失败保留 `uploadedPendingCleanup`，不假装完成。
- 启动时 `UploadJournalReconciler` 处理：有任务有文件、有任务文件缺失、孤儿文件、上传完成但数据库未更新；未知文件隔离，不删除。
- 每 Object/Pack 一把跨进程 `flock` 上传锁；临时文件独立命名、原子 rename。
- 失败指数退避 + 随机抖动并持久化 `nextAttemptAt`；重启后仍遵守；权限/数据损坏等永久错误不自动重试；达到上限保留任务。
- Spool 达到预算时停止生产新 chunk，已暂存数据永不删除。

证据：CT-159、CT-177、CT-190、CT-191、CT-192、CT-193。

## 9. 恢复安全

- 先写 `*.partial`，校验长度 + SHA-256 + fsync 后原子 rename；`verifyHashes=false` 不关闭基础长度/哈希保护。
- JSONL 恢复日志记录 snapshot/path/expected size+hash/actual size/state；中断可续传。
- 路径经过标准化与 staging 根校验；写入使用 `O_NOFOLLOW`；目录/普通文件先恢复，符号链接最后创建，避免后续写入穿过链接逃逸。
- 目录 mode/mtime 与文件 mode/mtime、符号链接目标均保留。
- 目标已存在时先做保护副本；失败不删除原目标，替换失败可回滚。

证据：CT-186、CT-187。

## 10. 迁移幂等

- 每个项目有稳定 `migrationID`（project + legacy repository），Journal 在任何基线工作前写入。
- 基线快照 ID 持久化；重启后先验证原基线，有效则复用，不创建第二个基线。
- 状态：pending → baselineCreated → baselineVerified → completed；失败 blocked 且不删除 Kopia 数据。
- 只有用户在明确同意后才释放旧本地仓库。

证据：CT-158、CT-162、CT-178。

## 11. 缓存、SQLite 与错误模型

- DiskChunkCache：先删除文件成功再删除索引；删除失败保留索引并报告；根外路径拒绝；不可读文件报错；`reconcile()` 清理缺失行与孤儿文件。
- SQLite 新增远端快照索引、迁移记录表与对应索引；GC 后执行 `wal_checkpoint(TRUNCATE)` 控制 WAL。
- `CodeTimeError.diagnosticCode` 提供稳定错误码（scan/upload/spool/iCloud/remote/manifest/commit/restore/gc/migration/storage/database 等）与 `isRetryable`。
- 诊断报告新增运行配置指纹、待上传任务数/字节、活动任务、GC 状态、最近错误。

证据：CT-179…CT-182。

## 12. 未完成 / BLOCKED（不得标记通过）

| 项 | 状态 | 原因 |
|---|---|---|
| 真实双 Mac iCloud 上传/驱逐/重新下载/跨设备发现 | **BLOCKED / NOT RUN** | 无第二台 Mac；Apple Developer PLA 未由用户接受；Xcode 无签名账号；真实容器写入报 `NSCocoaErrorDomain 4355` |
| 真实 Keychain 跨签名迁移 | **NOT RUN** | 需要 Developer ID/Beta→Release 真机签名链 |
| 100 GB 全随机数据 | **NOT RUN** | 本机可用空间不足，外接卷 ACL 不可写 |
| 100 万文件 v3 全量备份 | **NOT RUN** | 未生成百万 inode 数据集；CT-037 只验证扫描上限 |
| 100k 文件内存目标 350 MB | **未达标** | 复测 538 MB；已减少 FileNode/ScannedFile/Merkle 重复驻留，但仍高于目标 |
| 100k 文件 SQLite 体积降低 | **未达标** | 复测 287 MB；未做重复元数据压缩 |
| 真实 iCloud 本地副本驱逐 | **NOT RUN** | 本地镜像不是 ubiquitous item |

## 13. 复现命令

```bash
cd /Users/guofeng/Code/solo/CodeTime
CODETIME_SCALE_TESTS=1 Scripts/test.sh
Scripts/regression_gate.sh
Packages/CodeTimeKit/.build/out/Products/Release/V3Acceptance \
  perf /tmp/codetime-v3perf-100k small 100000 1024
```

真实双 Mac iCloud 验收按 `Docs/releases/ICLOUD_ACCEPTANCE_TEMPLATE.md` 执行；在完成前发布报告必须保持 `BLOCKED`。
