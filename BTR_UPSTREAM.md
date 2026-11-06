# BTR 上游同步

目前最新穩定使用版仍為 **PiliPlus-BTR-Upstream-20261027-01**。`codex/btr-stable` 為 APK 建置來源 `790e357f661b935b5eb064d9affa54279b0c51a9`，`codex/btr-accepted` 為維護來源 `184c1fe8ea5649593d0dcedda1b420e101bcc2b4`。見 [接受紀錄](BTR_STABLE_ACCEPTANCE_20261106.md)及[版本清單](tools/legacy/btr_current_recommendation.json)。分離候選未接受、未提升穩定版。

唯一官方上游是 https://github.com/bggRGjQaUbCoE/PiliPlus.git 的 main。Android BTR 自行維護，不追蹤／自動移植 Bilibili-thread-ripper；MIT notices 保留。`main` 含 BTR，不能當純官方來源。

## 來源與候選

設定在 `tools/legacy/btr_upstream.json`。requiredFeatures 固定為 `55fd75e41ae518c0330a11ea646ddf8b8b2bcae2`；預設使用 acceptedSource。bootstrapSource 僅供尚未建立接受 ref 的初始化。未接受候選只有明確指定 SourceRef 才能接續。

分離來源與重組入口見 [BTR_SOURCES.md](BTR_SOURCES.md)。舊已接受工作樹 `.btr-wt/up-1027-01` 繼續使用自己的 `tool/btr_sync_upstream.ps1`；本候選在根目錄使用：

```powershell
# 預設仍從 accepted 建候選，保留來源的原 layout。
pwsh -NoProfile -File tools/btr_sync_upstream.ps1 -RunId <唯一短名稱>
# 明確延續未接受的分離架構，不等於接受。
pwsh -NoProfile -File tools/btr_sync_upstream.ps1 -SourceRef codex/btr-separated-20261106-01 -RunId <唯一短名稱> -Python '<python.exe>'
```

先讀 AGENTS.md、本文件、BTR_EXPERIMENT.md、BTR_DEVELOPMENT_INDEX.md、版本清單與實際 Git 狀態。候選必須包含 requiredFeatures 及目前 accepted 祖先；於 repository 根的 `.btr-wt/<RunId>` 建 sibling worktree，分支為 `codex/btr-update-<RunId>`。既有路徑、ref、run 證據拒絕覆用。

來源與工具 checkout 同 layout 時，只攜帶已提交的維護工具與文件；未提交工具先另行提交，分歧則停止。不同 layout 時保留來源自己的工具及文件，避免默默遷移已接受版。其他 owner 未提交／未追蹤檔不 stash、不搬移、不清除。

## 官方樹與 Integration 更新

只 fetch 官方 main，不 fetch tags、不 prune、不 force。純上游鏡像僅 fast-forward；保留 `btr-pre-sync-<RunId>` 及 `evidence/upstream-sync/<RunId>/sync.json`。本次分離工程沒有執行實際官方同步。

來源為原 layout 時沿用既有 merge。來源含 `integration/sources.json` 時，以 Git subtree merge 把官方根樹映射到 `PiliPlus/`，保留官方與 BTR 祖先。衝突保留 index／MERGE_HEAD，讀 base/ours/theirs 後精確 stage，不整檔選 ours/theirs、不自動 abort。

無 merge 衝突後，更新官方 pin 並比較 16 個 integration patch 的 base blobs。任何目標被上游更動、刪除或改名，都記為 `INTEGRATION_REVIEW_REQUIRED` 並停止，保留未完成 merge、舊 patch 與新官方來源。即使 patch 可能乾淨套用，也必須審查舊官方／新官方／現有 patch；不能只換 baseBlob 規避審查。新增檔與 overlay 碰撞、官方樹不符或組合失敗也停止。

未觸及整合接點時，先組合 `.assembled/upstream-review/`，通過後提交 merge。重複同步相同 pin 不產生額外 merge 或 manifest 修改。source 與 upstream 必須是候選祖先；不移動 accepted 或 stable。

接點審查後修改最小 patch、更新其 baseBlob，必要時調整 overlay／manifest，再組合並完成測試與 ARM64 DEV APK。MERGE_HEAD 存在時，精確 stage 並提交 merge 後再驗證。SDK／lock／patch inputs 改變時須準備獨立工具鏈；不修改種子、全域設定或原有依賴 checkout。

## 驗證與交付

分離架構使用 `tools/btr.ps1` 的 Compose／Setup／Core／Settings／Analyze／Native／VerifiedWrite／Build。完整命令與 inputs 核對見 [BTR_SOURCES.md](BTR_SOURCES.md)。來源回歸：`python tools/test_sources.py`；既有同步安全：`pwsh -File tools/btr_sync_tests.ps1`；分離同步：`python tools/test_separated_sync.py`。同步測試只使用本機 disposable Git fixtures。

舊 `btr_verify_features.ps1` tripwire 保留在 `tools/legacy/`，只適用原 layout 的 Git checkout；分離來源改以 pin／manifest／逐檔 blob 與組合驗證，不能在生成目錄誤用外層 Git root。位元組／結構驗證與 APK 成功不是實機驗收。

不得放寬 8 HTTP 回應、4 執行槽、16 上游請求、Range/ETag、單來源固定、HTTPS、MCDN/P2P 或清理保護。DeviceTest 只是既有診斷編譯旗標，不操作裝置。僅遇到 AGENTS.md 指定 IPC 症狀後，才使用 repo-local 短路徑；不改 TEMP/TMP、hosts、Android source 或 JDK。MSVC 阻擋保留日誌，不列 PASS。

以 aapt／apksigner 核對 DEV applicationId、ARM64 及既有 certificate。APK 另存唯一 `build/btr-candidates/<RunId>/`，紀錄 SHA-256、大小、source/upstream SHA、fingerprint 與未接受狀態。實際 CDN、Seek／音畫、SAF、長時播放與原生資源未執行時維持 NOT RUN／UNVERIFIED／UNRESOLVED。

## 接受

只有使用者另行明確接受後，在乾淨、已審查且 HEAD 等於指定完整 SHA 的候選執行：

```powershell
pwsh -NoProfile -File tools/btr_sync_upstream.ps1 -AcceptCandidate <完整候選SHA> -AcceptanceNote '<使用者接受範圍>' -RunId <唯一名稱>
```

以 compare-and-swap 前進 `codex/btr-accepted` 並保存 `evidence/source-acceptance` 收據。ref 已 checkout、缺前一接受來源、未提交或 SHA 不等於 HEAD 即停止。AcceptCandidate 不提升 stable、不改版本清單、不表示 Android 驗收。保留歷史工作樹、分支、tags、APK 與 evidence；不 push、不建 PR、不發布、不自動裝機。
