# BTR 上游同步

日後直接要求 Codex：**「同步 PiliPlus 最新版本並保留 BTR 功能」**。
Codex 應先讀本文件、`tool/btr_upstream.json`、`BTR_EXPERIMENT.md` 及目前 Git 狀態，再執行下列流程。
同步與 APK 建置成功不代表 Android 實機驗收成功；不得自行提升穩定版本。

## 分支與還原點

| 名稱 | 用途 |
|---|---|
| `upstream/main` | 從原版官方 URL fetch 的純上游遠端追蹤 ref |
| `codex/upstream-piliplus` | 純上游本機鏡像，只允許 fast-forward，不放 BTR 修改 |
| `codex/btr-stable` | 既有可用版本 `788faa8ab`；只繼承該版本原有驗收範圍 |
| `codex/btr-settings-monitor` | 原功能分支，保留於 `f583de9e2`，設定／監控／生命週期功能的實機驗收仍為 UNRESOLVED |
| `codex/btr-maintenance` | 長期維護線，從 `f583de9e2` 建立並加入同步工具；不是實機已驗收的穩定版 |
| `codex/btr-update-<RunId>` | 每次更新的新候選；在 `.btr-wt/<RunId>` 獨立工作樹整合及建置 |
| `main` | 舊的含 BTR 分支，保留原位；不能當純上游來源 |
| `btr-stable-baseline-20261016` | 固定既有可用基準 `788faa8ab` |
| `btr-feature-snapshot-20261016` | 固定完整功能 Commit `f583de9e2` |
| `btr-pre-sync-<RunId>` | 每次同步前的已提交來源快照 |

`origin` 原設定不變；另加 `upstream` 明確表示官方來源。不推送、不建 PR，不改全域 Git 設定。

目前原版歷史與 BTR 有共同祖先，BTR 只有兩個功能 Commit，適合保留歷史的三方 merge。
候選從維護線建立，merge 純上游；以後已同步的上游 Commit 可由祖先關係辨識，不必反覆搬移整套 BTR。
不 rebase、不 squash、不改寫已存在的 Commit。

## 1. 取得上游並建立候選

在維護線所在的工作樹使用 PowerShell 7：

```powershell
pwsh -NoProfile -File .\tool\btr_sync_upstream.ps1
```

預設來源是 `codex/btr-maintenance` 的已提交內容，與當前 checkout 分支無關。
未提交工作不會帶入候選，也不會被 stash、覆蓋或清除；先確認需要同步的 BTR 功能已 commit。
腳本輸出候選分支、工作樹與 `evidence/upstream-sync/<RunId>/sync.json`。
可以指定 `-RunId <唯一名稱>`；已有路徑、分支或標籤一律拒絕覆用。

腳本只 fetch 官方 `main`，不抓 tags、不 prune、不強制更新 ref；上游歷史改寫或 URL 不符時停止。
原版與來源祖先都必須保留。鏡像若正被 checkout 且需要前進，先停止，避免改動其他工作樹的分支。

## 2. 衝突及相容性處理

沒有衝突時自動建立 merge Commit；已包含上游時保留相同 Commit，仍建立隔離候選。
有衝突時回報 `CONFLICTS` 並保留候選的 index、MERGE_HEAD 與檔案；不自動選 ours/theirs。
Codex 必須讀三方版本、上游 diff、BTR 呼叫鏈與測試，逐檔解決，精確 stage 檔案並完成 merge Commit。
不要整檔覆蓋、降低內容身分驗證或重新設計傳輸架構。
解決後更新該 run 的獨立驗證報告；原始 sync.json 保留最初衝突結果。

尤其檢查：

- 多 Range 排程、同來源身分、CDN 候選與備援、音訊容量、Hedge／續傳／Seek 取消。
- `VideoDetailController` → `NetworkSource` → `PlPlayerController` → `BtrPlayback` 的影音候選與代理連接。
- 設定頁、播放器入口、監控 overlay、Hive 設定鍵與舊模式遷移。
- `AudioService.onTaskRemoved`、所有 PlaybackTaskScope、晚完成的播放器建立、BTR 清理與 Kotlin 共用 engine。
- Android DEV applicationId／名稱、loopback network security、既有簽章身分。

在候選工作樹執行，將 ref 換成 sync.json 固定的 SHA：

```powershell
pwsh -NoProfile -File .\tool\btr_verify_features.ps1 -BtrRef <sourceCommit> -UpstreamRef <upstreamCommit>
```

此檢查要求沒有上游改動的 BTR 檔案與來源相同，列出雙方修改的檔案供實際審查，並檢查關鍵接線。
它只是遺失功能的結構警報，不能取代程式碼審查、測試或 Android 驗收。

## 3. 準備候選工具鏈、測試與 APK

候選必須使用符合 `.fvmrc`、lockfile 與上游 CI patches 的 SDK。不得執行會改全域設定／重置 SDK 的上游 patch helper。
若輸入完全相同，可在候選工作樹重用本專案既有私有 SDK／Pub／Gradle cache：

```powershell
pwsh -NoProfile -File .\tool\btr_candidate_setup.ps1 -SeedRoot <本專案原工作樹絕對路徑>
$env:PUB_CACHE = Join-Path (Get-Location) '.toolchain/pub-cache'
$env:CI = 'true'
& .\.toolchain\flutter\bin\flutter.bat pub get --enforce-lockfile
pwsh -NoProfile -File .\tool\btr_test.ps1
& .\.toolchain\flutter\bin\flutter.bat analyze --no-pub --no-fatal-infos
& .\.toolchain\flutter\bin\flutter.bat test --no-pub test/btr/audio_task_removed_flutter.dart
pwsh -NoProfile -File .\tool\btr_build.ps1 -AndroidSdk <SDK路徑> -JavaHome <JDK路徑>
```

若所有鎖定套件已在快取，可用 `pub get --offline --enforce-lockfile` 避免不必要的 Git 套件網路取得；仍必須核對 lockfile 沒有改動。

`btr_candidate_setup.ps1` 先核對同一 Git repository、SDK 版本、pubspec／lock 與 patch 內容，再建立 junction、複製既有 DEV key。
重用的 SDK/cache 不得執行 patch helpers，也不要並行執行 Pub 或 SDK 修改。
輸入有差異時拒絕重用：改在候選 `.toolchain` 準備獨立 SDK/cache、依新上游 patches 做相容處理，維持既有簽章並記錄版本；不要覆蓋種子 SDK。
若 `flutter pub get` 因新的鎖定 Git 套件缺長路徑檔案而失敗，先查明，再用既有修復腳本只恢復缺失檔案，不升級依賴或修改全域設定。

僅在實際出現 `Unable to establish loopback connection`／`PipeImpl`／`UnixDomainSockets`／`Invalid argument: connect` 後，才使用既有 `-ShortIpcPath` 重跑到**新的日誌**。
該選項依候選路徑建立 `.ipc`，只對建置程序設定 `jdk.net.unixdomain.tmpdir`；不改 TEMP/TMP、JDK、hosts 或 Android source。
若候選路徑本身過長，使用較短、唯一的 RunId 建立新候選，不移動或刪除舊工作樹。

純 Dart runner 直接測候選 production source，HTTP 僅限 loopback Fake CDN。
runner 以 `--enforce-lockfile` 取得自己的測試依賴，避免每次同步順便升級測試套件。
Flutter/native 測試若在 cnativeapi 的 Windows MSVC 前置條件阻擋，須保留失敗日誌並列為 BLOCKED，不能聲稱全部測試通過。

建置產物位於候選自己的 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`。
用 Android build-tools 的 `aapt dump badging`、`apksigner verify --print-certs` 核對：
`com.example.piliplus.btr.experiment.dev`、僅 ARM64、有效簽章且 certificate 與既有 DEV APK 相同。
交付到唯一的 `build/btr-candidates/<RunId>/`，記錄 SHA-256、大小、source/upstream/candidate SHA、測試與實機未驗收狀態。
不得覆寫舊 APK；不得安裝、操作手機或自動執行實際 CDN／長時播放測試。

## 4. 完成、下次同步與回復

完成報告要分開列 Git 整合、功能保留、Dart、靜態分析、Flutter/native、APK 及實機驗收。
記錄 `git diff --check`、原分支/tag SHA 與舊 APK/key 雜湊保留情況。
有必要的相容性修正只 commit 在候選；工具改善可另外 commit 維護線，再以正常 merge 傳給候選。

候選保留供審查。**只有使用者明確接受候選後**，才在乾淨維護工作樹用
`git merge --ff-only <候選分支>` 前進 `codex/btr-maintenance`；如果無法 ff，先分析分歧，再正常 merge，不能 reset。
穩定分支的提升是另一個明確授權步驟，需保留原還原 tag 並確認實機驗收範圍。
在接受前若明確要接續某候選同步，可使用 `-SourceRef <候選分支>`，此動作不提升任何穩定 ref。

更新失敗時原版本仍在原分支，直接繼續使用原工作樹／既有 APK。
若要從還原點另建修復線，使用 `git worktree add -b codex/btr-recovery-<唯一名稱> <專案內新目錄> btr-pre-sync-<RunId>`。
候選及 evidence 保留；不刪分支／tag／Commit，不用 reset --hard、clean、force push 或自動 abort 清掉衝突。

同步腳本的本機安全回歸：`pwsh -NoProfile -File .\tool\btr_sync_tests.ps1`。
測試在 evidence 內建立獨立小型 Git fixtures，涵蓋無衝突、髒工作樹保留、重複同步、ref 不變、衝突保留與上游歷史改寫拒絕。

首次實際驗證另見 `BTR_UPSTREAM_RESULT_20261016.md`；歷史證據留在原位置。
