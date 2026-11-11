# CodeTime Cloud Format v3

Cloud Format v3 是 CodeTime 2.0 的云端优先格式：完整历史只存在于 iCloud，本地只保留可重建索引、有界下载缓存和受保护的待上传数据。v2（Kopia 镜像）不被修改，两种格式可以并存。

实现位置：

| 组件 | 文件 |
|---|---|
| 内容定义分块 | `Packages/CodeTimeKit/Sources/BackupEngine/FastCDCChunker.swift` |
| 内容寻址（HMAC） | `Packages/CodeTimeKit/Sources/BackupEngine/ContentAddressing.swift` |
| 压缩与 AEAD 封装 | `Packages/CodeTimeKit/Sources/BackupEngine/ObjectEncoder.swift` |
| 不可变文件树 | `Packages/CodeTimeKit/Sources/BackupEngine/MerkleTreeBuilder.swift` |
| 快照模型 | `Packages/CodeTimeKit/Sources/SharedModels/CloudFormatV3.swift` |
| 云端对象存储 | `Packages/CodeTimeKit/Sources/CloudMirrorStore/CloudObjectStoreV3.swift` |
| 跨设备读取 | `Packages/CodeTimeKit/Sources/CloudMirrorStore/CloudMultiDeviceStoreV3.swift` |
| 对象包 | `Packages/CodeTimeKit/Sources/BackupEngine/ObjectPack.swift` |
| 持久上传队列 | `Packages/CodeTimeKit/Sources/BackupEngine/UploadQueue.swift` |
| 按需恢复 | `Packages/CodeTimeKit/Sources/BackupEngine/CloudRestoreEngine.swift` |
| 云端 GC | `Packages/CodeTimeKit/Sources/BackupEngine/CloudGarbageCollector.swift` |

## 1. 目录布局

```text
iCloud Drive/CodeTime/v3/
├── format.json
└── devices/<device-id>/
    ├── objects/<ab>/<objectID>
    ├── packs/<packID>
    ├── nodes/<nodeID>
    ├── projects/<project-id>/
    │   ├── manifests/<snapshotID>.enc
    │   └── snapshots/<snapshotID>.commit
    ├── tombstones/<tombstone>.json
    └── recovery-info.enc
```

- 每台 Mac 写入自己的 `devices/<device-id>/` 命名空间，不覆盖其他设备。
- 项目目录、对象文件名均为稳定 ID；不包含项目路径、用户名或明文哈希。
- `nodes`、`manifests` 使用 AEAD 加密；`objects` 是已加密的数据块；`format.json` 与 commit marker 只含不敏感元数据。

## 2. 数据块

- FastCDC：最小 256 KB，平均 1 MB，最大 4 MB；小于最小块的文件作为单块。
- 流式读取：同一时刻只持有当前数据块，不把文件或项目读入内存。
- 文件在读取期间发生变化时丢弃本次结果并重试，多次失败则该文件使快照失败。
- 对象 ID：

```text
ObjectID = HMAC-SHA256(dedupKey, SHA256(plaintextChunk))
```

- 相同内容在同一仓库内得到相同 ObjectID；不同仓库密钥不同，云端文件名无法做跨用户关联。
- 对象不可变；已存在对象不再重写。

## 3. 对象封装（CTO3）

```text
magic "CTO3" | format u8 | keyVersion u16 | compression u8
| originalSize u32 | nonce[12] | AES-GCM ciphertext+tag
```

- LZFSE 仅在确实变小时保留，压缩算法与原始大小写入头部。
- AEAD 的 AAD 包含头部与 ObjectID，防止对象被替换/错位。
- 解密后校验明文长度与 SHA-256；失败即对象损坏。

## 4. 对象包（CTP3）

大量小文件会为每个块创建一个 iCloud 文件，同步开销高。`ObjectPackWriter` 把多个已加密对象放入不可变包：

```text
"CTP3" | version u8 | reserved u8 | count u32
entries[count]: objectID[32] | offset u64 | length u32
blobs...
```

- 包 ID = 包内容 SHA-256。
- 已上传的包不再追加；只被部分版本引用的包整包保留。
- 引用记录 `packID` + `packOffset`；恢复时只下载需要的包并精确切片。
- 默认目标 8 MB，硬上限 16 MB；超过单包上限的对象单独存放。

## 5. 文件树与快照

- `FileNode` 包含路径、类型、大小、mtime、POSIX 权限、符号链接目标、整文件 SHA-256 与块引用。
- `DirectoryNode` 只包含本层文件与子目录指针；节点 ID = 规范化 JSON 的 SHA-256。未变化的子树保留原节点 ID，不重复上传。
- `SnapshotManifest`：快照/项目/设备 ID、时间、父版本、根节点、文件数、总大小、块数、格式/密钥版本、完整性摘要。Manifest 使用 AEAD 加密，context 为 `v3:manifest:<projectID>:<snapshotID>`。
- `SnapshotCommit` 是版本可见的唯一入口：只有它上传确认后版本才算完成。

发布顺序固定为：

```text
objects/packs → nodes → manifest → commit marker
```

`putCommit` 会拒绝 Manifest 缺失或哈希不一致的提交。

## 6. 本地索引

SQLite schema v3 新增（可重建，不是唯一副本）：

- `v3_file_index`：项目文件清单与块引用。
- `v3_chunk_index`：对象位置（独立对象或 pack 偏移）、大小、密钥版本、验证时间。
- `v3_snapshot_index`：版本、提交状态、manifest 哈希。
- `v3_pending_uploads`：未确认上传任务。
- `v3_cache_index`：下载缓存 LRU 与 pin 状态。
- `v3_migration_journal`：v2→v3 迁移阶段。

## 7. 待上传数据（spool）

- 加密对象先写入 `spool/pending/`，再进入上传队列；只有云端确认后才删除。
- 网络中断/应用退出/系统重启后，`v3_pending_uploads` 恢复任务；`.uploading` 回到待上传。
- 软上限默认 2 GB。达到上限时拒绝生成新块并暂停备份，**不会删除已有待上传数据**。
- spool 与下载缓存是不同目录；缓存 LRU 永远不触及 spool。

## 8. 恢复

1. 读取 commit，校验 manifest 哈希并解密。
2. 解析目标文件/目录的节点。
3. 只下载所需对象或包；本地缓存命中则复用。
4. 解密并校验明文大小与整文件 SHA-256。
5. 写入 staging，全部成功后原子移动；失败不触碰目标。
6. 路径经过穿越与符号链接父目录校验。

新 Mac 通过 `v3/devices/*/projects/*/snapshots/*.commit` 发现项目；校验最新 manifest 可解密后即可选择恢复。恢复某个版本不需要下载其他版本或 Kopia 仓库。

## 9. 云端 GC

两阶段、默认宽限期 30 天：

1. **Tombstone**：从所有保留版本的 commit 出发，递归收集节点、对象、包引用；不可达对象/节点/包与超期版本写墓碑。此阶段不删除。
2. **Sweep**：重新计算引用；要求无未上传数据、无进行中的快照发布、枚举与墓碑全部可读。只删除宽限期已过且仍不可达的对象；包内任一对象仍被引用则整包保留。任何不确定都中止。

保留策略沿用用户 `RetentionPolicy`，并额外保证最新两个版本永不删除。

## 10. 兼容与迁移

- 新引擎不读取、不写入本地 Kopia 仓库。
- v2 数据保持原样；旧版本继续通过 Kopia 引擎读取。
- 迁移阶段：检测旧本地仓库 → 发布/校验 v2 云端 → 创建并校验 v3 基线 → 用户明确同意后才释放旧本地仓库。
- 释放后恢复旧版本时，把包含该版本的 v2 generation 下载到临时仓库，恢复完成后清理临时目录。
