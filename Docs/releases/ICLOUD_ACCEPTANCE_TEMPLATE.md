# iCloud 双 Mac 验收记录模板

将本文件复制为 `Docs/releases/<tag>-icloud-acceptance.md`，由实际执行人填写并提交到独立的 `release-acceptance` 分支（不要提交到发布 tag 对应的源 commit，否则会改变构建 commit 造成循环依赖）；没有真实执行记录时不得发布 Stable。

- 发布 tag：TAG_PLACEHOLDER
- 构建 commit：COMMIT_PLACEHOLDER
- Candidate Artifact：CodeTime-VERSION-macos-universal.zip
- Candidate Artifact SHA-256：64HEX_PLACEHOLDER
- Candidate Workflow Run：RUN_ID_PLACEHOLDER
- 构建类型：Developer ID Release / 其他（说明）
- iCloud 容器：`iCloud.com.codetime.app`
- 执行时间：TIME_PLACEHOLDER
- 执行人：OPERATOR_PLACEHOLDER

## 设备

- Mac A：MACA_MODEL_PLACEHOLDER / macOS MACA_OS_PLACEHOLDER / 构建 MACA_BUILD_PLACEHOLDER
- Mac B：MACB_MODEL_PLACEHOLDER / macOS MACB_OS_PLACEHOLDER / 构建 MACB_BUILD_PLACEHOLDER

## 场景与结果

| 场景 | 操作 | 结果 |
|---|---|---|
| v3 首次上传 | Mac A 添加项目并备份；确认 Dashboard 显示云端优先、spool 为 0 | RESULT_PLACEHOLDER |
| v3 第二台发现 | Mac B「从云端恢复」列出 Mac A 的 v3 项目 | RESULT_PLACEHOLDER |
| v3 按需恢复 | Mac B 只恢复一个文件，确认未下载完整项目/Kopia 仓库 | RESULT_PLACEHOLDER |
| v3 历史版本 | Mac B 浏览多个时间点并恢复指定版本 | RESULT_PLACEHOLDER |
| v3 离线/未上传 | Mac A 断网后备份；待上传数据保留；恢复网络后自动完成 | RESULT_PLACEHOLDER |
| v3 本地副本驱逐 | Mac A 上传确认后观察本地空间；失败时显示“等待释放”而非成功 | RESULT_PLACEHOLDER |
| v3 双设备并发 | 两台 Mac 同时修改并备份；双方历史均可读取，不互相覆盖 | RESULT_PLACEHOLDER |
| v3 校验 | 两台 Mac 对同一版本执行云端完整性校验 | RESULT_PLACEHOLDER |
| v2 兼容 | Mac B 读取并恢复一个旧 Kopia 版本 | RESULT_PLACEHOLDER |
| 迁移 | v2→v3 基线验证、显式释放旧仓库、旧历史仍可恢复 | RESULT_PLACEHOLDER |
| 密钥不匹配 | 使用错误恢复密钥时明确阻塞，不误用其他设备 | RESULT_PLACEHOLDER |

## 原始证据

- Mac A 门禁/日志：PATHA_PLACEHOLDER
- Mac B 门禁/日志：PATHB_PLACEHOLDER
- 云端目录截图/对象数量：EVIDENCE_PLACEHOLDER
- 本地空间前后（元数据/缓存/spool/iCloud 副本）：SPACE_PLACEHOLDER

## 结论

- 结果：RESULT_PLACEHOLDER
- 未通过项与原因：FAILURES_PLACEHOLDER
