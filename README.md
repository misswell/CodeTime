# CodeTime

**macOS 原生代码时间机器。** 选择代码目录，CodeTime 会像 Time Machine 一样自动保存历史版本，把加密后的不可变对象同步到 iCloud Drive，并允许你回到任意一个保留的时间点。

不依赖 Git 提交，不修改 Git 工作区，不使用第三方云服务。

CodeTime 2.0 起默认使用**云端优先引擎（Cloud Format v3）**：

```
项目目录 ──▶ FastCDC 内容分块 ──▶ 压缩+AEAD 加密 ──▶ 待上传 spool ──▶ iCloud Drive/CodeTime/v3
             (流式/去重)          (内容寻址对象)      (确认后释放)      (不可变对象+加密树+Commit)
                                                                              │
本地：SQLite 索引 + 有界下载缓存 + 未上传数据 ◀── 按需恢复（只下载所需数据块）┘
```

旧版 Kopia / Cloud Format v2 继续保留为只读兼容路径；迁移会先发布并校验旧数据、再创建并校验 v3 基线，
只有用户明确同意后才释放旧本地仓库。

## 当前状态

| 能力 | 状态 | 验证方式 |
| --- | --- | --- |
| 云端优先 v3 引擎、FastCDC 分块、内容寻址、AEAD | 已实现 | CT-147…CT-164 自动化测试 |
| 不可变 Merkle 树、加密节点、Commit Marker | 已实现 | v3 存储与引擎测试 |
| 持久待上传队列、软上限暂停、断网续传 | 已实现 | CT-159（内存云 + 本地镜像） |
| 按需恢复（单文件/目录/项目）、新 Mac 发现 | 已实现 | CT-155、CT-160、CT-164 |
| 两阶段云端 GC、整包引用保护 | 已实现 | CT-163 |
| v2→v3 迁移、旧历史保留、显式释放旧仓库 | 已实现 | CT-158、CT-162 |
| 有界下载缓存与 iCloud 本地副本驱逐 | 已实现 | CT-156；真实 iCloud 驱逐行为未验收 |
| Kopia 仓库、定时/手动快照、排除规则、保留策略（兼容模式） | 已实现 | 原有回归测试 |
| SwiftUI 主界面、项目设置、时间机器、恢复、设置、菜单栏 | 已实现并编译通过 | 构建验证；未逐屏人工验收 |
| LaunchAgent 后台代理、唤醒补跑、文件锁选主 | 已实现 | `--agent --once` 冒烟通过 |
| 真实 iCloud 双 Mac 同步 | 代码路径已接好 | **NOT RUN**：需要签名构建、真实容器与两台 Mac |
| FSEvents 实时触发 | 预留（未启用） | 当前由定时/手动/唤醒补跑覆盖 |

自动化测试：**260 项，0 失败，3 项人工/规模验收跳过**。详情见 `Docs/Engineering/TEST_REPORT.md`
与 `Docs/Engineering/V3_ACCEPTANCE_REPORT.md`。

## 功能

- **无感备份**：按 15 分钟到 8 小时的可配置间隔创建加密快照；关闭主窗口后仍由后台代理继续。
- **时间机器**：三栏布局浏览快照目录树、文件内容与历史时间轴；支持键盘 ↑↓ 切换版本。
- **安全恢复**：预览、恢复副本、覆盖（先保护当前文件并要求二次确认）、整项目恢复。
- **开发者排除规则**：Node.js / Java / Python / Swift / 通用模板，自定义规则，排除预览（文件数、容量、示例）。
- **Git 上下文**：只读采集分支、HEAD、dirty/untracked 状态，绝不执行 commit/stash/checkout/reset。
- **iCloud 灾难恢复**：不可变对象按 SHA-256 存放，加密版本清单最后发布；换机后凭恢复密钥重建仓库。
- **存储治理**：Kopia 保留策略 + 云端两阶段清理（引用检查 + 30 天宽限期 + 至少 2 代）。
- **可诊断**：任务日志、完整性校验、恢复校验等级（本地校验 / 异机验证）。

## 环境要求

- macOS 14 或更高（开发环境为 macOS 27 / Xcode 27）
- Apple Silicon 或 Intel（内置 Kopia universal 二进制）
- Xcode 16+、Swift 6 工具链（工程以 Swift 5 语言模式编译）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- 首次构建前确认 `Resources/Kopia/kopia` 存在；缺失时运行 `Scripts/fetch_kopia.sh`

## 快速开始

```bash
# 1. 生成工程并构建（Debug，ad-hoc 签名）
./Scripts/build.sh

# 2. 运行
open .build/DerivedData/Build/Products/Debug/CodeTime.app

# 3. 运行核心测试（真实 Kopia + 云端镜像 + 换机恢复）
./Scripts/test.sh
```

Kopia 二进制（97 MB）不进入 Git 历史；`build.sh` / CI 会在缺失时自动运行
`Scripts/fetch_kopia.sh` 按固定 SHA-256 下载。

### Beta 发布

```bash
./Scripts/package_beta.sh
```

生成 `dist/CodeTime-<version>-beta.1-macos-universal.zip` 与 SHA-256。Beta 为
ad-hoc 签名、未公证、未启用 iCloud entitlement，只适合开发者试用；安装说明和已知
问题见 `Docs/releases/v1.0.0-beta.1.md`。正式版需要 Developer ID 证书并完成
`Scripts/package_release.sh` 的签名/公证流程。

首次启动会生成恢复密钥并写入 macOS Keychain。**请立即离线保存恢复密钥**；它是换机恢复时解密云端清单、取回 Kopia 仓库密码的唯一人工凭据。

### 使用 iCloud 镜像

Debug 构建不启用 App Sandbox 与 iCloud entitlement，因此只能使用“本地镜像”模式（设置 → 云端 → 本地镜像）。要使用真实 iCloud：

1. 在 Apple Developer 账号中注册容器 `iCloud.com.codetime.app`。
2. 配置 `Apps/CodeTime/CodeTime.entitlements` 与 `project.yml` 中的 Team / provisioning。
3. 使用 Developer ID 签名构建（`Scripts/package_release.sh`），并在设置中启用 iCloud。

## 数据位置

| 内容 | 路径 |
| --- | --- |
| 应用数据 | `~/Library/Application Support/CodeTime/` |
| SQLite（WAL） | `.../database/codetime.sqlite` |
| 本地 Kopia 仓库 | `.../repositories/<repository-id>/repo` |
| 日志 | `.../logs/codetime.log` |
| 覆盖前保护副本 | `.../recovery/<时间戳>/<项目>/<文件>` |
| iCloud 镜像 | `iCloud Drive/CodeTime/` |

SQLite 数据库**不会**同步到 iCloud；云端只保存 CodeTime Cloud Format v1（见 `Docs/CLOUD_FORMAT.md`）。

## 工程结构

```
CodeTime/
├── Apps/CodeTime/                 SwiftUI 应用 + 菜单栏 + agent 模式
├── Packages/CodeTimeKit/          Swift Package（8 个模块）
│   ├── Sources/SharedModels       模型、协议、错误、格式化
│   ├── Sources/Persistence        SQLite WAL + 版本迁移
│   ├── Sources/Security           Keychain、AES-256-GCM、HKDF、恢复密钥
│   ├── Sources/BackupEngine       Kopia CLI、排除规则、浏览/Diff/恢复/校验
│   ├── Sources/CloudMirrorStore   不可变对象、加密清单、恢复、清理
│   ├── Sources/GitIntegration     只读 Git 采集
│   ├── Sources/Diagnostics        文件日志与诊断
│   └── Sources/CodeTimeCore       服务、调度、备份/恢复/云编排
├── Resources/Kopia/               内置 Kopia 0.23.1 universal + 许可证
├── Resources/LaunchAgents/        com.codetime.agent.plist
├── Scripts/                       构建、测试、Kopia 拉取、发布
└── Docs/                          架构、云端格式、安全、恢复、测试计划
```

## 设计取舍

- **不使用独立 `CodeTimeAgent` 可执行文件启动后台任务。** LaunchAgent 以 `--agent` 模式运行主应用二进制。这样 UI 与代理共享同一签名与 Keychain ACL，避免两个二进制互相触发 Keychain 授权弹窗。调度仍由独立进程完成，通过 SQLite + `flock` 文件锁选主。
- **不使用 XPC。** v1 通过共享 SQLite、`repository.lock`、`scheduler.lock` 与 `DistributedNotificationCenter` 协调；崩溃恢复由持久化任务记录保证。XPC 可在不改变数据模型的前提下后续加入。
- **本地仓库是完整副本。** CodeTime 不是“零本地占用”的云备份；`Docs/SECURITY.md` 与设置页都会明确说明。
- **排除规则不实现 `!` 取反。** Kopia 的忽略列表不支持取反（已实测），预览与真实备份必须保持同一语义。
- **iCloud 的“已上传”只是信号。** 跨 Mac 恢复仍需要完整性校验与恢复演练，CodeTime 将两者分开记录。

## 已知限制

- 真实 iCloud 同步尚未在已注册容器的签名构建上验证。
- FSEvents 实时触发未启用；备份由定时、手动、唤醒补跑驱动。
- 备份期间持续变化的文件目前通过 Kopia 的 `errorCount` / `numFailed` 标记为“不完整”，没有做逐文件前后指纹比对。
- 尚未实现“无变化项目跳过快照”：到达间隔仍会生成一次快照（Kopia 仍会扫描源目录）。
- 云端发布每次都会枚举并哈希本地仓库文件（带 mtime 哈希缓存），仓库很大时发布会偏慢。
- 后台代理注册（SMAppService）需要 Developer 签名；ad-hoc 开发构建可能注册失败并给出提示。
- 云端恢复一次恢复一个设备的仓库（设备隔离设计）；多设备历史不会自动合并。

## 许可

Apache License 2.0。内置 Kopia 二进制同样以 Apache-2.0 分发，许可证见 `Resources/Kopia/LICENSE`，第三方声明见 `NOTICE`。
