# Cloud Restore 状态机与提交恢复（CT-102 / CT-103 / CT-104）

## 状态

| 状态 | 终态 | 可恢复 | 保留 staging | 说明 |
|---|---|---|---|---|
| `preparing` | 否 | 是 | 是 | 校验身份、准备 staging |
| `downloading` | 否 | 是 | 是 | 逐对象下载并校验 |
| `verifying` | 否 | 是 | 是 | 检查 Kopia 标记与对象集合 |
| `committing` | 否 | 是 | 是 | 已写入 `prepared` journal，正在替换 `repo` |
| `completed` | 是 | 否 | 否 | 完成 |
| `failed` | **否**（旧值，等价 retryableFailed） | 是 | 是 | 兼容旧数据库 |
| `retryableFailed` | 否 | 是 | 是 | 可重试失败（网络/磁盘/取消） |
| `permanentlyFailed` | 是 | 否 | 否 | 不可重试（身份/密钥/清单损坏） |
| `interrupted` | 否 | 是 | 是 | 进程退出 |
| `cancelled` | 是 | 否 | 否 | 用户取消 |

`RestoreStateMachine.allows(from:to:)` 是唯一校验入口；例如 `committing → downloading` 被禁止（避免在已移动的仓库上重新下载）。

## 提交日志（Journal）

位置：`<repositories>/<repoID>/restore-commit-<jobID8>.json`（在 staging 目录之外，因为 staging 即将被移走）。

```
prepared  → staging 已校验，尚未替换 repo
replaced  → moveItem(staging → repo) 已完成
```

## 提交位置判定（Journal 优先）

`restoreCommitPosition(journal:stagingExists:repositoryExists:repositoryHasMarker:jobState:)`：

| staging | repo | 标记 | journal | 结果 |
|---|---|---|---|---|
| 有 | 任意 | — | replaced 且 repo 有标记 | `alreadyCommitted` |
| 有 | 无/空 | — | 其他 | `resumeCommit` |
| 无 | 无 | — | 任意 | `download` |
| 无 | 有 | 无 | 任意 | `blockedDestination` |
| 无 | 有 | 有 | prepared/replaced 或 job 为 committing/verifying | `alreadyCommitted` |
| 无 | 有 | 有 | 无且 job 非 committing | `blockedDestination` |

关键点：**先读 journal，再决定是否创建 staging**。旧实现先重建 staging，导致"move 后崩溃"被误判为目标已存在而永久卡住。

## 幂等与租约

- `claimCloudRestoreJob` 原子声明，拒绝终态与未回收租约；`retryableFailed` 可重新声明。
- 心跳 90s 租约 / 30s 续租；提交前与完成前检查租约是否丢失。
- **所有失败出口释放租约**（否则同一进程内立即重试会被自己的旧租约挡住）。
- 旧 owner 的进度/状态写入被 store 的 owner 检查拒绝。

## Repository 级互斥

恢复在提交窗口内持有 `<repoRoot>/repository.lock`（跨进程 flock）。Kopia 引擎使用同一文件，因此该锁在引擎校验前显式释放——flock 不重入。

## 崩溃矩阵

| 崩溃点 | 下次启动行为 |
|---|---|
| 下载中 | 复用已校验对象继续下载 |
| journal 写入前 | staging 存在但无 journal → `resumeCommit`（重新校验后提交） |
| journal=prepared，move 前 | `resumeCommit` |
| move 后，journal 更新前 | staging 消失 + repo 有标记 + journal=prepared → `alreadyCommitted` |
| journal=replaced 后 | `alreadyCommitted` |
| Keychain/DB 写入前后 | 元数据写入幂等，重跑 |
| 最终校验中 | 重新校验 |
