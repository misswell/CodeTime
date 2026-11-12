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


## 证据生成方式（必须使用）

每个场景必须由实际执行人/实际 App 生成独立 JSON，不得手写 PASS：

```bash
Scripts/icloud_acceptance.sh record \
  --scenario first_backup \
  --result passed \
  --device-id "<Mac-A-device-id>" \
  --host "<Mac-A-hostname>" \
  --candidate-sha "<zip sha256>" \
  --commit "<git sha>" \
  --assertions '{"upload_confirmed":true,"spool_empty":true}' \
  --out Docs/releases/<tag>-icloud-evidence/first_backup.json
```

必须覆盖的场景（缺一不可）：

`first_backup`、`cross_device_discovery`、`metadata_only_read`、`repeat_backup`、
`interrupted_upload`、`upload_recovery`、`full_restore`、`wrong_key`、
`gc_barrier`、`gc_resume`、`migration`。

最后用证据目录生成报告：

```bash
Scripts/icloud_acceptance.sh report \
  --a <Mac-A-prepare.json> --b <Mac-B-verify.json> \
  --evidence-dir Docs/releases/<tag>-icloud-evidence \
  --tag <tag> --commit <git sha> \
  --candidate-sha <zip sha256> --candidate-name <zip name> \
  --run <workflow-run-id> --operator "<name>" \
  --out Docs/releases/<tag>-icloud-acceptance.md
```

报告生成器会拒绝缺失场景、同 Host、候选哈希不一致、恢复文件未全量校验和老式硬编码 PASS。

## 场景与结果

| 场景 | 操作 | 结果 |
|---|---|---|
| first_backup | Mac A 添加项目并备份；确认 Dashboard 显示云端优先、spool 为 0 | EVIDENCE_JSON_REQUIRED |
| cross_device_discovery | Mac B「从云端恢复」列出 Mac A 的 v3 项目 | EVIDENCE_JSON_REQUIRED |
| metadata_only_read / full_restore | Mac B 浏览元数据不下载正文，再全量恢复并校验每个文件 | EVIDENCE_JSON_REQUIRED |
| repeat_backup / migration | 重复备份不重复下载；Beta→Release 后旧数据可读 | EVIDENCE_JSON_REQUIRED |
| interrupted_upload / upload_recovery | 断网不发布快照；spool 保留；恢复网络后续传 | EVIDENCE_JSON_REQUIRED |
| eviction | Mac A 上传确认后观察本地空间；失败时显示“等待释放”而非成功 | EVIDENCE_JSON_REQUIRED |
| cross_device_discovery | 两台 Mac 同时修改并备份；双方历史均可读取 | EVIDENCE_JSON_REQUIRED |
| full_restore | 两台 Mac 对同一版本执行云端完整性校验与 SHA-256 恢复校验 | EVIDENCE_JSON_REQUIRED |
| migration | Mac B 读取并恢复一个旧 Kopia 版本 | EVIDENCE_JSON_REQUIRED |
| migration | v2→v3 基线验证、显式释放旧仓库、旧历史仍可恢复 | EVIDENCE_JSON_REQUIRED |
| wrong_key | 使用错误恢复密钥时明确阻塞 | EVIDENCE_JSON_REQUIRED |

## 原始证据

- Mac A 门禁/日志：PATHA_PLACEHOLDER
- Mac B 门禁/日志：PATHB_PLACEHOLDER
- 云端目录截图/对象数量：EVIDENCE_PLACEHOLDER
- 本地空间前后（元数据/缓存/spool/iCloud 副本）：SPACE_PLACEHOLDER

## 结论

- 结果：由 `icloud_acceptance.sh report` 生成，不得手填
- 未通过项与原因：FAILURES_PLACEHOLDER
