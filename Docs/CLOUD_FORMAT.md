# CodeTime Cloud Format v1

CodeTime 不把活动 Kopia 仓库直接放进 iCloud。云端保存的是 **我们自己定义的格式**：
不可变内容对象 + 加密版本清单。

## 1. 目录布局

```
iCloud Drive/CodeTime/
├── format.json
└── devices/
    └── <device-id>/
        └── repositories/
            └── <repository-id>/
                ├── objects/
                │   ├── a1/
                │   │   └── <sha256>
                │   └── b3/
                │       └── <sha256>
                ├── commits/
                │   └── <generation-id>.ctm
                └── recovery-info.json
```

- `device-id`、`repository-id`、`generation-id` 均为随机 UUID，不使用主机名/用户名。
- 每台 Mac 一个设备目录；同一设备内多个项目共用一个仓库。
- 不允许多台 Mac 同时写同一个活动仓库。

`format.json`：

```json
{
  "format": "codetime-cloud-format",
  "version": 1,
  "createdAt": "2026-11-07T00:00:00Z"
}
```

## 2. 不可变对象

- 文件路径：`objects/<sha256 前两位>/<完整 sha256>`。
- 内容：原样复制 Kopia 仓库文件（不重新压缩/加密）。
- 命名即校验和。写入采用“临时文件 + 原子移动”，目标已存在时**绝不覆盖**。
- 相同内容在多个仓库文件之间共享（内容寻址），因此天然去重。

上传完成由存储层确认：

- iCloud：轮询 `ubiquitousItemIsUploadedKey`。
- 本地镜像：立即返回。

## 3. 版本清单（commit）

### 3.1 二进制封装

```
偏移   内容
0      "CTM1"（4 字节 magic）
4      16 字节随机 salt
20     AES-256-GCM combined（12 字节 nonce + 密文 + 16 字节 tag）
```

- 密钥：`HKDF-SHA256(masterKey, salt, info="codetime.cloud.manifest.v1")`。
- AAD：`manifest:<repository-id>:<generation-id>`，把清单绑定到具体仓库与版本，
  防止跨版本重放。
- `masterKey` 即恢复密钥（32 字节）。

### 3.2 明文 JSON 结构

```json
{
  "formatVersion": 1,
  "repositoryId": "UUID",
  "generationId": "UUID",
  "deviceId": "UUID",
  "createdAt": "2026-11-07T00:00:00Z",
  "sourceSnapshotIds": ["<kopia-snapshot-id>"],
  "repositoryFiles": [
    {
      "relativePath": "packs/abc",
      "contentHash": "<sha256>",
      "size": 12345
    }
  ],
  "integrity": {
    "fileCount": 42,
    "totalBytes": 12345678,
    "repositoryHash": "<sha256 of sorted repositoryFiles JSON>"
  }
}
```

`repositoryFiles` 是 Kopia 仓库文件与云端对象之间的映射。恢复时按
`relativePath` 重组仓库，并逐个校验 `contentHash`。

## 4. 恢复凭据

`recovery-info.json` 是每个仓库唯一的**可变**元数据（其余对象/清单不可变）：

```json
{
  "formatVersion": 1,
  "repositoryId": "UUID",
  "deviceId": "UUID",
  "createdAt": "2026-11-07T00:00:00Z",
  "payload": "<base64 of CTM1 sealed data>"
}
```

`payload` 使用 `recovery:<repository-id>` 作为 AAD，内含：

```json
{
  "repositoryId": "UUID",
  "repositoryPassword": "<Kopia repository password>",
  "formatVersion": 1,
  "createdAt": "2026-11-07T00:00:00Z"
}
```

因此在全新 Mac 上，用户只需要：

1. iCloud 中的 `CodeTime/` 目录。
2. 离线保存的恢复密钥。

即可解密恢复凭据、重建 Kopia 仓库。

## 5. 发布不变式

| 规则 | 说明 |
| --- | --- |
| A. 对象不可覆盖 | 内容变化产生新的 SHA-256 对象，旧对象保留 |
| B. 清单最后发布 | 所有被引用对象上传成功后才写 `.ctm`，并等待上传确认 |
| C. 清单回读校验 | 清单写入后必须重新下载、解密并比对 Generation ID 与对象集合 |
| D. 中断保持旧版本 | 未完成的版本不写清单，旧清单继续有效；失败清单必须移除，移除失败显式报错 |
| E. 本地与云端状态分离 | 本地快照成功不代表云端已同步 |
| F. 清理先检查引用 | 完整枚举 + 墓碑保护 + 重新验证 + 独立宽限期，任一清单不可读即中止 |
| G. 上报失败关闭 | 上传未确认、元数据不可读、文件不在容器时不得报告发布成功 |

## 6. 版本状态机

```
staging → uploading → published → verified
                    ↘ failed（不产生可见清单）
```

`cloud_generations` 表持久化每个阶段，进程重启后可以识别未完成任务。

## 7. 清理算法

`CloudMirrorStore.cleanup(repositoryId:gracePeriod:minimumGenerations:)`

1. 读取全部可解密清单；任何一个不可读 → 暂停清理（返回 `skippedReason`）。
2. 保留：
   - 最新 `minimumGenerations` 代（默认至少 2 代）；
   - 以及所有年龄小于保留宽限期的代。
3. 汇总保留清单与墓碑清单引用到的全部对象哈希；墓碑不可读 → 暂停清理。
4. 如果任一被引用对象缺失 → 暂停清理。
5. 旧清单移入墓碑目录，等待独立的 `sweepGrace`（同步宽限期），
   不因用户把保留天数设为 0 而缩短。
6. 宽限期结束后从当前清单重新验证对象集合；验证失败恢复墓碑并中止。
7. 删除未被任何当前/墓碑清单引用、且修改时间早于同步宽限期的对象。
8. 每个阶段和每次对象删除都写入 GC 日志；日志读写失败即中止。
9. 返回删除数量、释放字节数与保留代数。

清理不会触碰其他设备目录；每台设备的仓库独立治理。

## 8. 灾难恢复流程

1. 在全新 Mac 上安装 CodeTime。
2. 设置 → 云端 → 从云端恢复。
3. 选择 iCloud Drive 中的 `CodeTime` 目录，输入恢复密钥。
4. CodeTime：
   - 扫描 `devices/*/repositories/*/recovery-info.json`；
   - 解密得到 Kopia 仓库密码；
   - 读取最新一代 `.ctm`；
   - 按清单下载对象、校验 SHA-256、重组仓库到本地；
   - 写入 Keychain（恢复密钥 + 仓库密码）；
   - 用 Kopia 连接重组后的仓库，发现历史项目路径。
5. 用户把发现的项目路径重新添加到 CodeTime，即可恢复任意快照。

恢复记录会标记为 `crossDeviceRestore`，与本地抽样校验区分。

## 9. 版本升级

- `format.json.version` 控制整体格式；不兼容变更必须拒绝读取并给出明确错误。
- 清单自身带 `formatVersion`，加字段必须保持向后兼容（解码忽略未知字段）。
- 迁移不得原地重写已发布清单；应发布新格式版本并保留旧版本可恢复路径。
