# CodeTime 测试报告 — 第五轮可靠性整改

- 基准 Commit：`6db49ce`（第五轮审查后）
- 交付 Commits：`38ba95a`（核心安全改造）→ `9177e80`（CT-082~098 全覆盖）→ 本次文档
- 日期：2026-11-08

## 1. 环境

| 项 | 值 |
|---|---|
| 机器 | macOS 27.2（arm64） |
| Swift | 6.4.2（Swift 5 语言模式） |
| 部署目标 | macOS 14.0 |
| Kopia | 0.23.1（内置 universal，SHA-256 sidecar） |
| 云端测试载体 | 本地镜像目录（Cloud Format v1）；真实 iCloud 未执行 |

## 2. 测试规模

- XCTest 总数：**133**（上一轮 114 → 新增 19 个第五轮行为测试）
- 失败：**0**；跳过：**4**（均为索引登记的真机/环境相关项）
- 回归门禁：`Scripts/regression_gate.sh` **PASS**（CT-001 … CT-098 全量、REGRESSION_INDEX.json 驱动、未登记跳过即失败）

## 3. 测试类分布

| 测试文件 | 覆盖 | 说明 |
|---|---|---|
| CloudMirrorRegressionTests | CT-001…CT-012 | 云端镜像：GC、发布、tombstone、多设备 |
| RecoveryRegressionTests | CT-013…CT-020 | 云端恢复：断点续传、哈希校验、多候选 |
| SecondRoundRegressionTests | CT-021…CT-054 | 租约、调度、迁移、书签、恢复状态机 |
| ThirdRoundRegressionTests | CT-045…CT-069 | 迁移锁、状态一致性、发布工作流、门禁 |
| FourthRoundRegressionTests | CT-070…CT-080 | Manifest 篡改、GC 多设备、生命周期锁、发布绑定 |
| FifthRoundRegressionTests | CT-077…CT-098 | 本轮全部新增：路径安全、恢复租约、SIGKILL、基准 |

第五轮测试全部为**真实行为断言**：真实进程 SIGKILL（CT-098 覆盖六个崩溃位）、真实子进程 flock（CT-084）、真实 kopia 引擎（CT-093/094/095）、真实损坏清单（CT-081 生产路径重写，替代原手工构造映射）。

## 4. 性能基准（独立子进程采样，非 XCTest 进程历史值）

Small 规模实测（300 文件，专用进程）：

| 指标 | Small (300) | Medium (10,000) |
|---|---:|---:|
| backupDurationMs | ~1.7s | ~2.0s |
| restoreDurationMs | ~1.4s | ~39.5s |
| peakMemoryMB（本进程真实峰值） | ~12 MB | ~12 MB |
| kopiaChildCpuUserSec（RUSAGE_CHILDREN） | ~1.2s | ~3.3s |
| verifyFiles | 300 通过 | 10,000 通过 |

恢复随文件数近似线性增长（每文件独立落盘），1 万小文件约 40s；大规模场景建议配合排除规则与并行度调优。

- 指标来源：`getrusage(RUSAGE_SELF)` 差值 + `RUSAGE_CHILDREN`（kopia 子进程单独计量）+ 专用新进程 `ru_maxrss`（无历史污染）。
- 规模入口：`Scripts/benchmark.sh [small|medium|large|stress]`（medium=1 万、large=10 万、stress=100 万，为手动/夜间入口）。

## 5. 环境相关（未执行，不声称通过）

| 项 | 状态 | 说明 |
|---|---|---|
| 双 Mac iCloud 真机验收 | **NOT RUN** | Stable 发布前置条件；验收报告须提交至 `release-acceptance` 分支并通过 CT-077/083 强制校验 |
| 真实 Keychain 迁移（跨签名身份） | **NOT RUN** | 需真实 Developer ID 设备环境 |
| 磁盘满 / 百万文件压力 | **NOT RUN** | CT-044 环境跳过；stress 级别需人工执行 `Scripts/benchmark.sh stress` |

## 6. 已知限制

- Coordinator 目前为类型化门面 + 真实服务调用链（CT-093 端到端驱动真实 API），业务逻辑的整体搬迁（Goal §12 完全拆分）未在本轮完成，CodeTimeService 仍保留兼容门面。
- 旧的 106 测试统计作废；以本文件与 `REGRESSION_INDEX.json`（98 项）为准。
