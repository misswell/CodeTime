# 回归测试矩阵

## 1. 运行方式

```bash
# 全量（需要 Bundled Kopia）
Scripts/test.sh

# 全量 + 门禁（要求 0 失败且 CT-001…CT-069 全部存在）
Scripts/regression_gate.sh

# 单个用例
Scripts/test.sh --filter CloudMirrorRegressionTests/testCT001
```

`Scripts/test.sh` 会设置 `KOPIA_PATH=Resources/Kopia/kopia`，并在过滤条件匹配 0 个测试时失败，避免“过滤写错但显示通过”。

## 2. 默认门禁用例

| 编号 | 测试类 | 场景 | 必须保持的不变量 | 默认运行 |
|---|---|---|---|---|
| CT-001 | CloudMirrorRegressionTests | 任意清单不可读时执行 GC | 清理中止，不删除任何对象；原因写入报告 | 通过 |
| CT-002 | 同上 | GC 在墓碑阶段中断后重跑 | 从持久化阶段继续，不跳过宽限期 | 通过 |
| CT-003 | 同上 | 零保留天数 + 同步宽限期 | 清单删除仍等待独立 `sweepGrace` | 通过 |
| CT-004 | 同上 | 同大小不同内容对象 | SHA-256 不一致导致校验失败，不接受大小匹配 | 通过 |
| CT-005 | 同上 | iCloud 未确认上传 | 不产生 Generation | 通过 |
| CT-006 | 同上 | iCloud 元数据读取失败 | 视为失败，不视为“已上传” | 通过 |
| CT-007 | 同上 | 云端文件不可读 | 失败关闭，不把不可读文件当不存在 | 通过 |
| CT-008 | 同上 | 两个发布者写同一对象 | 保留一份可验证对象，不产生双写损坏 | 通过 |
| CT-009 | 同上 | 清单发布失败 | 旧 Generation 完整，未验证清单不可见 | 通过 |
| CT-010 | 同上 | 哈希缓存文件身份变化 | 重新计算哈希，不复用过期值 | 通过 |
| CT-011 | 同上 | 两台设备发布独立 Generation | 互不覆盖，均可枚举 | 通过 |
| CT-012 | 同上 | GC 期间出现新 Generation | 新版本及其对象被保留 | 通过 |
| CT-013 | RecoveryRegressionTests | 恢复中断后重启 | 已校验对象跳过，继续剩余对象 | 通过 |
| CT-014 | 同上 | 恢复复制失败 | 正式仓库未被修改 | 通过 |
| CT-015 | 同上 | 恢复对象哈希不匹配 | 恢复失败，不写入损坏对象 | 通过 |
| CT-016 | 同上 | 多设备恢复信息、密钥不匹配 | 候选标记原因，不误用错误密钥 | 通过 |
| CT-017 | 同上 | 第一个候选不可用 | 继续搜索其他候选 | 通过 |
| CT-018 | 同上 | 恢复后仓库/快照校验缺失 | 不允许报告恢复完成 | 通过 |
| CT-019 | 同上 | 云端恢复任务重启 | 任务状态与进度可恢复 | 通过 |
| CT-020 | 同上 | 重复恢复同一 Generation | 幂等，不产生第二份污染 | 通过 |
| CT-021 | ConcurrencyPersistenceRegressionTests | 项目删除后旧任务回调 | 项目不复活、不重新启用 | 通过 |
| CT-022 | 同上 | 用户暂停后旧任务回调 | 暂停状态不被覆盖 | 通过 |
| CT-023 | 同上 | 第二个执行器申请租约 | 被拒绝，不并发写同一仓库 | 通过 |
| CT-024 | 同上 | 配置修订传播 | 旧修订不能覆盖新配置 | 通过 |
| CT-025 | 同上 | 全局暂停 | 调度门关闭，任务不启动 | 通过 |
| CT-026 | 同上 | 两个 Agent 同时启动 | 只有一个领导进程创建快照 | 通过 |
| CT-027 | 同上 | Agent 崩溃留下运行中任务 | 租约过期后可重试 | 通过 |
| CT-028 | 同上 | PID 被系统复用 | 用启动时间区分，不误判任务存活 | 通过 |
| CT-041 | 同上 | 失败任务重试 | 指数退避、抖动、永久错误分类正确 | 通过 |
| CT-029 | SandboxPerformanceRegressionTests | Beta → Release 数据迁移 | 数据库/仓库/Bookmark 无损，源目录保留 | 通过 |
| CT-030 | 同上 | 外部项目与递归路径 | 外部目录允许；仓库/数据目录/父子重叠拒绝 | 通过 |
| CT-031 | 同上 | 外部镜像 Bookmark 编解码 | 重新打开后仍可访问 | 通过 |
| CT-032 | 同上 | 过期/失效 Bookmark | 显式 `bookmarkFailed`，不静默降级 | 通过 |
| CT-033 | 同上 | 项目 Bookmark 与 Agent 共享 | Agent 能访问 UI 授权目录 | 通过 |
| CT-034 | 同上 | 全新 Sandbox 启动 | 首次启动路径与授权初始化成功 | 通过 |
| CT-035 | 同上 | 本地仓库目录丢失 | 不自动创建空仓库，报 `repositoryMissing` | 通过 |
| CT-036 | 同上 | 10 万文件排除预览 | 完整扫描且无权限错误 | **跳过**（需 `CODETIME_SCALE_TESTS=1`） |
| CT-037 | 同上 | 100 万文件扫描上限 | 在 `maxFiles` 处截断并显式报告 | **跳过**（需 `CODETIME_SCALE_TESTS=1`） |
| CT-038 | 同上 | 8 MB 大文件哈希 | 分块流式哈希与一次性结果一致 | 通过 |
| CT-039 | 同上 | 搜索结果超过上限 | 返回截断标记与原因，不假装完整 | 通过 |
| CT-040 | 同上 | 超过预览上限的大文件 | 显式错误，不截断后返回成功 | 通过 |
| CT-042 | 同上 | 同一秒内多次日志轮转 | 归档名唯一，日志总量有界 | 通过 |
| CT-043 | 同上 | 活动/缓存表长期增长 | 定期裁剪，表大小有界 | 通过 |
| CT-044 | 同上 | 磁盘写入 ENOSPC | 错误分类为磁盘空间，仓库不被破坏 | **跳过**（需可控小容量卷，本机未注入） |
| CT-045 | SecondRoundRegressionTests | Release 已初始化的空数据库/仓库请求 Beta 迁移 | 迁移请求被接受，目标最终使用 Beta 数据 | 通过 |
| CT-046 | 同上 | 目标已有空 repositories/cache | 不阻止迁移，整根替换成功 | 通过 |
| CT-047 | 同上 | Beta 仓库包含隐藏 `.shards` | 隐藏文件完整迁移 | 通过 |
| CT-048 | 同上 | 迁移复制阶段取消 | 目标保持原样，之后可重新迁移 | 通过 |
| CT-049 | 同上 | 恢复目录存在损坏文件和残留临时文件 | 自动替换并清理，恢复成功 | 通过 |
| CT-050 | 同上 | 恢复任务处于 committing | 状态可恢复，重启后继续提交 | 通过 |
| CT-051 | 同上 | 同一 Repository 多设备 | 严格使用用户选择的 deviceID | 通过 |
| CT-052 | 同上 | 最新 Generation 对象缺失 | 候选不可恢复并报告原因 | 通过 |
| CT-053 | 同上 | 云端对象缺失后校验 | 结果失败，数据库不保留 verified | 通过 |
| CT-054 | 同上 | aborted GC + 不可读墓碑 | 不删除墓碑引用对象 | 通过 |
| CT-055 | 同上 | 两个 SQLite 连接竞争同一任务 | 只有一个租约成功 | 通过 |
| CT-056 | 同上 | SQLite 丢失、仓库目录保留 | 重新发现仓库 ID/路径 | 通过 |
| CT-057 | 同上 | iCloud 镜像目录作为项目 | 明确拒绝 | 通过 |
| — | ICloudAcceptanceTests | 单 Mac 真实 iCloud 发布/恢复 | 上传确认、发布、恢复哈希一致 | **跳过**（需 `CODETIME_ICLOUD_TESTS=1` 与真实容器；双 Mac 为人工报告） |
| CT-058 | ThirdRoundRegressionTests | 双 Mac 验收门禁输入 | 模板/FAIL 行/缺字段/tag 不匹配全部拒绝，完整 PASS 通过 | 通过 |
| CT-059 | 同上 | 已登记仓库丢失 + 不同/多个仓库；SQLite+Keychain 双丢失 | 不自动切换仓库；不生成新密钥（fail-closed） | 通过 |
| CT-060 | 同上 | Beta Agent/Scheduler/Kopia 锁被持有 | 迁移拒绝并提示退出旧版；释放后完整迁移 | 通过 |
| CT-061 | 同上 | 迁移请求生命周期 | hasPendingRequest 随请求创建/完成翻转 | 通过 |
| CT-062 | 同上 | Keychain 不可读后的恢复密钥修复 | 错误密钥拒绝；正确密钥恢复 master-key 与仓库密码 | 通过 |
| CT-063 | 同上 | 双连接/双 Service 竞争同一项目任务 | 只有一个租约成功；owner 之外不能 finish/retry；过期+进程死亡才可回收 | 通过 |
| CT-064 | 同上 | 最新 Generation 不可读且曾有 verified | verifyCloud 清除 verifiedAt，列表保留损坏占位 | 通过 |
| CT-065 | 同上 | 旧上传回调 vs 最新快照状态 | 项目状态始终由最新快照推导 | 通过 |
| CT-066 | 同上 | 发布/GC 与本地仓库锁 | 上传等待期间不持有仓库锁；GC 持有仓库锁时仍可完成 | 通过 |
| CT-067 | 同上 | 迁移中断（取消/崩溃） | staging 被回收，源目录完好，重试成功 | 通过 |
| CT-068 | 同上 | workflow_dispatch 手动发布 | publish_release 输入与两个发布步骤、artifact 上传齐全，YAML 合法 | 通过 |
| CT-069 | 同上 | 回归门禁自身 | 缺失 CT、未登记跳过、非 0 失败均使门禁失败；白名单跳过通过 | 通过 |
| CT-070 | FourthRoundRegressionTests | Manifest 聚合字段篡改 | repositoryHash/totalBytes 不匹配被发现 | 通过 |
| CT-071 | 同上 | 多设备 GC | 其他设备存在时跳过物理删除；单设备正常 | 通过 |
| CT-072 | 同上 | 生命周期锁在 root 外部 | 锁文件不在可替换 root 内；迁移锁阻断 SQLite 打开 | 通过 |
| CT-073 | 同上 | 旧上传完成覆盖新状态 | 项目状态由最新 Snapshot 推导 | 通过 |
| CT-074 | 同上 | Restore Job 身份绑定 | 编译期四重绑定检查存在 | 通过 |
| CT-075 | 同上 | 进程崩溃迁移恢复 | 取消后源完好可重试；journal 安装阶段正确清理 | 通过 |
| CT-076 | 同上 | 发布 Tag/Commit 一致性 | workflow 使用 --target $GITHUB_SHA | 通过 |
| CT-078 | 同上 | 验收门禁精确匹配 | 使用 -Fx -e 完整行匹配 | 通过 |
| CT-080 | 同上 | Job Lease 类型约束 | 非 backup 类型 Job 不能被重试声明 | 通过 |
| CT-081 | 同上 | 云端状态分类 | notDownloaded/unreadable/corrupted 映射到不同状态 | 通过 |
| — | 同上 | 大规模数据性能 | 200 文件备份+恢复+逐文件内容校验 | 通过 |

## 3. Schema 与集成用例

| 编号 | 测试类 | 场景 | 不变量 | 状态 |
|---|---|---|---|---|
| MIG-001 | SchemaMigrationTests | v1 数据库升级到 v2 | 新字段/表存在，旧数据完整，重复迁移幂等 | 通过 |
| MIG-002 | SchemaMigrationTests | v2 迁移中途失败的数据库 | 下次启动补齐缺失列，不丢数据 | 通过 |
| — | CloudMirrorStoreTests | 发布、恢复、校验、GC 保留引用 | 对象不可变；引用对象不被删除 | 通过 |
| — | IntegrationTests | Kopia 快照、搜索、校验、云发布 | 真实 Kopia 二进制路径下端到端可用 | 通过（Kopia 可用时） |

## 4. 门禁规则

`Scripts/regression_gate.sh` 会：

1. 运行全量测试；
2. 要求输出包含 `with 0 failures`；
3. 要求 `testCT001_` … `testCT069_` 全部出现在测试列表中（缺失即失败）；CT-070…CT-081 由 XCTest 编译期保证；
4. 除已登记的环境跳过（CT-036/CT-037/CT-044/单 Mac iCloud）外，任何 XCTSkip 都使门禁失败；
5. 输出 `regression gate: PASS` 才允许进入发布流程。

CI 的 `regression-gate` job 与 Release 的稳定版 job 均调用该脚本。规模测试与真实 iCloud 验收不在默认 CI 中伪造通过，而是明确标记为 NOT RUN，并由发布检查清单要求人工执行。
