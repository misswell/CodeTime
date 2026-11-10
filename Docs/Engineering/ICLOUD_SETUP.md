# iCloud 自动配置与首次使用（CT-129 … CT-137）

目标：**安装 → 选择项目 → 保存恢复密钥 → 开始备份**。用户不需要理解 iCloud Container、镜像目录、Kopia 或 Manifest。

## 1. 检测服务（CloudSetupService）

唯一入口：`CloudSetupService.detect(probe:)`。UI 永远不根据开关或设置推断能力。

| 状态 | 稳定错误码 | 用户文案 | 处理 |
|---|---|---|---|
| `checking` | `ICLOUD_CHECKING` | 正在检测 iCloud | 等待 |
| `unsupportedBuild` | `ICLOUD_UNSUPPORTED_BUILD` | 当前版本不支持 iCloud 备份 | 用本机备份；正式签名版可用 |
| `accountNotSignedIn` | `ICLOUD_ACCOUNT_UNAVAILABLE` | 请先登录 Apple 账户 | 打开系统设置 |
| `driveDisabled` | `ICLOUD_DRIVE_DISABLED` | 请开启 iCloud Drive | 打开系统设置 |
| `containerUnavailable` | `ICLOUD_CONTAINER_UNAVAILABLE` | iCloud 服务暂时不可用 | 稍后重新检测 |
| `notWritable` | `ICLOUD_PERMISSION_DENIED` | iCloud 备份目录不可写 | 检查空间/权限 |
| `ready` | `ICLOUD_READY` | iCloud 已就绪 | 一键启用 |

检测顺序（每一步失败都带可操作原因，不合并为“未配置”）：

1. **构建能力**：读取当前进程的签名 entitlement（`com.apple.developer.icloud-container-identifiers` 是否含 `iCloud.com.codetime.app`）。Beta/Debug 构建没有该权限，必须显示“当前版本不支持”，而不是“未配置”。
2. **账户**：`FileManager.ubiquityIdentityToken` 是否存在。
3. **容器**：`url(forUbiquityContainerIdentifier: "iCloud.com.codetime.app")`。若为空，再用默认容器区分「iCloud Drive 关闭」与「容器不可用」——无法精确区分时只报告真实探测结果，不臆测。
4. **目录 + 读写探测**：创建 `Documents/CodeTime`，写入随机测试文件、读回比对、删除。失败 → `notWritable`。

容器标识唯一来源：`CloudSetupService.containerIdentifier`（`CloudLocation` 委托它）。不再使用 `nil`（默认容器），避免写到别的容器。

## 2. 存储目标（BackupDestination）

由现有设置派生，不新增持久化字段（旧库无需迁移）：

| 条件 | 目标 |
|---|---|
| `iCloudEnabled == true` | `.iCloud` |
| 存在 `localMirrorPath` | `.customLocal(path:)` |
| 否则 | `.localOnly` |

切换规则（`CodeTimeService.configureStorage(_:)`）：

1. 先验证新目标（iCloud → 完整 `detect()`；本地镜像 → 创建目录 + 可写检查）。
2. 验证失败 → **不写任何设置**，原路径、原书签、原备份全部保留。
3. 成功才 `configRevision += 1` 保存。
4. 切换不清空 `localMirrorPath`/`localMirrorBookmark`（切回无需重新授权）。
5. 任何切换都不删除旧镜像或云端对象。

## 3. 云备份状态机（CloudBackupState）

必须区分本地快照、上传确认、云端验证：

```
notConfigured → checking → ready → uploading → publishing → uploaded → verifying → verified
                                     ↘ retrying ↗        ↘ failed
waitingForNetwork ⇄ retrying
requiresUserAction（账户/权限/凭据/配置）
```

- `uploading → verified`、`uploading → uploaded` 是**非法**转换（必须先发布 Manifest 并确认）。
- `isCloudConfirmed` 仅对 `uploaded/verifying/verified` 为真。
- 本地快照成功只表示“本地备份完成”；`ProjectSyncDisplay` 负责把本地/上传/云端失败映射成互不混淆的文案。

## 4. 首次备份（Onboarding 第 4 步）

- 对每个已添加项目执行真实的 `createSnapshot`。
- 只有 `outcome.cloudError == nil` 且最新快照 `cloudState == .synced` 才显示「首次备份已完成，并已上传到 iCloud」。
- 云端失败显示「本地备份已完成；iCloud 同步失败：…」并提供「重新同步 iCloud」（`retryPendingCloudPublishes`，幂等）。
- 首次设置完成（`completeOnboarding`）与云端备份成功是两件事，前者不表示后者。

## 5. 换机恢复

`CloudRecoverySheet` 打开时自动 `detect()`：就绪则直接使用 `storageRoot`，用户只需输入恢复密钥；只有在构建/账户/容器不可用时才提供「选择其他目录…」作为兜底。恢复仍沿用既有 CloudMirrorStore 候选发现、对象校验、staging 与提交日志。

**CT-139 项目列表**：发布成功后把项目根路径（仅路径，不含内容/密钥）合并写入该设备的
`recovery-info.json` 的 `projectPaths` 字段（去重、排序、上限 50）。恢复页因此在**下载任何对象之前**
就能展示「设备名称 / 最近备份时间 / 项目」。该字段为可选，旧版恢复文件与旧版 App 均可正常读写；
`publish` 刷新恢复文件时会保留已有列表。

## 5.1 发布前置：Developer ID 描述文件

带 iCloud 权限的 Developer ID 构建**必须**有 Developer ID 描述文件。两条路径：

1. **自动（需先同意协议）**：`Scripts/setup_apple_provisioning.sh`
   - 校验 asc/gh 认证 → 查找 Bundle ID 与 Developer ID 证书 → 创建/复用描述文件 →
     下载并用 `security cms -D` 校验其中含 `iCloud.com.codetime.app`、App Group 与 Bundle ID →
     base64 写入 secret `APPLE_PROVISIONING_PROFILE`。任何一步失败都会给出下一步操作。
2. **手动**：developer.apple.com → Profiles → + → Developer ID → Mac App，
   App ID `com.codetime.app`，勾选 iCloud 容器与 App Group，下载后
   `base64 -i <file> | gh secret set APPLE_PROVISIONING_PROFILE --repo misswell/CodeTime`。

### 5.2 iCloud 验收构建（CT-140）

Beta 配置的 entitlements 是**空的**（ad-hoc 包不允许声称 iCloud）。要做真实双 Mac 验收，必须显式构建
带 iCloud 权限的验收包：

```bash
# 先安装描述文件到本机（setup 脚本会打印名称）
PROVISIONING_PROFILE_SPECIFIER="CodeTime Developer ID" \
CODETIME_BETA_ICLOUD=1 Scripts/package_beta.sh
```

实现说明（CT-143）：`project.yml` 新增 `BetaICloud` 配置承载 Release entitlements +
Hardened Runtime。**不要**用命令行 `CODE_SIGN_ENTITLEMENTS=...` 打开 iCloud——该设置会传播到
SwiftPM 包目标并按错误相对路径解析，导致构建失败（实测）。

要求：Developer ID 身份 + 含 iCloud 容器的描述文件；缺任一项脚本**明确失败**，不会静默退回 ad-hoc。
CI 侧可在手动触发 Release workflow 时勾选 `icloud_beta`（同样要求 `APPLE_PROVISIONING_PROFILE`）。
验收包与正式包使用同一容器，数据隔离沿用「每设备独立 deviceID/仓库目录」，两台 Mac 用同一 Apple 账户即可互相发现。

> **当前环境阻塞（2026-11-11 实测）**：App Store Connect API 返回
> `PLA Update available … Account Holder, Guofeng Liu, must agree to the latest Program License Agreement`。
> 描述文件与证书接口全部不可用，`xcodebuild -allowProvisioningUpdates` 同样建不出 profile。
> 只有账号持有人登录 developer.apple.com → Agreements 同意后才能继续；此后运行上面的脚本即可。

## 6. 发布校验

`Scripts/validate_entitlements.sh <signed.app>` 现在验证**签名产物**：

- `codesign -d --entitlements :-` 中含 sandbox、iCloud services、容器 `iCloud.com.codetime.app`、ubiquity 容器、App Group、keychain group；
- 嵌入的 `embedded.provisionprofile` 授权同一容器与 App Group；
- Beta entitlements 仍不得声明 iCloud（避免无签名构建看起来“支持同步”）。


## 7. 双 Mac 验收证据（CT-141 / CT-142）

验收本身必须在两台真实 Mac 上用**签名包**完成；脚本只负责让证据可复现、不可伪造：

```bash
# Mac A（源）
Scripts/icloud_acceptance.sh prepare --project ~/AcceptanceFixture --out A.json
#   → 逐文件 SHA-256、host/model/macOS
#   然后用 App：添加项目 → 备份 → 确认「已上传到 iCloud」

# Mac B（恢复）
#   用 App：从云端恢复 → 输入恢复密钥 → 恢复项目
Scripts/icloud_acceptance.sh verify --evidence A.json --restored ~/AcceptanceFixture --out B.json
#   → 逐文件比对；任何差异 exit 1，并列出 mismatched/missing

# 生成验收报告（B.verified 必须为 true，否则拒绝生成）
Scripts/icloud_acceptance.sh report --a A.json --b B.json \
  --tag v1.0.0 --commit <git sha> --candidate-sha <zip sha256> \
  --candidate-name CodeTime-1.0.0-macos-universal.zip \
  --run <workflow-run-id> --operator "<name>" \
  --out Docs/releases/v1.0.0-icloud-acceptance.md
```

要点：
- fixture 只用**不会被排除规则命中**的文件（`main.swift`、`README.md`、`src/*.txt`）；`node_modules/.git/logs` 等本就不会被恢复，不应作为对比对象。
- `report` 只从真实证据生成，字段（fileCount / checkedFiles / host / model）全部来自 JSON；
  校验未通过、文件数不一致、缺少 B 证据时**拒绝输出**，因此无法伪造 PASS 报告。
- `verify_release.sh` 现在会调用 `Scripts/smoke_launch.sh`（有界启动检查）：签名正确但**启动即崩溃**的包会被拦截；
  本地无 GUI 会话可用 `CODETIME_SKIP_LAUNCH_SMOKE=1` 跳过。
