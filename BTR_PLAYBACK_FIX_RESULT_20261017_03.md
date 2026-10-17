# BTR 播放修復候選 03（2026-10-17）

## 交付與範圍

- 獨立分支：`codex/btr-playback-fix-20261017-03`。
- 工作樹：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1017-03`。
- 從上一版候選最新 HEAD `f764b9ce6dba8fb8370f1d9b2e099f293def4b39` 建立；該 HEAD 相較指定修復 `0dee107ca` 只增加交付文件，沒有新增程式變更。
- 最終程式 Commit：`92b1e91e209a524359e8cbb33fa694a4638f2b46`；前置修復 Commit `064d7df844fec845740e519ee7a78c12e50d8562`。本報告以後續文件 Commit 保存。
- 還原點：既有候選分支原位保留，另加 `btr-before-playback-fix-20261017-03` 指向 `f764b9ce6`。
- 主工作樹開始及交付檢查皆乾淨，仍為維護分支 `a86c5daae`。177 個其他既有 branch/tag refs、19 份舊 APK、DEV key、lockfile 與 repository Git config 核對不變；種子 SDK 的 tracked state 不變。
- 未同步上游、升級依賴、推送、建 PR、安裝或操作手機；未做真實 CDN 壓力或長時播放測試。

**已修復本機可重現的控制器競爭與資源處理缺陷。這份實機摘要尚不足以確認完整根因鏈，也不能證明實機症狀已消失。無聲、畫面凍結與 A/V sync 保留 UNRESOLVED。**

## 確認的缺陷、證據與修復

### Seek、EOF 與重新開源沒有共用操作序列

上一版只序列化 `setDataSource()`；`refreshPlayer()` 直接呼叫 native open，Seek 也在來源序列之外執行。鎖定版 media_kit 的 open 會 stop、把 position/duration/buffer 與公開 tracks 清空，再載入 Media。故舊重開可能和新 Seek 交錯，使用重設成 0 的位置，或把新目標覆蓋掉。

media_kit 鎖定版本為 `73771ec38176be2d984a3049c28177bce23b54a0`。其 `real.dart` 的 `play()` 在 `state.completed` 為 true 時會 Seek 至 0 並設定 playlist-pos 0；`seek()` 在命令回覆後清除 completed，而 `eof-reached` 事件可再將它設回 true。**向實際控制器方法注入晚到 EOF 的 native contract 模擬，可以重現回拖 40 秒後被改為 0；尚未觀測到這個事件交錯確實發生於使用者的 Android 裝置。**

修復讓來源載入、Seek 與 reopen 共用 `PlaybackSourceSequence`。尚未派送的舊 Seek 會被最新意圖取代；已派送的命令依序完成，不以任意 timeout 強制 disposal。EOF 回拖在同一 native lock 內清除晚到 completed 後呼叫既有 `play(synchronized:false)`，保留 media_kit 的播放事件及 pause bookkeeping，避開重新從 0 播放的分支。

Seek 的目標在實際時間線向前到達附近前保留；命令回覆與時間線恢復分別記錄。回拖中的晚到 completed 不觸發完成／自動下一集，新的來源或暫停意圖會使舊恢復失效。拖到影片結尾仍可接受完成事件，正常 EOF 行為保留。

### Reopen 沒有清理已卸載播放器的舊 GET

上一版讓 GET 各自獨立是必要的：Seek 可以只命中 mpv cache，新 GET 也不能證明舊 GET 已無效。但 native reopen 並沒有明確的代理退休邊界，舊 GET 可以仍在 proxy-write 或等待共用有序緩衝，繼續占用四個名額。

本機 HTTP fixture 實際確認四個未完成 GET 可使第五個 GET 得到 503；raw loopback socket 不讀資料也可形成寫入阻塞。**這證明容量耗盡的機制存在；使用者提供的實機摘要未記錄 503，實機是否發生仍為 UNCONFIRMED。**

Reopen 現在先 await native stop，再取消並等待這個已卸載播放器的全部 GET、生產工作及 handler 清理，才 open。stop 是消費者所有權失效的邊界。Seek 或重疊 GET 本身仍不取消有效串流。proxy-close 也納入既有取消 token，拒絕回應的 close 保留有限期限。

handler 上限維持 4；未增加等待佇列、放寬上限或縮短正常寫入期限。四個仍有效的回應可以繼續占滿名額；此時明確記錄 503，而非宣稱永遠不會拒絕請求。

### 自動重開需要有限預算及最新目標

舊 retry timer 缺少 Seek 世代綁定，reopen 也未與 Seek 共用序列。現在新 Seek／來源會取消舊 timer；排隊 reopen 再核對來源與 Seek revision，避免卸載較新的 Seek。每次明確選擇來源最多一次 BTR 自動重開，手動刷新仍可使用；不建立無限重試。

尚待確認的 Seek 不會單憑 buffering 重開。只有當**同一傳輸 Seek 世代已記錄本機 503 或 proxy-write/proxy-close 失敗，且 native 回報 proxy/tcp 讀取錯誤**時，才安排一次保留最新 target 的恢復。時間線先恢復、新 Seek、來源切換、證據世代過期或預算耗盡，都使舊恢復失效。terminal 軌道仍停止，不重新開啟失效代理。

## 音訊與畫面凍結的判定

直接讀取鎖定 media_kit `real.dart` 確認：`eof-reached=true` 分支會將公開 `state.track`／`state.tracks` 設為空並發出事件；stop/open 也會重設這些欄位。上一版的 `nativeAudioTrackCount` 與 `nativeAudioSelected` 來自這些公開 stream。

因此，`completed + nativeAudioTrackCount:0 + selected:null` 可以由 SDK 的 EOF 重設產生，不能單憑這個快照判斷 mpv 從未辨識音軌。16.7 MB loopback 交付只證明 socket 接收資料，不能證明 demux、解碼、選軌或實際出聲。新增觀測保存本 session 曾觀測的最大音軌數及 completed 前的音軌／選取狀態，以區分「從未觀測到」與「先有後清空」；未觀測值保持 null。

未改 EDL 影音組合、audio-only、URL 選擇、音訊 filter、codec 或 audio output。EDL 的平行 stream 契約可參照 [mpv EDL 文件](https://github.com/mpv-player/mpv/blob/master/DOCS/edl-mpv.rst)。本次沒有真實音訊素材的 Android demux／decoder 執行證據。

**實機無聲與畫面凍結根因仍為 UNRESOLVED。** 目前沒有證據證明二者皆由此次控制器缺陷造成，亦未將原因歸給 CDN、音訊 URL、硬體解碼器或裝置輸出。

## 診斷與保留契約

新 JSON 欄位可區分：

- `proxyCapacityRejections`、`proxyInvalidRejections`、`proxyRetirementRejections`、`proxyLocalResponseFailures` 與 `proxy-rejected` 的受控 status/reason。
- `activeProxyHandlers`／`peakProxyHandlers`／`proxyHandlerLimit`，以及各需求的 request、generation、stage、ageMs、progressAgeMs、deliveredBytes。
- `playerOpenCount`、`player-open` 的 source/user/read-error/seek-local-read-error 原因、`player-open-ended`、`player-reopen-skipped`。
- `seek-command` 的 command-complete／failed、`seekCommandFailures`，與既有時間線 `seekPending`／`seekTimelineMs` 分開。
- `maxNativeAudioTrackCount`、`nativeAudioTracksBeforeCompleted`、`nativeAudioSelectedBeforeCompleted` 及 `native-audio-state`。

既有 128 事件、32 筆 Seek 時間與 8 次 recent session 上限維持；需求快照受四個 handler 限制。不記錄完整 URL、query、ETag 內容、原生錯誤全文、Cookie、Token、軌道標題、裝置或帳號名稱。

未修改 `network.dart`、`policy.dart`、`scheduler.dart`、settings、Android source、pubspec 或 lock。多線程、自動線程、CDN 選源／備援、音訊保留容量、Hedge、續傳、每軌合計 4 MiB 有序視窗及全域 16 upstream 連線限制保留。Range、ETag、Content-Range、來源身分與 MCDN/P2P 過濾未放寬。原始 PiliPlus 仍繞過 BTR 代理，來源與音訊處理維持原路徑。

## 本機驗證

證據目錄：`evidence/playback-fix-20261017-03/`。

| 驗證 | 最終結果 | 證據 |
|---|---|---|
| 純 Dart／Fake CDN／loopback socket 全部回歸 | **95/95 PASS**；含既有 Range／身分／Hedge／續傳／自動線程／音訊容量／原模式回歸 | `tests-final-06.log` |
| 擷取實際 controller 方法 | **15 個子情境 PASS**：EOF 回拖、連續 20 個排隊 Seek、暫停、新來源、重開競爭、Seek 失敗、有限恢復及恢復失效 | `controller-green-final.log`、`fixed-method-fixture.dart` |
| 前版方法對照 | 核心 8 情境中 7 個預期 RED，暫停 EOF 案例 PASS；其餘新增恢復 API 在前版不存在。只證明擷取方法與 Fake native contract，非 Android/native 執行 | `controller-baseline-red-final.log`、`baseline-method-fixture.dart`、`controller-red-green.json`、`reproduce-controller-baseline.ps1` |
| 四個 GET 滿額及卸載後恢復 | 503 可觀測；stop 邊界清理後 handler／upstream／queue／有序預留為零，再完成十輪雙軌精確 Range | `reopen_lifecycle_test.dart`、`tests-final-06.log` |
| 真實 localhost socket 背壓 | 每軌可有一個寫入阻塞，另一個等候共享視窗；stop 邊界清理在 3 秒內完成，不等待 15 秒 flush timeout | 同上 |
| 修改範圍分析 | **No issues found** | `analyze-changed-final-04.log` |
| 全 app／tests／pubspec 分析 | **0 errors / 0 warnings / 37 既有 infos** | `analyze-app-final-03.log`、`analyze-app-summary-final-03.json` |
| Flutter/native 測試 | **BLOCKED，未進入案例**：Windows 缺 Visual Studio/MSVC C compiler，cnativeapi native assets 無法建置 | `flutter-native-test.log` |
| Git whitespace | PASS | `git diff --check` |
| 最終程式 Commit ARM64 DEV build | **PASS**，64.9 秒 | `build-dev-03-final.log`、`build-source-final.json` |
| package／ABI／v2 簽章／原 DEV certificate | **PASS**，重新實讀新舊 APK，certificate 一致；原件與副本 SHA 相同 | `apk-badging.log`、`apk-signature.log`、`old-apk-signature.log`、`delivery-verification-02.log` |
| 原 refs／APK／key／lock／SDK state 保留 | **PASS** | `before.json`、`preservation-final.json` |
| Android 聲音／畫面／Seek／真實 CDN／長時 | **NOT RUN / UNRESOLVED** | 本次未操作手機 |

中途日誌原樣保留。`tests-final-05.log` 曾因 fixture 要求四個 GET 全部進入 proxy-write 而失敗；每軌共享 4 MiB 視窗允許另一需求等待 upstream，故改以每軌存在持續背壓的 writer 為就緒條件，沒有放寬 production 資源限制。第一輪封裝驗證未辨識 build-tools 37 的 `V2 Signer:` 文字格式；修正解析後，新舊 APK certificate 實讀相同。

首次 Gradle 建置出現 `Unable to establish loopback connection`，保留 `build-dev-01.log` 後才依候選根目錄推導 `.ipc`，於建置程序設定 `jdk.net.unixdomain.tmpdir` 重試。未修改全域 TEMP/TMP、JDK、hosts 或依賴。中途 `064d7df84` APK 與 source pin 另存於 `build/btr-candidates/intermediate-064d7df84/`，沒有作為最終交付。

## 最終 APK

`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1017-03\build\btr-candidates\playback-fix-20261017-03\PiliPlus-BTR-PlaybackFix-20261017-03-dev-arm64-v8a.apk`

- SHA-256：`b9d2bfd4be88778655a2a8e144c4d7ed5082696e24729e618eabdf9d1121d33f`。
- 大小：24,497,351 bytes；ARM64 only。
- package：`com.example.piliplus.btr.experiment.dev`；label：`PiliPlus BTR DEV`。
- versionName 2.1.6 / versionCode 1；minSdk 24 / targetSdk 37。
- v2 certificate SHA-256：`fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`，與前版 DEV APK 相同。
- 同目錄 `artifact.json` 保存最終程式 Commit、六個 production 檔案雜湊及驗收邊界；建置後逐檔與 source pin 核對不變。

## 仍需 Android 實機驗證

1. 正常播放中連續回拖、cache 內外 Seek、拖到 0／結尾、自然 EOF 後回拖；確認保留最新目標且不反覆從頭開啟。
2. 回拖期間暫停／恢復／換影片或畫質，確認舊重開不覆蓋新目標；比較 `seek-command` 和實際時間線恢復。
3. 分離 DASH 雙軌與 audio-only，檢查 completed 前／最大已觀測音軌數、實際可聽音訊、A/V sync、焦點及背景前景切換。
4. 若再次中斷，檢查 503、local response failure 世代、player-open 原因與次數、需求 stage／age，以區分代理滿額、native 開源及 Seek 失敗。不要把 decoder／音訊輸出問題歸因於 socket bytes。
5. 原始 PiliPlus 正常播放、Android 硬體解碼與畫面凍結仍需實機對照。native future 永不回覆及長時資源行為亦未驗證，沒有新增強制 disposal 或無限重試掩蓋此邊界。

本機測試與簽章驗證不是 Android 播放驗收；本次沒有安裝、ADB 或其他手機操作。
