# CodeTime 2.0（v3）验收报告

本报告对应任务书 §16–§19 的交付验收。**自动化结果真实执行；真实 iCloud 双 Mac 与 100 GB
规模验收未执行，明确标记 NOT RUN。**

- 代码提交：`4a52883`
- 门禁：`Scripts/regression_gate.sh`，`PASS`
- 测试：261 executed / 0 failures / 3 skipped（CT-001 … CT-165）
- 环境：macOS 27.2 arm64；本地镜像 + 内存云；Kopia 0.23.1 仅用于 v2 兼容测试

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

### 2.2 本机测量（300 文件砂箱，非验收规模）

| 指标 | 数值 |
|---|---:|
| 备份耗时 | 1.65 s |
| 恢复耗时 | 2.42 s |
| 峰值内存 | 133.5 MB |
| CPU 用户/系统 | 3.34 s / 2.97 s |
| 内容校验 | 300/300 文件通过 |

脚本：`CODETIME_SCALE_TESTS=1 Scripts/regression_gate.sh`（输出含 `PERF_METRICS`）。

### 2.3 未执行

| 项目 | 状态 | 说明 |
|---|---|---|
| 100 GB 项目 / 10 GB 单文件 | **NOT RUN** | 本机无标准数据集；需独立卷与长时间运行 |
| 10 万小文件 v3 备份 | **NOT RUN** | 需独立 inode/时间预算 |
| 1000 个历史版本 | **NOT RUN** | 需长时间连续快照 |
| 真实 iCloud 本地副本驱逐与空间变化 | **NOT RUN** | 本地镜像非 ubiquitous item |
| 磁盘写满 ENOSPC | **NOT RUN** | 需可控小容量卷 |

## 3. 双 Mac 验收

| 场景 | 状态 |
|---|---|
| 两台真实 Mac、同一 Apple 账号、真实 iCloud | **NOT RUN** |
| 单机双设备命名空间发现/恢复（Mac B 读取 Mac A 命名空间） | PASS（CT-164） |
| Mac B 输入恢复密钥、浏览历史、恢复项目 | PASS（单机模拟） |
| Mac B 不下载 Mac A 的 Kopia 仓库 | PASS（v3 全链路无 Kopia） |
| 真实 iCloud 并发上传、同步延迟、配额不足、账户切换 | **NOT RUN** |

双 Mac 报告模板：`Docs/releases/ICLOUD_ACCEPTANCE_TEMPLATE.md`。在真实环境执行前，
Stable 发布门禁会拒绝“已通过”声明。

## 4. 未完成/边界

- 真实 iCloud 与双 Mac 验收未执行（如上）。
- v3 UI 视觉未逐屏人工验收。
- v3 跨设备不做对象级去重（每设备独立命名空间），云端占用可能高于单设备。
- 旧版本在本地仓库释放后恢复需要临时下载完整 v2 generation。

详细边界见 `KNOWN_LIMITATIONS.md`；逐项测试映射见 `REGRESSION_MATRIX.md`。
