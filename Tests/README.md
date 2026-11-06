# Tests

自动化测试位于 Swift Package：

```bash
KOPIA_PATH="$PWD/Resources/Kopia/kopia" swift test --package-path Packages/CodeTimeKit
```

- `Packages/CodeTimeKit/Tests/CodeTimeKitTests/IntegrationTests.swift`：Kopia、云端格式、仓库重组、服务端到端与换机恢复。
- `.../SmokeTests.swift`：加密与恢复密钥。

设计中的真实 iCloud、故障注入、10k 文件与多设备测试尚未自动化，清单见
`Docs/TEST_PLAN.md`。
