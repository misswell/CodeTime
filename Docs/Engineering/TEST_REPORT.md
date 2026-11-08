# CodeTime 测试报告 — 第六轮可靠性整改

本报告绑定具体的提交与 CI 运行，**不是**历史结果的沿用。任何一项未真实执行都明确标记。

## 1. 绑定信息

| 项 | 值 |
|---|---|
| 基准 Commit | `c782a5c`（第六轮审查基准 `63a8d86c` 之后的最新 main） |
| 交付 Commit SHA | `88d0af5`（本轮代码最终提交；本报告为随后的 docs-only 提交） |
| CI Run | `42441771831`（GitHub Actions `CI`，`main` push，10/10 全绿） |
| 回归索引 | `REGRESSION_INDEX.json`（CT-001 … CT-116） |
| 门禁脚本 | `Scripts/regression_gate.sh`（索引驱动、required 不可跳过） |

## 2. 环境

| 项 | 值 |
|---|---|
| 机器 | macOS 27.2（arm64，Apple Silicon） |
| Swift | 6.4.2（Swift 5 语言模式） |
| 部署目标 | macOS 14.0 |
| Kopia | 0.23.1（内置 universal） |
| 云端测试载体 | 本地镜像目录（Cloud Format v1） |

## 3. 测试规模

- XCTest 总数：见「CI 结果」小节的最终计数（本文件不预填未执行数字）。
- 必需（required）回归：CT-001 … CT-116 中除两个人工验收项外的全部。
- 人工验收项（允许跳过，原因登记在索引）：
  - **CT-037** 百万文件规模测试（Stress）——由 `Scripts/benchmark.sh stress` 或夜间任务执行。
  - **CT-044** 磁盘写满（ENOSPC）——需可控小容量卷，由真机验收清单覆盖。
- 真实双 Mac iCloud 往返（`testSingleMacICloudRoundTrip`）：**NOT RUN**，需真实 iCloud 容器与两台设备。

## 4. 第六轮新增覆盖（CT-099 … CT-116）

| 编号 | 内容 | 测试方式 |
|---|---|---|
| CT-099 | 验收脚本对 CI 注入环境免疫 | 真实执行 `require_icloud_acceptance.sh` |
| CT-100 | publish-stable 先 checkout 再读 notes | workflow 结构断言 |
| CT-101 | 取消终止并回收 Kopia 子进程；drain 等到全部退出 | 真实 `/bin/sleep` 子进程 + 真实 kopia 备份 |
| CT-102 | 提交位置判定覆盖全部崩溃位 | 生产纯函数 7 种组合 |
| CT-103 | failed 可重试、permanentlyFailed 终态、租约回收 | 真实 SQLite claim |
| CT-104 | 仓库级互斥 | 真实 flock 双句柄 |
| CT-105 | iCloud 默认只预览；退役需显式记录 | 真实 CloudMirrorStore（coordinated） |
| CT-106 | 被篡改 journal 路径绝不删除 | 真实文件系统 + 真实清理函数 |
| CT-107 | 符号链接 staging 在写入前被拒 | 真实符号链接 + SafePath |
| CT-108 | janitor 不跟随仓库目录符号链接 | 真实 bootstrap |
| CT-109 | 新 RequestID 重新迁移 | 真实迁移两次 |
| CT-110 | 单事务状态重算 | 真实 SQLite |
| CT-111 | 目标路径跨进程互斥 | 真实 flock |
| CT-112 | 活的恢复任务不被其他 bootstrap 回收 | 真实 SQLite |
| CT-113 | Coordinator 承担策略；显式状态机 | 真实 Coordinator + 状态机断言 |
| CT-114 | required 不可跳过；门禁构建 CrashChild | 索引/脚本断言 |
| CT-115 | 基准内容校验 + 基线阈值 | 真实 300 文件基准（size+SHA+结构+隐藏+符号链接） |
| CT-116 | 报告绑定 Commit/CI Run | 本文件 |

## 5. 性能结果（独立子进程，内容校验通过）

| 规模 | 文件 | 备份 | 增量备份 | 恢复 | 峰值内存 | 内容校验 |
|---|---:|---:|---:|---:|---:|---|
| Small | 300 | ~1.9s | ~0.9s | ~3.3s | ~12.7 MB | PASS（size+SHA-256+结构+隐藏文件+符号链接） |
| Medium | 10,000 | ~2.0s | — | ~39.5s | ~12.0 MB | PASS |

- 基线文件：`Docs/Engineering/perf-baseline.json`；`Scripts/benchmark.sh --check` 以 2.5x 耗时 / 1.5x 内存作为回归阈值。
- 入口：`Scripts/benchmark.sh [small|medium|large|stress]`；Large=100,000、Stress=1,000,000 为手动/夜间入口。

## 6. 未执行项（不声称通过）

| 项 | 状态 | 原因 |
|---|---|---|
| 双 Mac iCloud 真机验收 | **NOT RUN** | 需要两台真实 Mac 与真实 iCloud；Stable 发布前置条件（`require_icloud_acceptance.sh` 强制） |
| 真实 Keychain 跨签名迁移 | **NOT RUN** | 需要 Developer ID 真机环境 |
| CT-037 百万文件 | **NOT RUN** | 人工/夜间规模测试 |
| CT-044 磁盘写满 | **NOT RUN** | 需要可控 ENOSPC 卷 |

## 7. 执行结果

### 本地门禁（提交前，真实运行）

```
regression gate: PASS
  executed: 154 tests, 0 failures
  skipped (manual acceptance only): testCT044_DiskFullLeavesRepositoryUntouched
                                    testSingleMacICloudRoundTrip
  index: CT-001 … CT-116 (114 required)
```

- 本轮真实执行了百万文件规模测试（CT-037，`CODETIME_SCALE_TESTS=1`）与 10,000 文件内容校验基准（CT-095）。

### CI 结果（Run `42441771831`，Commit `88d0af5`）

| Job | 结果 |
|---|---|
| build | ✓ 2m17s |
| unit-tests | ✓ 1m19s |
| integration-tests | ✓ 1m16s |
| cloud-tests | ✓ 1m20s |
| recovery-tests | ✓ 1m0s |
| concurrency-tests | ✓ 53s |
| security-tests | ✓ 1m26s |
| release-build | ✓ 2m23s |
| entitlements | ✓ 13s |
| regression-gate | ✓ 12m34s |

CI 的 regression-gate 与本地一致：`CODETIME_SCALE_TESTS=1`，CT-036/037 规模测试真实执行，
CT-098 的 SIGKILL 矩阵因门禁先构建 `CodeTimeCrashChild` 而不会跳过。

### 终审（独立 Code Review）

对 `c782a5c..88d0af5` 的独立审查：**P1 零项**；12 项 P2 中，P2-1（关停无法证明生产者已停）、
P2-2（--once 忽略不安全 drain）、P2-3（claim 后首次写入失败导致租约泄漏）、
P2-4（旧版完成记录使幂等失效）、P2-5（生产代码未走状态机/未记录永久失败）、
P2-6（测试未驱动生产入口）、P2-7（基准未校验符号链接）、P2-8（基准 --check 参数与失败开放）、
P2-9（janitor 被单个 journal 冻结）、P2-10（锁等待阻塞 actor）、P2-12（不可完成的重试）
已在 `88d0af5` 修复；P2-11（预览高估可删对象）保留为已登记权衡，方向安全。

## 8. 已知限制

- Coordinator 已完成策略内聚（批次/恢复计划/校验策略/生命周期决策），但 `CodeTimeService` 仍保留兼容门面，UI 入口未全量改走 Coordinator。
- `codeTimeService` 规模仍较大，属下一轮架构工作，不影响本轮数据安全结论。
