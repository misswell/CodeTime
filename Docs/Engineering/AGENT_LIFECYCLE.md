# Agent / Scheduler 生命周期与停止协议（CT-101 / CT-113）

## 任务注册表

所有阻塞型任务（备份、本地恢复、云端恢复）在开始时登记到 `CodeTimeService` 的活动任务表：

| 字段 | 含义 |
|---|---|
| `id` | Job ID |
| `kind` | `backup` / `restore` / `cloudRestore` |
| `projectID` | 所属项目（恢复为 nil） |
| `startedAt` | 开始时间 |

每个登记项同时提供取消闭包：备份任务取消其 `Task`（进而由 `ProcessRunner` 终止整个 Kopia 进程组）。

## 子进程登记

`ActiveChildProcesses` 在 `posix_spawn` 成功后登记 PID + 进程启动时间，**只有 `waitpid` 回收后才注销**。因此：

- 登记表非空 ⇒ 一定有子进程可能仍在写盘。
- `terminateAll(grace:killWait:)` 先 SIGTERM 整个进程组，超时后 SIGKILL，并轮询到所有 PID 真正消失。
- 反对照：仅靠 Swift Task 取消无法保证子进程结束；仅靠 PID 号无法防止 PID 重用（登记项比对启动时间）。

## 停止顺序（唯一决策点）

`LifecycleCoordinator.prepareForExit(timeout:)` 是唯一判定：

1. `drainActiveWork`：取消所有登记任务，轮询直到 **登记表为空且无活动子进程**。
2. `terminateOrphanChildren`：兜底终止任何逃脱任务生命周期的子进程。
3. 全部证明退出 → `.safeToExit`；否则 → `.unsafeToExit(remaining)`。

Agent 收到迁移请求或 SIGTERM 时：

```
stopAcceptingNewWork()          // 不再接受新任务
prepareForExit(30s)             // 等待/取消进行中任务
  .safeToExit     → releaseLeadership() → 释放 agent.lock → 释放 lifecycle shared lock → exit(0)
  .unsafeToExit   → 保留全部锁，继续运行（迁移侧安全失败）
```

**绝不**通过 `exit(0)` 绕过清理；**绝不**在子进程可能仍运行时释放它依赖的锁。

## 超时语义

- 单个 job 的取消会终止 Kopia 进程组（TERM → 1.5s → KILL），因此 drain 通常远快于 30s。
- 若 30s 后仍未退出，Agent **保留** `agent.lock` 与 lifecycle 共享锁继续运行；迁移的 `lockSource()` 会拒绝开始，迁移安全失败并可重试。
- 被取消的备份任务状态写入为 `interrupted`（不是 failed/retry），不会触发退避重试风暴；项目状态为 `.warning`，下次调度继续。
