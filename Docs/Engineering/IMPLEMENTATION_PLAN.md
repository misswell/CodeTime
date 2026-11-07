# CodeTime 可靠性整改实施计划

## 1. 范围与基线

- 产品：CodeTime（macOS 本地增量备份 + iCloud 跨设备备份）
- 目标版本：`v1.0.0 Stable`
- 整改基线：`v1.0.0-beta.1`，审查提交 `1888cc3`
- 约束：不改变“Kopia 本地仓库 + 加密云端镜像”的基本架构；不以删除旧数据、跳过测试或仅改文档的方式通过验收。

## 2. 设计原则

1. **失败关闭（fail-closed）**：无法确认的状态不得报告成功；无法读取的对象不得视为不存在。
2. **提交点唯一**：云端 Generation 只有在对象全部上传、清单写入、上传确认、回读解密一致后才算发布。
3. **删除前证明无引用**：GC 先完整枚举所有清单（含墓碑），再重新验证，最后才删除对象。
4. **身份优先于路径**：跨进程租约使用 PID + 进程启动时间；哈希缓存使用 inode/大小/mtime 身份。
5. **状态可恢复**：GC、恢复、迁移均持久化阶段与进度，崩溃后可继续。
6. **未知即错误**：不可读目录、失效 Bookmark、不可访问的 iCloud 文件都必须显式报错。
7. **测试即规格**：每个 P0/P1/P2 问题都有唯一编号和永久回归测试，测试不因修复而被弱化。

## 3. 实施顺序

整改按“先阻断数据损坏，再补可靠性，最后做性能与体验”的顺序推进：

| 阶段 | 内容 | 主要产物 | 状态 |
|---|---|---|---|
| 0 | 基线与审查复核 | 问题清单、测试骨架、模块边界 | 完成 |
| 1 | 云端发布与 GC 安全 | `CloudMirrorStore` 重写、GC 日志、哈希校验 | 完成 |
| 2 | 恢复系统 | 候选枚举、断点恢复、临时仓库、恢复后校验 | 完成 |
| 3 | 仓库生命周期 | Repository 状态机、禁止自动创建空仓库 | 完成 |
| 4 | 并发与任务 | 租约、心跳、重试退避、删除防复活 | 完成 |
| 5 | Sandbox 与迁移 | Bookmark、iCloud 协调、Beta → Release 迁移 | 完成 |
| 6 | 调度与维护 | 后台验证/GC、运行状态持久化、日志轮转 | 完成 |
| 7 | 性能与 UI 语义 | 并发上传、流式哈希、缓存上限、真实状态文案 | 完成 |
| 8 | 测试与发布门禁 | CT-001…CT-044、CI、Release 脚本 | 完成 |
| 9 | 全量验证与交付 | 全量测试、构建、Release 检查、报告 | 进行中 |

## 4. 模块与文件映射

| 模块 | 关键文件 |
|---|---|
| 云端存储 | `Packages/CodeTimeKit/Sources/CloudMirrorStore/CloudMirrorStore.swift`、`ICloudSupport.swift`、`CloudModels.swift` |
| 领域模型 | `Packages/CodeTimeKit/Sources/SharedModels/ReliabilityModels.swift`、`CloudModels.swift`、`Project.swift` |
| 持久化 | `Packages/CodeTimeKit/Sources/Persistence/SQLiteStore.swift` |
| 服务层 | `Packages/CodeTimeKit/Sources/CodeTimeCore/CodeTimeService.swift`、`BackupScheduler.swift` |
| 迁移与路径 | `Packages/CodeTimeKit/Sources/CodeTimeCore/DataMigration.swift`、`ProjectPathValidator.swift` |
| Kopia/进程 | `Packages/CodeTimeKit/Sources/BackupEngine/KopiaBackupEngine.swift`、`ProcessRunner.swift` |
| 安全 | `Packages/CodeTimeKit/Sources/Security/CryptoBox.swift`、`KeychainStore.swift` |
| 诊断 | `Packages/CodeTimeKit/Sources/Diagnostics/FileLogger.swift` |
| UI/Agent | `Apps/CodeTime/**` |
| 自动化 | `Packages/CodeTimeKit/Tests/CodeTimeKitTests/**`、`Scripts/**`、`.github/workflows/**` |

## 5. 验证策略

1. **单元/集成测试**：`swift test --package-path Packages/CodeTimeKit`（由 `Scripts/test.sh` 注入 Bundled Kopia）。
2. **故障注入**：不可读清单、上传未确认、哈希不一致、租约冲突、PID 复用、Bookmark 失效、磁盘满（受环境限制）。
3. **并发测试**：双 Agent 领导选举、双执行器租约、并发发布同一对象、旧回调覆盖新状态。
4. **迁移测试**：构造 v1 SQLite 数据库执行 v2 迁移，验证字段与数据不丢失；Beta 数据目录迁移验证源目录保留。
5. **发布检查**：Debug/Release 构建、静态 Entitlements 校验、`verify_release.sh`、公证与 stapling（需 Developer ID 凭据）。
6. **真机验收**：两台 Mac 登录同一 iCloud，使用签名 Release 构建执行发布/恢复（未在本次环境执行，见 `KNOWN_LIMITATIONS.md`）。

## 6. 回滚与保护

- 所有数据库迁移均为增量 `ALTER TABLE` / `CREATE TABLE IF NOT EXISTS`，失败时事务回滚，不删除旧表。
- Beta → Release 迁移先复制到 staging，校验文件数与字节数后才切换，并保留源目录。
- 云端清单是提交点；发布失败会移除未验证清单（移除失败则显式报错），旧 Generation 不受影响。
- GC 使用墓碑与宽限期；重新验证失败时恢复墓碑并中止，不删除对象。
- 发布脚本在签名、公证或校验失败时终止，不生成“看似成功”的产物。
