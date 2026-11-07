# 发布检查清单

## 0. 发布分类

| 标签 | 渠道 | 要求 |
|---|---|---|
| `v1.0.0-beta.*` | 预发布 | 全量回归 + 静态 Entitlements；ad-hoc 签名；不得声明 iCloud 已验收 |
| `v1.0.0-rc.*` | 预发布 | beta 门禁 + Release 构建 + 真实环境验收记录 |
| `v1.0.0` | 正式版 | 全部门禁 + Developer ID + 公证 + stapling + 双机 iCloud 验收 |

`Scripts/package_release.sh` 只接受 stable 渠道（`CODETIME_RELEASE_CHANNEL=stable`），要求 tag 与版本一致，并要求双 Mac iCloud 验收报告存在；手动 workflow 需填写 `version`（beta/rc 还需 `prerelease`），工作流会用解析后的 tag。

## 1. 代码与测试门禁

- [ ] `swift build --package-path Packages/CodeTimeKit` 无错误、无新增警告。
- [ ] `Scripts/regression_gate.sh` 输出 `REGRESSION GATE: PASS`。
- [ ] `Scripts/test.sh` 汇总为 `with 0 failures`。
- [ ] CT-001…CT-044 全部存在（门禁脚本会检查编号）。
- [ ] Schema 迁移（MIG-001/002）通过。
- [ ] 工作区差异已审查，无未提交的调试代码、临时文件或凭据。
- [ ] `git status` 中只包含本任务相关改动。

## 2. 构建

- [ ] Debug 构建通过：`xcodebuild -project CodeTime.xcodeproj -scheme CodeTime -configuration Debug build`。
- [ ] Release（未签名/本地签名）构建通过。
- [ ] Release 使用 App Sandbox + Hardened Runtime。
- [ ] `Resources/Kopia/kopia` 为固定版本、universal、已签名。
- [ ] LaunchAgent plist 被打包到 `Contents/Library/LaunchAgents`。

## 3. Entitlements 与签名

```bash
Scripts/validate_entitlements.sh
Scripts/validate_entitlements.sh path/to/CodeTime.app
```

- [ ] Release entitlements 含 iCloud 容器、App Group、Keychain Access Group、用户选择文件读写。
- [ ] Beta 不声明 iCloud。
- [ ] Kopia entitlements 与嵌套签名有效。
- [ ] `codesign --verify --deep --strict` 通过。
- [ ] Developer ID Application 签名（stable）。
- [ ] `codesign -dv --verbose=4` 显示 Hardened Runtime。
- [ ] `spctl --assess` 通过。

## 4. 公证与 Stapling（stable）

必需环境变量：

- `DEVELOPMENT_TEAM`
- `APPLE_ID`
- `NOTARY_PASSWORD`（app-specific password）

流程：

```bash
Scripts/package_release.sh
Scripts/verify_release.sh dist/CodeTime-<version>.zip
```

- [ ] `notarytool submit --wait` 返回 Accepted。
- [ ] `xcrun stapler staple` 成功。
- [ ] `xcrun stapler validate` 成功。
- [ ] 重新压缩后的 zip 生成 SHA-256 sidecar。
- [ ] `verify_release.sh` 通过（zip 哈希、解压、entitlements、`spctl`、stapler、Kopia 可运行且为 universal）。
- [ ] 缺少公证凭据时脚本必须失败，不允许默认放行。

## 5. Kopia 二进制

```bash
Scripts/fetch_kopia.sh
```

- [ ] 固定版本 0.23.1。
- [ ] 下载包 SHA-256 与脚本中固定值一致。
- [ ] 解压后验证版本、架构（arm64 + x86_64）。
- [ ] 已有二进制可用时，验证版本/架构/签名/sidecar；不匹配则重新获取。
- [ ] `Resources/Kopia/kopia.sha256` 与实际文件一致。
- [ ] 未经验证的二进制不得进入 Release。

## 6. CI

- [ ] `Build` 通过。
- [ ] `Unit Tests` 通过。
- [ ] `Integration Tests` 通过。
- [ ] `CloudMirrorStore Tests` 通过。
- [ ] `Recovery Tests` 通过。
- [ ] `Concurrency Tests` 通过。
- [ ] `Security Tests` 通过。
- [ ] `Release Build` 通过。
- [ ] `Entitlements Validation` 通过。
- [ ] `Regression Gate` 通过。
- [ ] 任一关键测试失败都阻止发布。

## 7. 真实环境验收（stable 必须）

- [ ] 两台 Mac 登录同一 iCloud 账号。
- [ ] Mac A 发布 Generation，Mac B 能看到并恢复。
- [ ] 断开/恢复 iCloud 同步，确认未确认上传不显示成功。
- [ ] 恢复中断后继续，已完成对象不重复下载。
- [ ] 多设备候选列表显示正确，密钥不匹配时可继续搜索。
- [ ] 恢复完成后仓库与快照校验通过。
- [ ] 已按 `Docs/releases/ICLOUD_ACCEPTANCE_TEMPLATE.md` 填写 `<tag>-icloud-acceptance.md`，且 `Scripts/require_icloud_acceptance.sh <tag>` 通过。
- [ ] Beta 数据迁移到 Stable 后项目、快照、仓库、Bookmark 正常。
- [ ] 卸载后重新安装，数据与授权行为符合预期。
- [ ] 稳定版升级与回退：升级后数据可读；回退到上一版本不损坏数据。

记录验收设备、macOS 版本、构建号、iCloud 账号环境与结果。未实际执行的项目保持未勾选，不得在发布说明中声明已通过。

## 8. 发布后

- [ ] 附上 SHA-256 sidecar 与签名/公证验证结果。
- [ ] 发布说明列出已知限制（见 `KNOWN_LIMITATIONS.md`）。
- [ ] 保留上一版本安装包与校验值，支持回退。
- [ ] 监控启动失败、迁移失败、iCloud 同步失败日志。
