# 真实 iCloud 双 Mac 验收状态

状态：**BLOCKED / NOT RUN**（截至 2026-11-11）

本文件记录真实环境验收的前置条件、已执行检查与原始证据。任何前置条件未满足时，
不得将本项标记为通过，也不得用本地镜像/模拟环境替代。

## 1. 前置条件检查

| 前置条件 | 当前结果 | 证据 |
|---|---|---|
| 本机有 Apple 代码签名身份 | 通过：Apple Development、Apple Distribution、Developer ID 三条有效身份 | `security find-identity -v -p codesigning` |
| Xcode 可见开发团队 | 部分：`com.apple.dt.Xcode` 可见 team `U8U443D7ZL` | `defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier` |
| Xcode 命令行有可用账号 | **失败**：`xcodebuild -allowProvisioningUpdates` 报 `No Accounts` | `xcodebuild-automatic-signing-blocked-20261111.log` |
| 带 iCloud feature 的 provisioning profile | **失败**：无 `com.codetime.app` 的 Mac Development/Developer ID profile；BetaICloud 构建报 “requires a provisioning profile with the iCloud feature” | `betaicloud-provisioning-blocked-20261111.log` |
| Apple Developer Program License Agreement | **失败**：App Store Connect API 报 “PLA Update available … Account Holder must agree” | `icloud-preflight-blocked-20261111.log` |
| 真实 iCloud Drive 可上传 | **失败**：对 iCloud Drive 的探测文件返回 `NSCocoaErrorDomain 4355` “Couldn't access your iCloud account” | `icloud-preflight-blocked-20261111.log`、`v3icloud-single-mac-blocked-20261111.log` |
| 第二台 Mac（同一 Apple ID） | **未提供** | 无第二台设备证据 JSON |

结论：本机连“单机真实 iCloud 上传”都未通过，双机验收不具备执行条件。

## 2. 已执行的真实检查

```bash
security find-identity -v -p codesigning
defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier
asc bundle-ids list
xcodebuild ... -configuration BetaICloud -allowProvisioningUpdates ...
Packages/CodeTimeKit/.build/out/Products/Release/V3Acceptance icloud \
  "$HOME/Library/Mobile Documents/com~apple~CloudDocs"
Scripts/icloud_preflight.sh
```

`V3Acceptance icloud` 使用独立命令行进程、真实 `NSFileCoordinator` 与
`UbiquitousUploadTracker`，在 iCloud Drive 中创建唯一测试目录；失败发生在
“等待 iCloud 确认上传”阶段，未发布 commit，未产生通过报告。

## 3. 解除阻塞所需的外部操作（只能由用户/Account Holder 完成）

1. 用团队 Account Holder `Guofeng Liu` 登录 App Store Connect，接受最新
   Apple Developer Program License Agreement。
2. 在 Xcode → Settings → Accounts 中登录同一 Apple ID，确认账号可用于
   `com.codetime.app`。
3. 在 Xcode Signing & Capabilities 中为 `CodeTime` 配置 iCloud
   (CloudDocuments) capability，使用 `iCloud.com.codetime.app`，生成并选择
   Mac Development / Developer ID provisioning profile。
4. 修复本机 iCloud 账户状态（系统设置 → Apple ID → iCloud），直到向
   iCloud Drive 写入探测文件后 `ubiquitousItemIsUploaded == true` 且
   `ubiquitousItemUploadingError == nil`。
5. 准备第二台 Mac，登录同一 Apple ID，确认 iCloud Drive 同步正常。
6. 两台 Mac 都运行：
   ```bash
   Scripts/icloud_acceptance.sh preflight
   ```
   必须返回 `ICLOUD_PRECHECK_READY`。
7. 按 `Docs/releases/ICLOUD_ACCEPTANCE_TEMPLATE.md` 执行上传、驱逐、重新下载、
   跨设备发现，并用 `Scripts/icloud_acceptance.sh prepare/verify/report` 归档
   原始 JSON 与日志。只有最终报告 `verified=true` 才能写 PASS。

## 4. 不得替代的证据

以下结果不能作为本项通过证据：

- 本地镜像目录/内存 Fake 对象存储的跨设备测试（CT-170 仅为模拟）。
- 单机真实 iCloud Drive 探测成功（即使未来恢复，也只覆盖上传/恢复，不覆盖双机发现）。
- 只构建成功、只跑通测试、只有计划或模板。
- 没有第二台 Mac 的 host 证据、或 B 侧 `verified != true`。

## 5. 原始日志

- `Docs/Engineering/TestArtifacts/icloud-preflight-blocked-20261111.log`
- `Docs/Engineering/TestArtifacts/v3icloud-single-mac-blocked-20261111.log`
- `Docs/Engineering/TestArtifacts/betaicloud-provisioning-blocked-20261111.log`
- `Docs/Engineering/TestArtifacts/xcodebuild-automatic-signing-blocked-20261111.log`
