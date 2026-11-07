# CodeTime 测试与验收计划

## 1. 测试环境

| 项 | 值 |
| --- | --- |
| macOS | 27.2 (arm64) |
| Xcode | 27.2 |
| Swift | 6.4.2（工程使用 Swift 5 语言模式） |
| Kopia | 0.23.1 universal（内置，SHA-256 记录于 `Resources/Kopia/VERSION.txt`） |
| 云端测试载体 | 本地镜像目录（与 iCloud 相同的 Cloud Format v1） |

## 2. 自动化测试结果

命令：

```bash
KOPIA_PATH="$PWD/Resources/Kopia/kopia" swift test --package-path Packages/CodeTimeKit
```

v1.0.0 整改后最近结果：**64 项测试，0 失败，4 跳过（约 21 秒）**。跳过项为 CT-036/CT-037（规模测试）、CT-044（磁盘满注入）与真实 iCloud 双机验收，执行方式见 [`Engineering/REGRESSION_MATRIX.md`](Engineering/REGRESSION_MATRIX.md) 与 [`Engineering/KNOWN_LIMITATIONS.md`](Engineering/KNOWN_LIMITATIONS.md)。

下表为 Beta 阶段的测试清单，v1.0.0 新增的 CT-001…CT-044 与 MIG-001/002 以矩阵文档为准。

| # | 测试 | 覆盖点 |
| --- | --- | --- |
| 1 | `CryptoBoxRoundTrip` | AES-256-GCM + HKDF 加解密、AAD 不匹配拒绝 |
| 2 | `RecoveryKeyRoundTrip` | 32 字节恢复密钥的 Base32 编解码 |
| 3 | `SQLiteStoreTests` | 项目/策略/快照/任务 CRUD、WAL、崩溃任务恢复 |
| 4 | `ExclusionMatcherTests` | 预设规则、目录规则、受保护文件、`.git` 保护、Kopia 同语义 |
| 5 | `KopiaEngine...SnapshotBrowseRestoreAndVerify` | 真实 Kopia：建仓、快照、排除、列目录、读文件、Diff、单文件/整项目恢复、校验、源路径发现、递归搜索 |
| 6 | `KopiaEngine...RestoreRefusesOverwriteByDefault` | 默认拒绝覆盖已有文件 |
| 7 | `ProcessRunnerTests` | POSIX 子进程执行与输出 |
| 8 | `CloudMirrorStore...PublishRestoreVerifyAndRecovery` | 发布、列表、按清单重组、校验、恢复凭据 |
| 9 | `CloudMirrorStore...ObjectsRemainImmutable` | 旧对象不被覆盖/删除，旧版本仍可恢复 |
| 10 | `CloudMirrorStore...CleanupRetainsReferencedObjects` | 宽限期清理只删除无引用对象，保留版本可恢复 |
| 11 | `CloudMirrorStore...MissingObjectIsDetected` | 缺失对象导致校验失败并阻止恢复 |
| 12 | `RepositoryReplicationTests` | 仓库经云端往返后文件完全一致，Kopia 可重新连接 |
| 13 | `ServiceEndToEndTests` | 完整链路：建仓→添加项目→备份→发布→校验→整项目恢复→清理→全新 Mac 凭恢复密钥重建仓库 |
| 14 | `ServiceEndToEnd` 内密码/设备断言 | 恢复凭据中的仓库密码、设备 ID 与发布方一致 |
| 15 | 搜索断言 | 递归搜索结果路径正确 |
| 16 | 恢复密钥正文包含 `CT1` | 只移除前缀，不破坏密钥内容 |
| 17 | 已有仓库时 Keychain 拒绝自动生成 | 缺少密钥必须进入恢复流程 |

Beta 前新增的回归断言还覆盖：快照列表最新在前、根锚定排除规则只匹配根目录、跨项目恢复被拒绝。

### 已覆盖的设计验收项

- 删除本地数据库后从云端恢复：`ServiceEndToEndTests` 用全新 `AppPaths` 模拟。
- 全新 Mac 登录 iCloud 后用恢复密钥重建：同上（本地镜像等价格式）。
- 云端删除单个必要对象：`testMissingObjectIsDetected`。
- 恢复已有项目不覆盖：`testRestoreRefusesOverwriteByDefault`。
- 版本清理不删除保留版本引用数据：`testCleanupRetainsReferencedObjects`。
- Diff 与实际快照内容一致：`KopiaEngine...` 比对修改前后快照。
- 断网/重复上传幂等：内容寻址 + 对象存在即跳过（单元级覆盖），真实 iCloud 待验收。

## 3. 尚未自动化的验收项

以下项目需要真实 iCloud 账户、签名构建或故障注入环境，当前**未执行**：

| 项 | 方法 | 通过标准 |
| --- | --- | --- |
| 10,000 个小文件（已有 CT-036/037 覆盖 10 万/100 万规模，需 `CODETIME_SCALE_TESTS=1`） | 生成 fixture，创建/上传/恢复 | 文件数与内容哈希完全一致 |
| 备份时正在写文件 | 后台持续写文件并备份 | 快照标记不完整，不谎报成功 |
| 100 次随机强制退出 | 在快照/上传/发布各阶段 kill -9 | 之前已验证的云端版本仍可恢复 |
| 真实 iCloud 同步规模 | 数百 MB / 数千对象，多台 Mac | 状态最终一致，逐出后可重新下载 |
| iCloud 空间不足 | 配额受限账户 | 暂停上传，不删除旧版本 |
| iCloud 断网/重连 | 关闭网络后恢复 | 本地快照有效，重试幂等 |
| 云端空间真正回收 | 清理后用 Finder/配额确认 | 文件删除且容量释放 |
| 低磁盘空间 | 填充磁盘后备份/恢复 | 不执行可能损坏数据的操作 |
| 覆盖恢复断电 | 恢复中断电 | 原文件与保护副本至少一个完整 |
| 多 Mac 同时备份 | 两台设备同一账户 | 设备目录隔离，互不覆盖 |
| 代码签名/公证/升级回退 | Developer ID 构建 | Gatekeeper 通过，旧版可回退 |

## 4. 手动验收清单（UI）

| # | 步骤 | 期望 |
| --- | --- | --- |
| 1 | 首次启动 | 展示恢复密钥；未确认前不能继续 |
| 2 | 添加项目 | NSOpenPanel；项目出现；默认策略含排除模板 |
| 3 | 立即备份 | 状态从备份中→同步/仅本地；活动记录出现 |
| 4 | 时间机器 | 三栏渲染；目录可进入；文件可预览；↑↓ 切换快照 |
| 5 | 版本差异 | 显示新增/修改/删除统计；文本逐行并排 |
| 6 | 恢复副本 | 写入新位置，项目文件不变 |
| 7 | 覆盖恢复 | 未勾选确认时按钮禁用；执行后 `recovery/` 有保护副本 |
| 8 | 整项目恢复 | 非空目录被拒绝；空目录恢复出 `.git` |
| 9 | 排除预览 | 文件数/容量/示例与真实备份一致 |
| 10 | 设置 | 修改后重启仍生效；iCloud/本地镜像互斥 |
| 11 | 菜单栏 | 显示项目数、快速备份、暂停/恢复 |
| 12 | 关闭窗口 | 进程内调度继续；后台代理启用时由 agent 接管 |
| 13 | 云端恢复 | 选择目录 + 恢复密钥可重建仓库并发现历史路径 |

> 开发会话中主机处于锁屏状态，无法进行屏幕截图验收；上述 UI 项目需在解锁后人工执行。

## 5. 性能目标（设计目标，未测量）

- 日常增量备份不重复读取全部文件内容。
- 待机时无明显 CPU/磁盘活动（30 秒调度 tick 为轻量查询）。
- 浏览历史不重新扫描项目目录。
- Diff 只读取被比较的两个文件。
- 单文件恢复优先使用本地仓库。
- 大量快照下时间轴仍可快速加载（当前一次加载最多 1000 条元数据）。
- 云端同步失败不阻塞本地开发。

## 6. 发布门禁

在以下条件满足前不标记稳定版：

1. 真实 iCloud 同步规模、断网、逐出、配额测试通过。
2. 至少一次真实的“另一台 Mac 从云端恢复”演练。
3. 云端清理后保留版本仍可恢复，并确认空间释放。
4. 故障注入（随机 kill、断电）不破坏已验证版本。
5. Developer ID 签名、公证、自动更新与回退验证完成。
