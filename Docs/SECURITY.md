# CodeTime 安全模型

## 1. 密钥层级

```
恢复密钥 / master key（32 字节，随机生成）
│  存放：macOS Keychain（AfterFirstUnlock）
│  展示：Crockford Base32，形如 CT1-XXXXX-XXXXX-…
│
├── HKDF-SHA256(salt=每次清单随机 16B, info="codetime.cloud.manifest.v1")
│      └── 版本清单加密密钥（AES-256-GCM，AAD 绑定仓库 ID + 版本 ID）
│
└── 恢复凭据 payload（AES-256-GCM，AAD="recovery:<repository-id>"）
       └── Kopia repository password（32 字节随机，Base64URL）
              └── Kopia 内容加密（AES-256-GCM-HMAC-SHA256）
```

- 恢复密钥同时是云端清单的根密钥；它不会上传到任何地方。
- Kopia 仓库密码由应用随机生成并存入 Keychain；用户无需记忆。
- 不同用途使用独立 HKDF 上下文与随机 Salt，不复用同一密钥流。
- 清单 AAD 绑定 `repositoryId + generationId`，无法把旧清单重放到新版本。

## 2. 加密实现

| 数据 | 算法 | 说明 |
| --- | --- | --- |
| Kopia 仓库内容 | AES-256-GCM（Kopia 默认） | CodeTime 不替换 Kopia 的加密实现 |
| 云端版本清单 | AES-256-GCM + HKDF-SHA256 | CryptoKit |
| 恢复凭据 | AES-256-GCM + HKDF-SHA256 | 与清单使用不同 info/Salt |
| 恢复密钥编码 | Crockford Base32 | 32 字节 → 52 字符，5 字符分组 |
| 对象校验 | SHA-256 | 内容寻址，可流式校验大文件 |

`CTM1` 文件格式见 `Docs/CLOUD_FORMAT.md`。

## 3. Keychain 与多进程

当前应用与后台代理是**同一签名二进制**：

- UI：`CodeTime.app/Contents/MacOS/CodeTime`
- 代理：同一可执行文件 + `CODETIME_AGENT_MODE=1`（LaunchAgent）

这保证 Keychain 条目的默认 ACL 对两者都有效，不会出现“窗口能读、后台代理弹授权”
的分裂行为。

开发构建使用 ad-hoc 签名时，每次重新构建都会改变代码哈希，Keychain 可能要求重新
授权。正式发布必须使用稳定的 Developer ID 签名；若未来拆分为独立 agent 二进制，
需要：

1. 两个 target 使用相同的 Team ID 与 `keychain-access-groups` entitlement。
2. Keychain 查询携带 `kSecAttrAccessGroup`。
3. 使用带 provisioning profile 的签名构建。

## 4. 文件访问

- 通过 `NSOpenPanel` 选择项目目录，保存 Security-Scoped Bookmark。
- 不申请全盘访问；不在用户目录之外扫描。
- 授权失效时提示重新选择，不静默跳过。
- 恢复路径必须位于项目根目录内；标准化并解析符号链接后再检查前缀。
- 云端清单中的相对路径拒绝绝对路径、`..`、空字节与反斜杠。
- Kopia 子进程使用 `posix_spawn` + 参数数组，不拼接 shell 命令。
- 仓库密码通过 `KOPIA_PASSWORD` 环境变量传递，不出现在进程参数或日志中。
- 活动日志不记录密码、恢复密钥或完整清单内容。

## 5. 代码签名与沙箱

| 配置 | Sandbox | iCloud | Hardened Runtime | 签名 |
| --- | --- | --- | --- | --- |
| Debug | 否 | 否 | 否 | ad-hoc |
| Beta | 否 | 否（脚本拒绝声明） | 否 | ad-hoc |
| Release | 是 | 是（`iCloud.com.codetime.app`） | 是 | Developer ID + provisioning |

Release 下内置 Kopia 以 `com.apple.security.inherit` 签名，从而继承父进程沙箱与
用户选择目录的安全扩展。Kopia 只读写仓库与项目目录，不需要网络。

Release entitlements 同时包含 App Group `U8U443D7ZL.com.codetime.app` 与
Keychain Access Group，用于 UI 与后台 Agent 共享数据库、书签和密钥。
`Scripts/validate_entitlements.sh` 在打包与发布时静态校验这些键；Beta 不得声明
iCloud 容器。Debug/Beta 的授权行为与 Release 不同，不能替代 Sandbox 验收。

## 6. 威胁模型

### 防护目标

- 云端静态数据：攻击者拿到 iCloud 文件也无法解密（无恢复密钥）。
- 传输：由 iCloud 自身加密；CodeTime 不额外上传明文。
- 本地其他用户：Keychain ACL + 用户目录权限。
- 恶意路径：路径遍历、符号链接逃逸、恶意文件名。
- 命令注入：所有 Kopia 调用使用参数数组与受控可执行文件路径。
- 损坏/截断的云端对象：SHA-256 校验 + 清单认证，失败则拒绝恢复。

### 非目标 / 已知限制

- **不防护已取得当前用户会话权限的攻击者**：该用户可以读取 Keychain、内存中的
  密码与解密后的快照。
- **恢复密钥丢失即无法恢复**：没有后门、没有服务端托管密钥。
- **iCloud 的“已上传”不是恢复保证**：仍需独立完整性校验与异机演练。
- **本地仓库文件完整存在**（内容由 Kopia 加密，但仓库文件占用磁盘）。
  不能宣称“零本地占用”。
- **时间点一致性**：普通目录扫描不等于 APFS 全文件系统原子快照；备份期间被修改
  的文件可能来自不同瞬间，CodeTime 通过 Kopia 错误计数标记不完整，但不提供严格
  快照语义。
- **符号链接**：默认不跟随备份；恢复时重建链接类型，不解析到项目外。

## 7. 凭据与恢复

- 首次启动生成恢复密钥并展示，要求用户离线保存。
- 换机恢复只依赖：iCloud 中的 `CodeTime/` + 恢复密钥。
- 恢复成功后把恢复密钥与仓库密码写入新 Mac 的 Keychain。
- 应用不会自动上传恢复密钥、密码或明文清单。
- CodeTime 对原始项目永久只读：备份/扫描只读，恢复只写入独立目标目录。
- 恢复目标等于、位于或包含任一原始项目时直接拒绝；“覆盖原文件”模式已禁用。
- 云端删除、GC 和恢复失败都不会反向修改原始项目。

## 8. 日志与诊断

- 日志写入 `Application Support/CodeTime/logs/codetime.log`，5 MB 轮转。
- 活动记录写入 SQLite，默认保留最近 5000 条。
- 云端清单只记录相对路径、哈希与大小；不记录文件内容。
- 诊断报告只包含路径、状态与版本，不包含密钥。
