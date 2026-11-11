# 真实 iCloud 双 Mac 验收状态

状态：**PARTIAL / BLOCKED**（最近更新：2026-11-11T14:09Z）

已完成：PLA 已接受；`com.codetime.app` Bundle ID 已创建；ICLOUD capability 已启用；
本机已注册为 Mac 开发设备；Mac Development profile 已生成。
仍阻塞：profile 的 iCloud container 数组为空（public API 不能创建/关联 container）；
本机 iCloud Drive 上传仍报 4355；没有第二台 Mac。

> 接受 Apple Developer Program License Agreement 是 Account Holder 的法律行为，
> Agent 不得代为接受。以下阻塞必须由用户本人完成。

本文件记录真实环境验收的前置条件、已执行检查与原始证据。任何前置条件未满足时，
不得将本项标记为通过，也不得用本地镜像/模拟环境替代。

## 1. 前置条件检查

| 前置条件 | 当前结果 | 证据 |
|---|---|---|
| 本机有 Apple 代码签名身份 | 通过：Apple Development、Apple Distribution、Developer ID 三条有效身份 | `security find-identity -v -p codesigning` |
| Xcode 可见开发团队 | 部分：`com.apple.dt.Xcode` 可见 team `U8U443D7ZL` | `defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier` |
| Xcode 命令行有可用账号 | **失败**：`xcodebuild -allowProvisioningUpdates` 报 `No Accounts` | `xcodebuild-automatic-signing-blocked-20261111.log` |
| 带 iCloud feature 的 provisioning profile | **失败**：无 `com.codetime.app` 的 Mac Development/Developer ID profile；BetaICloud 构建报 “requires a provisioning profile with the iCloud feature” | `betaicloud-provisioning-blocked-20261111.log` |
| Apple Developer Program License Agreement | **通过**：2026-11-11T13:52Z 后 `asc bundle-ids list` 可用 | `asc bundle-ids list` |
| Bundle ID `com.codetime.app` | **通过**：已创建，resource `33UYTPSVJB` | `asc bundle-ids` |
| ICLOUD capability | **通过**：已启用 `ICLOUD_VERSION=XCODE_6` | `asc bundle-ids capabilities list` |
| Mac Development provisioning profile | **部分**：profile ACTIVE，但 container 数组为空 | `Scripts/configure_icloud_signing.sh --check-only` |
| iCloud Container `iCloud.com.codetime.app` | **失败**：公共 API 不支持创建/关联，需 Developer Portal | `configure_icloud_signing.sh` 输出 |
| 真实 iCloud Drive 可上传 | **失败**：对 iCloud Drive 的探测文件返回 `NSCocoaErrorDomain 4355` “Couldn't access your iCloud account” | `icloud-preflight-blocked-20261111.log`、`v3icloud-single-mac-blocked-20261111.log` |
| 第二台 Mac（同一 Apple ID） | **未提供** | 无第二台设备证据 JSON |

结论：本机连“单机真实 iCloud 上传”都未通过，双机验收不具备执行条件。

## 2. 已尝试的本机修复

- 对 `bird` 发送 `SIGHUP`：无变化。
- 终止 `bird` 并由 launchd 重启（新 PID）：无变化，仍为 `NSCocoaErrorDomain 4355`。
- 网络检查：`www.icloud.com`、`www.apple.com` 均 200；`appleid.apple.com` 可达。
- 时钟检查：系统 UTC 时间与 Apple HTTP `Date` 头相差约 8 分钟，不足以解释认证失败。
- 结论：不是同步进程卡死、网络不通或时钟严重漂移；仍需用户重新认证 iCloud 账户/接受相关条款。

## 3. 已执行的真实检查

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

## 4. 解除阻塞所需的外部操作（只能由用户/Account Holder 完成）

1. 在 Developer Portal → Identifiers → iCloud Containers 注册
   `iCloud.com.codetime.app`（描述 CodeTime）。
2. 在 Identifiers → App IDs → `com.codetime.app` → iCloud → Configure，
   勾选该 container 并保存。
3. 运行 `Scripts/configure_icloud_signing.sh`：脚本会重建 profile、校验
   container entitlement、安装 profile 并构建/验证 BetaICloud。若 container
   未关联，脚本以 `ICLOUD_SIGNING_BLOCKED` 退出。
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

## 5. 不得替代的证据

以下结果不能作为本项通过证据：

- 本地镜像目录/内存 Fake 对象存储的跨设备测试（CT-170 仅为模拟）。
- 单机真实 iCloud Drive 探测成功（即使未来恢复，也只覆盖上传/恢复，不覆盖双机发现）。
- 只构建成功、只跑通测试、只有计划或模板。
- 没有第二台 Mac 的 host 证据、或 B 侧 `verified != true`。

## 6. 原始日志

- `Docs/Engineering/TestArtifacts/icloud-preflight-blocked-20261111.log`
- `Docs/Engineering/TestArtifacts/v3icloud-single-mac-blocked-20261111.log`
- `Docs/Engineering/TestArtifacts/betaicloud-provisioning-blocked-20261111.log`
- `Docs/Engineering/TestArtifacts/xcodebuild-automatic-signing-blocked-20261111.log`
- `Docs/Engineering/TestArtifacts/icloud-preflight-recheck-20261111T1348Z.log`
- `Docs/Engineering/TestArtifacts/icloud-preflight-after-bird-restart-20261111.log`（重启 bird 后仍 4355）
- 签名配置脚本：`Scripts/configure_icloud_signing.sh`
