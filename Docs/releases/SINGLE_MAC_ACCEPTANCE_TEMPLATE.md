# iCloud 单 Mac 验收记录模板

将本文件复制为 `Docs/releases/<tag>-single-mac-acceptance.md`，由实际执行人填写并提交到独立的 `release-acceptance` 分支。没有真实执行记录时不得发布 Stable。

本次范围内只验收 **单 Mac + iCloud Drive**；不要求第二台 Mac，也不把多设备能力作为发布阻塞条件。

- 发布 tag：TAG_PLACEHOLDER
- 构建 commit：COMMIT_PLACEHOLDER
- Candidate Artifact：CodeTime-VERSION-macos-universal.zip
- Candidate Artifact SHA-256：64HEX_PLACEHOLDER
- Candidate Workflow Run：RUN_ID_PLACEHOLDER
- 执行时间：TIME_PLACEHOLDER
- 执行人：OPERATOR_PLACEHOLDER
- Mac：HOST_PLACEHOLDER / 设备 DEVICE_PLACEHOLDER / App VERSION_PLACEHOLDER

## 范围声明

本次发布只验收单 Mac + iCloud Drive；多设备能力不在本次发布范围内。

## 场景与结果

每个场景必须有独立 JSON 证据，由 `Scripts/single_mac_acceptance.sh record` 生成：

```bash
Scripts/single_mac_acceptance.sh record \
  --scenario backup_created \
  --result passed \
  --device-id "<device-id>" \
  --candidate-sha "<zip sha256>" \
  --commit "<git sha>" \
  --assertions '{"commit_published":true}' \
  --out Docs/releases/<tag>-single-mac-evidence/backup_created.json
```

必须覆盖：

| 场景 | 关键断言 |
|---|---|
| backup_created | commit_published=true |
| upload_confirmed | upload_confirmed=true, pending_tasks=0 |
| app_restart | snapshot_readable_after_restart=true |
| cache_cleared | cache_bytes=0 |
| redownload_from_icloud | redownloaded=true |
| restore_to_new_directory | restored_files=expected_files |
| sha256_all_files | sha256_all=true, checked_files=expected_files |
| metadata_and_symlinks | modes/mtimes/symlinks=true |
| upload_interruption | snapshot_not_published/spool_preserved/retry_completed=true |
| upload_crash_recovery | journal_recovered/no_duplicate_upload=true |
| restore_interruption | partial_rejected/resume_completed=true |
| gc_safe_single_device | active_restore_blocks_delete/referenced_objects_protected/pack_protected/incomplete_reference_aborts/resume_idempotent=true |
| space_management | spool_within_budget/cache_within_budget/locks_bounded=true |

生成报告：

```bash
Scripts/single_mac_acceptance.sh report \
  --evidence-dir "Docs/releases/<tag>-single-mac-evidence" \
  --tag "<tag>" --commit "<git sha>" \
  --candidate-sha "<zip sha256>" --candidate-name "<zip name>" \
  --run "<workflow-run-id>" --operator "<name>" \
  --out "Docs/releases/<tag>-single-mac-acceptance.md"
```

报告生成器和 `Scripts/require_single_mac_acceptance.sh` 会拒绝缺失场景、候选哈希不符、恢复文件未全量校验、占位符和手写 PASS。

## 原始证据

- 场景证据目录：EVIDENCE_DIR_PLACEHOLDER
- 门禁/日志：LOG_PLACEHOLDER
- 云端对象数量与本地空间前后：SPACE_PLACEHOLDER

## 结论

- 结果：由 `single_mac_acceptance.sh report` 生成，不得手填
- 未通过项与原因：无
