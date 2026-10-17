# BTR 播放修復候選（2026-10-17）

## 範圍與狀態

- 基準：`codex/btr-maintenance` / `a86c5daae6f614485f5b4542ceea13eb68c70729`，開始時追蹤及未追蹤 Git 狀態皆乾淨。
- 獨立分支：`codex/btr-playback-fix-20261017-02`。
- 修復程式 Commit：`0dee107ca8c45ac0a4299cc34a0a4b32ac1d0ca9`；交付報告另以後續本機 Commit 保存，程式不再變更。
- 獨立工作樹：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1017-02`。
- 既有維護／穩定／功能分支、tags、舊候選、APK 及歷史 evidence 留在原位；沒有同步上游、升級依賴、推送或 PR。
- **這是本機程式與 Fake CDN 驗證的修復候選。三項 Android 使用者症狀的完整原因及實際修復效果仍為 UNRESOLVED / NOT RUN。**

## 確認的缺陷與修復

### 1. 自然 EOF 後回拖只有 Seek，沒有恢復播放意圖

鎖定的 media_kit `73771ec38176be2d984a3049c28177bce23b54a0` 設定 `keep-open=yes`。其 native Seek 在內部鎖中送出命令並清除 completed，沒有自動 play。既有控制器回拖只呼叫 Seek，`seekTo()` 在已知 duration 時也沒有等待它完成。

[mpv keep-open 文件](https://mpv.io/manual/stable/#options-keep-open) 說明預設 EOF 會暫停；[keep-open-pause](https://mpv.io/manual/stable/#options-keep-open-pause) 預設為 yes。這支持 EOF 後只有 Seek 不保證繼續播放；**沒有把未 await 推斷為 native 命令必然亂序，因為鎖定實作本身已序列化命令**。

修復以小型 `PlaybackSeekIntent` 保留明確的播放／暫停意圖：等待 Seek，僅最新且仍屬目前來源的 EOF 回拖可恢復播放；使用者暫停、新 Seek、新來源及關閉會使舊恢復失效。暫停狀態維持暫停。`seekTo()` 的已知／尚未取得 duration 路徑都等待實際 Seek 或取消；舊 duration 監聽不會把舊 Seek 套到新來源。原始模式的播放中 buffer 同步保留，但有 250 ms 上限，EOF／暫停不等待可能永不再發出的 buffer 事件。

### 2. Seek／重疊 GET 無條件取消有效影音回應

基準 `BtrTransport.seek()` 取消 video/audio 所有需求；每個新同軌 GET 也取消前一個 GET。[mpv cache 文件](https://mpv.io/manual/stable/#options-demuxer-seekable-cache) 說明快取內 Seek 可不觸發底層 demux Seek。故收到 Seek 通知不能視為 mpv 已捨棄 HTTP 回應；新 GET 也不能證明舊 GET 已不再使用。

本機雙軌 Fake CDN 測試實際重現：舊有效 Range 被截斷／502；沒有 replacement GET 的快取 Seek 使影音都失去目前回應。修復把每個本機 HTTP 需求的生命週期分開，依 peer disconnect、正常完成、session close 或不可恢復錯誤取消。Seek 只更新診斷世代，不主動截斷 mpv 仍可能使用的串流。

重疊需求共用原有**每軌合計 4 MiB**有序視窗，沒有把限制乘上需求數。每個需求只等待自己的分塊清理；session close 仍等待全部工作、排程與 HTTP handler。

### 3. 可恢復 upstream／本機寫入錯誤永久毒化軌道

基準 `BtrTrack.serve()` 把 upstream 與 localhost flush/close 錯誤放在同一個 catch，非取消錯誤都設 terminal。Fake CDN 已重現：本機 flush timeout 或暫時 503 耗盡單次重試後，後續正常精確 Range 仍被拒絕。

修復區分 discovery、upstream、proxy-write、proxy-close。可恢復的本機輸出失敗只結束該 HTTP 需求；upstream 的 timeout、連線中斷、body-short、408／429／5xx 仍受單塊原有三次嘗試／25 秒期限限制，後續 GET 可在**同一已鎖定來源與身分**恢復。連續三個耗盡的需求就終止，成功完整 GET 才清除此計數；HEAD 不清除預算。attempt/piece deadline 與真正取消分開記錄。

HTTP 412、來源身分／ETag、Content-Range、編碼矛盾與 body-overrun 等錯誤仍立即終止，不使用此恢復途徑。任何音／影軌終止後，控制器一次性標記錯誤、暫停並釋放該 session 的兩軌資源；禁止同來源 autoplay／refresh 再開啟已終止的代理，不無限重試。

### 4. 來源初始化競爭可能清掉新播放器的 surface／listeners

基準 `PlaybackTaskScope.acquire` 處理生命週期，不序列化初始化。兩次 `setDataSource()` 可以同時看到沒有 player；`_initPlayer()` 在 stale generation 檢查前修改共享 VideoController／listeners，舊初始化清理便可能清掉新初始化的共享欄位。

此項以實際程式交錯分析及 baseline ownership 語句模型確認，**不是 native/mpv 執行重現，也沒有證明它就是本次裝置無聲的原因**。新增小型 `PlaybackSourceSequence`，來源準備、native player/surface 建立、open、舊資源釋放與初始化採同一擁有權序列；跳過被較新選擇取代的排隊來源。開啟期間的最新明確 play/pause 意圖優先，舊初始化／錯誤回呼不能覆蓋新選擇。

來源變更也取消舊重試計時器。既有 refresh 在來源準備中／來源已失效／軌道已終止時不重開，重開時沿用當前 play/pause 意圖，避免舊的 `open(play:true)` 再次覆蓋暫停。

保留現有 DASH 影音候選與 EDL 獨立音軌、audio-only、音訊 filter、codec 及輸出設定。未發現足以確認「選錯音訊 URL」或 Android audio output／解碼器故障的現場證據。

## 保留的傳輸與模式契約

- 原始 PiliPlus 不建立 BTR 代理；正常來源選擇、EDL、codec／音訊輸出與裝置設定未改。
- 多線程、自動線程／手動設定、CDN discovery／備援、音訊保留容量、Hedge、強 validator 的同來源續傳皆保留。
- scheduler／adaptive／network／policy／settings 未修改；保留既有連線／handler／Hedge 與記憶體限制。
- 不降低 Range、Content-Range、ETag、實際來源身分、MCDN/P2P 過濾，不跨 CDN 分塊拼接。
- 診斷保留既有 128 事件與 32 Seek 上限，只增加需求階段／錯誤分類及原生音軌數／選取／mpv 音量觀測；未知值為 null。不保存原生錯誤全文、URL、query、ETag、軌道標題或裝置名稱。觀測值不代表可聽聲音、解碼畫面或 A/V sync 驗收。
- 序列化會等待已經開始的 native future 完成，沒有用任意 timeout 後強制 disposal 來引入另一個競爭；native 本身永不返回的情況仍未確認。

## 驗證與交付

| 驗證 | 本次結果 | 證據（`evidence/playback-fix-20261017-02/`） |
|---|---|---|
| 基準傳輸重現 | 4 個預期 RED：重疊 GET、無 replacement GET 的 Seek、本機 flush timeout、暫時 503 耗盡後無法接受新 Range | `transport-baseline-red.log` |
| 基準 Seek 方法擷取 | 預期 RED：Seek Future 提早完成、completed Seek 後保持 paused；精確擷取基準方法，native 是 Fake contract | `baseline-seek-extraction.json`、`.log`、`reproduce-baseline-seek.ps1` |
| 純 Dart／Fake CDN 全部 | **89/89 PASS**：原有 58 項，加 11 需求／期限／412、12 Seek／意圖、6 source ownership、2 隱私診斷 | `tests-final-02.log` |
| 所有修改的 Dart／BTR tests 分析 | **0 issues** | `analyze-changed-final.log`（exit 0，無診斷輸出） |
| 全部 app／tests／pubspec 分析 | **0 errors / 0 warnings / 37 infos**，既有 app 提示保留 | `analyze-app-final.log`、`analyze-app-summary.json` |
| 包括忽略的 evidence 模型之整目錄掃描 | 0 errors / 1 warning / 45 infos；其中 1 warning 與 8 infos 僅來自本次擷取／ownership 模型，app 與 tests 無新增問題 | `analyze-final-02.log`，原始 exit 1 保留 |
| Flutter/native AudioHandler | **BLOCKED，未進入案例**：cnativeapi 在 Windows x64 找不到 MSVC C compiler | `flutter-native-test.log` |
| Git whitespace | **PASS** | `git diff --check` |
| 基準保留 | **PASS**：161 個既有 branch/tag refs 與 9 份舊 APK、DEV key、Git config、lock 不變；主工作樹仍乾淨且為 `a86c5daae` | `before.json`、`preservation.json` |
| Android ARM64 DEV APK | **PASS**；固定程式 Commit 後重建 12.7 秒，package／ABI／v2 簽章／原 DEV certificate／原件副本雜湊皆核對通過 | `build-dev-03-pinned.log`、`apk-badging.log`、`apk-signature.log`、`old-dev-signature.log`、`build-source-pinned.json` |
| Android／真實 CDN／聲音與畫面／長時 | **NOT RUN / UNRESOLVED** | 授權及驗收邊界 |

建置第一次在 Gradle 出現 `Unable to establish loopback connection`；保留 `build-dev-01.log` 後，才使用工具依候選根目錄推導的 `.ipc` 與建置程序專用 `JAVA_TOOL_OPTIONS=-Djdk.net.unixdomain.tmpdir=...`。沒有變更 Windows TEMP/TMP、全域 Git、JDK、hosts、Android source 或 dependencies 來處理 IPC。第一輪靜態分析的修補期錯誤／日誌亦保留；最終結果以表內指定檔案為準。

交付 APK：

`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1017-02\build\btr-candidates\playback-fix-20261017-02\PiliPlus-BTR-PlaybackFix-2.1.6-dev-arm64-v8a.apk`

- SHA-256：`c09f30783e4d857a84bd8b1980b296a1d8c761af76ffcae62b133361a07c67a3`。
- 大小：24,485,559 bytes；applicationId `com.example.piliplus.btr.experiment.dev`；label `PiliPlus BTR DEV`。
- ARM64 only；versionName 2.1.6 / versionCode 1；minSdk 24 / targetSdk 37。
- v2 signature 驗證通過；certificate SHA-256 `fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`，與原 DEV APK 相同。
- 同目錄 `artifact.json` 記錄修復 Commit、六個 production Dart 檔案的固定雜湊與驗收邊界。固定後建置前後逐一核對檔案雜湊不變；最終交付副本與 build 原件相同。
- 原始模式、Range/identity、Hedge/續傳及清理的證據是本機測試；APK 的 package/ABI/signature 證據只證明封裝，沒有代替 Android 播放驗收。

## Android 仍需確認

1. 自然 EOF 後快取內／快取外回拖、連續回拖，以及回拖期間暫停／恢復／切來源；確認畫面、聲音與 UI 狀態一致。
2. 分離 DASH 影音、audio-only、畫質／音訊切換、背景／前景與音訊焦點；確認可聽音訊及 A/V sync。
3. 真實網路暫停／恢復、CDN 退讓及解碼器緩衝；確認可恢復錯誤後的 native 重連／重新緩衝，以及終止錯誤的明確錯誤狀態。
4. Android codec／硬體解碼、audio output、真實畫面凍結及長時資源行為仍無現場證據，保持 UNRESOLVED。沒有以 Fake CDN、測試或 APK 建置宣稱修復全部實機無聲／凍結問題。

本次沒有安裝、ADB／手機操作、真實 CDN 壓力或長時實機播放；也沒有提升穩定／維護分支。
