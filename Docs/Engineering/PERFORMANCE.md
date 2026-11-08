# 性能基准（CT-094 / CT-095 / CT-115）

## 设计

- 基准在**独立子进程**（`CodeTimeCrashChild bench`）中运行，因此 `RUSAGE_SELF` 与 `ru_maxrss` 精确反映本次基准，不受 XCTest 进程历史影响。
- Kopia 子进程 CPU 单独用 `RUSAGE_CHILDREN` 计量。
- 数据集包含：普通文件（内容随序号变化）、嵌套目录、空文件、隐藏文件、Unicode/特殊字符文件名、符号链接。
- 恢复后逐文件比对**大小 + SHA-256**，并校验目录结构、隐藏文件存在性；任何不一致使基准以非零退出码失败（`contentCheck: FAIL`）。

## 规模

| 规模 | 文件数 | 入口 |
|---|---:|---|
| Small | 300 | `Scripts/benchmark.sh small`（也在 XCTest CT-094） |
| Medium | 10,000 | `Scripts/benchmark.sh medium`（也在 XCTest CT-095） |
| Large | 100,000 | `Scripts/benchmark.sh large` |
| Stress | 1,000,000 | `Scripts/benchmark.sh stress`（夜间/手动） |

## 指标

`backupDurationMs`、`incrementalBackupDurationMs`、`restoreDurationMs`、`totalDurationMs`、`cpuUserSec`、`cpuSysSec`、`kopiaChildCpuUserSec`、`kopiaChildCpuSysSec`、`peakMemoryMB`、`snapshotFiles`、`verifiedFiles`、`contentMismatches`、`contentCheck`。

## 回归阈值

`Docs/Engineering/perf-baseline.json` 记录稳定环境实测值；`Scripts/benchmark.sh --check [small|medium]` 在以下情况失败（退出码 4）：

- 内容校验失败；
- 备份或恢复耗时 > 基线 × 2.5；
- 峰值内存 > 基线 × 1.5。

阈值刻意宽松，用于拦截数量级退化，不用于卡 CI 抖动。
