# CodeTime 测试报告 — CodeTime 2.0（Cloud Format v3）

本报告绑定具体提交与门禁运行。三份工程文档（TEST_REPORT / IMPLEMENTATION_STATUS /
KNOWN_LIMITATIONS）的统计以下方机器可读块为唯一事实源，由
`Scripts/check_test_report.py` 强制校验；跳过项不计入通过。

<!-- test-report
{"commit":"376ff895652479a78d4043bf29ca9fc8133c09a5","run":"202611110006","executed":263,"failures":0,"skipped":3,"passed":260,"gate":"PASS","notRun":["双 Mac iCloud 真机验收","真实 Keychain 跨签名迁移","CT-044 磁盘写满","CT-037 百万文件压力测试"]}
-->

## 1. 绑定信息

| 项 | 值 |
|---|---|
| 交付 Commit SHA | `376ff89`（FSEvents、恢复续传、并发去重、每日内容校验与空间展示） |
| CI Run | `202611110006`（本次为本地门禁；CI 运行需在 CI 环境重新生成） |
| 门禁 | `Scripts/regression_gate.sh`（本地全量，`CODETIME_SCALE_TESTS=1`） |
| 门禁结果 | `PASS`，263 tests / 0 failures / 3 skipped |
| 回归索引 | `REGRESSION_INDEX.json`，CT-001 … CT-167（165 required） |
| 运行标识 | `202611110006`（本地门禁，非 CI；CI 运行需在 CI 环境重新生成） |
| 门禁日志 | `Docs/Engineering/TestArtifacts/376ff89-regression-gate.log`（原始输出归档） |

## 2. 环境

| 项 | 值 |
|---|---|
| 机器 | macOS 27.2（arm64，Apple Silicon） |
| Swift | Swift 5 语言模式，Swift 6 工具链 |
| 部署目标 | macOS 14.0 |
| Kopia | 0.23.1（仅旧引擎兼容测试使用） |
| 云端测试载体 | 本地镜像目录；v3 测试覆盖本地镜像与跨设备命名空间，真实 iCloud 容器未执行 |

## 3. 测试规模

- **全量门禁**：263 个 XCTest，260 通过，0 失败，3 跳过。
- 跳过项均为人工/规模验收，登记在 `REGRESSION_INDEX.json` 的
  `manualAcceptance=true`：CT-037 百万文件、CT-044 磁盘写满、单机真实 iCloud 往返。
- 规模测试（`CODETIME_SCALE_TESTS=1`）在门禁中真实执行 CT-036/CT-117 的规模变体。
- 计数口径：`passed = executed - failures - skipped`，跳过项不计入通过。

## 4. CodeTime 2.0 / Cloud Format v3 覆盖（CT-147 … CT-164）

| 编号 | 覆盖内容 | 关键断言 |
|---|---|---|
| CT-147 | FastCDC 内容定义分块 | 相同内容相同块 ID；插入/删除/少量修改只影响局部块；空文件、大文件、流式读取 |
| CT-148 | 内容寻址与对象封装 | HMAC 对象 ID、LZFSE 仅在实际变小时保留、AEAD 篡改失败、明文哈希校验 |
| CT-149 | 不可变 Merkle 树 | 未变化子树保留节点 ID；变更只重写对应节点 |
| CT-150 | 版本模型 | Manifest 完整性摘要；ChunkRef/节点 canonical JSON 稳定 |
| CT-151 | 云端对象存储 | 对象/节点幂等；节点加密；Commit 拒绝缺失或哈希不一致的 Manifest；包往返 |
| CT-152 | 本地索引 | 重扫无幽灵行；重试计数持久；pin 与可驱逐区分；迁移日志按 id 更新 |
| CT-153 | 项目扫描 | 排除项计数；符号链接不跟随；不可读子树显式标记不完整；身份增量判断 |
| CT-154 | 云优先引擎端到端 | 顺序发布、未变化零上传、追加式修改去重、删除保留历史、跨文件去重、取消、不完整扫描拒绝发布 |
| CT-155 | 按需恢复 | 单文件只下载自身块；目录恢复跳过兄弟目录；损坏对象中止；Manifest 篡改拒绝；路径穿越拒绝；不覆盖目标 |
| CT-156 | 缓存与本地副本驱逐 | LRU 预算、pin 不驱逐、只删除缓存根内文件、未确认上传不驱逐、驱逐失败上报 |
| CT-157 | 不可变对象包 | 包 ID = 内容哈希；越界/重复/截断拒绝；引擎打包、恢复从包内精确切片 |
| CT-158 | 迁移状态机 | 旧云端与 v3 基线都验证后才允许清理；失败 blocked 且保留旧数据；需显式同意；崩溃续跑 |
| CT-159 | 持久上传队列 | 失败保留加密数据；软上限暂停而非删除；崩溃续传；离线后恢复并提交 |
| CT-160 | BackupEngine v3 适配层 | 备份/列表/浏览/读取/Diff/单文件恢复/全量校验；损坏块使校验失败 |
| CT-161 | 服务层 v3 集成 | v3 模式不写 v2 generations；恢复经 staging；spool 上传确认后清空；空间统计准确 |
| CT-162 | 服务层迁移 | 未同意时旧仓库保留；基线验证后切换 v3；旧历史仍可见；释放后可临时下载 v2 仓库恢复旧版本 |
| CT-163 | 云端 GC | 先墓碑；引用重算；宽限期内不删除；只删无引用对象/版本；引用缺失立即中止 |
| CT-164 | 新 Mac 恢复 | 发现 v3 项目；恢复密钥校验；按需恢复；注册项目并继续浏览历史；不下载 Kopia 仓库 |
| CT-165 | 全新安装引擎选择 | 云端可用且无历史时直接使用 v3；已有快照的安装保持旧引擎直到迁移 |
| CT-166 | 恢复续传 | 中断保留 staging；重试复用已校验文件；成功后原子移走 |
| CT-167 | FSEvents 变化监听 | 事件去抖；最小变化间隔生效；FSEvents 仅优化，完整扫描兜底 |

## 5. 可靠性与兼容回归

- CT-001 … CT-146：v2 云端发布、GC 安全、恢复、租约、并发、迁移、Schema、发布门禁全部保持通过。
- v2/v3 并存：按版本归属选择引擎；跨格式 Diff 明确拒绝；v2 数据不被新引擎改写。
- 加密：所有数据块、Manifest、目录节点均为 AEAD；恢复密钥丢失无法通过哈希恢复。
- 节点加密在本轮加入，CT-151 重新覆盖 idempotent put/read。

## 6. 未执行项（NOT RUN）

| 项目 | 原因 | 执行方式 |
|---|---|---|
| 双 Mac iCloud 真机验收 | **NOT RUN**：需要两台真实 Mac、同一 iCloud 账号与签名 Release 构建 | 按 `Docs/releases/ICLOUD_ACCEPTANCE_TEMPLATE.md`；Stable 门禁强制报告 |
| 真实 Keychain 跨签名迁移 | **NOT RUN**：需要 Developer ID/Beta→Release 真机 | 按 `RELEASE_CHECKLIST.md` |
| CT-044 磁盘写满 | **NOT RUN**：需要可控 ENOSPC 卷 | 独立 APFS 小容量卷注入 |
| CT-037 百万文件压力测试 | **NOT RUN**：需要百万 inode 与独立卷 | `CODETIME_STRESS_TESTS=1` |
| v3 iCloud 本地副本驱逐真实行为 | **NOT RUN**：本地镜像不是 ubiquitous item | 真实 iCloud 容器中观察 `evictUbiquitousItem` 与空间变化 |
| v3 100 GB 性能验收 | **NOT RUN**：本机无 100 GB 标准数据集 | 按任务书 §17 数据集执行并记录 |

## 7. 门禁输出

```
regression gate: PASS
  executed: 263 tests, 0 failures
  skipped (manual acceptance only): testCT037_MillionFilesBoundedByLimit
testCT044_DiskFullLeavesRepositoryUntouched
testSingleMacICloudRoundTrip
  index: CT-001 … CT-167 (165 required)
  test-report check: PASS
```

## 8. 性能与空间（真实执行，详见 V3_ACCEPTANCE_REPORT §2.2）

`Packages/CodeTimeKit/Sources/V3Acceptance` 是独立的验收工具（不属于门禁测试）。在根卷
仅 11–23 GB 可用、外接卷 ACL 不可写的环境下，使用逻辑大小达标、部分物理随机数据的稀疏
数据集；原始 `V3PERF_RESULT` 见 `Docs/Engineering/TestArtifacts/v3-perf-*.log`。

| 场景 | 首次备份 | 增量 | 峰值 RSS | 本地 DB | spool 结束 | 云端 |
|---|---:|---:|---:|---:|---:|---:|
| 10 GiB 单文件（2.5 GiB 随机） | 79.6 s / 上传 1.90 GB | 改 1 KiB → 上传 1.03 MB / 1 对象 | 467 MB | 1.68 MB | 0 | 1.90 GB |
| 100 GiB 单文件（1 GiB 随机） | 465.8 s / 读取 100 GiB | 未执行 | 379 MB | 6.58 MB | 0 | 789 MB |
| 100k × 1 KiB 文件 | 40.8 s / 53 packs | 重跑 0 B / 100k 复用 | 545 MB | 247 MB | 0 | 167.7 MB |

门禁内置 300 文件砂箱仍保留：备份 1.65 s、恢复 2.42 s、峰值 133.5 MB。
全随机 10/100 GB、1000 版本、ENOSPC 与真实 iCloud 驱逐仍为 **NOT RUN**，原因见验收报告。
