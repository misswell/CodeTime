# 回归测试矩阵（CT-001 … CT-098）

由 `REGRESSION_INDEX.json` 驱动；`Scripts/regression_gate.sh` 在每次 CI、Beta、Stable Candidate/Publish 强制执行。

| 编号 | 测试 | 文件 | 目的 | 必需 | 允许环境跳过 |
|---|---|---|---|---|---|
| CT-001 | `testCT001_UnreadableManifestAbortsCleanup` | CloudMirrorRegressionTests.swift | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-002 | `testCT002_InterruptedGarbageCollectionResumes` | CloudMirrorRegressionTests.swift | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-003 | `testCT003_ManifestDeletionWaitsForGrace` | CloudMirrorRegressionTests.swift | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-004 | `testCT004_SameSizeDifferentContentFailsVerification` | CloudMirrorRegressionTests.swift | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-005 | `testCT005_UnconfirmedUploadProducesNoGeneration` | CloudMirrorRegressionTests.swift | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-006 | `testCT006_MetadataFailureIsNotTreatedAsUploaded` | CloudMirrorRegressionTests.swift | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-007 | `testCT007_UnreadableCloudFileFailsClosed` | CloudMirrorRegressionTests.swift | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-008 | `testCT008_ConcurrentPublisherOfSameObjectKeepsOneVerifiedCopy` | CloudMirrorRegressionTests.swift | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-009 | `testCT009_FailedManifestPublishLeavesOldGenerationIntact` | CloudMirrorRegressionTests.swift | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-010 | `testCT010_InvalidHashCacheIsRecomputed` | CloudMirrorRegressionTests.swift | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-011 | `testCT011_TwoDevicesPublishIndependentGenerations` | CloudMirrorRegressionTests.swift | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-012 | `testCT012_NewGenerationDuringCleanupIsPreserved` | CloudMirrorRegressionTests.swift | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-013 | `testCT013_InterruptedRestoreResumesVerifiedObjects` | RecoveryRegressionTests.swift | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-014 | `testCT014_RestoreCopyFailureLeavesRepositoryUntouched` | RecoveryRegressionTests.swift | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-015 | `testCT015_RestoreFailsOnObjectHashMismatch` | RecoveryRegressionTests.swift | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-016 | `testCT016_MultiDeviceCandidatesReportKeyMismatch` | RecoveryRegressionTests.swift | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-017 | `testCT017_MismatchedFirstCandidateDoesNotAbortRecovery` | RecoveryRegressionTests.swift | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-018 | `testCT018_RestoreReportRequiresRepositoryAndSnapshotChecks` | RecoveryRegressionTests.swift | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-019 | `testCT019_CloudRestoreJobSurvivesRestart` | RecoveryRegressionTests.swift | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-020 | `testCT020_DuplicateRestoreIsSafe` | RecoveryRegressionTests.swift | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-021 | `testCT021_DeletedProjectIsNotResurrectedByRuntimeUpdate` | ConcurrencyPersistenceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-022 | `testCT022_PauseIsNotOverwrittenByRuntimeUpdate` | ConcurrencyPersistenceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-023 | `testCT023_LeaseBlocksSecondExecutor` | ConcurrencyPersistenceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-024 | `testCT024_SettingsPropagationUsesRevision` | ConcurrencyPersistenceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-025 | `testCT025_PauseClosesSchedulingGate` | ConcurrencyPersistenceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-026 | `testCT026_TwoAgentsElectSingleLeader` | ConcurrencyPersistenceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-027 | `testCT027_CrashLeavesInterruptedJobsRetryable` | ConcurrencyPersistenceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-028 | `testCT028_PIDReuseIsNotTreatedAsAliveOwner` | ConcurrencyPersistenceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-029 | `testCT029_BetaToReleaseMigrationIsLosslessAndNonDestructive` | SandboxPerformanceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-030 | `testCT030_ExternalProjectAllowedButRecursiveRootsRejected` | SandboxPerformanceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-031 | `testCT031_ExternalMirrorBookmarkSurvivesEncoding` | SandboxPerformanceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-032 | `testCT032_StaleBookmarkFailsExplicitly` | SandboxPerformanceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-033 | `testCT033_ProjectBookmarkIsSharedWithAgentConnection` | SandboxPerformanceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-034 | `testCT034_FreshSandboxBootstrap` | SandboxPerformanceRegressionTests.swift | 第一/二轮可靠性回归 | 是 | 否 |
| CT-035 | `testCT035_MissingRepositoryIsNotAutoCreated` | SandboxPerformanceRegressionTests.swift | 第二轮可靠性回归 | 是 | 否 |
| CT-036 | `testCT036_HundredThousandFilesPreview` | SandboxPerformanceRegressionTests.swift | 环境相关回归（允许真机跳过） | 是 | 是（需要 kopia 二进制或 CodeTimeCrashChild 子进程，缺失时允许 XCTSkip） |
| CT-037 | `testCT037_MillionFilesBoundedByLimit` | SandboxPerformanceRegressionTests.swift | 环境相关回归（允许真机跳过） | 是 | 是（需要 kopia 二进制或 CodeTimeCrashChild 子进程，缺失时允许 XCTSkip） |
| CT-038 | `testCT038_LargeFileHashStreamsInChunks` | SandboxPerformanceRegressionTests.swift | 第二轮可靠性回归 | 是 | 否 |
| CT-039 | `testCT039_SearchTruncationIsExplicit` | SandboxPerformanceRegressionTests.swift | 第二轮可靠性回归 | 是 | 否 |
| CT-040 | `testCT040_LargeFilePreviewDegradesExplicitly` | SandboxPerformanceRegressionTests.swift | 第二轮可靠性回归 | 是 | 否 |
| CT-041 | `testCT041_RetryBackoffAndClassification` | ConcurrencyPersistenceRegressionTests.swift | 第二轮可靠性回归 | 是 | 否 |
| CT-042 | `testCT042_LogRotationIsBounded` | SandboxPerformanceRegressionTests.swift | 第二轮可靠性回归 | 是 | 否 |
| CT-043 | `testCT043_CacheAndActivityTablesArePruned` | SandboxPerformanceRegressionTests.swift | 第二轮可靠性回归 | 是 | 否 |
| CT-044 | `testCT044_DiskFullLeavesRepositoryUntouched` | SandboxPerformanceRegressionTests.swift | 环境相关回归（允许真机跳过） | 是 | 是（需要 kopia 二进制或 CodeTimeCrashChild 子进程，缺失时允许 XCTSkip） |
| CT-045 | `testCT045_InitializedReleaseCanRequestMigration` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-046 | `testCT046_EmptyTargetDirectoriesDoNotBlockMigration` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-047 | `testCT047_HiddenRepositoryFilesAreMigrated` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-048 | `testCT048_InterruptedMigrationLeavesTargetRetryable` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-049 | `testCT049_PartialRestoreFileIsReplaced` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-050 | `testCT050_CommittingRestoreIsResumable` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-051 | `testCT051_SelectedDeviceIsBoundToRecovery` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-052 | `testCT052_MissingObjectMakesCandidateNonRestorable` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-053 | `testCT053_FailedVerificationDoesNotRemainVerified` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-054 | `testCT054_AbortedTombstoneDoesNotDeleteObjects` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-055 | `testCT055_TwoConnectionsCompeteForOneLease` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-056 | `testCT056_LocalRepositoryIsRediscoveredWithoutDatabase` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-057 | `testCT057_ICloudMirrorPathIsRejected` | SecondRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-058 | `testCT058_AcceptanceGateAcceptsCompletePassReport` | ThirdRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-059 | `testCT059_SelectPrefersRegisteredRepositoryAmongDiscovered` | ThirdRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-060 | `testCT060_MigrationBlocksWhileBetaAgentLockIsHeld` | ThirdRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-061 | `testCT061_PendingMigrationRequestLifecycle` | ThirdRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-062 | `testCT062_KeychainRepairFromCloudRestoresAccess` | ThirdRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-063 | `testCT063_LeaseClaimAndOwnerChecksAreAtomic` | ThirdRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-064 | `testCT064_VerifyCloudClearsStaleVerifiedOnUnreadableNewest` | ThirdRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-065 | `testCT065_ProjectStatusFollowsNewestSnapshot` | ThirdRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-066 | `testCT066_GCPublishDoNotHoldRepositoryLock` | ThirdRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-067 | `testCT067_InterruptedMigrationStagingIsReclaimed` | ThirdRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-068 | `testCT068_ManualDispatchPublishesRelease` | ThirdRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-069 | `testCT069_GateRejectsMissingTestsAndUnexpectedSkips` | ThirdRoundRegressionTests.swift | 第三轮可靠性回归 | 是 | 否 |
| CT-070 | `testCT070_ManifestAggregateFieldTamperingIsDetected` | FourthRoundRegressionTests.swift | Manifest 完整性：篡改字段必须被真实校验函数拒绝 | 是 | 否 |
| CT-071 | `testCT071_GCSkippedWhenOtherDevicesExist` | FourthRoundRegressionTests.swift | GC：多设备/中断/不可读清单不得误删 | 是 | 否 |
| CT-072 | `testCT072_LifecycleLocksAreOutsideReplaceableRoot` | FourthRoundRegressionTests.swift | LifecycleLock 跨进程共享/独占语义 | 是 | 否 |
| CT-073 | `testCT073_OldUploadCompletionDoesNotOverrideNewSnapshotStatus` | FourthRoundRegressionTests.swift | 项目状态按最新快照推导 | 是 | 否 |
| CT-074 | `testCT074_RestoreJobWrongRepositoryIDThrows` | FourthRoundRegressionTests.swift | 恢复身份四重绑定校验 | 是 | 否 |
| CT-075 | `testCT075_SimulatedCrashDuringMigrationIsRecoverable` | FourthRoundRegressionTests.swift | 迁移崩溃恢复（journal/staging） | 是 | 否 |
| CT-076 | `testCT076_WorkflowUsesTargetCommitForRelease` | FourthRoundRegressionTests.swift | 发布 Tag/Commit 一致性 | 是 | 否 |
| CT-077 | `testCT077_CandidateArtifactSHA256Verification` | FifthRoundRegressionTests.swift | Candidate Artifact SHA-256 强制校验 | 是 | 否 |
| CT-078 | `testCT078_AcceptanceGateRejectsSubstringTag` | FourthRoundRegressionTests.swift | 验收报告精确匹配 | 是 | 否 |
| CT-079 | `testCT079_ManualReleaseTagMustExistAndPointAtBuildCommit` | FifthRoundRegressionTests.swift | 手动发布 Tag 必须存在且指向构建 commit | 是 | 否 |
| CT-080 | `testCT080_ClaimBackupJobRejectsNonBackupType` | FourthRoundRegressionTests.swift | 任务租约类型约束 | 是 | 否 |
| CT-081 | `testCT081_UnreadableStatesClassifiedByProductionListing` | FifthRoundRegressionTests.swift | 云端状态分类（生产 listGenerationEntries） | 是 | 否 |
| CT-082 | `testCT082_CandidatePackagingDoesNotRequireAcceptanceReport` | FifthRoundRegressionTests.swift | Candidate 构建不依赖验收报告 | 是 | 否 |
| CT-083 | `testCT083_AcceptanceReportMustBindImmutableArtifact` | FifthRoundRegressionTests.swift | 验收报告绑定不可变 Artifact | 是 | 否 |
| CT-084 | `testCT084_SharedLocksCoexistExclusiveBlocksAndDeathReleases` | FifthRoundRegressionTests.swift | UI 生命周期完整持有 shared lock（跨进程语义） | 是 | 否 |
| CT-085 | `testCT085_MigrationWaitsForAgentExitAndRefusesStuckAgent` | FifthRoundRegressionTests.swift | Agent 收到迁移请求能够安全停止 | 是 | 否 |
| CT-086 | `testCT086_SafePathRejectsTraversalSymlinkAndPrefixSiblings` | FifthRoundRegressionTests.swift | Restore 路径穿越和符号链接防护 | 是 | 否 |
| CT-087 | `testCT087_CloudRestoreLeaseIsCrossProcessExclusive` | FifthRoundRegressionTests.swift | Restore Job 跨进程独占租约 | 是 | 否 |
| CT-088 | `testCT088_GCFailsClosedWhenDeviceDirectoryUnreadable` | FifthRoundRegressionTests.swift | GC 目录读取失败时 Fail Closed | 是 | 否 |
| CT-089 | `testCT089_DeviceRegistryRecordedAndMultiDeviceGCStaysBlocked` | FifthRoundRegressionTests.swift | 多设备离线禁止不安全删除 + 设备注册 | 是 | 否 |
| CT-090 | `testCT090_MigrationIsIdempotentAndResidualRequestNeverReplacesAgain` | FifthRoundRegressionTests.swift | Migration 重复执行和请求残留保护 | 是 | 否 |
| CT-091 | `testCT091_StatusRecomputeFollowsNewestSnapshotNotLateUpload` | FifthRoundRegressionTests.swift | 项目状态按最新 Snapshot 原子重算 | 是 | 否 |
| CT-092 | `testCT092_RegressionGateCoversAllRequiredTests` | FifthRoundRegressionTests.swift | Regression Gate 覆盖全部必需 CT | 是 | 否 |
| CT-093 | `testCT093_CoordinatorsDriveRealServiceAPIs` | FifthRoundRegressionTests.swift | Coordinator 实际驱动真实服务 API | 是 | 是（需要 kopia 二进制或 CodeTimeCrashChild 子进程，缺失时允许 XCTSkip） |
| CT-094 | `testCT094_BenchmarkRunsInIsolatedChildWithRealMetrics` | FifthRoundRegressionTests.swift | CPU/内存/并发指标来自独立子进程真实采样 | 是 | 是（需要 kopia 二进制或 CodeTimeCrashChild 子进程，缺失时允许 XCTSkip） |
| CT-095 | `testCT095_MediumScaleBenchmarkCompletes` | FifthRoundRegressionTests.swift | 大规模文件性能与稳定性 | 是 | 是（需要 kopia 二进制或 CodeTimeCrashChild 子进程，缺失时允许 XCTSkip） |
| CT-096 | `testCT096_RepositoryUsageFailsClosedAndCountsHiddenFiles` | FifthRoundRegressionTests.swift | repositoryUsage 扫描错误 fail-closed + 隐藏文件计数 | 是 | 是（需要 kopia 二进制或 CodeTimeCrashChild 子进程，缺失时允许 XCTSkip） |
| CT-097 | `testCT097_UploadJobLeaseRequiresHeartbeatAndStaleOwnerCannotFinish` | FifthRoundRegressionTests.swift | Upload Job Lease Heartbeat 与旧 owner 防护 | 是 | 否 |
| CT-098 | `testCT098_MigrationSurvivesRealSIGKILLAtEveryPhase` | FifthRoundRegressionTests.swift | Migration 真实子进程 SIGKILL 崩溃恢复 | 是 | 是（需要 kopia 二进制或 CodeTimeCrashChild 子进程，缺失时允许 XCTSkip） |

## 门禁规则

- 测试命令退出码必须为 0 且汇总为 `0 failures`。
- 每个必需 CT 必须出现在测试输出中（执行或跳过）。
- 未在索引中登记 `envSkip` 的跳过测试将导致门禁失败。
- 跳过允许项：真机/iCloud 相关（CT-036/037/044、single-Mac round trip）与依赖 kopia/crash-child 二进制的测试（CT-093~096/098），原因已登记于索引。
