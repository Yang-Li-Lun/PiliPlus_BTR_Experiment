# BTR 播放可靠性候選 06（2026-10-17）

候選 06 修復三個可在本機重現的恢復狀態缺陷，並補充有界的原生影音診斷。**Android 畫面凍結、無聲及音畫同步仍為 UNRESOLVED，未宣稱已完全解決。**

## 版本與調查來源

- Worktree：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1017-06`。
- 分支：`codex/btr-playback-fix-20261017-06`。
- 基準：候選 05 `103a207e7612f72e2ebb2bfbfb678a054bdb3955`；開始時工作樹乾淨，目標 06 路徑與分支均不存在。
- 程式 commit：`a8997270d830f47be9bc1c86800e3493ab283fc0`；交付文件另以後續 commit 保存。
- buildId：`playback-fix-20261017-06`；程式檔案 SHA-256 固定於 `evidence/playback-fix-20261017-06/build-source.json`。
- 實讀 AGENTS.md、BTR_UPSTREAM.md、tool/btr_upstream.json、BTR_EXPERIMENT.md、05 production source、04 調查報告及 05 evidence 的 before/build-source/artifact/closeout/user-observations。05 的結果 Markdown 實際只有空白，沒有用它推導缺失的診斷內容。
- 本次使用者補充的「音軌選取、volume=100、未靜音、audio-pts 持續前進」另存 `user-observations.json`。05 既有摘要中的較早 session 是 audio-pts 不動，兩者不混為同一次故障。未存取裝置，未取得新的原始 Android/mpv log。
- 本機實讀候選 05 APK SHA-256：`8c9dac9f6c2e26b84f976a3f477f5f9348592a516824c74bbc5a35fb04d480c7`；與既有 artifact 記錄一致。

## 已確認及修復的本機缺陷

### 1. 開啟期間的讀取錯誤可能失去後續恢復機會

`_handleBtrNativeError` 能保存已分類的 HTTP/native read failure，但 `_scheduleBtrReadRecovery` 在 `_processing` 或 `_reopening` 期間直接返回。開啟結束後，既有 meter 只經由需要代理失敗時間的 stall 判斷重試；若只有 native read error 與異常 EOF、沒有後續 proxy failure，就可能永久保留異常完成狀態而沒有恢復排程。

修正：既有 500 ms BTR meter 在開啟結束後，重新檢查已鎖存的讀取失敗，且僅在仍要求播放、持續等待或有待確認 Seek 時安排原有三秒計時器。仍要求已分類的讀取證據；未知錯誤、單純時鐘不動、單純音量／音軌狀態都不能觸發重開。

### 2. 非 Seek 的已排隊恢復可能卸載已恢復的播放

原計時器在送入來源操作序列前檢查 read revision，但 `refreshPlayer` 等待序列期間的播放進展，只對 recoverSeek 路徑有較窄的失效檢查。非 Seek 恢復已排隊後，即使播放重新前進、讀取證據被 reset，仍會執行 stop/open 並消耗自動預算。

修正：自動 BTR 恢復在取得操作序列後、執行 stop 前，再核對保存的 read revision。等待期間的實際進展會使此操作失效；不卸載播放器、不消耗恢復預算。原有來源、最新 Seek 及暫停意圖保護繼續生效。

### 3. 一次恢復用盡後，僅有原生讀取錯誤的持續等待無法走到停止清理

原 `_checkBtrReadStall` 即使已知 `readRecovery.failed`，仍要求 `currentReadFailureAt` 才能走到恢復預算耗盡分支。native 已回報明確讀取失敗，但 proxy 沒有另發證據時，可能繼續等待而不結束。

修正：沿用 15 秒位置不動且持續等待的界線，接受尚未被新 Seek、load 或實際進展清除的已分類讀取失敗。預算用盡後走既有暫停／關閉 transport／錯誤狀態，沒有第二次自動重開。只有代理證據時仍沿用原世代及時效限制。

### 修復前後證據與限制

`recovery-baseline-red-02.log` 在未修改的 05 production controller 上，三個新增情境分別失敗：opening-time native failure was never reconsidered、queued recovery unloaded recovered playback、native-only exhausted recovery waits forever。原有情境通過。

修復後 `recovery-green-01.log` 及 `tests-final.log` 對應情境全部通過；另驗證延後錯誤在暫停、reset、新來源、task close、重新前進後不會誤重開。

控制器契約測試擷取實際 production methods/listeners 與鎖定 media_kit 的 log→error dispatch，對確定性 native stub 發事件；其中既有案例也經過真實 localhost 阻塞 socket、有限 503、stop→退休 GET→雙軌逐 byte reload。**這不是執行 mpv ABI、解碼器或 Android 音訊輸出。** 這三項缺陷尚未與使用者實機故障建立同一次事件的因果關係。

## HTTP、排程、Seek 及原生影音調查

| 範圍 | 實讀結果與本次處置 |
|---|---|
| HTTP／Range／身分 | 保留嚴格 206、精確 Content-Range／body 長度、identity encoding、完整 URI／總長／strong ETag、If-Range 及 redirect 拒絕；未修改 network.dart、policy.dart 或 transport.dart |
| 並行／優先權 | 原共享連線上限 16、音訊保留容量、每軌 4 MiB、有界 Hedge／重試及舊預取回收均未改動；沒有增加線程或放寬容量 |
| GET／Seek 生命週期 | 舊 GET 可繼續被 native 消費；Seek 通知本身不取消有效 GET，退休仍須先 stop 並等待 producer／handler 清理；較舊世代的失敗不得冒充當前 Seek 證據 |
| 選源／CDN | 保留合格候選競速與備援，分段／續傳／Hedge 仍固定在已驗證的同一來源；未引入跨 CDN 拼接 |
| media_kit／mpv | 依鎖定 commit `73771ec38176be2d984a3049c28177bce23b54a0` 檢查 error/log dispatch、play 的 completed→零秒重播分支、property getter 及預設 network-timeout=5。Proxy 的有限上游等待可長於此原生 timeout，但沒有本次實機對照證據證明它造成無聲或凍結，因此未延長 timeout 掩蓋問題 |
| Android 音訊／影片整合 | `_initPlayer` 沿用 Pref.audioOutput、video-sync、volume；EDL 雙軌、audioFilterExtras、AudioSessionHandler 的焦點／中斷行為、Kotlin lifecycle 與 media_kit native library 均沒有程式修改。沒有證據支持改 codec、AO backend 或強制重新取得焦點 |
| 原始模式 | 所有新增恢復判斷須有 BTR transport；新增原生 probe／log observer 沿用 BTR attach guard；原始模式既有 bypass 與 controller 契約測試通過 |

503 表示當時代理拒絕或上游錯誤的觀察，timeout 表示某階段等待超時；兩者不是 Android 聲音輸出失敗的證明。畫面凍結可能涉及傳輸、demux、解碼或顯示；無聲也可能在不同層發生，目前不指定共用根因。

## 僅補充有界診斷的部分

`metrics.dart` 在原有 BTR 500 ms meter 增加 `time-pos`、`avsync`、輸入音訊採樣率、decoder/VO drop counters、`vo-configured`，以及 allowlist 的 `current-ao`／`current-vo`。每筆固定 18 個欄位；未知、不支援、NaN／Infinity／例外均保持 null。driver 僅接受固定名稱，包含字串 `null` backend，與未觀測的 JSON null 分開。

保留目前／前一筆、EOF 前、第一／最後 native error 的固定快照；不新增時間線歷史或計時器。錯誤來源可辨識 `ao/aaudio`、`vd/ffmpeg` 等子 namespace，但只存固定父類別。media_kit 的 unregistered MPV reply 僅以受控代碼計數，不保存 ID，也不拿它觸發網路恢復。沿用最近 8 sessions、每次 128 events、32 Seek 上限。

這些欄位有助於分辨讀取／解碼／輸出狀態；`current-ao`、audio-pts、VO 設定或掉幀數仍不能證明實際可聽聲音、Android Surface 畫面持續更新或音畫同步。屬性語義以 [mpv 官方 properties](https://mpv.io/manual/stable/#properties) 為依據，實際 Android bundled mpv 的支援度仍待驗證。不保存原始錯誤字串、完整媒體 URL、簽名、Cookie、Token、ETag 內容、裝置名或軌道標題；注入敏感字串的回歸驗證通過。

## 驗證

| 項目 | 結果 |
|---|---|
| 候選 05 原始基準 | **109/109 PASS**，baseline-tests.log |
| 修改後純 Dart／Fake CDN／localhost | **111/111 PASS**，tests-final.log；包含 32 個 controller 子情境 |
| 影音雙軌／Range／Seek／取消／恢復 | 原有實際 localhost 測試全數通過，包含不同影音 bytes、來源身分、錯誤資料拒絕、音訊容量、Hedge／續傳、重疊 GET、stop／task close 清理 |
| 修改五檔 analyze | **No issues found**，analyze-changed-final.log |
| 全專案 analyze | **0 errors / 0 warnings / 37 既有 infos**，與 05 逐項相同，analyze-app-summary.json |
| Flutter/native | **BLOCKED，未進入案例**：cnativeapi Windows native asset 缺少 MSVC，flutter-native-test.log |
| 工具鏈 | 相同 .fvmrc／lock／patch 輸入才重用既有 SDK/cache；Flutter 3.47.7 / Dart 3.13.5；25 個 Flutter、9 個 material_ui 正確目標 reverse checks 通過。未執行 patch helper／升級依賴 |
| Git whitespace | git diff --check 通過 |
| ARM64 DEV／package／簽章／AOT buildId／hash | **PASS**，234.2 秒；ARM64 only、DEV package、v2 簽章有效、certificate 與 05 相同；AOT 可讀到本候選 buildId，建置原件／交付副本與來源 pin 核對通過 |
| Android 音訊／畫面／Seek 實效／A/V sync | **NOT RUN / UNRESOLVED** |
| 安裝、操作裝置、真實 CDN、長時播放或網路壓測 | **NOT RUN** |

首次 build-01 實際遇到 `Unable to establish loopback connection`，保留日誌後才使用 `-ShortIpcPath`，依本候選位置建立 `.ipc` 並僅為該程序設定 jdk.net.unixdomain.tmpdir。未修改 TEMP／TMP、hosts、JDK、Android source 或依賴來處理 IPC。SDK patch 初次探索將非 Android／material patches 也拿到 Flutter root 檢查，不能作為缺 patch 證據；正式正確目標結果在 sdk-patch-check-correct-targets.json。

## APK 交付與保留

APK：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1017-06\build\btr-candidates\playback-fix-20261017-06\PiliPlus-BTR-PlaybackFix-20261017-06-dev-arm64-v8a.apk`

- SHA-256：`f04dc9671f0ad597b1d8c946c5f27436000dd803fca06a27d4758c5c4b6014a7`。
- 大小：24,513,651 bytes。
- buildId：`playback-fix-20261017-06`，已在編譯後 `libapp.so` 找到；來源 commit 與五檔 SHA-256 在 build-source.json，建置前後一致。
- package：`com.example.piliplus.btr.experiment.dev`，label：`PiliPlus BTR DEV`；versionName 2.1.6 / versionCode 1；minSdk 24 / targetSdk 37；只有 arm64-v8a。
- v2 簽章有效；certificate SHA-256：`fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`，與實讀候選 05 相同。
- 獨立核對證據：artifact-verification-final.log、apk-badging.log、apk-signature.log、previous-apk-signature.log；交付資料在 APK 同目錄的 artifact.json。

另外比較 APK 的七個非 AOT 原生函式庫：libmpv、libflutter、media_kit event loop/helper、cnativeapi、datastore 共六個 SHA-256 完全相同。libdartjni.so 的 SHA-256 不同，進一步逐 byte／ELF sections 核對發現，131,400 bytes 中只有 `.note.gnu.build-id` 的 20 個 GNU build-id bytes 不同，其餘整個 ELF（包括 code/data）完全相同。沒有修改、替換或正規化 APK 內的 library；原始雜湊及區段比較保留於 native-library-comparison.json、jni-section-comparison.json，不能把該檔原始 SHA-256 宣稱為相同。這個 GNU build-id 與 BTR_BUILD_ID 是兩個不同概念。

preservation.json 核對 **166 個其他既有 branch/tag refs、29 份舊 APK、候選 05 HEAD／乾淨狀態、維護工作樹狀態、DEV key、pubspec.lock 與 Git config 均不變**。toolchain-preservation.json 核對共享 SDK tracked state／diff 與 media_kit tracked state 不變。只在候選 06 提交五個修復／測試檔及本報告；Git 身分使用與既有 commit 一致的程序級 `-c`，未改 Git 設定。未修改 main／穩定分支、改寫歷史、推送、建立 PR 或提升穩定版。

## 未解決事項與後續實機驗收

1. Android 上畫面凍結、無聲、Seek 後的視聽恢復及 A/V sync 均未驗收；三項本機修復不能替代這些結論。
2. audio-pts 持續推進而無聲的那一次故障，仍缺 Android AO／AudioTrack／AAudio 實際輸出、音訊焦點／route 及同時原生解碼證據；未擅自改輸出策略。
3. 凍結時是否原生讀取已停止、是否僅畫面停止而時鐘前進、是否有 decoder／VO 故障，仍缺同一次 session 的完整關聯；新增診斷只縮小後續觀察盲區。
4. 沒有可靠身分證據的跨 CDN 拼接仍停用。新診斷屬性在 Android 的可用性、額外 getter 成本，以及 native stop/open 若永不回覆的行為，仍未經裝置驗證。
5. 後續需另由使用者授權安裝，在同裝置／網路／影片／畫質／音軌下對照 combined 與 original，短時確認實際出聲、連續畫面、Seek、暫停恢復及一次自動預算；本次不執行。
