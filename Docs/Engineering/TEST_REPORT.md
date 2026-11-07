# 测试报告

## 1. 环境

| 项 | 值 |
|---|---|
| 机器 | macOS 27.2（arm64） |
| Xcode | 27.2 |
| Swift | 6.4.2（Swift 5 语言模式） |
| 部署目标 | macOS 14.0 |
| Kopia | 0.23.1（内置 universal，SHA-256 sidecar） |
| 云端测试载体 | 本地镜像目录（Cloud Format v1）；真实 iCloud 未执行 |

## 2. 全量测试

命令：

```bash
Scripts/regression_gate.sh
```

结果：

```text
Executed 64 tests, with 4 tests skipped and 0 failures
regression gate: PASS (CT-001 … CT-044 present, 0 failures)
```

| 测试类 | 数量 | 失败 | 跳过 | 耗时 |
|---|---:|---:|---:|---:|
| CloudMirrorRegressionTests（CT-001…012） | 12 | 0 | 0 | 0.35 s |
| RecoveryRegressionTests（CT-013…020） | 8 | 0 | 0 | 0.09 s |
| ConcurrencyPersistenceRegressionTests（CT-021…028、041） | 9 | 0 | 0 | 0.05 s |
| SandboxMigrationRegressionTests（CT-029…040、042…044） | 15 | 0 | 3 | 4.20 s |
| SchemaMigrationTests（MIG-001/002） | 2 | 0 | 0 | 0.03 s |
| CloudMirrorStoreTests | 4 | 0 | 0 | 1.39 s |
| KopiaEngineIntegrationTests | 2 | 0 | 0 | 5.86 s |
| ExclusionMatcherTests | 3 | 0 | 0 | 0.004 s |
| SmokeTests | 4 | 0 | 0 | 0.004 s |
| ServiceEndToEndTests | 1 | 0 | 0 | 6.26 s |
| ICloudAcceptanceTests | 1 | 0 | 1 | — |
| **合计** | **64** | **0** | **4** | **20.8 s** |

跳过项：

- CT-036（10 万文件）：默认关闭；本次单独执行 **通过（33.26 秒）**，见第 4 节。
- CT-037（100 万文件上限）：默认关闭，本次未执行。
- CT-044（磁盘满 ENOSPC）：无可控小容量卷，本次未执行。
- 真实 iCloud 双 Mac 验收：缺少第二台 Mac 与真实容器，本次未执行。

## 3. 构建与静态检查

| 检查 | 命令 | 结果 |
|---|---|---|
| SwiftPM 构建 | `swift build --package-path Packages/CodeTimeKit` | 成功 |
| Debug App | `xcodebuild -configuration Debug ... CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Release App | `xcodebuild -configuration Release ... CODE_SIGNING_ALLOWED=NO` | BUILD SUCCEEDED |
| Entitlements | `Scripts/validate_entitlements.sh` | PASS |
| Kopia 完整性 | `Scripts/fetch_kopia.sh`（已有二进制） | PASS（版本/架构/签名/sidecar） |
| 回归门禁 | `Scripts/regression_gate.sh` | PASS |

未执行：Developer ID 签名、公证、stapling、`spctl` 评估、安装/升级/回退、卸载重装。原因是没有发布凭据与安装环境；这些项目在 `RELEASE_CHECKLIST.md` 中保持未勾选。

Release 构建以 `CODE_SIGNING_ALLOWED=NO` 编译，仅验证编译与打包流程，不代表签名产物合格。

## 4. 性能测量

| 项目 | 结果 | 说明 |
|---|---|---|
| 10 万文件排除预览（CT-036） | 33.26 秒通过 | 含创建 10 万空文件与完整扫描；`permissionErrors = 0`，结果为完整 |
| 100 万文件扫描（CT-037） | 未执行 | 需要大量 inode 与时间，建议夜间任务独立卷执行 |
| 大文件哈希（CT-038） | 8 MB 分块哈希与一次性哈希一致 | 验证流式实现正确性，未做吞吐基准 |
| 全量测试 | 20.8 秒 | 不含构建时间 |
| 端到端备份/发布/校验/恢复（ServiceEndToEndTests） | 6.26 秒 | 小规模测试夹具 |
| 恢复故障注入（CT-013…020） | 0.09 秒 | 合成对象，不代表真实仓库规模 |
| 上传并发 | 未做吞吐基准 | 仅验证并发写同一对象的正确性（CT-008） |
| 内存峰值 | 未测量 | 无长期运行基准 |
| 恢复临时空间 | 未测量 | staging 需要与目标仓库同卷空间 |

## 5. 功能验证结论

已验证：

- GC 在清单不可读、墓碑不可读、重新验证失败时中止，不删除对象。
- 对象 SHA-256 校验区分同大小不同内容；已存在对象不可校验时隔离而非覆盖。
- 上传未确认、元数据不可读、非 iCloud 文件均失败关闭。
- Manifest 回读不一致时不产生可见版本；失败清单移除失败会显式报错。
- 恢复中断可续跑；复制失败与哈希不符不污染正式仓库；恢复完成必须通过仓库与快照校验。
- 多设备候选与密钥不匹配可继续搜索。
- 项目删除/暂停不被旧回调复活；任务租约与 PID 启动时间防止误判；失败重试有退避。
- Beta → Release 迁移无损、非破坏、重复迁移被拒绝。
- 仓库丢失不自动创建空仓库。
- v1 → v2 数据库迁移增量、幂等，部分迁移可修复。

未验证：

- 真实 iCloud 双机发布与恢复。
- 公证、stapling、Gatekeeper、安装升级回退。
- 100 万文件规模与磁盘满故障注入。
- 长时间运行的内存与磁盘增长。
- SwiftUI 界面的逐屏视觉与交互。

## 6. 结论

默认自动化门禁全部通过；P0/P1 代码修复有对应回归测试。Stable 发布仍被真实 iCloud 双机、公证、安装升级回退与最低系统版本冒烟阻塞。在上述人工验收完成前，本报告不支持“Stable 已完整验收”的结论。
