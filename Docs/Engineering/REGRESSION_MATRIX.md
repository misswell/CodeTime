# 回归测试矩阵（CT-001 … CT-233）

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
| CT-037 | `testCT037_MillionFilesBoundedByLimit` | 环境相关回归（允许真机跳过）（百万文件规模测试（Stress），由 Scripts/benchmark.sh stress 或夜间任务执行；不在 CI 常规门禁内） | 否 | 是 |
| CT-038 | `testCT038_LargeFileHashStreamsInChunks` | 第二轮可靠性回归 | 是 | 否 |
| CT-039 | `testCT039_SearchTruncationIsExplicit` | 第二轮可靠性回归 | 是 | 否 |
| CT-040 | `testCT040_LargeFilePreviewDegradesExplicitly` | 第二轮可靠性回归 | 是 | 否 |
| CT-041 | `testCT041_RetryBackoffAndClassification` | 第二轮可靠性回归 | 是 | 否 |
| CT-042 | `testCT042_LogRotationIsBounded` | 第二轮可靠性回归 | 是 | 否 |
| CT-043 | `testCT043_CacheAndActivityTablesArePruned` | 第二轮可靠性回归 | 是 | 否 |
| CT-044 | `testCT044_DiskFullLeavesRepositoryUntouched` | 环境相关回归（允许真机跳过）（需要可控小容量卷注入 ENOSPC，由真机验收清单覆盖） | 否 | 是 |
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
| CT-117 | `testCT117_OversizedFileProtectionCopySurvivesItsOwnPrune` | P1：超预算保护副本被自身 prune 删除 | 是 | 否 |
| CT-118 | `testCT118_OversizedDirectoryProtectionKeptWithOverBudgetStatus` | 超额目录保护与状态上报 | 是 | 否 |
| CT-119 | `testCT119_SourceMutatedDuringCopyAbortsInsteadOfFakeProtection` | 复制期间源变化不得伪装保护成功 | 是 | 否 |
| CT-120 | `testCT120_TamperedProtectionCopyFailsVerificationAndListing` | 保护副本损坏检测 | 是 | 否 |
| CT-121 | `testCT121_PruneNeverDeletesNewestOrActiveCopies` | 清理策略必须保护最新与活动副本 | 是 | 否 |
| CT-122 | `testCT122_ActiveRestoreCopyProtectedFromPrune` | 清理与恢复并发 | 是 | 否 |
| CT-123 | `testCT123_DuplicateObjectsVerifiedOncePerUniqueHash` | 云端重复对象重复哈希 | 是 | 否 |
| CT-124 | `testCT124_ClonedDatabaseOnNewMacMintsNewDeviceIdentity` | macOS 迁移助理复制设备数据库 | 是 | 否 |
| CT-125 | `testCT125_TwoMacsPublishingConcurrentlyKeepIndependentGenerations` | 双 Mac 并发发布（双设备模拟） | 是 | 否 |
| CT-126 | `testCT126_GCOnOneMacNeverDeletesOtherMacsCommittedObjects` | 双 Mac GC 与发布竞争（双设备模拟） | 是 | 否 |
| CT-127 | `testCT127_TestReportBindingMismatchFailsConsistencyCheck` | 测试报告绑定错误 Commit | 是 | 否 |
| CT-128 | `testCT128_SkippedTestsCountedAsPassedFailTheCheck` | 跳过项计入通过的报告 | 是 | 否 |
| CT-129 | `testCT129_BuildCapabilityDecidesICloudAvailability` | 构建能力检测：无 iCloud 权限的构建必须明确报不支持 | 是 | 否 |
| CT-130 | `testCT130_EnvironmentMatrixIsExplicit` | iCloud 环境矩阵（未登录/Drive 关闭/容器缺失/不可写/就绪） | 是 | 否 |
| CT-131 | `testCT131_EnablingICloudOnUnsupportedBuildDoesNotMutateSettings` | 启用 iCloud 失败时不得修改存储配置 | 是 | 否 |
| CT-132 | `testCT132_CloudStateMachineForbidsFalseSuccess` | 云端状态机禁止虚假成功 | 是 | 否 |
| CT-133 | `testCT133_ProjectSyncDisplaySeparatesLocalUploadAndFailure` | 项目同步展示区分本地/上传/云端失败 | 是 | 否 |
| CT-134 | `testCT134_FirstBackupPublishesBeforeReportingSynced` | 首次备份端到端：先发布再显示已同步 | 是 | 否 |
| CT-135 | `testCT135_RetryPendingPublishesIsIdempotentAndKeepsSyncedProjectsAlone` | 立即同步幂等且不重传已同步项目 | 是 | 否 |
| CT-136 | `testCT136_RecoveryAutoDetectsContainerStorageRoot` | 换机恢复自动发现容器目录 | 是 | 否 |
| CT-137 | `testCT137_ReleaseValidationChecksTheSignedProduct` | 发布校验检查签名产物与描述文件 | 是 | 否 |
| CT-138 | `testCT138_StressTestIsOptInSeparatelyFromScale` | 百万文件压力测试与常规门禁分离（避免 CI job 超时） | 是 | 否 |
| CT-139 | `testCT139_RecoveryCandidateListsProjectsBeforeDownload` | 恢复页在下载前展示设备/时间/项目 | 是 | 否 |
| CT-140 | `testCT140_ICloudBetaBuildIsOptInAndRequiresProfile` | iCloud 验收构建必须显式开启且要求身份+描述文件 | 是 | 否 |
| CT-141 | `testCT141_AcceptanceHarnessDetectsMismatchAndRefusesFakeReport` | 双 Mac 验收证据脚本不可伪造 | 是 | 否 |
| CT-142 | `testCT142_LaunchSmokeDetectsCrashAndHangFreeSuccess` | 分发包含启动即崩溃必须被拦截 | 是 | 否 |
| CT-143 | `testCT143_ICloudBetaUsesDedicatedConfiguration` | iCloud 验收构建使用专用配置，避免命令行污染 SwiftPM 目标 | 是 | 否 |
| CT-144 | `testCT144_DoctorReportsStructuredBlockers` | 发布前置自检报告结构化且可操作 | 是 | 否 |
| CT-145 | `testCT145_DiagnosesOffScreenAppWindow` | 窗口保存位置在屏幕外时必须可诊断并给出修复命令 | 是 | 否 |
| CT-146 | `testCT146_ProjectDiscoverySkipsTCCProtectedFolders` | 首启向导的项目发现不得自动扫描 TCC 保护目录（文稿/桌面/下载） | 是 | 否 |
| CT-147 | `testCT147_ChunkerIsContentDefinedAndStable` | 内容定义分块稳定、追加不改已有块、插入可复用 | 是 | 否 |
| CT-148 | `testCT148_ObjectIdentityIsStableAndKeyScoped` | 对象 ID 由 HMAC 派生且按仓库密钥隔离 | 是 | 否 |
| CT-149 | `testCT149_EncryptedObjectRoundTrip` | 对象信封压缩+AEAD 往返与防篡改 | 是 | 否 |
| CT-150 | `testCT150_TreeIsDeterministicAndOrderIndependent` | Merkle 树身份确定且变更只沿路径传播 | 是 | 否 |
| CT-151 | `testCT151_CommitRequiresManifestAndMatchingHash` | v3 云存储发布顺序与幂等 | 是 | 否 |
| CT-152 | `testCT152_FileIndexReplacementLeavesNoGhosts` | v3 本地索引：扫描替换无残留、块索引、快照状态、待上传计数、缓存与迁移日志 | 是 | 否 |
| CT-153 | `testCT153_ScanAppliesExclusionsAndKeepsStructure` | 项目扫描：排除规则、符号链接不跟随、增量变化集、不可读子树如实标记 | 是 | 否 |
| CT-154 | `testCT154_FirstBackupPublishesInOrderAndIsReadable` | 云优先引擎端到端：发布顺序、增量复用、历史不可变、跨文件去重 | 是 | 否 |
| CT-155 | `testCT155_FullProjectRestoreIsBitForBit` | 按需恢复：staging、逐文件校验、单文件/目录范围、路径穿越拒绝、失败不触碰目标 | 是 | 否 |
| CT-156 | `testCT156_CacheStoresReadsAndEvictsLRUWithinBudget` | 缓存预算/固定条目/越界拒绝 + iCloud 本地副本驱逐的确认与失败上报 | 是 | 否 |
| CT-157 | `testCT157_PackFormatRoundTripsEveryObject` | 不可变对象包：格式往返、越界/重复/截断拒绝、引擎打包并恢复 | 是 | 否 |
| CT-158 | `testCT158_HappyPathWithConsentReleasesLegacyLast` | v2→v3 迁移状态机：顺序、失败阻塞、崩溃续跑、释放旧仓库需显式同意 | 是 | 否 |
| CT-159 | `testCT159_FailedUploadKeepsSpooledBytesAndResumeCompletes` | 持久化待上传队列：失败保留加密数据、软上限暂停、崩溃续传、引擎离线后恢复 | 是 | 否 |
| CT-160 | `testCT160_BackupBrowseDiffRestoreAndVerifyThroughTheAdapter` | BackupEngine v3 适配层：备份/列表/浏览/读取/Diff/单文件恢复/全量校验 | 是 | 否 |
| CT-161 | `testCT161_ServiceBacksUpBrowsesRestoresAndReportsSpace` | 服务层真正走 v3 引擎：设置切换、快照、浏览、恢复、空间统计 | 是 | 否 |
| CT-162 | `testCT162_MigrationReleasesLegacyOnlyWithConsentAndKeepsHistory` | 服务层 v2→v3 迁移：基线验证、显式同意后才释放旧仓库、旧历史保留 | 是 | 否 |
| CT-163 | `testCT163_TombstonesFirstThenSweepsOnlyExpiredUnreferencedData` | v3 两阶段云端 GC：先墓碑、引用重算、宽限期后只删除无引用对象/版本 | 是 | 否 |
| CT-164 | `testCT164_NewMacDiscoversAndRestoresV3Project` | 新 Mac：发现 v3 项目、用恢复密钥恢复版本、注册项目并继续浏览历史 | 是 | 否 |
| CT-165 | `testCT165_OnboardingStartsFreshInstallOnV3` | 全新安装且云端可用时默认启用 v3；已有快照的安装保持旧引擎直到迁移 | 是 | 否 |
| CT-166 | `testCT166_InterruptedRestoreResumesStagedFiles` | v3 恢复中断后从确定性 staging 续传，已校验文件不重复下载 | 是 | 否 |
| CT-167 | `testCT167_FSEventsDeliverChangeAndGateRespectsMinimumInterval` | FSEvents 变化监听与最小变化间隔；FSEvents 仅作优化，完整扫描仍兜底 | 是 | 否 |
| CT-168 | `testCT168_ServiceCancellationStopsEngineBeforeCommit` | 服务层取消传播：已开始上传后取消，不得发布 commit，任务标记 interrupted | 是 | 否 |
| CT-169 | `testCT169_ResolverTrustsRemoteCommitAndNeverDowngradesLocalV3` | 快照格式以远端 commit 为准；本地 v3 记录无 commit 时禁止降级为 Kopia | 是 | 否 |
| CT-170 | `testCT170_RemoteSnapshotIndexIsPersistentAndRebuildable` | 远端快照索引持久化与重建；索引不是存在性权威 | 是 | 否 |
| CT-171 | `testCT171_DeviceListHasTTLAndFailedRefreshKeepsLastKnownList` | 跨设备列表 TTL、强制刷新、失败不缓存空结果 | 是 | 否 |
| CT-172 | `testCT172_TwoServiceInstancesDiscoverEachOthersVersions` | 两个服务实例共享云根：互相发现、恢复并继续备份（本地镜像模拟） | 是 | 否 |
| CT-173 | `testCT173_EveryRelevantSettingChangesTheFingerprint` | Runtime 配置指纹覆盖存储模式、设备、缓存/Spool 预算、书签 | 是 | 否 |
| CT-174 | `testCT174_ServiceReportsNewFingerprintAfterSettingsChange` | 设置变更后服务报告新指纹并可重建 v3 Runtime | 是 | 否 |
| CT-175 | `testCT175_HashMismatchPreventsEviction` | 上传确认后回读哈希；不一致时禁止驱逐本地副本 | 是 | 否 |
| CT-176 | `testCT176_NodesManifestsAndCommitsAllEvictAfterConfirmation` | Node/Manifest/Commit 统一走确认、校验、释放本地副本 | 是 | 否 |
| CT-177 | `testCT177_RetryBackoffIsDurableAcrossQueueInstances` | 上传失败指数退避 + 抖动持久化，重启后仍遵守 | 是 | 否 |
| CT-178 | `testCT178_BaselineRegistryPersistsProjectIDAndSnapshotAcrossRuns` | 迁移基线按项目持久化，崩溃后续用同一基线 ID | 是 | 否 |
| CT-179 | `testCT179_FailedDeleteKeepsIndexAndReportsFailure` | 缓存删除失败时保留索引并报告失败 | 是 | 否 |
| CT-180 | `testCT180_ReconcileDropsMissingRowsAndRemovesOrphans` | 缓存崩溃恢复：清理缺失行与孤儿文件 | 是 | 否 |
| CT-181 | `testCT181_OutsideRootEntryIsNeverDeleted` | 缓存索引指向根外时拒绝删除 | 是 | 否 |
| CT-182 | `testCT182_InaccessibleCacheFileIsReportedNotTreatedAsMiss` | 缓存文件不可访问时报错并保留索引 | 是 | 否 |
| CT-183 | `testCT183_InspectReportsAbsentCorruptInaccessibleAndVerified` | 远端完整性检查区分缺失/损坏/不可访问/已验证 | 是 | 否 |
| CT-184 | `testCT184_VerificationIgnoresCacheAndFailsOnCorruptCloudObject` | 云端校验绕过本地缓存；缓存正确但云端损坏必须失败 | 是 | 否 |
| CT-185 | `testCT185_PackCorruptionIsDetected` | Pack 头部/索引/边界/对象解密完整校验 | 是 | 否 |
| CT-186 | `testCT186_TruncatedStagingFileIsNeverAcceptedWhenVerifyHashesIsFalse` | 恢复默认校验长度与哈希，verifyHashes=false 不关闭基础保护 | 是 | 否 |
| CT-187 | `testCT187_DirectoryModeAndSymlinksAreRestoredWithoutEscaping` | 目录权限/mtime 与符号链接安全恢复，最后创建符号链接 | 是 | 否 |
| CT-188 | `testCT188_SharedLeasesOverlapAndExclusiveMaintenanceIsBlocked` | 跨进程操作租约：共享备份/恢复可并存，GC/迁移独占 | 是 | 否 |
| CT-189 | `testCT189_LeaseReleaseIsIdempotent` | 租约释放幂等，重复释放不破坏其他持有者 | 是 | 否 |
| CT-190 | `testCT190_ReconcilerAdoptsValidOrphansAndQuarantinesUnknown` | Spool 孤儿恢复：合法对象收养，未知文件隔离 | 是 | 否 |
| CT-191 | `testCT191_ReconcilerResolvesMissingFilesAgainstTheCloud` | Journal 有任务但 spool 缺失时以云端存在性判定 | 是 | 否 |
| CT-192 | `testCT192_ReconcilerCleansUploadedPendingCleanup` | 已上传待清理状态的重试清理 | 是 | 否 |
| CT-193 | `testCT193_UploadQueueRefusesConcurrentWriterForSameObject` | 同一 Object ID 的跨进程上传租约 | 是 | 否 |
| CT-194 | `testCT194_SweepRefusesWhileDataIsStagedOrPublishing` | 有暂存上传或发布中快照时 GC 拒绝清扫 | 是 | 否 |
| CT-195 | `testCT195_MissingReferencedObjectAbortsBeforeAnyTombstone` | 引用图不完整时在任何删除前中止 GC | 是 | 否 |
| CT-196 | `testCT196_RetentionPlannerKeepsNewestAndBuckets` | 保留策略：最新版本与时间桶保留 | 是 | 否 |
| CT-197 | `testCT197_MissingScenarioEvidenceBlocksReport` | 双 Mac 验收缺少场景证据必须拒绝生成报告 | 是 | 否 |
| CT-198 | `testCT198_SameHostCannotPassDualMacAcceptance` | 同一 Host 不能冒充双 Mac 验收 | 是 | 否 |
| CT-199 | `testCT199_CandidateHashMismatchAndIncompleteRestoreBlock` | 候选哈希不一致或恢复文件未全部校验必须阻塞 | 是 | 否 |
| CT-200 | `testCT200_RecordProducesStructuredEvidenceAndReportIsNotHardcoded` | 结构化证据记录与拒绝无证据报告 | 是 | 否 |
| CT-201 | `testCT201_AppendDuringFlushDoesNotLoseChunks` | flush 挂起期间追加的 Chunk 不得丢失 | 是 | 否 |
| CT-202 | `testCT202_ConcurrentFlushSharesInFlightBatch` | 并发 flush 共享一个 in-flight 批次 | 是 | 否 |
| CT-203 | `testCT203_FailedBatchIsPreservedAndRetried` | 失败的 Pack 批次保留并可重试 | 是 | 否 |
| CT-204 | `testCT204_FinalizeWaitsForAllPendingBatches` | finalize 等待 pending/in-flight/failed 全部完成 | 是 | 否 |
| CT-205 | `testCT205_DuplicateObjectIDIsPackedOnce` | 同一 Object ID 只进入 Pack 一次 | 是 | 否 |
| CT-206 | `testCT206_PackLocationOnlyPublishedAfterConfirmation` | 上传确认前不得暴露 PackLocation | 是 | 否 |
| CT-207 | `testCT207_PendingObjectIsNotReportedAsUploaded` | 上传中的对象不得报告为已上传 | 是 | 否 |
| CT-208 | `testCT208_ConcurrentDuplicateChunkWaitsForUpload` | 并发重复 Chunk 等待首个上传结果 | 是 | 否 |
| CT-209 | `testCT209_UploadFailurePropagatesToAllWaiters` | 上传失败传播给所有等待者 | 是 | 否 |
| CT-210 | `testCT210_ZeroStoredSizeKnownRecordIsNotReusableAndPackedLocationWins` | 零大小索引占位不得复用；Pack 位置优先 | 是 | 否 |
| CT-211 | `testCT211_UploadingObjectIsWaitedForNotOverwritten` | uploading 状态交由底层等待，不写第二份密文 | 是 | 否 |
| CT-212 | `testCT212_UploadingIsNotReportedAsReusable` | uploading 不得被 hasObject 当作可复用 | 是 | 否 |
| CT-213 | `testCT213_UploadLockFilesRemainBounded` | 上传锁文件固定为分片数量 | 是 | 否 |
| CT-214 | `testCT214_RetryExhaustionKeepsSpoolAndJournal` | 重试耗尽仍保留 spool 与 journal | 是 | 否 |
| CT-215 | `testCT215_SameObjectIDWithDifferentRandomNonceIsReusedByEncryptedIdentity` | 随机 nonce 导致密文不同但 Object ID 相同仍可复用；损坏对象不覆盖 | 是 | 否 |
| CT-216 | `testCT216_ReadersAndPinsPreventEviction` | 读者与 pin 阻止本地副本驱逐 | 是 | 否 |
| CT-217 | `testCT217_ConcurrentReadersKeepCopyUntilLastRelease` | 最后一个读者释放后才可驱逐 | 是 | 否 |
| CT-218 | `testCT218_WriterExcludesReadersAndEviction` | 写租约排除读者与驱逐 | 是 | 否 |
| CT-219 | `testCT219_CoordinatedReadEvictsOnlyAfterLastReader` | 协调读取结束后安全驱逐 | 是 | 否 |
| CT-220 | `testCT220_PackIDMismatchRejected` | Pack ID 哈希不匹配拒绝 | 是 | 否 |
| CT-221 | `testCT221_DuplicateObjectIDRejected` | 重复 Object ID 拒绝 | 是 | 否 |
| CT-222 | `testCT222_OverlappingRangesRejected` | 重叠数据区拒绝 | 是 | 否 |
| CT-223 | `testCT223_IntegerOverflowIsRejectedWithoutCrashing` | 恶意 UInt64 偏移不得导致 Int 溢出/崩溃 | 是 | 否 |
| CT-224 | `testCT224_TruncatedIndexRejected` | 截断索引拒绝 | 是 | 否 |
| CT-225 | `testCT225_CorruptedEncryptedMemberRejectedByObjectValidator` | Pack 内损坏密文被对象校验拒绝 | 是 | 否 |
| CT-226 | `testCT226_InvalidOriginalSizeAndDecompressionLimitRejected` | 非法原大小与解压上限拒绝 | 是 | 否 |
| CT-227 | `testGCBarrierCreatedWithPreparedAckAndReleasedOnlyAfterCompletion` | GC Prepared ACK 建立持久 Barrier，完成后才释放 | 是 | 否 |
| CT-228 | `testGCLegacyEpochWithoutBarrierCannotDelete` | 旧 Epoch 无 Barrier 不得删除 | 是 | 否 |
| CT-229 | `testGCAckRefusedWhileLocalWorkIsActive` | 本机有活动任务时拒绝写 ACK/Barrier | 是 | 否 |
| CT-230 | `testCT230_MissingSingleMacScenarioBlocksReport` | 单机验收缺少场景证据必须拒绝报告 | 是 | 否 |
| CT-231 | `testCT231_TwoHostsCannotPassSingleMacGate` | 单机验收不得接受重复/多 Host 证据 | 是 | 否 |
| CT-232 | `testCT232_CompleteSingleMacEvidenceGeneratesReportAndPassesGate` | 完整单机证据生成报告并通过发布门禁 | 是 | 否 |
| CT-233 | `testCT233_HandWrittenPassWithoutEvidenceIsRejected` | 手写 PASS 缺少全部场景证据必须拒绝 | 是 | 否 |
