# 架构审查报告（第四轮）

审查基准：`c07c21f` | 日期：2026-11-07

## 模块依赖图

```
SharedModels ←──────────────────────────────┐
     ↑                                      │
Security                                     │
     ↑                                      │
CSQLite                                      │
     ↑                                      │
Persistence ──┐                              │
              │                              │
BackupEngine ─┤                              │
CloudMirrorStore ─┤                          │
GitIntegration ─┤                          │
Diagnostics ────┤                          │
              │                            │
CodeTimeCore ─┴──────────────────────────────┘
```

**结论：无循环依赖。** 依赖图为严格有向无环图。

## `try?` 使用审查

| 模块 | try? 数量 | 评估 |
|---|---|---|
| CloudMirrorStore | 30 | 大部分为 GC 中的 `try?` 清理（删除可能失败但不影响安全），和 `try?` 确认 iCloud 属性（nil 表示"不是 iCloud 文件"）。**1 处高风险**：`cleanup` 中 `try? fileManager.removeItem` 可能静默失败。 |
| CodeTimeService | 17 | 大部分为 `try? await database.xxx` 的活动记录写入（非关键路径）。**1 处需关注**：`try? await database.upsertSnapshot` 在 refreshSnapshots 中，合并结果可能不写入。 |
| KopiaBackupEngine | 14 | 主要是 Kopia 输出的 `try?` 解析（失败时返回默认值）和日志写入。安全。 |
| FileLogger | 12 | 日志写入失败不应影响业务。安全。 |
| DataMigration | 12 | `try? FileManager.removeItem` 清理临时文件。安全（失败不影响主流程）。 |
| AppModel | 12 | UI 层 `try?` 用于刷新和通知。安全。 |
| 其他模块 | ≤7 | 低风险。 |

**建议**：CloudMirrorStore.cleanup 中的 `try? removeItem` 应改为 `do/catch` 并记录失败的哈希。

## 吞掉错误的 catch 审查

| 模块 | 空 catch | 评估 |
|---|---|---|
| ICloudSupport | 9 | iCloud 属性读取失败返回 nil 是正确语义（表示"不是 iCloud 文件"）。安全。 |
| CloudMirrorStore | 40 | GC/清理路径中的 `try?` 失败不影响数据安全（对象不可变，下次重试）。 |
| GitInspector | 1 | git 命令失败返回 nil 是正确语义（Git 信息不可用）。 |
| SQLiteStore | 5 | 数据库操作中的 catch 会抛出 PersistenceError。安全。 |
| DataMigration | 4 | `try?` 用于 journal 写入和临时文件清理。失败不影响回滚路径。 |
| BackupScheduler | 7 | catch 块用于调度器 tick 中的容错（错误已由 service 记录）。安全。 |

**结论**：未发现真正"吞掉关键错误"的 catch 块。

## 过大文件

| 文件 | 行数 | 评估 |
|---|---|---|
| CodeTimeService.swift | ~2300 | **过大**。承担了备份执行、恢复、云端发布、验证、清理、迁移、诊断等多种职责。建议拆分为 BackupCoordinator + RestoreCoordinator + CloudPublishCoordinator + VerificationCoordinator。 |
| CloudMirrorStore.swift | ~1500 | 较大但职责单一（云端镜像存储）。可拆分 Publish/GC/Restore 子类。 |
| TimelineView.swift | ~750 | SwiftUI 视图，可接受。 |
| SQLiteStore.swift | ~1300 | SQLite 封装，职责单一。 |
| AppModel.swift | ~830 | SwiftUI 状态管理，可接受。 |

**建议**：v1.1 拆分 CodeTimeService.swift。

## 全局状态

未发现公开全局变量。所有状态通过 actor 隔离或 SwiftUI @Published 管理。

## 线程安全

- `SQLiteStore`：actor 隔离 ✓
- `CloudMirrorStore`：actor 隔离 ✓
- `CodeTimeService`：actor 隔离 ✓
- `BackupScheduler`：actor 隔离 ✓
- `LifecycleLock`：NSLock 保护 fd 操作 ✓
- `RepositoryLock`：@unchecked Sendable，fd 操作为系统调用 ✓
- `FileLogger`：actor 隔离 ✓

**结论**：无线程安全问题。

## 缓存审计

| 缓存 | 模块 | 有界 | 过期 |
|---|---|---|---|
| hashCache | CloudMirrorStore | 有界（内存字典） | 按 mtime 失效 |
| directoryCache | KopiaBackupEngine | 有界（按 snapshotID 清除） | 每次快照后清除 |
| usageCache | CodeTimeService | 有界（单条） | 300 秒 TTL |
| cachedSettings | CodeTimeService | 有界（单条） | saveSettings 时刷新 |
| cachedPassword | KopiaBackupEngine | 有界（单条） | 进程生命周期 |

## 资源泄漏

- RepositoryLock：defer release + deinit ✓
- LifecycleLock：defer release + deinit ✓
- Process：defer waitpid ✓
- FileHandle：defer close ✓
- DispatchSource：signal source 持有至进程退出 ✓

**结论**：无已知资源泄漏。
