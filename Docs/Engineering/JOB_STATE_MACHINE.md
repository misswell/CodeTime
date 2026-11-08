# 任务状态机

## 状态

| 状态 | 含义 |
|---|---|
| queued | 已入队，等待执行 |
| running | 正在执行（持有租约） |
| succeeded | 成功完成（终态） |
| failed | 失败（终态，但可重试创建新 Job） |
| cancelled | 用户取消（终态） |

## 合法转换

```
queued ──→ running ──→ succeeded
   │           │
   │           ├──→ failed
   │           │
   └───────────┘        (claimBackupJob 从 queued 或 retry 创建 running)
```

`running` 可通过 `scheduleRetry` 回到 `queued`（retryCount 递增）。

## 非法转换

- `succeeded → running`（终态不可重启）
- `failed → running`（失败必须创建新 Job 或通过 scheduleRetry 回到 queued）
- 跨项目转换（Job 绑定 projectID）

## 租约

- `JobLease` 绑定 `ProcessIdentity`（PID + 进程启动时间）。
- 过期 ≠ 可回收：还要求 `!owner.isAlive`（进程死亡 + PID 未复用）。
- `claimBackupJob` 原子化：项目占用检查 + 租约获取在同一个 SQLite 事务。
- `finishJob` owner 校验：只有租约 owner 才能 finish。
- `scheduleRetry` owner 校验：只有租约 owner 才能 retry。
- 旧 running Job（无租约）有 60 秒宽限期。
- 回收旧 Job 和创建新 Job 在同一个 SQLite 事务中完成。


## 第六轮补充

- Restore（本地）：`running → completed | failed`，并新增 **JobLease + 心跳 + 目标路径跨进程锁**；
  bootstrap 只在租约过期且 owner 进程已死（或旧版无租约记录超过 10 分钟）时回收。
- Cloud Restore：见 `CLOUD_RESTORE_STATE_MACHINE.md`（`retryableFailed` / `permanentlyFailed` 与提交 journal）。
- ProjectStatus：`SQLiteStore.recomputeProjectRuntimeState(projectID:)` 在**单个 `BEGIN IMMEDIATE` 事务**内读取
  生命周期、活动备份任务、最新快照并写入状态；`ProjectStatus.derived` 是服务与存储共用的唯一规则。
