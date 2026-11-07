# iCloud 同步协议

## 一致性模型

iCloud Drive（Ubiquity Container）是**最终一致**文件同步系统：

- **写入**：通过 NSFileCoordinator 协调，保证同设备原子性。
- **跨设备**：最终一致；无法提供原子 CAS 或全局快照。
- **读取**：文件可能处于未下载状态（`.icloud` 占位符）。
- **删除**：由 iCloud 同步引擎传播，无法保证即时跨设备可见。

## 锁

| 锁 | 位置 | 作用域 | 保证 |
|---|---|---|---|
| `lifecycle.lock` | 本机 lifecycle 目录 | 同一 Mac 多进程 | flock 共享/独占 |
| `repository.lock` | 本机仓库目录 | 同一 Mac 多进程 | flock 独占 |
| `publish.lock` | 本机仓库目录 | 同一 Mac 多进程 | flock 独占 |
| `migration.lock` | 本机 lifecycle 目录 | 同一 Mac 多进程 | flock 独占 |

**iCloud 中不存在跨 Mac 分布式锁。** 多设备协调依赖：

1. 独立设备 ID（不同 `devices/<deviceID>/` 目录）。
2. 不可变内容寻址对象（SHA-256）。
3. Manifest 最后发布（对象上传完成后才可见）。
4. 多设备模式下 GC 物理删除完全禁用。

## 操作原子性

| 操作 | 原子性 | 备注 |
|---|---|---|
| 对象上传 | 原子（临时文件 + rename） | 不覆盖已有对象 |
| Manifest 发布 | 原子（unique 文件名） | 最后写入 |
| Generation 列表读取 | 最终一致 | 不可读 Manifest 保留占位 |
| GC 删除 | 非原子 | 多设备模式禁用 |
| 跨设备恢复 | 原子（staging + rename） | 先下载、校验、后切换 |

## 失败分类

| readState | 含义 | UI 展示 |
|---|---|---|
| valid | 清单可读且完整 | 正常 |
| notDownloaded | iCloud 文件未下载 | "尚未下载" |
| unreadable | iCloud 暂时不可用 | "暂时不可用"（不等于损坏） |
| corrupted | 清单解密/解析失败 | "已损坏" |
| unsupportedVersion | 格式版本不兼容 | "格式不受支持" |
