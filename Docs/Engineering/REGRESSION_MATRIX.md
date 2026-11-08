# 回归测试矩阵（CT-001 … CT-116）

由 `REGRESSION_INDEX.json` 驱动；`Scripts/regression_gate.sh` 在 PR、main、Beta、Stable Candidate/Publish 强制执行。

| 编号 | 测试 | 目的 | 必需 | 人工验收 |
|---|---|---|---|---|
| CT-001 | `testCT001_UnreadableManifestAbortsCleanup` | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-002 | `testCT002_InterruptedGarbageCollectionResumes` | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-003 | `testCT003_ManifestDeletionWaitsForGrace` | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-004 | `testCT004_SameSizeDifferentContentFailsVerification` | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-005 | `testCT005_UnconfirmedUploadProducesNoGeneration` | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-006 | `testCT006_MetadataFailureIsNotTreatedAsUploaded` | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-007 | `testCT007_UnreadableCloudFileFailsClosed` | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-008 | `testCT008_ConcurrentPublisherOfSameObjectKeepsOneVerifiedCopy` | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-009 | `testCT009_FailedManifestPublishLeavesOldGenerationIntact` | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-010 | `testCT010_InvalidHashCacheIsRecomputed` | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-011 | `testCT011_TwoDevicesPublishIndependentGenerations` | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-012 | `testCT012_NewGenerationDuringCleanupIsPreserved` | 云端镜像可靠性回归（CT-001…CT-012） | 是 | 否 |
| CT-013 | `testCT013_InterruptedRestoreResumesVerifiedObjects` | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-014 | `testCT014_RestoreCopyFailureLeavesRepositoryUntouched` | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-015 | `testCT015_RestoreFailsOnObjectHashMismatch` | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-016 | `testCT016_MultiDeviceCandidatesReportKeyMismatch` | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-017 | `testCT017_MismatchedFirstCandidateDoesNotAbortRecovery` | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-018 | `testCT018_RestoreReportRequiresRepositoryAndSnapshotChecks` | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-019 | `testCT019_CloudRestoreJobSurvivesRestart` | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-020 | `testCT020_DuplicateRestoreIsSafe` | 云端恢复回归（CT-013…CT-020） | 是 | 否 |
| CT-021 | `testCT021_DeletedProjectIsNotResurrectedByRuntimeUpdate` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-022 | `testCT022_PauseIsNotOverwrittenByRuntimeUpdate` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-023 | `testCT023_LeaseBlocksSecondExecutor` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-024 | `testCT024_SettingsPropagationUsesRevision` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-025 | `testCT025_PauseClosesSchedulingGate` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-026 | `testCT026_TwoAgentsElectSingleLeader` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-027 | `testCT027_CrashLeavesInterruptedJobsRetryable` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-028 | `testCT028_PIDReuseIsNotTreatedAsAliveOwner` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-029 | `testCT029_BetaToReleaseMigrationIsLosslessAndNonDestructive` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-030 | `testCT030_ExternalProjectAllowedButRecursiveRootsRejected` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-031 | `testCT031_ExternalMirrorBookmarkSurvivesEncoding` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-032 | `testCT032_StaleBookmarkFailsExplicitly` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-033 | `testCT033_ProjectBookmarkIsSharedWithAgentConnection` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-034 | `testCT034_FreshSandboxBootstrap` | 第一/二轮可靠性回归 | 是 | 否 |
| CT-035 | `testCT035_MissingRepositoryIsNotAutoCreated` | 第二轮可靠性回归 | 是 | 否 |
| CT-036 | `testCT036_HundredThousandFilesPreview` | 环境相关回归（允许真机跳过） | 是 | 否 |
| CT-037 | `testCT037_MillionFilesBoundedByLimit` | 环境相关回归（允许真机跳过） | 否 | 是（百万文件规模测试（Stress），由 Scripts/benchmark.sh stress 或夜间任务执行；不在 CI 常规门禁内） |
| CT-038 | `testCT038_LargeFileHashStreamsInChunks` | 第二轮可靠性回归 | 是 | 否 |
| CT-039 | `testCT039_SearchTruncationIsExplicit` | 第二轮可靠性回归 | 是 | 否 |
| CT-040 | `testCT040_LargeFilePreviewDegradesExplicitly` | 第二轮可靠性回归 | 是 | 否 |
| CT-041 | `testCT041_RetryBackoffAndClassification` | 第二轮可靠性回归 | 是 | 否 |
| CT-042 | `testCT042_LogRotationIsBounded` | 第二轮可靠性回归 | 是 | 否 |
| CT-043 | `testCT043_CacheAndActivityTablesArePruned` | 第二轮可靠性回归 | 是 | 否 |
| CT-044 | `testCT044_DiskFullLeavesRepositoryUntouched` | 环境相关回归（允许真机跳过） | 否 | 是（需要可控小容量卷注入 ENOSPC，由真机验收清单覆盖） |
| CT-045 | `testCT045_InitializedReleaseCanRequestMigration` | 第三轮可靠性回归 | 是 | 否 |
| CT-046 | `testCT046_EmptyTargetDirectoriesDoNotBlockMigration` | 第三轮可靠性回归 | 是 | 否 |
| CT-047 | `testCT047_HiddenRepositoryFilesAreMigrated` | 第三轮可靠性回归 | 是 | 否 |
| CT-048 | `testCT048_InterruptedMigrationLeavesTargetRetryable` | 第三轮可靠性回归 | 是 | 否 |
| CT-049 | `testCT049_PartialRestoreFileIsReplaced` | 第三轮可靠性回归 | 是 | 否 |
| CT-050 | `testCT050_CommittingRestoreIsResumable` | 第三轮可靠性回归 | 是 | 否 |
| CT-051 | `testCT051_SelectedDeviceIsBoundToRecovery` | 第三轮可靠性回归 | 是 | 否 |
| CT-052 | `testCT052_MissingObjectMakesCandidateNonRestorable` | 第三轮可靠性回归 | 是 | 否 |
| CT-053 | `testCT053_FailedVerificationDoesNotRemainVerified` | 第三轮可靠性回归 | 是 | 否 |
| CT-054 | `testCT054_AbortedTombstoneDoesNotDeleteObjects` | 第三轮可靠性回归 | 是 | 否 |
| CT-055 | `testCT055_TwoConnectionsCompeteForOneLease` | 第三轮可靠性回归 | 是 | 否 |
| CT-056 | `testCT056_LocalRepositoryIsRediscoveredWithoutDatabase` | 第三轮可靠性回归 | 是 | 否 |
| CT-057 | `testCT057_ICloudMirrorPathIsRejected` | 第三轮可靠性回归 | 是 | 否 |
| CT-058 | `testCT058_AcceptanceGateAcceptsCompletePassReport` | 第三轮可靠性回归 | 是 | 否 |
| CT-059 | `testCT059_SelectPrefersRegisteredRepositoryAmongDiscovered` | 第三轮可靠性回归 | 是 | 否 |
| CT-060 | `testCT060_MigrationBlocksWhileBetaAgentLockIsHeld` | 第三轮可靠性回归 | 是 | 否 |
| CT-061 | `testCT061_PendingMigrationRequestLifecycle` | 第三轮可靠性回归 | 是 | 否 |
| CT-062 | `testCT062_KeychainRepairFromCloudRestoresAccess` | 第三轮可靠性回归 | 是 | 否 |
| CT-063 | `testCT063_LeaseClaimAndOwnerChecksAreAtomic` | 第三轮可靠性回归 | 是 | 否 |
| CT-064 | `testCT064_VerifyCloudClearsStaleVerifiedOnUnreadableNewest` | 第三轮可靠性回归 | 是 | 否 |
| CT-065 | `testCT065_ProjectStatusFollowsNewestSnapshot` | 第三轮可靠性回归 | 是 | 否 |
| CT-066 | `testCT066_GCPublishDoNotHoldRepositoryLock` | 第三轮可靠性回归 | 是 | 否 |
| CT-067 | `testCT067_InterruptedMigrationStagingIsReclaimed` | 第三轮可靠性回归 | 是 | 否 |
| CT-068 | `testCT068_ManualDispatchPublishesRelease` | 第三轮可靠性回归 | 是 | 否 |
| CT-069 | `testCT069_GateRejectsMissingTestsAndUnexpectedSkips` | 第三轮可靠性回归 | 是 | 否 |
| CT-070 | `testCT070_ManifestAggregateFieldTamperingIsDetected` | Manifest 完整性：篡改字段必须被真实校验函数拒绝 | 是 | 否 |
| CT-071 | `testCT071_GCSkippedWhenOtherDevicesExist` | GC：多设备/中断/不可读清单不得误删 | 是 | 否 |
| CT-072 | `testCT072_LifecycleLocksAreOutsideReplaceableRoot` | LifecycleLock 跨进程共享/独占语义 | 是 | 否 |
| CT-073 | `testCT073_OldUploadCompletionDoesNotOverrideNewSnapshotStatus` | 项目状态按最新快照推导 | 是 | 否 |
| CT-074 | `testCT074_RestoreJobWrongRepositoryIDThrows` | 恢复身份四重绑定校验 | 是 | 否 |
| CT-075 | `testCT075_SimulatedCrashDuringMigrationIsRecoverable` | 迁移崩溃恢复（journal/staging） | 是 | 否 |
| CT-076 | `testCT076_WorkflowUsesTargetCommitForRelease` | 发布 Tag/Commit 一致性 | 是 | 否 |
| CT-077 | `testCT077_CandidateArtifactSHA256Verification` | Candidate Artifact SHA-256 强制校验 | 是 | 否 |
| CT-078 | `testCT078_AcceptanceGateRejectsSubstringTag` | 验收报告精确匹配 | 是 | 否 |
| CT-079 | `testCT079_ManualReleaseTagMustExistAndPointAtBuildCommit` | 手动发布 Tag 必须存在且指向构建 commit | 是 | 否 |
| CT-080 | `testCT080_ClaimBackupJobRejectsNonBackupType` | 任务租约类型约束 | 是 | 否 |
| CT-081 | `testCT081_UnreadableStatesClassifiedByProductionListing` | 云端状态分类（生产 listGenerationEntries） | 是 | 否 |
| CT-082 | `testCT082_CandidatePackagingDoesNotRequireAcceptanceReport` | Candidate 构建不依赖验收报告 | 是 | 否 |
| CT-083 | `testCT083_AcceptanceReportMustBindImmutableArtifact` | 验收报告绑定不可变 Artifact | 是 | 否 |
| CT-084 | `testCT084_SharedLocksCoexistExclusiveBlocksAndDeathReleases` | UI 生命周期完整持有 shared lock（跨进程语义） | 是 | 否 |
| CT-085 | `testCT085_MigrationWaitsForAgentExitAndRefusesStuckAgent` | Agent 收到迁移请求能够安全停止 | 是 | 否 |
| CT-086 | `testCT086_SafePathRejectsTraversalSymlinkAndPrefixSiblings` | Restore 路径穿越和符号链接防护 | 是 | 否 |
| CT-087 | `testCT087_CloudRestoreLeaseIsCrossProcessExclusive` | Restore Job 跨进程独占租约 | 是 | 否 |
| CT-088 | `testCT088_GCFailsClosedWhenDeviceDirectoryUnreadable` | GC 目录读取失败时 Fail Closed | 是 | 否 |
| CT-089 | `testCT089_DeviceRegistryRecordedAndMultiDeviceGCStaysBlocked` | 多设备离线禁止不安全删除 + 设备注册 | 是 | 否 |
| CT-090 | `testCT090_MigrationIsIdempotentAndResidualRequestNeverReplacesAgain` | Migration 重复执行和请求残留保护 | 是 | 否 |
| CT-091 | `testCT091_StatusRecomputeFollowsNewestSnapshotNotLateUpload` | 项目状态按最新 Snapshot 原子重算 | 是 | 否 |
| CT-092 | `testCT092_RegressionGateCoversAllRequiredTests` | Regression Gate 覆盖全部必需 CT | 是 | 否 |
| CT-093 | `testCT093_CoordinatorsDriveRealServiceAPIs` | Coordinator 实际驱动真实服务 API | 是 | 否 |
| CT-094 | `testCT094_BenchmarkRunsInIsolatedChildWithRealMetrics` | CPU/内存/并发指标来自独立子进程真实采样 | 是 | 否 |
| CT-095 | `testCT095_MediumScaleBenchmarkCompletes` | 大规模文件性能与稳定性 | 是 | 否 |
| CT-096 | `testCT096_RepositoryUsageFailsClosedAndCountsHiddenFiles` | repositoryUsage 扫描错误 fail-closed + 隐藏文件计数 | 是 | 否 |
| CT-097 | `testCT097_UploadJobLeaseRequiresHeartbeatAndStaleOwnerCannotFinish` | Upload Job Lease Heartbeat 与旧 owner 防护 | 是 | 否 |
| CT-098 | `testCT098_MigrationSurvivesRealSIGKILLAtEveryPhase` | Migration 真实子进程 SIGKILL 崩溃恢复 | 是 | 否 |
| CT-099 | `testCT099_AcceptanceGateIsInsulatedFromCIEnvironment` | CT-083 测试继承 GITHUB_SHA 导致 CI 失败 | 是 | 否 |
| CT-100 | `testCT100_PublishStableChecksOutReleaseNotes` | Stable Publish 缺少 Checkout，Release Notes 无法读取 | 是 | 否 |
| CT-101 | `testCT101_CancellingWorkTerminatesAndReapsChild` | Agent 退出时没有等待 Kopia 子进程结束 | 是 | 否 |
| CT-102 | `testCT102_CommitPositionCoversEveryCrashPoint` | Cloud Restore move 后崩溃无法恢复提交 | 是 | 否 |
| CT-103 | `testCT103_FailedIsRetryableAndPermanentlyFailedIsNot` | Cloud Restore failed 状态与 Lease 语义矛盾 | 是 | 否 |
| CT-104 | `testCT104_RepositoryLockIsExclusiveAcrossHandles` | Cloud Restore 缺少 Repository 级互斥 | 是 | 否 |
| CT-105 | `testCT105_CoordinatedStoreNeverDeletesWithoutExplicitConsent` | iCloud Device Registry 不能证明设备列表完整 | 是 | 否 |
| CT-106 | `testCT106_TamperedMigrationJournalNeverDeletesArbitraryPaths` | Migration Journal stagingPath 缺少删除前安全校验 | 是 | 否 |
| CT-107 | `testCT107_SymlinkStagingIsRejectedBeforeAnyWrite` | Restore staging 允许仓库内部符号链接 | 是 | 否 |
| CT-108 | `testCT108_JanitorSkipsSymlinkedRepositoryDirectory` | Restore Janitor 未验证 Repository 根目录符号链接 | 是 | 否 |
| CT-109 | `testCT109_NewMigrationRequestFromSameSourceRunsAgain` | Migration 完成记录只比较 sourceRoot | 是 | 否 |
| CT-110 | `testCT110_StoreLevelRecomputeIsAtomicAndFollowsNewestSnapshot` | 项目状态重算不是原子事务 | 是 | 否 |
| CT-111 | `testCT111_LocalRestoreTargetLockRejectsConcurrentWriter` | 本地 Restore 缺少任务租约和目标路径互斥 | 是 | 否 |
| CT-112 | `testCT112_LiveRestoreJobIsNotReclaimedByAnotherBootstrap` | Bootstrap 可能误判其他进程的运行中 Restore | 是 | 否 |
| CT-113 | `testCT113_RestoreCoordinatorDecidesResumePlanFromState` | Coordinator 仍然只是 Service 转发层 | 是 | 否 |
| CT-114 | `testCT114_IndexForbidsRequiredSkippableAndGateBuildsCrashChild` | Regression Gate 允许关键测试跳过 | 是 | 否 |
| CT-115 | `testCT115_BenchmarkVerifiesContentAndHasBaseline` | 性能基准缺少实际内容校验和回归阈值 | 是 | 否 |
| CT-116 | `testCT116_TestReportBindsCommitRunAndGateResult` | TEST_REPORT 未同步最新 CI 结果 | 是 | 否 |

## 门禁规则（CT-114）

- 索引必须恰好登记 CT-001…CT-116，编号与测试名唯一，且每个测试都能在测试源码中找到。
- `required=true` 的测试 **不允许** 标记 `envSkip`/`manualAcceptance`；标记了门禁直接失败。
- 门禁先构建 `CodeTimeCrashChild`，CT-098 的 SIGKILL 矩阵不得因缺少二进制而跳过。
- 只有 `manualAcceptance=true` 的条目（CT-037 百万文件、CT-044 磁盘满）允许跳过，且必须写明原因。
- 失败时输出失败套件、失败用例与断言/错误详情。
