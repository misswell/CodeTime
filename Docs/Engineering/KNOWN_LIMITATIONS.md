# 已知限制与未执行验收

本文件区分“已实现但未在本环境验证”和“功能本身仍有边界”。未执行的项目不得在其他文档或发布说明中标记为通过。

## 1. 本环境未执行的验收

| 项目 | 原因 | 如何执行 |
|---|---|---|
| 单机真实 iCloud 往返（ICloudAcceptanceTests） | 默认环境没有真实 iCloud 容器 | 设置 `CODETIME_ICLOUD_TESTS=1`、`CODETIME_ICLOUD_CONTAINER` 后运行；仍不代表双 Mac 验收 |
| 真实 iCloud 双 Mac 发布/恢复 | 需要两台 Mac、同一 iCloud 账号、签名 Release 构建与真实容器 | 按 `Docs/releases/ICLOUD_ACCEPTANCE_TEMPLATE.md` 填写报告；Stable 脚本会强制检查 |
| 10 万文件排除预览（CT-036） | 默认门禁关闭，避免 CI 资源消耗 | `CODETIME_SCALE_TESTS=1 Scripts/test.sh --filter testCT036` |
| 100 万文件扫描上限（CT-037） | 创建 100 万文件耗时且占用大量 inode | `CODETIME_STRESS_TESTS=1 Scripts/test.sh --filter testCT037`（建议独立卷；CT-138 起与常规 scale 开关分离） |
| 磁盘满故障注入（CT-044） | 本机无可控小容量卷，无法安全制造 ENOSPC | 在独立 APFS 小容量卷或 CI 容器中运行；禁止在用户数据卷上注入 |
| Developer ID 签名与公证 | 本环境未提供发布凭据 | 配置 `DEVELOPMENT_TEAM`、`APPLE_ID`、`NOTARY_PASSWORD` 后运行 `Scripts/package_release.sh` |
| Stapling 与最终安装包验证 | 依赖公证结果 | `Scripts/verify_release.sh` |
| 安装、升级、回退、卸载重装 | 需要真实安装环境与上一版本包 | 按 `RELEASE_CHECKLIST.md` 第 7 节执行 |
| SwiftUI 界面视觉/交互验收 | 未在本环境启动应用逐屏检查 | 使用 Release 构建在 macOS 14/15 上人工检查 |

全量默认测试结果：**363 个测试，0 失败，3 跳过**。跳过项即单机 iCloud 验收、CT-044 磁盘写满
与 CT-037 百万文件；它们不计入“通过”。CT-036 及 CT-117 的 3GiB 变体在门禁中由 `CODETIME_SCALE_TESTS=1` 启用；
CT-037 百万文件与 3GiB 变体需 `CODETIME_STRESS_TESTS=1`（夜间/手动）下真实执行（CI 不设
该变量，规模项在 CI 中跳过，两处口径在 TEST_REPORT 分开陈述）。
CT-045…CT-057、CT-058…CT-116、CT-117…CT-128、CT-129…CT-146、CT-147…CT-167、CT-168…CT-196、CT-197…CT-233 全部通过。
统计口径以 `TEST_REPORT.md` 的机器可读块为唯一事实源（`Scripts/check_test_report.py` 强制校验）。

## 2. 功能边界

### 2.0 CodeTime 2.0 / Cloud Format v3

- **真实 iCloud 未验收**：v3 的对象、包、节点、Manifest、Commit、spool 续传与恢复均由本地镜像和内存云双端测试覆盖；
  真实 iCloud 的同步延迟、占位符下载、配额不足、账户切换、`evictUbiquitousItem` 实际释放行为未执行。
- **双 Mac 未验收**：跨设备命名空间读取由 CT-164 在单机模拟（两个设备目录）；真实两台 Mac 的并发上传与恢复未执行。
- **规模验收部分执行**：全随机 10 GiB 单文件、稀疏 100 GiB 单文件与 10 万小文件已真实执行，
  结果见 `V3_ACCEPTANCE_REPORT.md` §2.2；全随机 100 GB（需约 190 GB 空闲）与 1000 个
  历史版本仍未执行（磁盘空间不足）。
- **真实 iCloud 被环境阻塞**：Developer ID iCloud 描述文件无法创建（Account Holder 未同意
  最新 PLA），本机 iCloud Drive 写入返回 `NSCocoaErrorDomain 4355`；单机真实 iCloud 与
  双 Mac 均未通过。
- **v3 GC 宽限期未真实验证**：两阶段逻辑由注入时钟测试；30 天真实等待与真实 iCloud 枚举完整性未执行。
- **v3 本地副本驱逐**：`ICloudEvictionManager` 在本地镜像上会跳过非 ubiquitous 文件；真实 iCloud 上的释放结果与
  “等待释放”提示未验收。
- **旧版本临时恢复**：释放本地仓库后，恢复旧版本需要重新下载完整 v2 generation；下载时间与临时磁盘占用
  取决于旧仓库大小，界面会明确提示，但未在真实大仓库上测量。
- **v3 跨设备去重**：每台设备写入独立命名空间；不同设备之间不做对象级去重（相同内容会在各自命名空间各存一份）。
  这是任务书“每设备独立命名空间”的直接结果，不是缺陷，但会增加云端总占用。
- **UI 视觉验收**：Dashboard/设置/迁移/恢复界面已编译通过，未逐屏人工检查布局与文案。

### 2.1 调度

- 后台调度器每 30 秒轮询到期项目，并在系统唤醒后补跑一次，作为 FSEvents 丢失事件时的兜底。
- FSEvents 监听已实现（`ProjectChangeMonitor`）：2 秒内核合并、5 秒去抖，并受项目
  `minimumChangeIntervalMinutes` 约束；首次备份不会被文件写入被动触发。
- 监听只在进程存活且持有项目安全作用域时运行；LaunchAgent 与 UI 各自启动。应用退出期间的
  变更由下次启动的完整扫描发现，不影响数据完整性。
- 真实 macOS 上事件丢失/合并的极端情况仍由周期完整扫描兜底；未做长时间 FSEvents 压力验收。

### 2.2 上传并发

- 上传使用有界并发，宽度来自性能配置的 `uploadParallelism`。
- 本次未做吞吐基准，不能声称“并发使上传速度提升 N 倍”；只验证了并发写入的正确性（CT-008）。

### 2.3 iCloud 行为

- 未在真实双设备环境验证，因此以下行为只由单元/集成测试与代码路径保证：
  - 上传未确认不产生 Generation；
  - 不可读文件失败关闭；
  - 多设备候选与密钥不匹配继续搜索。
- iCloud 同步延迟、配额不足、账户切换等真实环境差异可能暴露测试未覆盖的行为。

### 2.3.1 Beta → Release 的 Keychain 限制

迁移会复制数据库、仓库和隐藏文件，并修复 RepositoryRecord 路径；但 Beta 的 Keychain 条目属于 Beta 签名身份，Release 的 Keychain Access Group 不一定能读取。若迁移后 `ensureSecrets(allowCreation: false)` 找不到主密钥/仓库密码，应用会明确失败而不是生成新密钥。此时应使用云端恢复流程或由用户提供恢复凭据；不要把文件复制成功误认为完整迁移成功。该限制未在真实 Beta→Release 安装中验收。

### 2.4 Sandbox

- Stable/Release 构建启用 App Sandbox、Hardened Runtime 与 iCloud entitlements。
- Beta 为 ad-hoc 签名且不声明 iCloud，Debug 为本地开发配置；这三者的授权行为不同，不能互相替代验收。
- Beta 用户若要使用云端功能，应使用带正确签名与 iCloud 权限的构建。

### 2.5 恢复

- 恢复面向 CodeTime 云端 Generation，不提供任意版本降级或跨大版本 schema 回退。
- 恢复 staging 需要与目标仓库同卷空间；空间不足会显式失败并保留 staging 以便清理/重试。
- 未执行真实 iCloud 恢复验收，断点恢复由本地故障注入测试覆盖。

### 2.6 性能

- 大型仓库的扫描上限为 `maxScannedFiles`；超过上限会显式标记截断，不会返回“完整”结果。
- 哈希流式读取，内存占用不随文件大小线性增长（CT-038 覆盖 8 MB 文件，未做超大文件基准）。
- 日志、活动表、哈希缓存有上限与清理策略，但未做长时间运行的内存/磁盘基准。

### 2.7 平台

- 部署目标 macOS 14+。
- 本次构建环境为 macOS 27.2（arm64）。未在 macOS 14/15、Intel 实机或低内存设备上运行全量测试。
- Kopia 固定为 0.23.1；升级 Kopia 需要重新执行完整性校验与回归。

## 3. 风险说明

| 风险 | 影响 | 缓解 |
|---|---|---|
| 真实 iCloud 未验收 | 极端同步时序可能与本地模拟不同 | 发布前必须完成双机验收；未完成则不发 Stable |
| 未做公证 | 用户首次打开可能被 Gatekeeper 阻止 | Stable 脚本强制公证；缺凭据直接失败 |
| FSEvents 长时压测未做 | 极端事件丢失只能延迟触发 | 周期完整扫描兜底；数据完整性不受影响 |
| 规模测试默认关闭 | 超大仓库性能未在 CI 持续监控 | 发布前手动运行 CT-036/037；必要时建立夜间任务 |
| Beta ad-hoc 无 iCloud | Beta 用户无法验证云端功能 | 发布说明明确；云端验收使用 Release 构建 |
| 未在旧 macOS 验证 | 兼容性问题可能只在旧系统出现 | 发布前在最低支持版本上做冒烟测试 |

## 4. 结论

P0/P1 的代码修复与默认自动化测试已完成；Stable 发布仍取决于本文件第 1 节中的人工验收项，尤其是真实 iCloud 双机、公证、安装升级回退和最低系统版本冒烟。未完成这些项目之前，只能发布 beta/rc，不能声明 Stable 已通过完整验收。
