# Sandbox、授权与数据迁移

## 1. 目录布局

| 用途 | 位置 |
|---|---|
| 应用数据 | `~/Library/Application Support/CodeTime`（受 App Group 约束时使用容器内路径） |
| SQLite | 应用数据目录下 `database/codetime.sqlite` |
| 本地 Kopia 仓库 | 应用数据目录下 `repositories/<repositoryID>` |
| 保护副本 | 应用数据目录下 `recovery/` |
| 日志 | 应用数据目录下 `logs/` |
| iCloud 镜像 | `iCloud.com.codetime.app` 容器内 `CodeTime/CloudMirror` |

`AppPaths` 统一计算路径；迁移、Agent 与 UI 使用同一套路径，不允许各自拼接。

## 2. Entitlements

### 2.1 Stable（Release）

`Apps/CodeTime/CodeTime.entitlements`：

- App Sandbox：开启
- 用户选择文件读写：`com.apple.security.files.user-selected.read-write`
- iCloud：`CloudDocuments` + `iCloud.com.codetime.app`
- App Group：`U8U443D7ZL.com.codetime.app`
- Keychain Access Group：`$(AppIdentifierPrefix)com.codetime.app`
- Hardened Runtime：开启（`project.yml` Release 配置）
- Kopia 嵌套二进制：Developer ID 签名，`Resources/Kopia/kopia.entitlements` 继承必要权限

### 2.2 Beta / Debug

- Beta 使用 ad-hoc 签名，不声明 iCloud 容器；`validate_entitlements.sh` 会拒绝 Beta 声明 iCloud。
- Debug 使用本地 entitlements，仅用于开发运行。
- 真实 iCloud 行为必须用 Stable/Release 签名构建验收，不能用 Beta/Debug 结果替代。

### 2.3 静态校验

`Scripts/validate_entitlements.sh` 检查：

- Release entitlements 中 Sandbox、iCloud、App Group、Keychain 键存在；
- Kopia entitlements 包含所需权限；
- `project.yml` 的 Release Hardened Runtime 与 entitlements 路径；
- Beta 不声明 iCloud；
- 给定 `.app` 时验证代码签名、Developer ID authority、runtime 标志、嵌入 entitlements、LaunchAgent 与 Kopia 签名。

## 3. Security-Scoped Bookmark

### 3.1 生成与解析

`SecurityScopedBookmarks`：

- `makeBookmark(for:)` 生成安全作用域 Bookmark；
- `resolve(_:)` 解析并开始访问；
- 解析失败时尝试 fallback；fallback 仍失败则抛出 `SecurityError.bookmarkFailed`，不返回“假路径”。

Bookmark 用于：

- 项目根目录；
- 本地镜像目录；
- Beta → Release 迁移源目录。

### 3.2 失效处理

- UI 明确提示“授权已失效”，要求重新选择目录；
- Agent 使用持久化 Bookmark 访问项目；
- 不把失效 Bookmark 当成不存在或空目录；
- 不删除原项目或仓库数据。

## 4. iCloud 容器与协调

- 容器标识固定为 `iCloud.com.codetime.app`。
- 读写/下载使用 `NSFileCoordinator`；协调失败显式抛出。
- 区分：
  - 文件未下载（触发下载）；
  - 下载中（等待）；
  - 非 iCloud 项（不能确认上传）；
  - 元数据不可读（失败关闭）。
- 云端发布在对象写入后等待上传确认，未确认不产生 Generation。

## 5. Beta → Release 迁移

### 5.1 背景

Beta 数据目录与 Release 沙盒容器不同；直接切换会表现为“数据消失”。迁移必须在 Release 首次启动、打开数据库之前完成。

### 5.2 流程

1. **选择源目录**：用户在 Onboarding 选择 Beta 数据目录。
2. **记录请求**：写入 `migration-request.json`，包含源路径与安全作用域 Bookmark。
3. **下次启动执行**：`DataMigrator.resumePendingMigration` 在数据库打开前运行。
4. **预检 `inspect`**：
   - 源目录必须存在且可读；
   - 必须包含数据库或备份仓库，否则报 `nothingToMigrate`；
   - 当前目标不能已有数据库或非空仓库，否则报 `targetNotEmpty`；
   - 源仓库不可读时报 `sourceUnreadable`，不当作空。
5. **复制到 staging**：目标同级的 `.codetime-migration-<id>`。
6. **逐文件校验**：大小 + SHA-256，任何不一致即失败。
7. **安装**：只移动 staging 的子项到目标，不覆盖已有文件；冲突即失败。
8. **写完成标记**：`migration-complete.json`，记录文件数、字节数、时间与源路径。
9. **保留源目录**：不删除 Beta 数据，允许回退。
10. **失败处理**：写 `failed` journal，保留错误信息，删除 staging 后抛出；下次可重试。

### 5.3 崩溃恢复

- journal 记录 `copying → verifying → installing`。
- `clearInterruptedStaging` 清理非安装阶段的残留 staging。
- `installing` 阶段不自动清理，避免删除可能已安装的数据。
- 目标已有数据库时不会覆盖；由用户确认后另行处理。

### 5.4 验证

- CT-029：构造 Beta 目录（数据库、仓库、文件），迁移后源目录保留、目标数据完整、文件哈希一致。
- CT-034：全新 Sandbox 启动路径初始化成功。
- CT-030：外部项目、仓库目录、父子路径的授权与拒绝规则。

## 6. 首次启动与 Agent

- 首次启动创建应用数据目录并初始化数据库（增量迁移到 schema v2）。
- LaunchAgent 使用同一 App Group 数据库与 Bookmark。
- 全局暂停、配置修订、项目 lifecycle 由数据库统一持久化，UI 与 Agent 读取同一状态。
- Agent 崩溃后任务租约过期可恢复，不会因 PID 复用误判。

## 7. 安全边界

- 不使用 `try?` 把不可读目录当作空目录。
- 不在仓库丢失时自动创建空仓库。
- 不把“无法确认 iCloud 状态”当作成功。
- 所有路径比较使用真实路径与路径组件，不使用字符串前缀。
