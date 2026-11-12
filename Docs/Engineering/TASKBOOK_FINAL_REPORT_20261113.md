# CodeTime 全仓库可靠性加固任务书 — 最终实施报告

- 任务书：`CodeTime 全仓库可靠性加固与缺陷彻底修复实施任务书.md`
- 完成提交：`c26e920`（最终门禁绑定本提交）
- 门禁：`Scripts/regression_gate.sh`，`CODETIME_SCALE_TESTS=1`
- 结果：**416 tests / 0 failures / 3 skipped**
- 回归索引：CT-001 … CT-316（314 required）

本报告只描述真实代码和真实执行结果。真实 iCloud、百万文件、100 GB 的 NOT RUN 项
不会被写成通过。

## 1. 原始缺陷与根本原因

| 缺陷 | 根本原因 | 修复 |
|---|---|---|
| 本地 journal 的 uploaded/completed 被当作云端存在 | UploadQueue 的终态没有回查 Store；本地状态被当成远端事实 | 终态必须调用底层 `objectState`/`packState`；对象删除返回 absent 并重传；不可访问停止 |
| Pack 未确认上传即可被引用 | Pack 路径只查文件名/`hasPack`，没有统一生命周期 | Pack 统一走 `packState`；`.uploading` 等待，`.failed` 重写重试，`.inaccessible` 停止；已有 Pack 逐字节比较 |
| 本地 SQLite ChunkRecord 被无条件复用 | 增量备份信任索引，不验证远端 | 备份前探测 pack/object 状态；缺失则重读源文件；复用内容通过 UploadQueue 校验解密/结构 |
| Commit 可能在对象丢失后发布 | 上传完成与 Commit 之间没有最终一致性屏障 | Commit 前 `assertAllReferencesDurable` 检查全部 Chunk/Pack |
| iCloud `.failed` 永久无法恢复 | Store 对 failed 直接抛错，重试永远撞同一状态 | 用调用方仍持有的精确 payload 原子重写并重新确认；错误分类区分可恢复/永久 |
| Spool flock 跨 `await` 导致 Actor 死锁 | 配额锁覆盖了 SQLite enqueue | flock 只包围同步额度检查+原子写文件；释放后才 await journal；孤儿由 Reconciler 收养 |
| 恢复 staging 可复用错误目标/被符号链接替换 | staging 仅用路径+Snapshot 前 8 位；写入仍用绝对路径 | 身份含完整 Snapshot/目标/目录；`RestoreDirectoryFS` 用目录 FD + openat/mkdirat/symlinkat/renameat/unlinkat |
| 公开 `isDisasterRecovery` 可绕过源保护 | 安全边界是 Service 约定 + 公开 Boolean | 删除 Boolean；普通恢复必须提供非空边界；`RestoreProtectedRoots` 统一源/受保护根 |
| 书签解析失败回退旧 rootPath | `try?` 把安全解析错误降级 | 书签存在但解析失败时拒绝；只有项目确实从本机消失才跳过 |
| Adapter 把读取错误吞成“文件” | `try?` 包住目录识别 | 只对明确 `pathNotFound` 返回文件；其他错误传播 |
| 租约表分裂、状态泄漏、Writer 饥饿 | 两个 Store 各自建管理器；空闲不回收；Reader 优先 | Service 注入同一个 `LocalCopyLeaseManager`；空闲回收；Writer 优先 |
| 不可变 Node/Manifest/Commit 可能被覆盖 | 读取已有内容使用 `try?`，失败被当成不存在 | 严格存在性 + 严格读取；冲突/不可读停止；相同 Manifest 复用不重写 |
| Spool 额度/恢复上限/清理不一致 | 每 Actor 缓存额度；10k 单批；drain 重复清理 | 跨进程 flock 额度；`UploadTaskCursor` 分页；成功清理统一 `finish` |

## 2. 实际修改文件

核心：

- `Packages/CodeTimeKit/Sources/BackupEngine/UploadQueue.swift`
- `Packages/CodeTimeKit/Sources/BackupEngine/CloudFirstBackupEngine.swift`
- `Packages/CodeTimeKit/Sources/BackupEngine/CloudFirstEngineAdapter.swift`
- `Packages/CodeTimeKit/Sources/BackupEngine/CloudRestoreEngine.swift`
- `Packages/CodeTimeKit/Sources/BackupEngine/SecureRestoreFS.swift`
- `Packages/CodeTimeKit/Sources/BackupEngine/UploadJournalReconciler.swift`
- `Packages/CodeTimeKit/Sources/CloudMirrorStore/CloudObjectStoreV3.swift`
- `Packages/CodeTimeKit/Sources/CloudMirrorStore/CloudAccessCoordinator.swift`
- `Packages/CodeTimeKit/Sources/CloudMirrorStore/CloudMultiDeviceStoreV3.swift`
- `Packages/CodeTimeKit/Sources/CloudMirrorStore/LocalCopyLeaseManager.swift`
- `Packages/CodeTimeKit/Sources/CodeTimeCore/CodeTimeService.swift`
- `Packages/CodeTimeKit/Sources/Persistence/CloudIndexV3.swift`
- `Packages/CodeTimeKit/Sources/SharedModels/CloudObjectLifecycle.swift`
- `Packages/CodeTimeKit/Sources/SharedModels/Protocols.swift`

测试：

- 新增 `SecureRestoreFS.swift` 的目录 FD 安全层
- 新增 `TaskBookFileSystemTests.swift`（CT-300…CT-309）
- 新增 `TaskBookRestoreSecurityTests.swift`（CT-290…CT-299）
- 扩充 `UploadLifecycleTests.swift`（CT-274…CT-289）
- 扩充 `RemoteReuseSafetyTests.swift`（CT-265…CT-273）
- 扩充 `CloudFirstEngineAdapterTests.swift`（CT-310…CT-314）
- 扩充 `ServiceV3IntegrationTests.swift`（CT-266、CT-269 生产链路）
- 扩充 `ServiceV3RecoveryTests.swift`（CT-291）
- 扩充 `SourceImmutabilityTests.swift`（CT-315、CT-316）

## 3. 修复后的机制

### 云端状态

```
UploadQueue.objectState/packState
  → 终态也必须查 CloudObjectStoreV3
  → absent: 允许重新读取/上传
  → uploading: 等待
  → failed: 重写精确 payload 并重新确认
  → inaccessible: 停止
```

生产队列还注入了解密/结构校验：
- Object：读取远端密文并 `ObjectEncoder.decode`。
- Pack：读取远端 Pack，验证结构、偏移、长度，并解密每个成员。
- 验证缓存默认 TTL=0；每次复用都验证真实内容。正确性优先，性能代价见第 7 节。

Commit 前：

```
所有对象/包状态必须是 uploaded/verified/packed
        ↓
Manifest 写入并确认
        ↓
Commit 写入
```

### 恢复安全

- `RestoreProtectedRoots` 同时携带源项目根与受保护根。
- 普通恢复无源边界直接拒绝；换机恢复由 Service 传入数据目录/仓库/生命周期等边界。
- 目录 FD 安全层：
  - staging 根 FD 保留；
  - `openat`/`mkdirat`/`symlinkat`/`renameat`/`unlinkat`/`fstatat`；
  - 每级目录 `O_NOFOLLOW|O_DIRECTORY`；
  - 文件 `O_NOFOLLOW`；
  - journal 由父目录 FD 打开，含 version/identity 头；
  - partial 完整校验后才 `renameat`。

### Spool

- 配额锁只覆盖同步临界区。
- 文件先写临时文件再原子替换。
- 文件写入后、SQLite 入队前崩溃 → Reconciler 收养或隔离。
- 游标 `(created_at, task_id)` 分页处理 pending/failed/cleanup。

## 4. 回归测试对应

| 范围 | CT |
|---|---|
| 云端真实状态/生产链路/Pack | CT-265–CT-273 |
| Spool 并发/配额/孤儿/崩溃 | CT-274–CT-282 |
| 上传失败恢复/重启/退避 | CT-283–CT-289 |
| 恢复保护根/Boolean/书签/目标重叠 | CT-290–CT-299 |
| 目录 FD/openat/符号链接/大小写 staging | CT-300–CT-309 |
| Adapter 文件/目录/错误分类/取消 | CT-310–CT-316 |
| 原始项目只读（字节/权限/mtime/xattr/符号链接/结构） | CT-234–CT-245、CT-316 |
| 租约/GC/UploadQueue 既有回归 | CT-201–CT-233 等 |

完整矩阵见 `REGRESSION_MATRIX.md` 与 `REGRESSION_INDEX.json`。

## 5. 测试执行结果

- `Scripts/regression_gate.sh`：**PASS**
- 416 tests，0 failures，3 skipped，413 passed
- 索引：CT-001 … CT-316（314 required）
- 跳过项：真实单 Mac iCloud、CT-037 百万文件、CT-044 磁盘写满
- App Debug 构建：**BUILD SUCCEEDED**
- 原始门禁日志：`Docs/Engineering/TestArtifacts/taskbook-final-gate-20261112.log`

## 6. 尚未解决的问题

1. **真实单 Mac iCloud 往返 NOT RUN**：本机仍受 `NSCocoaErrorDomain 4355` 阻塞；没有伪造 PASS。
2. **百万文件 NOT RUN**：10 万文件恢复已约 10.9 分钟，百万规模超出本次可验证窗口。
3. **10 GB / 100 GB 大文件 NOT RUN**：本次未重新执行；历史数据不能替代当前提交。
4. **真实双进程 Spool 竞争**：代码使用跨进程 `flock`，自动化测试使用两个 UploadQueue 实例并发；未单独启动第二个 OS 进程做竞争测试。
5. **大小写敏感 APFS**：CT-306/307 使用显式卷属性注入验证 staging 身份逻辑；未挂载真实大小写敏感 APFS 卷。
6. **恢复性能**：100,003 文件恢复 652,871 ms，是明确瓶颈；对象复用内容验证默认无缓存进一步增加大项目增量成本。

## 7. 性能结果

详见 `PERFORMANCE_REPORT_20261112.md`。

- 10 万文件：峰值 RSS **50.4 MB**，内容 100,003 文件 0 mismatch，PASS。
- 首次备份 7,463 ms；增量 1,484 ms；恢复 652,871 ms（瓶颈）。
- 百万/100 GB：NOT RUN。

## 8. 兼容性

- 未修改 Object ID、Pack、Manifest、Commit 的磁盘格式。
- 未修改数据库 schema；`UploadTaskCursor` 是查询层分页，不改变持久化格式。
- 既有 v2/v3 回归全部通过；迁移测试仍通过。
- 旧 Spool 文件继续由 Reconciler 识别/收养。
- 已上传对象只读复用，不覆盖。

## 9. 发布条件

| 条件 | 状态 |
|---|---|
| Swift Build | PASS |
| Unit/Integration/Cloud/Recovery/Concurrency/Crash Tests | PASS |
| Regression Gate | PASS |
| 原始项目只读回归 | PASS |
| 新增 P1/P2 回归 | PASS |
| 100k 性能/RSS | PASS（恢复耗时记录为瓶颈） |
| 百万文件 | NOT RUN |
| 10/100 GB | NOT RUN |
| 真实 iCloud 单 Mac | NOT RUN |

结论：**代码级任务书修复和自动化门禁已完成；由于真实 iCloud、百万文件、100 GB
仍未执行，不能宣称达到生产发布标准。**
