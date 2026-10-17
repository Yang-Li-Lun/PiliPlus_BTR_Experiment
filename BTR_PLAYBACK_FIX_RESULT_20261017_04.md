# BTR 播放修復候選 04（2026-10-17）

本候選修復本機可重現的預取容量飢餓、錯誤入口及 EOF／恢復競爭。**Android 連續 Seek、無聲、畫面凍結仍待實機驗收，不能宣稱全部已修復。**

## 版本與證據來源

- 分支：`codex/btr-playback-fix-20261017-04`；Worktree：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1017-04`。
- 基準：實讀候選 03 HEAD `326bf3872e6013fc5eb6bbbee5ddb808498983e7`，程式修復 `92b1e91e2` 之後僅交付文件。開始時維護線 `a86c5daae` 與候選 03 均乾淨。
- 最終程式 Commit：`da5121e09ce370556e3f09f7109d79b7d32358e8`；本交付報告另以文件 Commit 保存。
- 實讀舊 APK SHA-256：`b9d2bfd4be88778655a2a8e144c4d7ed5082696e24729e618eabdf9d1121d33f`，符合候選 03 artifact.json。
- evidence：`evidence/playback-fix-20261017-04/`。附件原文完整保留於 `device-43515-user.txt`，含 JSON 後的使用者症狀敘述；另存 `device-43515-parsed.json`，沒有改寫原件。
- 使用者另在對話貼入 66,565 ms 舊格式資料：3,209 ms 唯一錯誤分類為 other；沒有候選 03 的開源／容量欄位，不能從該 JSON 確認來源 APK。與 43,515 ms 紀錄分開判讀。

## 已確認的本機缺陷與修復

### 1. 舊 GET 的寫入背壓可耗用共用預取視窗，先於 handler 滿額阻塞新 Range

`BtrTrack._ordered()` 在 `yield` 後等待下游 flush，期間仍保留自己已排程的資料。舊 writer 不再被讀取時，原本的貪婪 fill 可以占住幾乎整個每軌 4 MiB，新 GET 即使有 handler 名額也可能沒有首段／後續段的容量。舊 GET 直到 15 秒 flush timeout 才釋放，故 handler-capacity 並非唯一的阻塞機制。

使用真實 localhost socket 停止讀取舊 GET、同時完整讀取新的 1 MiB Range：舊程式三秒逾時（`window-baseline-red.log`），修正後通過。最終測試覆蓋一個及三個舊 writer，新 Range 逐 byte 正確、舊 GET 沒有被取消、沒有 503、預留量不超過 4 MiB。

修正僅在既有 4 MiB 內，從 speculative 預取預算保留另外三個 handler 各 64 KiB 的 head 空間（192 KiB）。沒有已預留資料的需求可用 64 KiB 前進；其餘仍用既有自適應分段及多線程排程。handler 上限仍為 4，不新增等待佇列、不縮短正常寫入期限、不因 Seek 取消 GET。這可能略減單一需求的最大預取深度；真實吞吐量與資源成本未量測。

附件支持這條可能的故障鏈：3,634 ms Seek、8,750 ms 首次 network error、13,863 ms 再次 network error，13,865 ms 才有 503；新 video GET 最後各交付 64 KiB。但原始診斷沒有錯誤文字及當時各需求的即時預留／進度，**尚不能把該 Android 首次錯誤確定歸因於本機重現的視窗飢餓**。

### 2. native 錯誤到恢復入口有格式與時序缺口

鎖定 media_kit `73771ec38176be2d984a3049c28177bce23b54a0` 的 `real.dart` 把特定 mpv error log 的 text 單獨送進 errorController。舊入口只認 URL 或固定 `tcp: ffurl_read` 開頭，漏接 `HTTP error 503 ...` 與帶前綴的 ffurl_read；pending Seek 又要求代理先出現本機失敗。相同讀取錯誤持續到來時，還會不停取消重設三秒恢復計時器。

新增窄範圍分類：HTTP 4xx/5xx、ffurl_read、明確 loopback 開源失敗。只在 BTR transport 存在時使用；decoder、audio output、其他未知文字不猜成網路錯誤。首次 native read failure 即可保留最新 Seek 目標安排既有三秒恢復，不必等後來的 503。重複事件不延後同一計時器。

每個明確來源仍最多一次自動 reopen；Seek／來源改變或時間線實際前進使舊恢復失效。reopen 依序 stop → 退休舊 GET 並等待 handler／producer 清理 → open，最新 Seek 與播放／暫停意圖仍由原操作序列負責。終端身分／協定失敗仍停止，不以重開繞過。

另外修正舊 demand 的 proxy-write 失敗被標成當下 Seek 世代：現在記錄 demand 自己的世代，且晚到的舊失敗不覆寫較新的失敗證據。

### 3. EOF 與重新從零播放

舊 listener 只攔截 pending Seek 的 completed，沒有 pending Seek 時的讀取失敗 completed 會觸發完成通知。舊 reopen 的 `play()` 也可能在晚到 native EOF 下進入 media_kit 的從零重播分支。

BTR 現在保留失敗時的位置，已觀測讀取失敗或未確認的中途 completed 不發布正常播畢；沒有 read failure 的中途 completed 只標為 unconfirmed-eof，不憑此自動重試。判斷中途的時間線條件是已知 duration、位置距結尾超過兩秒；這是保守的完成閘門，並非讀取失敗歸因。明確拖到結尾、無失敗證據且位於結尾附近的自然 EOF 仍通過；未知 duration 不捏造結尾。

手動恢復與自動恢復保留失敗位置／最新目標；BTR reopen 使用既有 native lock 中的 resume 方法，避免晚到 completed 導致 play 重播零秒。所有新增判斷限於 BTR；original 入口維持既有行為。

## 無聲與畫面凍結：仍為 UNRESOLVED

43,515 ms 資料在 795 ms 已觀測音軌被選取，13,890 ms completed 後音軌清空；這符合 SDK EOF 時清空公開 track/tracks 的程式行為。31 MB 音訊來源大小、交付量、音軌選取與 volume=100 皆不能證明音訊解碼、實際出聲或 Android 畫面呈現。另一次 recent session 有 audio 類錯誤，但原分類不足以判定是外部音軌讀取、decoder 或輸出裝置。

未修改 DASH EDL、音訊 URL、codec、filter、硬體解碼或 audio output。只在既有 500 ms BTR meter 上增加有限觀測：audio-pts、音訊輸出採樣率／聲道數、frame-drop-count、mute／ao-mute、paused-for-cache、core-idle、eof-reached。保留兩筆快照及 EOF 前最後一筆；不支援、例外與非有限數值均為 null。其語義參考 [mpv 官方 properties](https://mpv.io/manual/stable/#properties)，仍不是實際可聽音訊／畫面證據。

新增 allowlist native-error-origin（ffmpeg/ad/vd/ao/cplayer/stream/file/other）及受控 readKind；不保存原生錯誤文字、URL、query、headers、ETag、裝置名或軌道標題。沿用 128 事件上限，無新增網路探測或背景 timer。

## 驗證結果

| 驗證 | 結果與界線 |
|---|---|
| 純 Dart／Fake CDN／localhost 回歸 | **104/104 PASS**，`tests-final.log`；最後測試格式整理另跑相關 8/8 PASS |
| 原生事件入口契約 | 同一 suite 內 **25 個子情境 PASS**：擷取鎖定 SDK log→error 轉送及 production error/completed listener，經 StreamController 發出事件，再執行實際控制器方法；包括四個真實阻塞 socket 503 後 stop／退休／雙軌逐 byte reload。**這不是執行 mpv ABI 或 Android native。** |
| 前版對照 | `controller-baseline-red.log` 有六個新增入口／EOF／恢復情境失敗；另有 `reopen-eof-red.log` 顯示晚到 EOF 會使重開從零播放。這些是受控契約重現，不是實機事件交錯的證明 |
| 代理生命週期 | 一／三個背壓 writer 下新 Range 可前進；四 handler 仍有限拒絕；明確 stop 清理；舊失敗世代不污染新 Seek |
| 原契約回歸 | Range、ETag、來源身分、音訊容量、Hedge、續傳、自動／手動線程、取消清理、original bypass 既有測試通過 |
| 修改範圍 analyze | **No issues found**，`analyze-changed-final-02.log` |
| 全 app analyze | **0 errors / 0 warnings / 37 既有 infos**，與前候選逐行相同，`analyze-app-summary.json` |
| Flutter/native | **BLOCKED，未進入案例**：cnativeapi Windows native assets 缺 MSVC，`flutter-native-test.log` |
| ARM64 DEV APK | **PASS**，227.4 秒，`build-02-short-ipc.log`（首次 IPC 失敗另存） |
| APK package／ABI／簽章／來源 | **PASS**，ARM64 only、DEV package、v2 簽章、前候選 certificate 相同；source pin 與交付副本 hash 一致 |
| Android 聲音／畫面／Seek／A/V sync | **NOT RUN / UNRESOLVED** |
| 真實 CDN 壓力、長時播放、安裝／手機操作 | **NOT RUN** |

首次 build 01 實際遇到 `Unable to establish loopback connection`，保留日誌後才使用候選內 `.ipc` 與程序級 `JAVA_TOOL_OPTIONS` 重試。沒有改全域 TEMP/TMP、JDK、hosts 或依賴。

## 交付與保留

完整路徑：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1017-04\build\btr-candidates\playback-fix-20261017-04\PiliPlus-BTR-PlaybackFix-20261017-04-dev-arm64-v8a.apk`

- SHA-256：`4e1fab7e4172a2cf418f832aa1668deb3f550de51254b290b2e49d5866bcd362`。
- 大小：24508555 bytes。
- package：`com.example.piliplus.btr.experiment.dev`，label：`PiliPlus BTR DEV`，versionName 2.1.6 / versionCode 1，minSdk 24 / targetSdk 37。
- 僅 ARM64，APK v2 簽章有效；certificate SHA-256：`fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`，與前候選實讀相同。
- `artifact.json` 與 `build-source.json` 記錄程式 Commit、檔案雜湊及驗收界線。建置完成後再次核對十個程式／測試檔與 pin 相同；APK 副本與建置原件 SHA-256 相同。沒有安裝。

180 個其他既有 branch/tag refs、23 份舊 APK、既有 DEV key、pubspec.lock、Git config 與私有 SDK tracked state 均核對不變；維護線／候選 03 HEAD 不變且乾淨。`before.json`、`preservation.json`、`build-source.json` 保留來源與核對資料。只提交本次十個程式／測試檔及本報告；未 push、建 PR、上游同步、升級依賴或提升穩定版本。

## Android 待驗收

1. 固定影片／裝置／網路，以 combined 測正常播放、cache 內外連續 Seek、回拖、到 0／結尾、自然 EOF 後回拖；確認時間線恢復及最新目標，沒有非預期零秒重播或自動下一集。
2. Seek 中暫停、恢復、換來源；確認 stop/reopen 次數、一次自動預算、最新播放意圖；記錄 native-read-failure、proxy handler／reservation 與 suppressed completed。
3. DASH 雙軌與 audio-only 分別確認實際可聽音訊、音畫同步及畫面持續更新；比對音訊輸出觀測、error origin、音訊焦點與 Android decoder/render 實況。原生屬性可用性仍需裝置確認。
4. original 模式對照。單源預取深度小幅變化的吞吐量／記憶體／CPU 與長時行為未量測，不宣稱加速效能改善。

尚無證據確定 8,750 ms 首次 Android 錯誤的完整根因、所有 other 類 native 錯誤、無聲與凍結的獨立原因。未知錯誤不自動擴大為恢復條件；native stop/open 若永不回覆仍是未驗證邊界，沒有新增強制 disposal 或無限重試。
