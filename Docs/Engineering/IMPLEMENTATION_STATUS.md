# 实施状态

本表记录任务书中每项问题的唯一编号、修改位置、修复内容、对应测试与当前状态。状态含义：

- **PASS**：代码已修改，对应自动化测试在本机实际运行通过。
- **PASS（静态）**：代码/脚本已修改并通过静态检查或编译，但没有可自动执行的运行时验收。
- **PARTIAL**：功能已实现，但环境受限的验收项未执行（明确列出）。
- **FAIL**：未修复或测试失败。

## P0：数据安全阻断项

| ID | 问题 | 修改文件 | 修复内容 | 测试 | 状态 |
|---|---|---|---|---|---|
| P0-01 | GC 可能删除有效历史版本引用的对象 | `CloudMirrorStore.swift`、`ReliabilityModels.swift` | 完整枚举全部清单；至少保留 2 个版本；墓碑清单引用对象纳入保护集；删除前从零重新验证；`sweepGrace` 与用户保留期解耦 | CT-001、CT-002、CT-003、CT-012、CT-044 | PASS |
| P0-02 | 清单不可读时 GC 仍可能继续 | `CloudMirrorStore.swift` | 枚举、墓碑读取、重新验证任一失败即中止；中止阶段写入日志；墓碑恢复失败时抛错而非返回“已中止” | CT-001、CT-002 | PASS |
| P0-03 | iCloud 上传状态检查失败时放行 | `ICloudSupport.swift` | 上传跟踪区分“未确认/文件不存在/非 iCloud 项”；等待超时、协调失败、元数据不可读均报错；不再用布尔默认值表示成功 | CT-005、CT-006、CT-007 | PASS |
| P0-04 | 对象只校验大小，不校验 SHA-256 | `CloudMirrorStore.swift` | `hashStable` 前后指纹校验；对象写入后重新流式哈希；已存在对象哈希不一致或不可校验时隔离并报错 | CT-004、CT-015 | PASS |
| P0-05 | 哈希缓存返回过期内容哈希 | `CloudMirrorStore.swift`、`ReliabilityModels.swift` | 缓存项携带 file identity、大小、mtime；任一不匹配即重新哈希；缓存读取/写入失败只影响性能，不影响正确性 | CT-010 | PASS |
| P0-06 | Manifest 在对象未全部上传时发布 | `CloudMirrorStore.swift` | 对象全部写入并验证后才写清单；清单临时文件原子移动；等待 iCloud 确认；回读并解密比对 Generation ID 与对象集合；失败移除未验证清单 | CT-005、CT-009 | PASS |
| P0-07 | 恢复不支持中断和继续 | `CodeTimeService.swift`、`CloudMirrorStore.swift`、`SQLiteStore.swift` | 恢复任务持久化阶段与已校验对象；临时仓库写入；中断后跳过已校验对象；完成后校验仓库与快照 | CT-013、CT-014、CT-019、CT-020 | PASS |
| P0-08 | 本地仓库丢失后自动初始化空仓库 | `KopiaBackupEngine.swift` | 引入 Repository 状态机；`missing`/`corrupted` 为硬错误；仅 `uninitialized` 允许创建；不可读目录不再视为空 | CT-035 | PASS |
| P0-09 | Kopia/云端校验错误报告成功 | `KopiaBackupEngine.swift`、`CodeTimeService.swift`、`CloudMirrorStore.swift` | 校验读取 Kopia 错误计数与退出码；云端校验逐对象 SHA-256；清单回读不一致视为失败 | CT-018、集成测试 | PASS |
| P0-10 | 备份结束用旧 Project 覆盖用户最新状态 | `SQLiteStore.swift`、`CodeTimeService.swift` | 运行时更新按 `config_revision` 与 lifecycle 守卫；已删除/删除中项目拒绝复活；暂停状态不被旧回调覆盖 | CT-021、CT-022、CT-024 | PASS |
| P0-11 | Beta → Release 未设计数据迁移 | `DataMigration.swift`、`AppPaths.swift`、`CodeTimeService.swift` | 迁移计划、staging 复制、文件数/字节数校验、journal 恢复、源目录保留、Bookmark 重建入口 | CT-029、CT-034 | PASS |
| P0-12 | 恢复密钥与恢复信息不对应 | `CloudMirrorStore.swift`、`CryptoBox.swift` | 恢复信息记录密钥指纹；逐个候选校验指纹与解密；不匹配候选标记原因并继续搜索 | CT-016、CT-017 | PASS |

## P1：正式版可靠性要求

| ID | 问题 | 修改文件 | 修复内容 | 测试 | 状态 |
|---|---|---|---|---|---|
| P1-01 | UI 与 Agent 配置不同步 | `CodeTimeService.swift`、`SQLiteStore.swift`、`AppModel.swift` | 配置持久化统一写入数据库；`config_revision` 递增；调度器每次读取最新设置 | CT-024 | PASS |
| P1-02 | 多进程任务可能并发执行或误判失败 | `SQLiteStore.swift`、`ReliabilityModels.swift`、`BackupScheduler.swift` | 任务租约（PID + 启动时间）、心跳、过期回收；领导进程文件锁；崩溃任务可重试 | CT-023、CT-026、CT-027、CT-028 | PASS |
| P1-03 | LaunchAgent 生命周期不完整 | `LaunchAgentManager.swift`、`AgentRunner.swift`、`Resources/LaunchAgents` | 安装/卸载/Bootstrap 重载；Agent 与 UI 共用服务与数据库；静态校验 plist label 与 BundleProgram | CT-034、`validate_entitlements.sh` | PASS |
| P1-04 | Sandbox 文件授权与 Bookmark | `CryptoBox.swift`、`CodeTimeService.swift`、`AppModel.swift` | 安全作用域 Bookmark 编解码；失效时显式 `bookmarkFailed`；项目授权与本地镜像授权分别记录 | CT-031、CT-032、CT-033 | PASS |
| P1-05 | iCloud 文件协调 | `ICloudSupport.swift` | 读写/下载使用 `NSFileCoordinator`；区分未下载、下载中、不可读；协调失败显式抛出 | CT-006、CT-007 | PASS |
| P1-06 | 项目路径与仓库路径重叠 | `ProjectPathValidator.swift`、`CodeTimeService.swift`、`ProjectEditorView.swift` | 使用真实路径与路径组件判断包含关系；拒绝项目位于 CodeTime 数据目录、仓库、保护副本、镜像内；拒绝父子项目重叠 | CT-030 | PASS |
| P1-07 | ProcessRunner 进程回收与取消不安全 | `ProcessRunner.swift` | 进程组启动；取消时校验 PID 启动时间；输出有上限；超时后终止整个进程组 | 集成测试、CT-027、CT-028 | PASS |
| P1-08 | 恢复任务状态管理 | `CodeTimeService.swift`、`SQLiteStore.swift`、`ReliabilityModels.swift` | 恢复任务状态机与进度持久化；重复恢复幂等；失败不污染正式仓库 | CT-013、CT-014、CT-019、CT-020 | PASS |
| P1-09 | 缺少云端完整性周期检查 | `CodeTimeService.swift`、`SQLiteStore.swift` | `maintenance_state` 记录下次运行时间；到期才执行；未完成的验证不写入 `verified` | CT-043、校验集成测试 | PASS |
| P1-10 | 缺少后台 GC 调度 | `CodeTimeService.swift`、`BackupScheduler.swift` | 调度器统一触发维护任务；GC 阶段与日志持久化；等待宽限期不误报完成 | CT-002、CT-003 | PASS |
| P1-11 | 失败重试无退避 | `ReliabilityModels.swift`、`SQLiteStore.swift`、`BackupScheduler.swift` | 指数退避（60/300/900/1800/3600 秒 + 抖动）；永久错误不重试；`next_retry_at` 持久化 | CT-041 | PASS |
| P1-12 | 搜索、Diff、排除预览错误处理 | `KopiaBackupEngine.swift`、`DiffViewerView.swift`、`Exclusion.swift` | 搜索达到上限显式截断；大文件预览显式降级；排除规则解析错误返回原因而非静默忽略 | CT-039、CT-040、排除规则测试 | PASS |

## P2：性能与体验

| ID | 问题 | 修改文件 | 修复内容 | 测试 | 状态 |
|---|---|---|---|---|---|
| P2-01 | 上传并发未真正生效 | `CloudMirrorStore.swift` | 有界任务组按 `uploadParallelism` 并发，失败传播并取消其余任务 | CT-008（并发正确性） | PASS（正确性） |
| P2-02 | 仓库哈希无增量缓存 | `CloudMirrorStore.swift`、`SQLiteStore.swift` | 对象索引 + 哈希缓存按文件身份复用；失效自动重算 | CT-010 | PASS |
| P2-03 | 大仓库扫描性能与上限 | `CloudMirrorStore.swift`、`Exclusion.swift` | 枚举错误收集；超过 `maxScannedFiles` 显式标记截断；流式处理不持有全部文件内容 | CT-036、CT-037（默认跳过，需 `CODETIME_SCALE_TESTS=1`） | PARTIAL |
| P2-04 | 目录缓存无容量限制 | `KopiaBackupEngine.swift`、`SQLiteStore.swift` | 有界 LRU；活动与缓存表定期裁剪 | CT-043 | PASS |
| P2-05 | 日志无限增长 | `FileLogger.swift` | 日志轮转、唯一归档名、按数量/时间清理；移动失败不丢原日志 | CT-042 | PASS |
| P2-06 | FSEvents 功能描述不真实 | `SettingsView.swift`、`ProjectEditorView.swift`、`BackupScheduler.swift` | 无 FSEvents 实现，统一改为“按频率轮询 + 唤醒补跑一次”的真实描述 | 静态检查 | PASS（静态） |
| P2-07 | 低磁盘空间处理 | `ReliabilityModels.swift`、`CodeTimeService.swift` | 写入错误分类为 `diskSpace`；磁盘检查使用卷可用容量；错误不被吞掉 | CT-044（需故障注入，NOT RUN） | PARTIAL |
| P2-08 | 大文件 Diff 无保护 | `DiffViewerView.swift`、`KopiaBackupEngine.swift` | 超过预览上限显式报错，不截断后声称完整 | CT-040 | PASS |
| P2-09 | 恢复/任务进度不准确 | `CodeTimeService.swift`、`ReliabilityModels.swift`、`AppModel.swift` | 进度按已校验对象与字节持久化；状态来自实际结果 | CT-013、CT-019 | PASS |
| P2-10 | Dashboard 状态不准确 | `CodeTimeService.swift`、`DashboardView.swift` | 云端概览失败时记录告警并显示“不可用”，不使用伪造数据 | 静态检查 | PASS（静态） |

## 工程门禁与迁移

| ID | 项目 | 修改文件 | 内容 | 验证 | 状态 |
|---|---|---|---|---|---|
| MIG-001 | v1 → v2 增量迁移 | `SQLiteStore.swift`、`SchemaMigrationTests.swift` | 事务内 `ALTER TABLE`/建表；`user_version` 升级；重复执行幂等 | MIG-001 | PASS |
| MIG-002 | 部分迁移崩溃修复 | `SQLiteStore.swift`、`SchemaMigrationTests.swift` | 每个字段独立检查存在性；中途失败的数据库下次启动补齐 | MIG-002 | PASS |
| CI-001 | CI 分阶段门禁 | `.github/workflows/ci.yml` | Build → Unit → Integration → Cloud → Recovery → Concurrency → Security → Release Build → Entitlements → Regression | 工作流静态检查 | PASS（静态） |
| REL-001 | Release 渠道分类 | `.github/workflows/release.yml`、`Scripts/package_*.sh` | beta/rc/stable 分类；stable 要求签名、公证、stapling | 脚本静态检查 | PASS（静态） |
| REL-002 | Stable 不允许缺少公证 | `Scripts/package_release.sh`、`Scripts/verify_release.sh` | 无 Developer ID / 公证凭据直接失败；发布后验证签名与票据 | 脚本静态检查 | PASS（静态） |
| REL-003 | Kopia 二进制固定与校验 | `Scripts/fetch_kopia.sh` | 固定 0.23.1、SHA-256、架构、版本、签名与 sidecar 校验 | 脚本实际运行 | PASS |
| SEC-001 | Entitlements 静态校验 | `Scripts/validate_entitlements.sh` | 校验 iCloud 容器、App Group、Keychain、Kopia 继承权限、Beta 不声明 iCloud | 脚本实际运行 | PASS |

## 第二轮整改（c81fda5 审查反馈）

| ID | 问题 | 修改文件 | 修复内容 | 测试 | 状态 |
|---|---|---|---|---|---|
| R2-01 | Beta → Release 目标已初始化时被拒绝 | `DataMigration.swift`、`AppModel.swift` | 请求允许替换新建的空数据根；整根 staging 完成后再原子替换；保留旧根备份 | CT-045、CT-046 | PASS |
| R2-02 | 迁移逐项安装冲突且不可回滚 | `DataMigration.swift` | 使用 `replaceItemAt` 整根切换；取消/失败时目标不变；备份旧根 | CT-048 | PASS |
| R2-03 | 迁移跳过隐藏文件 | `DataMigration.swift` | 复制枚举不再跳过隐藏项；计划与实际复制使用同一规则 | CT-029、CT-047 | PASS |
| R2-04 | 迁移复制活动 SQLite | `DataMigration.swift` | 使用 SQLite Backup API 生成一致快照；校验 `integrity_check` | CT-029 | PASS |
| R2-05 | 迁移没有进程协调 | `DataMigration.swift` | 迁移锁 + Agent 锁；失败可重试 | CT-048 | PASS |
| R2-06 | 恢复中断留下半文件 | `CloudMirrorStore.swift` | 临时文件 → 校验 → 原子移动；损坏目标自动替换 | CT-013、CT-049 | PASS |
| R2-07 | committing 阶段不可续传 | `ReliabilityModels.swift`、`SQLiteStore.swift`、`CodeTimeService.swift` | `.committing` 纳入可恢复状态；已移动仓库继续提交；密钥/记录幂等写入 | CT-050 | PASS |
| R2-08 | 恢复被 snapshotCount 阻断 | `CodeTimeService.swift` | 移除快照行数门槛，以实际仓库槽位为准 | CT-050、服务测试 | PASS |
| R2-09 | 多设备恢复未绑定用户选择 | `CloudMirrorStore.swift`、`CodeTimeService.swift` | `recover` 增加 `deviceID` 过滤并校验；恢复凭据内部 ID 必须一致 | CT-051 | PASS |
| R2-10 | 候选只验证清单可解密 | `CloudMirrorStore.swift` | 校验 manifest 的仓库/设备/版本 ID；最新版本对象存在性；候选不可恢复时禁止选择 | CT-052 | PASS |
| R2-11 | 校验失败仍标记 verified | `CodeTimeService.swift` | 只有 passed 才写 verified；失败清除 `verifiedAt`；`verifyCloud` 使用含不可读项的入口列表 | CT-053 | PASS |
| R2-12 | GC 墓碑引用未纳入 Sweep | `CloudMirrorStore.swift`、`SQLiteStore.swift` | aborted 日志先恢复墓碑；Sweep 保护未解决墓碑；tombstoning 中断继续移动计划 | CT-054 | PASS |
| R2-13 | 租约/CAS 非原子 | `SQLiteStore.swift` | 所有读-检查-写使用 `BEGIN IMMEDIATE`；心跳失败取消任务并停止回写 | CT-055 | PASS |
| R2-14 | SQLite 丢失后无法发现旧仓库 | `RepositoryDiscovery.swift`、`CodeTimeService.swift` | 扫描 `repositories/*` 与 `repository.json`；唯一仓库复用；多仓库拒绝自动选择 | CT-056 | PASS |
| R2-15 | iCloud 镜像可作为项目 | `ProjectPathValidator.swift`、`CodeTimeService.swift` | 实际 iCloud 根加入保护路径 | CT-057 | PASS |
| R2-16 | 上传期间长期占用 Kopia 锁 | `CloudMirrorStore.swift`、`CodeTimeService.swift` | 独立 publish lock；本地对象复制后释放 repository lock | 静态检查 | PASS（静态） |
| R2-17 | 发布提交后缓存失败被当失败 | `CloudMirrorStore.swift` | manifest 提交后 recovery-info/索引失败仅告警；幂等确认已提交版本 | CT-053、静态检查 | PASS |
| R2-18 | 云端发布无独立重试 | `CodeTimeService.swift`、`BackupScheduler.swift`、`CloudModels.swift` | `.upload` 任务、退避、幂等确认；发布失败不再等待下一次备份 | 代码路径 + 全量测试 | PASS |
| R2-19 | `--once` 绕过全局暂停 | `BackupScheduler.swift` | `runOnce` 先检查 `allowsScheduling` | 静态检查 | PASS（静态） |
| R2-20 | localOnly 显示为 synced | `CodeTimeService.swift` | 区分 `.synced` 与 `.localOnly` | 静态检查 | PASS（静态） |
| R2-21 | 哈希缓存缺少 ctime | `ReliabilityModels.swift`、`CloudMirrorStore.swift` | FileStamp 增加 ctime；缓存必须匹配 ctime | CT-010 | PASS |
| R2-22 | GC 看不到隐藏临时对象 | `ICloudSupport.swift`、`CloudMirrorStore.swift` | 对象枚举包含隐藏项；quarantine 按年龄清理 | CT-042、代码路径 | PASS（静态） |
| R2-23 | 手动发布 TAG 错误 | `.github/workflows/release.yml` | 手动输入 version/prerelease 生成 tag；下游统一使用解析后的 tag | YAML 校验 | PASS（静态） |
| R2-24 | 伪 iCloud XCTFail 测试 | `SandboxPerformanceRegressionTests.swift`、`Scripts/require_icloud_acceptance.sh` | 改为可执行单机 iCloud 往返；双 Mac 验收改为 Stable 必需的人工报告门禁 | iCloud 测试默认跳过；门禁静态检查 | PARTIAL（真机未执行） |

## 当前测试汇总

| 类别 | 数量 | 结果 |
|---|---|---|
| 全量测试（本机） | 166 | 0 失败，2 跳过 |
| CT-001…CT-044 | 44 | 42 通过，2 跳过（单机 iCloud 验收、CT-044 磁盘满；CT-036/037 在 scale=1 下真实执行） |
| CT-045…CT-057 | 13 | 13 通过 |
| CT-058…CT-116 | 59 | 59 通过 |
| CT-117…CT-128 | 12 | 12 通过（第七轮） |
| Schema 迁移 | 2 | 通过 |
| 静态发布检查 | 4 个脚本 | 通过（公证、stapling、真实 iCloud 未执行） |

统计口径以 `TEST_REPORT.md` 的机器可读块为唯一事实源（`Scripts/check_test_report.py` 强制校验）。
跳过项不是“通过”，原因与执行方式见 `REGRESSION_MATRIX.md` 与 `KNOWN_LIMITATIONS.md`。
