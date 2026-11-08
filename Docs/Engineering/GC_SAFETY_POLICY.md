# GC 安全策略

## 多设备模式

当 `storageRoot/devices/` 目录下存在多于一个设备目录时，CodeTime 进入多设备模式。

**多设备模式下自动物理删除被完全禁用。**

`cleanup()` 在枚举设备目录后如果发现非当前设备 ID 的目录存在，立即返回
`CloudCleanupReport(skippedReason: "检测到 N 台其他设备…")`。

这是有意的保守策略：iCloud 是最终一致文件同步系统，不具备跨设备原子锁或
全局一致性快照。在不能证明另一台 Mac 的对象引用关系安全之前，任何物理删除
都存在误删风险。

## 单设备模式

只有一个设备目录时，GC 可以安全执行。

流程：

1. **publish lock 获取**：防止与并发发布冲突。
2. **全量 Manifest 枚举**：任何不可读 Manifest 即中止（返回 skippedReason）。
3. **保留集合计算**：最新 `minimumGenerations` 代 + 宽限期内代。
4. **保留版本引用完整性检查**：任何被引用对象缺失即中止。
5. **不可变对象查找**：`objects/<prefix>/<sha256>` 中不在引用集合中的对象。
6. **宽限期检查**：仅删除 `contentModificationDate <= cutoff` 的对象。
7. **删除**：删除不可引用且超过宽限期的对象。
8. **过期 Manifest 清理**：不在保留集合中的旧 `.ctm` 删除。

## 确定性排序

Manifest 按以下规则排序（保证与发布顺序一致）：

1. `createdAt`（降序）
2. `.ctm` 文件修改时间（降序，tie-breaker）
3. UUID 字符串（降序，最终 tie-breaker）

## 不变量

- 引用对象永不删除。
- Manifest 不可覆盖。
- 清理可中断并可恢复（通过 GCJournal 持久化阶段）。
- aborted 状态不删除任何对象（墓碑保护）。


## 第六轮：iCloud 默认只预览（CT-105）

- `CloudMirrorStore.cleanup(allowPhysicalDelete:)` 对 **coordinated（iCloud）** 存储默认 `false`：此时只计算
  `plannedDeletes` / `plannedGenerationDeletes`，不写 tombstone、不删除任何对象，返回 `skippedReason` 说明原因。
- 本地镜像（非 coordinated）保持原有行为。
- 物理删除只由用户显式确认触发（设置 → 云端 → 立即清理 → 确认删除）。
- 设备守卫使用协调访问（`CloudFileAccess.list`），不再绕过 NSFileCoordinator。

## 设备退役（CT-105）

- 只有显式 `retireDevice(_:reason:)` 写入 `devices/<id>/retired.json` 后，GC 才会忽略该设备。
- 设备离线、长时间未上线、目录暂时缺失都**不会**被自动视为退役。
- 已退役设备的目录与对象仍不会被任何 GC 流程删除（仅解除"多设备"阻断）。
