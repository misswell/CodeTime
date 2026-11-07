# 恢复系统设计

## 1. 目标

恢复必须在以下条件下仍然安全：

- 换机、重装、系统崩溃；
- iCloud 文件尚未下载或同步中断；
- 多台 Mac 保存了同一仓库或不同仓库；
- 恢复中途断电、退出应用或网络中断；
- 恢复密钥不匹配或恢复信息损坏。

核心原则：**恢复失败不得污染现有正式仓库；任何未确认的恢复都不得报告成功。**

## 2. 恢复凭据与候选发现

云端每个设备/仓库目录包含 `recovery-info.json`：

- `repositoryId`
- `deviceId` / `deviceName`
- `keyFingerprint`
- 加密的 `RecoveryPayload`（仓库密码、创建时间）

`recoverCandidates(storageRoot:recoveryKey:)`：

1. 列出 `devices/`。目录不存在报 `notFound`；存在但不可读报 `metadataUnavailable`，不把它当作空目录。
2. 只接受 UUID 命名的设备目录；无法识别的目录不会被伪造成候选。
3. 逐设备列出 `repositories/`。缺失视为该设备没有仓库；不可读直接报错。
4. 对每个仓库：
   - 确保 `recovery-info.json` 已从 iCloud 下载；
   - 解析并校验 `repositoryId` 与目录一致；
   - 比较 `keyFingerprint`；
   - 解密 payload 并校验可解码。
5. 枚举 `commits/*.ctm`：缺失视为 0 个版本；不可读则候选标记 `blockedReason`，不假装完整。
6. 逐个下载、解密、解析清单，统计可读版本与最新版本；任一不可读则候选 `integrityOK = false`。

候选按 `latestBackupAt` 倒序返回。单个候选失败不会中断其他候选（CT-016、CT-017）。

## 3. 恢复流程

```text
选择 Generation / 候选
  ↓
创建或恢复 cloud_restore_job（状态、进度、stagingPath）
  ↓
按清单逐对象下载到 staging 仓库
  ├─ 目标已存在且哈希匹配：跳过
  ├─ 目标损坏/半文件：写临时文件 → 校验 → 原子替换
  └─ 对象缺失/哈希不符：失败，不写入正式仓库
  ↓
更新 completed_files / completed_bytes / last_error（可恢复）
  ↓
全部对象完成后校验 staging 仓库
  ↓
校验清单声明的快照 ID 全部存在
  ↓
STAGING → REPOSITORY_MOVED → SECRETS_INSTALLED → DATABASE_COMMITTED → ENGINE_VERIFIED
  ↓
写入 RestoreReport
```

### 3.1 临时仓库

- 恢复写入 `staging` 目录，不直接写正式仓库。
- 已存在且哈希匹配的对象可复用，实现断点恢复（CT-013）。
- 复制目标先写 `.ctrestore-*` 临时文件，校验后再原子移动；崩溃留下的临时文件下次自动清理（CT-049）。
- 损坏的既有目标文件会被替换，而不是永久阻塞恢复。
- 提交阶段（`committing`）可恢复：若 staging 已移动，重启后继续安装密钥、写记录和校验（CT-050）。
- 复制/下载失败时，正式仓库保持不变（CT-014）。
- 对象哈希不匹配时失败（CT-015）。

### 3.2 状态持久化

`cloud_restore_jobs` 保存：

- 任务 ID、仓库 ID、Generation ID；
- 当前状态；
- `stagingPath`；
- 总/已完成文件数与字节数；
- 最后错误。

应用重启后通过未完成任务列表恢复（CT-019）。重复执行同一恢复任务幂等，不会创建第二份污染数据（CT-020）。恢复不再用 `snapshotCount == 0` 阻止；是否可恢复由实际仓库槽位和用户选择决定。

### 3.3 完成校验

`RestoreReport` 只有在以下两项都为真时才返回 `.passed`：

1. **仓库检查**：Kopia 能打开 staging 仓库并通过校验；
2. **快照检查**：清单声明的每个 snapshot ID 都存在于恢复后的仓库中；空集合不视为通过。

任何一项失败都返回 `.failed`，不写入 `verified` 状态（CT-018）。

## 4. 多设备与密钥不匹配

- 每个候选独立验证密钥指纹与解密结果。
- 指纹不匹配标记“恢复密钥与该设备不匹配”，继续搜索。
- 第一个候选不可用不会中止整个恢复。
- 同一仓库 ID 出现在多台设备时，候选保留各自的 `deviceID`，避免仅凭 repository ID 误用其他设备的恢复信息。

## 5. 失败处理

| 失败 | 行为 |
|---|---|
| 恢复信息不可下载 | 候选标记阻塞原因，继续其他候选 |
| 恢复信息格式无效 | 候选标记原因 |
| 密钥指纹不匹配 | 候选标记原因，继续 |
| Payload 解密失败 | 候选标记原因，继续 |
| 版本清单不可读 | 候选 `integrityOK = false` |
| 对象下载失败 | 任务可重试，staging 保留 |
| 对象哈希不符 | 任务失败，正式仓库不变 |
| 仓库/快照校验失败 | 报告 `.failed`，不切换正式仓库 |
| 应用退出/崩溃 | 任务保留，下次继续 |

## 6. 用户可见语义

- 候选列表明确显示“可恢复 / 被阻塞及原因”，不隐藏不可读设备。
- 恢复进度来自持久化的已完成文件与字节数。
- 只有实际完成并通过校验的恢复才显示成功。
- 未执行真实 iCloud 双机验收时，不得在发布说明中声称已完成该验收。
