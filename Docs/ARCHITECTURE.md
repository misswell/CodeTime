# CodeTime 架构

## 0. CodeTime 2.0：云端优先引擎（v3）

自 Cloud Format v3 起，新备份不再依赖本地 Kopia 仓库。完整历史保存在
`iCloud Drive/CodeTime/v3`，本地只保留三类数据：

```text
Application Support/CodeTime/
├── database/codetime.sqlite          # 可重建索引（文件/块/版本/任务/缓存/迁移）
├── cache/
│   ├── downloaded-objects/           # 有界 LRU 下载缓存（可安全清理）
│   └── restore-staging/              # 恢复暂存，成功后原子提交
├── spool/
│   ├── pending/                      # 已加密、未确认上传（永不因缓存上限删除）
│   └── journal/                      # 任务日志（SQLite 为主）
├── legacy/kopia/                     # 迁移后的旧仓库临时位置
├── logs/ recovery/
└── repositories/                     # 仅旧引擎使用；v3 不读取
```

数据流：

```text
项目文件 → 流式 FastCDC 分块 → HMAC 对象 ID → LZFSE 压缩 → AEAD 加密
        → spool/pending → UploadQueue → iCloud objects/packs
        → 目录 Merkle 节点 → 加密 Manifest → Commit Marker
```

- 发布顺序不可交换；Commit 是版本可见的唯一入口。
- 恢复只下载目标文件需要的块或包，写入 staging 并校验 SHA-256 后原子提交。
- 上传确认后才释放 spool 副本；上传成功后按需驱逐 iCloud 本地副本。
- v2→v3 迁移顺序：旧本地仓库检测 → v2 云端发布/校验 → v3 基线创建/校验 →
  用户明确同意 → 释放旧本地仓库。旧历史在迁移后仍可恢复。

详细格式见 [CLOUD_FORMAT_V3.md](CLOUD_FORMAT_V3.md)。

### 引擎选择

`AppSettings.engineMode` 决定新快照写入哪个引擎：

| 模式 | 行为 |
|---|---|
| `kopia` | 旧版兼容：本地 Kopia 快照 + Cloud Format v2 发布 |
| `cloudFirst` | 云端优先：CloudFirstBackupEngine + Cloud Format v3 |

读取/恢复按版本归属选择引擎：存在 `v3_snapshot_index` 记录的版本走 v3，
其余走 Kopia；比较/恢复不混用两种格式。迁移基线验证通过后自动切换到
`cloudFirst`，旧引擎保留为只读兼容路径。

---

## 1. 总览（v2 / 兼容路径）

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
   元数据不可读、文件不在 iCloud 容器或上传未确认时抛错，不视为成功。
4. 用 AES-256-GCM 加密版本清单，写入临时文件后原子移动到 `commits/<generation>.ctm`。
5. 等待清单上传确认，再回读并解密，比对 Generation ID 与对象集合；不一致则移除未验证清单并报错。
6. 更新 `recovery-info.json`（含加密的 Kopia 仓库密码）与对象索引。

任何一步失败都不会产生新的可见版本；旧清单继续有效。清单是唯一提交点。

发布使用独立的 `publish.lock`：本地对象复制完成后释放 Kopia `repository.lock`，iCloud 上传等待期间不会阻塞下一次本地快照；GC 获取同一把发布锁，避免清扫尚未提交的对象。提交后的 recovery-info/索引失败只记录告警，不撤销已发布版本。

`CloudMirrorStore` 的存储根可以是：

- `iCloud Drive/CodeTime`（启用 iCloud，`coordinatedIO=true`）。
- 用户选择的本地镜像目录（开发/演练，`coordinatedIO=false`）。

两者使用完全相同的格式与恢复路径，因此本地镜像测试能覆盖云端格式逻辑。

## 5. 调度

`BackupScheduler` 的核心不是“每 30 分钟定时器”，而是：

- 每 30 秒检查一次“是否有项目已超过下次应执行时间”。
- 每项目使用 `lastBackupAt + interval` 判断，避免重复扫描。
- 睡眠唤醒后只补跑一次，不补齐每个时间刻度。
- 失败任务按 60/300/900/1800/3600 秒指数退避（带抖动），永久错误不重试；同一项目用 `activeProjects` 去重。
- 云端发布失败会创建独立的 `.upload` 任务，由调度器按退避策略重试，不必等待下一次本地备份。
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
| `cloud_restore_jobs` | 云端恢复任务、staging 路径与进度 |
| `gc_journals` | 云端清理阶段与删除记录 |
| `maintenance_state` | 验证/清理下次运行时间与结果 |
| `object_hash_cache` | 按文件身份的增量哈希 |
| `cloud_object_index` | 仓库文件与对象映射 |
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
| 跨设备 | 先写入 staging 仓库，逐对象校验，完成仓库/快照校验后再切换；临时文件+原子移动，支持 committing 阶段续跑 |

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

v1.0.0 整改后的验证状态：

1. **Kopia 仓库能否安全重组**：已验证。`RepositoryReplicationTests`、
   `ServiceEndToEndTests` 与 CT-013…CT-020 覆盖发布、恢复、断点续跑与失败不污染。
2. **GC 安全性**：CT-001…CT-003、CT-012 与 `CloudMirrorStoreTests` 验证完整枚举、
   引用保护、墓碑恢复与重新验证；真实 iCloud 容量释放仍待双机验收。
3. **iCloud 同步语义**：上传确认、元数据失败与不可读文件均失败关闭
   （CT-005…CT-007）；真实双 Mac 验收未执行，见 `Engineering/KNOWN_LIMITATIONS.md`。
4. **多进程一致性**：CT-021…CT-028、CT-041 覆盖租约、领导选举、旧回调与 PID 复用。
5. **Sandbox 与迁移**：CT-029…CT-035 覆盖 Beta → Release、Bookmark 与仓库丢失；
   Release 公证与安装升级仍需人工执行。

完整状态表见 [`Engineering/IMPLEMENTATION_STATUS.md`](Engineering/IMPLEMENTATION_STATUS.md)，
测试矩阵见 [`Engineering/REGRESSION_MATRIX.md`](Engineering/REGRESSION_MATRIX.md)。
未完成真实 iCloud、公证与安装升级验收前，不应把版本标记为 Stable 已完整验收。
