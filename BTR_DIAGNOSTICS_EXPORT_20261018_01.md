# BTR 診斷匯出候選 20261018-01

本候選只改善診斷取得方式；不代表高碼率播放瓶頸已歸因或改善。

- 基準：候選 07，`03804e1e619d9a49437cdee7b414a529041aa8e7`。
- 工作樹：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\diagnostics-export-1018-01`。
- 分支：`codex/btr-diagnostics-export-20261018-01`。
- 功能 commit：`e0c0a8aec99a78030087c1fa811b7f77be1c7f35`。
- Build ID：`btr-diagnostics-export-20261018-01`。
- 證據目錄：`evidence/diagnostics-export-20261018-01/`；未安裝、啟動或操作 Android 裝置。

## 1. 原始機制與歸因

原本設定頁以 `BtrPlayback.diagnosticReport()` 的 `JsonEncoder.withIndent` 結果呼叫 `Clipboard.setData`。程式中沒有約 20,000 字元的裁切，也沒有對 JSON 字串取前綴。每次工作階段的 `events` 原本位於 transport 欄位之前，長事件陣列會讓連線與軌道欄位出現在文字後段。

因此，剪貼簿、文字編輯器與貼上過程何處截斷仍為 **UNRESOLVED**；本次沒有把它認定為 JSON 序列化缺陷。

## 2. 完整 JSON 匯出

入口：設定 → BTR 功能設定 → **匯出完整診斷（JSON）**。

使用者點擊時才取得及序列化現有快照，立即凍結成 UTF-8 bytes。保留 `selectedSettings`、`current`、全部 `recent`、`units`、完整 metrics/transport、tracks、demands、錯誤與已保留事件；只把工作階段的 `events` 排到效能欄位之後。新增頂層 `schema`、`buildId`，空工作階段也可識別版本。原有欄位名稱、值與工作階段 schema 保留。

先檢查了鎖定依賴 `file_picker 13.1.0` / `android_file_picker 2.1.0`。其 Android 寫入會以 nullable output stream 寫檔，並回傳 `renamedUri.path`，遺失完整 content URI；無法可靠覆讀驗證。因此沒有修改共享套件快取，改用僅供此功能的原生通道：

1. Android `ACTION_CREATE_DOCUMENT` / `CATEGORY_OPENABLE`，MIME `application/json`，由使用者選擇目的地。
2. 只使用系統授予該文件的 URI 權限；沒有新增 manifest 儲存權限或持久 URI grant。
3. 原生背景工作以 `openOutputStream(uri, "wt")` 寫入、flush、close。
4. 重新開啟同一 URI，以 16 KiB buffer 核對全部 bytes 的數量及 SHA-256。覆讀超長、過短、同長度毀損、null stream、write/flush/close 失敗均不回報成功。
5. 通道只回傳 saved/取消、確認的 byte count 或固定錯誤代碼；不回傳路徑、URI 或原始例外。

取消、空間不足、核對失敗及一般寫入/覆讀失敗各有提示。檔名只包含 buildId 與 UTC 時間。工作線程只於選定文件後啟動，閒置 10 秒自動回收；沒有 HTTP chunk 序列化、背景記錄或新增播放器輪詢。桌面沿用既有 picker 並自行寫入、覆讀核對。

## 3. 精簡診斷

入口：**複製精簡診斷**。JSON 使用無縮排編碼，保留：

- schema/buildId、選定及工作階段設定、播放狀態、elapsed、起播、32 筆有界 Seek 時間、緩衝及錯誤統計。
- `networkBps5s`、`loopbackDeliveredBps5s`、分軌速率與流量、active/queued/concurrency/video/audio connections。
- 完整當前 `tracks`，包括實際 host、selection、identity 類型、demands/request/generation/stage/age/progress、ordered reservation、舊預取降優先狀態、health 與 terminal。
- Proxy Handler 使用量、上限、拒絕及本機回應錯誤，全部既有 request/terminal failures、retries、hedges、resumes、cancellations、eventsDropped。
- 當前 `nativeAvProbe`（audio-pts/time-pos/avsync/current-ao/current-vo/paused-for-cache 等）、音軌選取、原生錯誤分類及 first/last 摘要。

省略四份歷史 AV context：`previousNativeAvProbe`、`nativeAvBeforeCompleted`、`nativeAvAtFirstError`、`nativeAvAtLastError`。最近歷史先取最新一份；重複 Hedge/Resume/Retry、一般 demand 事件改為視窗統計，最多保留每份 session 最近 6 筆重要錯誤、Seek、重開/恢復、預取回收及傳輸異常事件。

`eventSummary` 明示其 counts 只代表尚未淘汰的事件視窗；累計量仍以原有 `hedges`、`resumes` 等計數為準，不以視窗統計冒充全工作階段統計。

大小策略以 **12,288 UTF-8 bytes** 為目標，超出時依序去除可選事件、歷史；沒有活動 session 時，保留最新已結束 session 作為主要證據。若未來關鍵快照本身仍超出，保留關鍵資料並設 `sizePolicy.exceeded=true`，不裁切字串。`omissions` 標示省略資訊並提示完整 JSON 匯出。

HTTP body 接收、loopback socket 交付及 native demux 輸入估計仍是不同口徑；沒有聲稱量到真正解碼量。原始模式/未知觀測維持 null 或原有欄位缺省。

## 4. 本機測試結果

| 驗證 | 結果與證據 |
|---|---|
| 純 Dart / 本機 Fake CDN 回歸 | **127/127 PASS**，`tests-final-02.log` |
| 一般、350 筆 Hedge/Resume 事件輸入、128 筆事件上限、8 次歷史、原始模式、空 session、已結束 session | PASS；完整 JSON 逐欄與原快照相等，記憶體上限不變 |
| 超過 20,000 字元的真實檔案寫入/覆讀 | **227,215 字元 / 227,225 UTF-8 bytes**；完整 parse、byte equality、編碼及檔案長度 PASS |
| 精簡版 | 樣本 **10,988 UTF-8 bytes**；tracks/CDN/連線/需求/效能欄位均保留，位於事件之前；超限策略及結構完整性 PASS |
| 實際處理中的本機 HTTP demand | 匯出保留真實 active/queued、CDN、Seek generation、stage、預留量；無 ETag 原文或 URL 洩漏 |
| Flutter 原生通道契約（隔離 harness） | **10/10 PASS**，長 UTF-8 payload、取消、空間不足、失敗、未確認回覆/錯誤 byte count；`flutter-channel-tests-final.log` |
| 正式 Kotlin I/O verifier JVM 測試 | **9/9 PASS**，120,017 bytes 真實檔案及 null/write/flush/close/truncation/corruption/trailing-byte 失敗；`verified-write-01.log` |
| 修改範圍靜態分析 | **No issues found**，`analyze-final.log`；`git diff --check` PASS |
| 完整 app Flutter/native 前置 | **BLOCKED，未進入案例**：既有 cnativeapi 缺 Windows MSVC；`flutter-app-native-test.log` |

初次新增的 HTTP 匯出測試把 fixture CDN 誤設為 origin host，與實際既有 ALI-OV 優選不符。已修正測試預期為既有選源政策；未修改選源實作。原始失敗保留於 `tests-final.log`。

隔離 Flutter 測試使用正式 exporter、Mock MethodChannel；JVM 測試使用正式 I/O verifier。它們不能代替 Android 系統 picker、provider、實際儲存空間不足及取消操作驗收。

重現命令：

```powershell
./tool/btr_test.ps1
./tool/btr_diagnostics_flutter_test.ps1
./tool/btr_verified_write_test.ps1 -JavaHome '<existing JDK>'
./tool/btr_build.ps1 -AndroidSdk '<existing SDK>' -JavaHome '<existing JDK>' -ShortIpcPath -BuildId btr-diagnostics-export-20261018-01
```

建置先實際遇到 Gradle `Unable to establish loopback connection`，後以腳本依工作樹推導 `.ipc` 及單程序 `jdk.net.unixdomain.tmpdir` 重試。未修改全域 TEMP/TMP、hosts、JDK 或工具鏈。SDK/cache 重用前核對版本、lock、34 份 Flutter/material patches 與 DEV key；沒有重新套 patch 或升級依賴。

## 5. 隱私、修改範圍與隔離

沒有新增敏感資料來源。快照仍只含 CDN host、固定分類/代碼、數值與受控輸出驅動名稱。完整及精簡 JSON 測試均確認原始簽名 URL、Cookie/Authorization、ETag 原文、原始 native error/裝置字串不洩漏；不讀取帳號或裝置識別碼。儲存 provider 的原始例外僅用於內部分類，不傳入 JSON 或 UI。

修改 13 個檔案：

- `lib/services/btr/diagnostics.dart`、`diagnostics_export.dart`：快照報告、精簡與 UTF-8 儲存接線。
- `lib/services/btr/playback.dart`：診斷組裝及事件順序；播放/Seek/close 邏輯不變。
- `lib/pages/setting/pages/btr_experiment.dart`：兩個操作、忙碌狀態與結果提示。
- `android/app/src/main/kotlin/com/example/piliplus/BtrDiagnosticsExport.kt`、`BtrVerifiedWrite.kt`、`MainActivity.kt`：SAF、覆讀驗證與 exporter plugin 註冊。
- `test/btr/diagnostics_test.dart`、`diagnostics_export_flutter.dart`、`demand_lifecycle_test.dart`：資料、通道及真實本機需求的診斷測試。
- `tool/btr_diagnostics_flutter_test.ps1`、`btr_verified_write_test.ps1`、`tool/btr_tests/verified_write_test.kt`：隔離且可重現的測試入口。

`metrics.dart`、`transport.dart`、`monitor_data.dart`、`network.dart`、`scheduler.dart`、`policy.dart`、播放器 controller、pubspec/lock 與 Android manifest 均未修改。沒有改變下載演算法、CDN、Hedge/Resume、Range/ETag/身分、Seek/EOF、解碼、Proxy/線程上限或緩衝/預取決策。

main、候選 07、其他既有候選、穩定分支及歷史 refs 保留；沒有占用候選 08，沒有 push、PR 或發布。APK/commit/source hashes 與保護檢查見 evidence 中的 manifests。

## 6. Android 待實機驗收

以下均為 **NOT RUN**：

1. 兩個新按鈕在真實 Android 畫面的布局、忙碌/返回行為，以及精簡 JSON 實際複製貼上完整性。
2. 系統文件選擇器開啟、位置/檔名選擇、取消、重複點擊、前後景及 Activity 重建。
3. Downloads/其他 provider 實際建立 `.json`，以使用者取得的檔案核對大小、UTF-8、JSON 結尾、tracks/CDN/連線/需求等資料。
4. 實際空間不足、provider 權限失效、寫入/覆讀失敗時提示，以及不出現成功提示的行為。
5. 播放中、原始模式、無工作階段及工作階段結束後的匯出；短程播放回歸需另行授權。

本次沒有進行長時間播放、真實 CDN 效能/壓力測試或裝置操作，既有播放/高碼率瓶頸歸因仍維持未驗證邊界。

## 7. APK 交付與核對

- 完整路徑：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\diagnostics-export-1018-01\build\btr-candidates\diagnostics-export-20261018-01\PiliPlus-BTR-diagnostics-export-20261018-01-arm64-v8a.apk`。
- SHA-256：`2dcb8734c77c0fc6e3e2c328518b06569e628d9a5ae0897ad56f9b8f8af42188`。
- 大小：24,526,203 bytes；ARM64；versionName 2.1.6 / versionCode 1；minSdk 24 / targetSdk 37。
- 套件：`com.example.piliplus.btr.experiment.dev`，label `PiliPlus BTR DEV`。
- 已從 APK 的 `libapp.so` 核對 buildId；DEX 亦包含正式 exporter 通道。
- 應用程式來源 commit：`e0c0a8aec99a78030087c1fa811b7f77be1c7f35`；`build-source.json` 記錄並驗證修改來源及核心檔案雜湊。
- 固定 commit 的最終增量建置通過（37.0 秒）；此前乾淨候選完整建置通過（635.8 秒）。日誌：`build-final.log`、`build-02-short-ipc.log`；最初 IPC 失敗保留於 `build-01.log`。
- APK v2 簽章驗證通過，憑證 SHA-256 `fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`，與候選 07 相同。
- APK 權限清單與候選 07 相同，無新增儲存權限。原件與交付副本雜湊一致。
- `libmpv.so`、`libflutter.so`、`libmedia_kit_native_event_loop.so`、`libmediakitandroidhelper.so`、`libcnativeapi.so`、`libdatastore_shared_counter.so` 六個函式庫與候選 07 整檔 SHA-256 一致。
- `libdartjni.so` 整檔雜湊不同。使用既有 NDK LLVM 工具在 evidence 副本核對：`.text`、`.rodata` 完全一致；只移除 `.note.gnu.build-id` 後整檔 SHA-256 相同，確認差異僅是 ELF 建置識別區段。沒有修改 APK 內的原件。證據：`dartjni-comparison.json`、`native-library-comparison.json`。
- `preservation.json` 確認既有 refs、候選 07 APK、11 個核心檔案不變，其他工作樹均保持原 HEAD 且乾淨。

交付 metadata：APK 同目錄的 `artifact.json`；完整核對結果：`evidence/diagnostics-export-20261018-01/artifact-verification-final.log`。首次嚴格整檔比對的 JNI 差異亦保留在 `artifact-verification.log`，沒有刪除失敗證據。
