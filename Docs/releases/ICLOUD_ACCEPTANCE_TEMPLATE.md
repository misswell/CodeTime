# iCloud 双 Mac 验收记录模板

将本文件复制为 `Docs/releases/<tag>-icloud-acceptance.md`，由实际执行人填写并提交；没有真实执行记录时不得发布 Stable。

- 发布 tag：TAG_PLACEHOLDER
- 构建 commit：COMMIT_PLACEHOLDER
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
| 首次上传 | Mac A 发布一个 Generation | RESULT_PLACEHOLDER |
| 第二台发现 | Mac B 列出并选择 Mac A 的版本 | RESULT_PLACEHOLDER |
| 未下载读取 | Mac B 在对象未下载时读取/恢复 | RESULT_PLACEHOLDER |
| 上传中断 | 断网/退出后重试，未确认上传不报告成功 | RESULT_PLACEHOLDER |
| 恢复 | Mac B 恢复并校验仓库与快照 | RESULT_PLACEHOLDER |
| 迁移 | Beta → Release 后项目、快照、仓库可用 | RESULT_PLACEHOLDER |
| 密钥不匹配 | 使用错误恢复密钥时明确阻塞，不误用其他设备 | RESULT_PLACEHOLDER |

## 结论

- 结果：RESULT_PLACEHOLDER
- 未通过项与原因：FAILURES_PLACEHOLDER
