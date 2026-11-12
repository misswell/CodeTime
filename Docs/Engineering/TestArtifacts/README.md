# 测试产物

本目录保存可以复核的门禁/验收原始日志。日志是当时命令的真实输出，不手工改写；
机器路径与临时 UUID 会出现，但不包含用户代码内容、密钥或恢复密钥。

| 文件 | 内容 | 对应提交/环境 |
|---|---|---|
| `apple-provisioning-blocked-*.log` | `Scripts/setup_apple_provisioning.sh` 的真实失败输出（PLA 未同意） | 本机 |
| `376ff89-regression-gate.log` | 前一轮全量门禁输出（263 tests / 0 failures / 3 skips） | `376ff89` |
| `3ab6bde-reliability-gate.log` | 可靠性加固后全量门禁输出（295 tests / 0 failures / 3 skips，scale=1） | `3ab6bde` |
| `46805da-reliability-p0p1-gate.log` | 第一轮 P0/P1 修复门禁（328 tests / 0 failures / 3 skips，scale=1） | `46805da` |
| `e6e8090-reliability-final-gate.log` | 最终 P0/P1（含恢复屏障）全量门禁（328 tests / 0 failures / 3 skips，scale=1） | `e6e8090` |
| `single-mac-gate-20261112.log` | 单 Mac 验收范围修订后的全量门禁（332 tests / 0 failures / 3 skips，scale=1） | `01bf82b` |
| `icloud-preflight-blocked-20261111.log` | 真实 iCloud 预检：PLA 未同意、iCloud Drive 上传报 4355 | 本机 macOS 27.2.1 |
| `icloud-preflight-recheck-20261111T1348Z.log` | 复检：PLA、Xcode 账号、iCloud 4355、第二台 Mac 均未变化 | 本机 macOS 27.2.1 |
| `icloud-preflight-after-bird-restart-20261111.log` | 重启 bird 后仍报 iCloud 4355，排除同步进程卡死 | 本机 macOS 27.2.1 |
| `icloud-signing-ready-20261111.log` | Bundle/container/profile/entitlement 全链路，输出 ICLOUD_SIGNING_READY | 本机 macOS 27.2.1 |
| `icloud-selftest-upload-4355-20261111.log` | 已签名 App 解析容器成功、ubiquity token 存在，但上传仍报 4355 | 本机 macOS 27.2.1 |
| `v3icloud-single-mac-blocked-20261111.log` | `V3Acceptance icloud` 单机真实 iCloud 上传失败（未确认上传） | 本机 macOS 27.2.1 |
| `betaicloud-provisioning-blocked-20261111.log` | BetaICloud 构建失败：缺少带 iCloud feature 的 provisioning profile | 本机 Xcode |
| `xcodebuild-automatic-signing-blocked-20261111.log` | `-allowProvisioningUpdates` 失败：Xcode CLI `No Accounts` | 本机 Xcode |
| `v3-perf-10gb-random-20261111-170416.log` | 10 GiB 全随机单文件：126.4s，上传 8.42GB；改 1 KiB → 1.84MB；峰值 477/502MB | 本机 macOS 27.2 |
| `v3-perf-10gb-final-20261111-163826.log` | 10 GiB 稀疏单文件（2.5 GiB 随机）：79.6s，增量 1 KiB → 1.03 MB 上传，峰值 467/437 MB | 本机 macOS 27.2 |
| `v3-perf-100gb-isolated-20261111-163504.log` | 100 GiB 逻辑单文件：465.8s，读取 100 GiB，峰值 379 MB，spool 0 | 本机 macOS 27.2 |
| `v3-perf-100k-files-20261111-164015.log` | 100k × 1 KiB 旧记录：首发 40.8s，重跑 0 B，53 packs，DB 247 MB | 本机 macOS 27.2 |
| `v3-perf-100k-reliability-20261111.log` | 100k × 1 KiB 复测：首发 36.6s，重跑 0 B，49 packs，峰值 538 MB，DB 287 MB（未达 350 MB 目标） | 本机 macOS 27.2 |

性能数据是稀疏数据集（逻辑大小达标，部分物理随机），不是全随机 10/100 GB；
真实 iCloud 双 Mac 因 PLA / 第二台 Mac / 账户上传状态阻塞，未生成通过日志。
门禁结果同时以 `Docs/Engineering/TEST_REPORT.md` 顶部机器可读块为准。
