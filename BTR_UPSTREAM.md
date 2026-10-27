# BTR 上游同步

唯一持續同步的上游是 PiliPlus 官方 main：https://github.com/bggRGjQaUbCoE/PiliPlus.git。
Android BTR 為本專案自行維護，不追蹤或自動移植 Bilibili-thread-ripper 更新；原 MIT notices 保留。

## 維護來源

tool/btr_upstream.json 的 requiredFeatures 固定完整功能基準 55fd75e41ae518c0330a11ea646ddf8b8b2bcae2。
沒有已接受維護來源時使用 bootstrapSource：btr-user-trial-20261027-55fd75e41。
使用者明確接受候選後，acceptedSource（codex/btr-accepted）才可前進。後續來源必須包含它及 requiredFeatures。
codex/btr-maintenance 為保留的舊維護線，不是建議 APK 來源；main 也包含 BTR，不是純上游。
同步與接受維護來源都不提升 codex/btr-stable、不變更 tool/btr_current_recommendation.json。
未接受候選只能在明確指定 SourceRef 時接續。測試與建置通過不是 Android 驗收或使用者接受。

## 程式碼邊界

政策、CDN 身分驗證、排程、Range/ETag、取消、容量、監控及設定集中在 lib/services/btr/。
player_integration.dart 是 PlPlayerController library 的私有 part/extension，集中 terminal、read-stall、native error、EOF 校正與 seek resume。
它仍共享 controller 的來源序號、Seek 意圖及生命週期，不是獨立播放器或另一套狀態機。
共用 open/refresh/seek/play/dispose 留在 controller，保持 native stop → retire GET → reopen、最新 Seek 意圖及原始模式契約。
播放與事件 hook、影音候選擷取、設定入口、overlay、AudioService task removal 仍須三方審查。
不建立新 repository/package，不放寬 8 個 HTTP 回應、4 個執行槽、16 個上游連線及清理保護。

## 建立候選

在最新維護工具所在的新候選工作樹，先讀 AGENTS.md、本文件、BTR_EXPERIMENT.md、BTR_DEVELOPMENT_INDEX.md、版本清單及實際 Git 狀態。

~~~powershell
pwsh -NoProfile -File .\tool\btr_sync_upstream.ps1 -RunId <唯一短名稱>
~~~

預設從已接受來源建立 codex/btr-update-<RunId>，工作樹固定為本 repository 的 .btr-wt/<RunId>，不逐層巢狀。
當工具 checkout 比來源新，只帶入已提交的維護文件與 tool；應用功能仍來自接受來源。來源較新時保留其工具，分歧則停止審查。
未提交工具需先在新候選提交；其他 owner 未提交檔不 stash、不搬移、不清除。
明確接續未接受候選時加 -SourceRef <候選分支或固定SHA>；不得因此提升接受來源。

只 fetch 官方 main，不抓 tags、不 prune、不強制更新；純上游鏡像只允許 fast-forward。
保留 btr-pre-sync-<RunId>、evidence/upstream-sync/<RunId>/sync.json。已有 ref、路徑或 run 拒絕覆用。
衝突保留 index/MERGE_HEAD，讀 base/ours/theirs 後精確 stage，不整檔選 ours/theirs、不自動 abort。
驗證 source 和 upstream 都是候選祖先。

## 驗證與工具鏈

~~~powershell
pwsh -NoProfile -File .\tool\btr_verify_features.ps1 -BtrRef <sourceCommit> -UpstreamRef <upstreamCommit>
pwsh -NoProfile -File .\tool\btr_candidate_setup.ps1 -SeedRoot <本專案種子工作樹>
~~~

verify 僅為結構警報；沒被上游修改的 BTR 檔案須等同來源。架構整理先獨立提交，再用其 SHA 作同步來源。
CDN 審查追蹤選定 DASH representation → 原始完整 URL 候選 → NetworkSource → BtrPlayback → 單一驗證來源。
不得把改寫 host 後的簽章當成內容身分證明，不放寬 Range、ETag 或單來源固定規則。

setup 僅在 .fvmrc、pubspec、lock 與 patches 一致時重用 SDK/cache。
不同時在候選 .toolchain 準備獨立 SDK/Pub cache，依新上游 Android patch 清單核對並使用 btr_prepare.ps1。
不得修改種子 SDK、全域設定、既有依賴 checkout 或原 PiliPlus 目錄；保留既有 DEV key，缺 key 時建置停止。
只複製候選需要的快取，記錄來源版本，不執行會 reset SDK 的上游 helper。

~~~powershell
$env:PUB_CACHE = Join-Path (Get-Location) '.toolchain/pub-cache'
$env:CI = 'true'
& .\.toolchain\flutter\bin\flutter.bat pub get --enforce-lockfile
pwsh -NoProfile -File .\tool\btr_test.ps1
& .\.toolchain\flutter\bin\flutter.bat analyze --no-pub --no-fatal-infos lib test
& .\.toolchain\flutter\bin\flutter.bat test --no-pub test/btr/audio_task_removed_flutter.dart
pwsh -NoProfile -File .\tool\btr_diagnostics_flutter_test.ps1
pwsh -NoProfile -File .\tool\btr_verified_write_test.ps1 -JavaHome <JDK>
pwsh -NoProfile -File .\tool\btr_build.ps1 -AndroidSdk <SDK> -JavaHome <JDK> -DeviceTest -BuildId <RunId>
~~~

DeviceTest 僅啟用 55fd 既有 DEV 診斷編譯旗標，不操作裝置。
只有實際遇到 loopback/PipeImpl/UnixDomainSockets/Invalid argument: connect，才以 -ShortIpcPath 重試並另存日誌。
不改 TEMP/TMP、hosts、Android source 或 JDK。cnativeapi/MSVC 阻擋留失敗日誌，不記 PASS。
用 aapt dump badging、apksigner verify --print-certs 核對 DEV applicationId、ARM64、既有 certificate。
交付至候選 build/btr-candidates/<RunId>/，記錄 SHA-256、大小、build/source/upstream SHA；不覆寫舊 APK。

## 接受與後續使用

只有使用者另行明確接受後，從乾淨、已審查候選 checkout 執行：

~~~powershell
pwsh -NoProfile -File .\tool\btr_sync_upstream.ps1 -AcceptCandidate <完整候選SHA> -AcceptanceNote '<使用者接受範圍>' -RunId <唯一名稱>
~~~

以 compare-and-swap 前進 codex/btr-accepted，保留 evidence/source-acceptance 收據；不變更建議版本、穩定分支或裝置。
ref 已 checkout、歷史缺前一接受來源、未提交、或 SHA 不等於 HEAD 時停止。
日後直接要求「同步 PiliPlus 最新版本並保留 BTR 功能」，並使用本工具所在候選路徑。
本機安全回歸：pwsh -NoProfile -File .\tool\btr_sync_tests.ps1（只用 disposable Git fixtures）。
保留原始 evidence、候選、分支與 APK；不 push、不建 PR、不發布、不自動裝機。
歷史同步報告為 BTR_UPSTREAM_RESULT_20261016.md；驗收缺口見 BTR_DEVELOPMENT_INDEX.md。
