# 分離來源官方上游同步驗證（2026-11-06）

狀態：`LOCAL_UNACCEPTED_CANDIDATE`。候選分支 `codex/btr-update-up-1106-03`，工作樹為 repository 根下 `.btr-wt/up-1106-03`。應用程式與工具實作 Commit 為 `0e5e30bc1f7e66c5dc552aaf2a78cebb9c83ff21`；後續報告提交不更換 APK 的建置來源。

## 官方來源與所有權

- 來源分離 parent：`fdfdd4b2c77e78420ed7a35ddf96600d16ff75a7`。
- 舊官方：`d680e3f95cf777ff20492dd2a23c89264481dca0`（2.1.6+1）。
- 本次重新 fetch 官方 `main` 後選定：`d0e03529b6938aeb9aa290fcf6ba58d4e93a537a`（2.2.0+1）。官方來源為 `https://github.com/bggRGjQaUbCoE/PiliPlus.git`。
- `PiliPlus/` 的 1,665 個 blobs、完整清單及 Git tree **`2205c3d9d14cc17ee3e553316648e48f2a6d56fe`** 與選定官方 commit 的根 tree 完全相同。
- merge commit 的兩個 parent 分別為原來源分離 commit 及選定官方 commit，保留雙方祖先。
- `BTR/` 55 個檔案與 `integration/overlay/` 8 個檔案，均與來源 parent 完全相同。16 份整合 patch 中，7 份因官方接點變動重新審查，其餘 9 份未更動。
- 最終組合為 `.assembled/build/`，共 1,744 個檔案，fingerprint：`47e4a39b3ebb985aa9fcd6060dfd846da850db46e4efadbb8b07dc3e7fd30ae9`。`verify --baseline` 不適用新版；manifest 中舊 behavior/APK baseline 只保留歷史識別。

## 整合適配

同步工具先停在 `INTEGRATION_REVIEW_REQUIRED`，保留 MERGE_HEAD、舊 patch 與新官方來源。7 個目標逐一比較舊官方、新官方與既有 BTR 整合；以原 patch 實際套用驗證三方審查的 BTR side，再處理 8 個衝突區塊，從新官方與審查後結果產生 patch。沒有只更換 base blob 略過驗證。

| 接點 | 保留與適配 |
| --- | --- |
| 音訊 controller | 保留 task scope／acquire／有序 dispose；接納上游音量限制、音訊焦點與 await open/play，在新非同步邊界核對 task 及播放器 owner。 |
| 影片 controller | 接納上游 season／API 變更，完整保留 DASH representation 選定後、CDN 改寫前的影音候選擷取與手動來源清除。 |
| 播放器 controller | 接納 orientation、desktop PiP、hover、controls 與 capped volume；保留私有 BTR part、source queue、Seek intent、native stop → retire GET → reopen、故障代次與 scope 清理。新增音量初始化位於原生建立的 try/dispose 範圍內。 |
| 播放器 view | 接納新版 episodes、adaptive danmaku、背景 pause/play 接點及動畫；保留 IgnorePointer 唯讀監控。 |
| AudioService handler | 接納新版 Android 音量鍵條件、isPlaying 及 live notification actions；task removal 清除新 callback，customAction 同樣受 task-removed gate 保護，保留 closeAll／idle／native stop。 |
| pubspec／lock | 採用官方新版的完整依賴 pin，BTR patch 只補原 test_api 0.7.12／matcher 0.12.20 的直接測試依賴。locked resolution 通過，沒有任意升級或放寬 constraints。 |

工具鏈為候選專用 Flutter 3.47.9（`c197ca5199e9ee5661e865596c9c07294dfab51c`）、Dart 3.13.7，獨立 pub／Gradle cache，沿用既有 DEV signing key。版本與 lock 不同，未透過共享 junction 修改種子。25 份 Flutter 與 9 份 Material patches 均實際反向檢查通過，沒有 skipped paths。

修正 `tools/legacy/btr_prepare.ps1` 的巢狀工作目錄定位：舊命令在 assembled app 內可能跳過 Material patch 卻 exit 0；現在明確指定私有 package work tree 與 SDK Git metadata，只套用 patch，不改 index/ref。新的 `tools/test_upstream_lifecycle.py` 擷取實際組合後方法，用正式 PlaybackTaskScope 及 mock native/session 驗證新的非同步接點。

## 已完成驗證

證據集中於 `evidence/upstream-20261106-03/`。

| 項目 | 實際結果 | 證據 |
| --- | --- | --- |
| 官方 Git tree、逐檔 blob、完整來源及組合 | PASS，1,665 官方／1,744 組合檔案 | `source-verification.json`、`compose-final.log` |
| BTR 核心、Fake CDN、安全、Hive 設定、Seek／來源／生命周期回歸 | 169/169 PASS | `core-tests.log` |
| 專屬設定頁／診斷 channel 隔離測試 | 13/13 PASS | `settings-tests.log` |
| 新上游音訊／通知生命周期接點 | 12/12 PASS；mock 原生合約 | `upstream-lifecycle-tests-02.log` |
| Kotlin 正式寫入覆讀驗證 | 9/9 PASS；未執行 Android picker/provider | `verified-write.log` |
| 來源組合保護 | 11/11 PASS | `composition-tests.log` |
| 既有同步安全 | 19 assertions PASS | `legacy-sync-tests-02.log` |
| 分離同步、安全停止與相同 pin 重複同步 | 3/3 scenarios PASS | `separated-sync-tests-02.log` |
| Flutter analyze（lib、test） | 0 errors、0 warnings、39 info；exit 0 | `analyze.log` |
| 分析診斷與來源分離版比較 | 無新增診斷，原 40 info 減為 39；移除上游 unnecessary_lambdas 一項 | `analyze-comparison.json` |
| SDK／Material patch 實際套用 | 34/34 reverse checks PASS，無 skipped path | `toolchain-patch-verification.json` |
| 完整 AudioService Flutter/native | **BLOCKED**：cnativeapi 0.5.10 在案例前因缺少 Windows MSVC cl.exe 無法建立 native assets | `native-tests.log` |
| ARM64 DEV APK | PASS；aapt／apksigner／SHA-256 核對通過 | `build-02.log`、`apk-badging.log`、`apk-signature.log` |

初次 Git ref／fixture 操作受 sandbox 限制，獲准本機程序執行後完成；首次新增 lifecycle harness 的方法擷取不完整，修正 harness 後 12 個案例通過。初次 Material helper 的 skipped-path 問題已修正並驗證實際 patch。各輪原始日誌保留，不宣稱初次整輪全綠。沒有以隔離 harness 或 APK 建置代替完整 native 驗證。

## APK

- [ARM64 DEV APK](build/btr-candidates/upstream-separated-20261106-03/PiliPlus-BTR-upstream-separated-20261106-03-dev-arm64-v8a.apk)。
- Build ID：`upstream-separated-20261106-03`；建置來源：`0e5e30bc1f7e66c5dc552aaf2a78cebb9c83ff21`。
- 大小：**25,374,814 bytes**。
- SHA-256：**`4172d5105410776da7b37e678c97340a83bb6ae810aa9bf8b4d7b3d624da6a20`**。
- package：`com.example.piliplus.btr.experiment.dev`；label：`PiliPlus BTR DEV`。
- versionName：`2.2.0`；versionCode：`1`；ABI 僅 `arm64-v8a`；minSdk `24`；targetSdk／compileSdk `37`。
- APK v2 signature 驗證成功，單一 signer；DEV certificate SHA-256：`fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`，與既有 DEV 身分一致。
- [artifact.json](build/btr-candidates/upstream-separated-20261106-03/artifact.json) 保存來源／官方 commit、fingerprint、大小、SHA-256 與未接受狀態。`BTR_DEVICE_TEST=true` 只作診斷編譯，沒有裝置操作。

首輪 build 的 Windows Gradle `Unable to establish loopback connection` 保存於 `build-01.log`。依 AGENTS.md 以 `-ShortIpcPath` 使用此組合專案內的 `.ipc` 後，第二輪 Gradle 500.2 秒成功；沒有更改 TEMP/TMP、hosts、JDK、Android source 或依賴版本來處理 IPC。建置仍有上游外掛 compileSdk、KGP 遷移與 Java deprecation 提示；Flutter 靜態分析的 0 errors／0 warnings 結果另列，不混為無任何建置訊息。

保留最終 `.assembled/build/` 與獨立工具鏈、候選 APK 及全部驗證日誌。已辨識的一次性三方比對、測試 fixture、舊組合、失效 plugin links 與重複 APK 另有清理收據；未清理歷史工作樹、既有 APK／evidence 或共享種子。完整證據入口為 `evidence/upstream-20261106-03/validation.json`。

## 保留界線

`codex/btr-separated-20261106-01` 保持 `fdfdd4b2c77e78420ed7a35ddf96600d16ff75a7`；`codex/btr-accepted` 保持 `184c1fe8ea5649593d0dcedda1b420e101bcc2b4`；`codex/btr-stable` 保持 `790e357f661b935b5eb064d9affa54279b0c51a9`。既有根工作樹修改／未追蹤內容、歷史工作樹、tags、APK 與 evidence 保留。

沒有放寬 8 HTTP 回應／4 執行槽／16 上游請求、Range／ETag、HTTPS、MCDN/P2P、單來源固定或清理保護。沒有改 Hive keys／使用者資料、BTR 傳輸演算法、CDN 策略或來源分離架構。

本候選未接受、未提升 stable，未 Push、未建立 PR、未發布、未安裝 APK、未使用 ADB 或操作 Android 裝置。真實 CDN、實機播放／Seek／音畫、長時性能、SAF 與原生／GPU 資源上界沒有在本次驗證，既有 UNRESOLVED 繼續保留。
