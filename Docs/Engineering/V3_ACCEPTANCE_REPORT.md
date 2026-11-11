# CodeTime 2.0（v3）验收报告

本报告对应任务书 §16–§19 的交付验收。**自动化结果真实执行；真实 iCloud 双 Mac 与 100 GB
规模验收未执行，明确标记 NOT RUN。**

- 代码提交：`7eb52b8`
- 门禁：`Scripts/regression_gate.sh`，`PASS`
- 测试：263 executed / 0 failures / 3 skipped（CT-001 … CT-167）
- 环境：macOS 27.2 arm64；本地镜像 + 内存云；Kopia 0.23.1 仅用于 v2 兼容测试
- 性能日志：`Docs/Engineering/TestArtifacts/v3-perf-*.log`（原始 `V3PERF_RESULT`）

## 1. 架构验收

| 要求 | 证据 | 状态 |
|---|---|---|
| 新引擎不依赖完整本地 Kopia 仓库 | v3 备份/恢复全链路只使用 `CloudObjectStoreV3` + `UploadQueue`；v3 模式下 bootstrap 不初始化 Kopia 仓库；CT-161 | PASS |
| 内容定义分块 | FastCDC 256 KB / 1 MB / 4 MB；流式、可取消、空文件/大文件；CT-147 | PASS |
| 内容寻址与跨版本去重 | HMAC 对象 ID；相同内容跨文件/跨版本复用；CT-148、CT-154 | PASS |
| 压缩与 AEAD 加密 | LZFSE 仅在实际变小时保留；AES-GCM + AAD；节点本轮改为加密；CT-148、CT-151 | PASS |
| 不可变 Merkle 树 | 未变化子树保留节点 ID；只上传变化节点；CT-149、CT-154 | PASS |
| 可靠 Commit Marker | 发布顺序 objects→nodes→manifest→commit；manifest 哈希不一致拒绝提交；CT-151 | PASS |
| 本地有限缓存 | LRU、预算预设、pin、只删自身根目录；CT-156 | PASS |
| 持久待上传队列 | 先写 spool 再上传；失败/崩溃保留；软上限暂停；CT-159 | PASS |
| 安全云端 GC | 两阶段墓碑、引用重算、整包保护、任何不确定即中止；CT-163 | PASS |
| 旧数据兼容 | v2 未修改；按版本选择引擎；迁移需显式同意；释放后临时下载 v2 仓库恢复；CT-158、CT-162 | PASS |
| 换 Mac 恢复 | v3 项目发现 + 恢复密钥 + 按需恢复 + 历史注册；CT-164 | PASS（单机双设备模拟） |

## 2. 本地空间

### 2.1 设计约束（已实现）

- 首次备份不创建完整本地项目副本；数据块流式读取、加密后写入 spool，上传确认即删除。
- 下载缓存默认 256 MB（极简 128 MB / 快速 512 MB / 自定义），独立于 spool。
- spool 默认软上限 2 GB；达到上限暂停备份，不删除未上传数据。
- iCloud 本地副本在上传确认后尝试驱逐；失败上报“等待释放”，不伪装成功。
- Dashboard 分开显示：元数据索引、下载缓存、待上传数据、iCloud 云端。

### 2.2 §17 数据集测量（真实执行）

测试机根卷可用空间仅 11–23 GB，外接卷 `/Volumes/JZAO` 的 ACL 拒绝写入，因此使用
**稀疏数据集**：逻辑大小达到要求，只有一部分由随机字节支撑，其余为零洞。这样仍会完整
读取、FastCDC 分块、哈希、压缩、加密和写入逻辑大小对应的数据量，但不能代替“全随机
100 GB”验收，报告中明确区分。

工具：`Packages/CodeTimeKit/Sources/V3Acceptance/main.swift`
（`swift build -c release --product V3Acceptance`）。

| 场景 | 逻辑大小 | 物理随机数据 | 首次备份 | 增量修改 | 增量上传 | 峰值 RSS | 本地 DB | spool 结束 | 云端数据 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 10 GB 单文件 | 10 GiB | 2.5 GiB（25%） | 79.6 s | 文件中间改 1 KiB | 1.03 MB / 1 对象 | 467 MB | 1.68 MB | 0 | 1.90 GB |
| 100 GB 单文件 | 100 GiB | 1 GiB（1%） | 465.8 s | 未执行（`--no-incremental`） | — | 379 MB | 6.58 MB | 0 | 789 MB |
| 10 万小文件 | 100 MB（100k×1 KiB） | 100k 文件 | 40.8 s | 无修改重跑 | 0 B；100k 文件复用 | 545 MB | 247 MB | 0 | 167.7 MB（53 packs） |

关键结论：

- 100 GB 文件首次备份**确实读取了 100 GiB**（`firstBytesRead=107374182400`），
  峰值 RSS 379 MB；本地只增加 6.6 MB 索引，spool 上传确认后为 0。
- 10 GB 文件中间修改 1 KiB，第二次备份只上传 **1.03 MB / 1 个对象**（约为文件的 0.01%），
  证明内容定义分块与块级去重生效。
- 10 万小文件第二次备份零上传；元数据约 247 MB（随文件数量线性增长），不含备份正文。
- 首次备份期间没有项目大小的长期本地副本；spool 峰值受 pack 目标大小与上传并发约束。
- 本轮修复了两个流式读取缺陷（否则 10 GiB 只读一半、缓冲区会保留整个文件）：
  `FastCDCChunker` 的重复读取和 `Data.removeFirst` 保留已消费前缀。修复后 CT-154
  增加 3 MB 文件校验与跨天完整重读断言。

未执行的标准数据集：

| 项目 | 状态 | 原因 |
|---|---|---|
| 全随机 10 GB / 100 GB | **NOT RUN** | 根卷可用空间不足；外接卷不可写 |
| 1000 个历史版本 | **NOT RUN** | 需长时间连续快照与额外空间 |
| 磁盘写满 ENOSPC | **NOT RUN** | 需可控小容量卷 |
| 真实 iCloud 下载缓存驱逐/空间变化 | **NOT RUN** | 当前 iCloud 账户上传不可用（见 §3） |

## 3. 真实 iCloud / 双 Mac 验收（环境阻塞）

| 场景 | 状态 | 证据/原因 |
|---|---|---|
| 两台真实 Mac、同一 Apple 账号 | **NOT RUN** | 当前只有一台 Mac；SSH 主机为 Linux；无第二台 macOS 设备或虚拟机 |
| 签名 Release 构建（iCloud entitlement） | **BLOCKED** | `xcodebuild -configuration Release`：`"CodeTime" requires a provisioning profile with the iCloud feature` |
| 创建 Developer ID iCloud 描述文件 | **BLOCKED** | `asc profiles list`：Account Holder 未同意最新 Apple Developer Program License Agreement |
| 真实 iCloud Drive 上传（单机） | **BLOCKED** | 写入后 `ubiquitousItemUploadingError` = `NSCocoaErrorDomain 4355`（Couldn’t access your iCloud account）；1 KiB 探测文件曾被标记 uploaded，但 2 MiB 文件稳定失败 |
| 单机双设备命名空间发现/恢复（同一台 Mac） | PASS（CT-164） | 两个 device 目录，Mac B 读取 Mac A 命名空间；不下载 Kopia 仓库 |
| 真实 iCloud 并发上传、同步延迟、配额不足、账户切换 | **NOT RUN** | iCloud 账户在当前环境不可上传 |

结论：§16.H 不能宣称通过。需要的外部条件：

1. 由 Account Holder 在 https://developer.apple.com/account → Agreements 接受当前 PLA；
2. 用 `Scripts/setup_apple_provisioning.sh` 生成/下载 Developer ID iCloud 描述文件，
   并安装到两台签名 Mac；
3. 两台 Mac 登录同一 Apple 账户、iCloud Drive 可上传；
4. 按 `Docs/releases/ICLOUD_ACCEPTANCE_TEMPLATE.md` 执行并附双 Mac 日志。

在条件满足前，不把双 Mac/iCloud 标记为通过。

## 4. 未完成/边界

- 真实 iCloud 与双 Mac 验收被 PLA / 第二台 Mac / 账户上传状态阻塞（如上）。
- v3 UI 视觉未逐屏人工验收。
- v3 跨设备不做对象级去重（每设备独立命名空间），云端占用可能高于单设备。
- 旧版本在本地仓库释放后恢复需要临时下载完整 v2 generation。

详细边界见 `KNOWN_LIMITATIONS.md`；逐项测试映射见 `REGRESSION_MATRIX.md`。
