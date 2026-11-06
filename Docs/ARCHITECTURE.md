# CodeTime 架构

## 1. 总览

CodeTime 把“备份算法”和“云端封装”严格分开：

```
┌──────────────────────────────────────────────────────────────┐
│ SwiftUI App (Apps/CodeTime)                                  │
│  Dashboard / Projects / Timeline / Restore / Diff / Settings │
│  MenuBarExtra · Onboarding · agent 模式入口                   │
└──────────────────────────┬───────────────────────────────────┘
                           │ AppModel (MainActor)
┌──────────────────────────▼───────────────────────────────────┐
│ CodeTimeCore                                                │
│  CodeTimeService · BackupScheduler · CloudLocation           │
└───┬───────────┬──────────────┬──────────────┬────────────────┘
    │           │              │              │
┌───▼────┐ ┌────▼─────┐ ┌──────▼──────┐ ┌─────▼────────┐
│Backup  │ │Cloud     │ │Persistence  │ │Git integration│
│Engine  │ │Mirror    │ │SQLite WAL   │ │read-only      │
│(Kopia) │ │Store     │ │             │ │               │
└───┬────┘ └────┬─────┘ └─────────────┘ └───────────────┘
    │           │
┌───▼────┐ ┌────▼──────────────┐
│ Kopia  │ │ iCloud Drive /    │
│ CLI    │ │ local mirror      │
└────────┘ └───────────────────┘
```

`Packages/CodeTimeKit` 用一个 Swift Package、七个库目标承载原设计中的
`CodeTimeCore / BackupEngine / CloudMirrorStore / GitIntegration / Persistence /
Security / SharedModels`。模块边界与设计一致，只是合并为一个包以简化 Xcode/SwiftPM 集成。

## 2. 进程模型

### 2.1 主应用

`CodeTime.app` 包含主窗口、菜单栏、设置与（默认开启的）进程内调度器。
应用启动流程：

1. 打开/迁移 SQLite（WAL）。
2. 读取或生成设备 ID、仓库记录、应用设置。
3. 从 Keychain 读取/生成恢复密钥与 Kopia 仓库密码。
4. 定位内置 Kopia，校验/创建本地仓库。
5. 恢复“运行中”状态被中断的任务，标记为失败。
6. 启动 `BackupScheduler`，订阅唤醒与 `com.codetime.changed` 通知。
7. 周期校验/清理（按设置）。

### 2.2 后台代理

在 `Contents/Library/LaunchAgents/com.codetime.agent.plist` 注册的 LaunchAgent
以 `--agent` 参数运行 **同一个应用二进制**：

```
Contents/MacOS/CodeTime --agent
```

原因：macOS Keychain 的默认 ACL 绑定创建条目的应用代码签名。独立 agent 二进制会
触发跨应用的 Keychain 授权弹窗，且每次重签名后可能失效。共用二进制后，UI 与后台
进程拥有同一签名与同一 Keychain 访问权。

代理与 UI 之间不使用 XPC，而是：

- 共享同一 SQLite 数据库（WAL，`busy_timeout=5s`）。
- 仓库写入锁 `repositories/<id>/repository.lock`（`flock`）。
- 调度领导锁 `scheduler.lock`（`flock`）；只有持锁进程创建快照。
- `DistributedNotificationCenter` 的 `com.codetime.changed` 通知 UI 刷新。

这套方案满足“同一时刻只有一个进程写仓库”的核心约束；XPC 可在后续版本引入而
不改变数据模型。

### 2.3 崩溃恢复

- 每个备份/恢复/上传任务先写 `backup_jobs` / `restore_jobs`，再执行。
- 启动时把所有 `running` 任务改为 `failed`，记录“进程在任务完成前退出”。
- 云端版本只有清单最后写入才可见；中断的发布会留下不可变孤儿对象，由清理流程
  在宽限期后回收。
- 本地 Kopia 快照由 Kopia 自身保证完整性；CodeTime 不直接改仓库文件。

## 3. 本地备份流程

```
due/manual
   │
   ▼
BackupScheduler.tick
   │  scheduler.lock 选主
   ▼
CodeTimeService.createSnapshot
   │  activeProjects 去重
   │  写 backup_jobs
   ▼
KopiaBackupEngine.createSnapshot
   │  repository.lock（跨进程）
   │  policy set：排除规则 + 保留策略
   │  kopia snapshot create --json
   │  读取 stats（errorCount / excluded*）
   ▼
写入 snapshots 表 + 更新项目状态
   │
   ├── 云端未启用 ──▶ 结束（本地成功）
   └── 云端启用 ────▶ CloudMirrorStore.publish
```

规则：

- **本地成功 ≠ 云端成功**：`snapshots.status` 与 `snapshots.cloud_state` 分开存储。
- 快照完整性与一致性分开：`status`（complete/incomplete）与 `consistency`
  （consistent/possiblyInconsistent）。后者在 Kopia 报告读取失败时置位。
- 仓库写入串行：进程内由 actor 串行化，跨进程由 `flock` 保证。
- 定时频率、保留数量、排除规则均由项目级 `BackupPolicy` 决定。

## 4. 云端发布流程

见 `Docs/CLOUD_FORMAT.md` 的格式细节。核心顺序：

1. 枚举本地 Kopia 仓库文件，计算 SHA-256。
2. 按内容哈希写入 `objects/<前两位>/<sha256>`，**不覆盖已存在对象**。
3. 等待所有对象被存储层确认上传（iCloud：`ubiquitousItemIsUploadedKey`）。
4. 用 AES-256-GCM 加密版本清单，写入 `commits/<generation>.ctm`（最后一步）。
5. 更新 `recovery-info.json`（含加密的 Kopia 仓库密码）。

任何一步失败都不会产生新的可见版本；旧清单继续有效。

`CloudMirrorStore` 的存储根可以是：

- `iCloud Drive/CodeTime`（启用 iCloud，`coordinatedIO=true`）。
- 用户选择的本地镜像目录（开发/演练，`coordinatedIO=false`）。

两者使用完全相同的格式与恢复路径，因此本地镜像测试能覆盖云端格式逻辑。

## 5. 调度

`BackupScheduler` 的核心不是“每 30 分钟定时器”，而是：

- 每 30 秒检查一次“是否有项目已超过下次应执行时间”。
- 每项目使用 `lastBackupAt + interval` 判断，避免重复扫描。
- 睡眠唤醒后只补跑一次，不补齐每个时间刻度。
- 失败由下一次 tick 重试；同一项目用 `activeProjects` 去重。
- 低电量模式 + `pauseOnBattery` 时暂停自动任务。
- 领导锁保证 UI 与 agent 不会同时创建快照。

设置项 `autoBackupOnLaunch` 控制启动时是否立即检查补跑；关闭后首个检查发生在
30 秒后。

## 6. 数据模型

SQLite（WAL）保存元数据，不进入 iCloud：

| 表 | 用途 |
| --- | --- |
| `projects` | 项目、书签、状态、最近备份 |
| `policies` | 频率、保留、排除规则、Git/敏感文件选项 |
| `snapshots` | 快照索引、完整性、云端状态、校验等级 |
| `jobs` | 备份任务与检查点（崩溃恢复） |
| `cloud_generations` | 云端版本发布状态与清单哈希 |
| `cloud_objects` | 对象上传状态（诊断） |
| `restore_jobs` | 恢复记录 |
| `verification_results` | 本地/云端/异机校验结果 |
| `activities` | 活动日志（自动裁剪） |
| `repositories` | 本机仓库记录 |
| `kv` | 设备 ID、设置、调度/校验时间戳 |

模型均为 `Codable`，整条记录存于 `payload` BLOB，同时冗余索引列用于查询；
升级通过 `PRAGMA user_version` 迁移。

## 7. 恢复路径

四种模式：

| 模式 | 行为 |
| --- | --- |
| 预览 | 只读仓库对象，不落盘 |
| 恢复副本 | 写入用户选择的新位置，默认推荐 |
| 覆盖 | 仅单文件；先复制当前文件到 `recovery/`，失败则中止 |
| 整项目 | 恢复到空目录，包含目录结构与 `.git` |

路径安全：

- 拒绝绝对路径、`..`、空字节与反斜杠。
- 覆盖目标必须位于项目根目录内（标准化 + 解析符号链接后再校验前缀）。
- 云端清单中的相对路径同样校验，防止恢复路径遍历。

## 8. 关键设计取舍

| 决策 | 结论 | 原因 |
| --- | --- | --- |
| 自研备份算法 | 否 | 复用 Kopia 的去重、压缩、加密、保留策略 |
| Git 作为存储引擎 | 否 | Git 只提供历史上下文 |
| 直接同步活动 Kopia 仓库 | 否 | iCloud 语义不满足 Kopia 的原子写/一致性要求 |
| 自研云端适配层 | 是 | 不可变对象 + 加密清单 + 最后发布 |
| 多项目共用仓库 | 是 | 同一 Mac 内跨项目去重 |
| 多 Mac 写同一仓库 | 否 | 设备隔离目录 |
| 后台代理形态 | 同二进制 `--agent` | 保持 Keychain ACL 一致 |
| 进程通信 | SQLite + 文件锁 + 通知 | 简化 v1，可后续替换为 XPC |
| 实时文件触发 | 暂不启用 | 当前由定时/手动/唤醒覆盖，避免误触发扫描 |

## 9. 架构门禁与验证现状

原设计的三个架构级风险：

1. **Kopia 仓库能否安全重组**：已验证。`RepositoryReplicationTests` 与
   `ServiceEndToEndTests` 把仓库经 CloudMirrorStore 往返后重新连接并读取快照。
2. **iCloud 对象规模与同步语义**：代码路径已实现，尚未在注册容器的签名构建上
   实测；本地镜像只验证格式与恢复，不等价于 iCloud 验收。
3. **云端空间回收**：`CloudMirrorStoreTests` 验证宽限期清理不会删除被保留版本
   引用的对象；真实 iCloud 的容量释放仍待实测。

未通过第 2、3 项真实环境验收前，不应把版本标记为“生产可用”。
