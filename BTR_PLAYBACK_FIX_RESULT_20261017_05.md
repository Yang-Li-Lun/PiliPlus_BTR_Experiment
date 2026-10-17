# BTR 播放修復候選 05（2026-10-17）

本候選修復四項可由本機程式／回歸重現的問題。**仍不能確認兩段新實機紀錄的全部根因，Android 連續 Seek、無聲、凍結與音畫同步仍為 UNRESOLVED／待驗收。**

## 來源與隔離

- Worktree：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1017-05`。
- 分支：`codex/btr-playback-fix-20261017-05`。
- 基準：實讀候選 04 HEAD `2e896d6e9b496363a3fabcfa17eb8fcec69ae682`，程式 commit `da5121e09`；候選 04 與維護線開始／結束均乾淨且 HEAD 不變。
- 本次程式 commit：`0e483fb93a5854080657a84b8a8b6c1c5a8a848b`。本交付文件另以文件 commit 保存。
- 舊 APK 實讀 SHA-256：`4e1fab7e4172a2cf418f832aa1668deb3f550de51254b290b2e49d5866bcd362`，符合候選 04 文件。
- 新的 196,522 ms／9,760 ms 紀錄僅由本次使用者訊息摘要取得，存於 `evidence/playback-fix-20261017-05/user-observations.json`，不是原始診斷或裝置擷取。來源 APK 身分仍未核實；沒有補造缺失／被覆蓋的時間線。候選 04 的 43,515 ms 原件保留原位。

## 已確認缺陷與修復

### 1. 本機排隊消耗 upstream attempt 預算

`_attempt()` 原先在 `scheduler.acquire()` 前啟動 15 秒計時，未取得連線名額也會耗盡 attempt，增加 requestFailures／重試。用七個受控 video permits 阻擋名額 250 ms、attempt 設為 100 ms，舊碼在沒有送出該 HTTP 請求時已記一次失敗。修正後，attempt 計時從取得 permit 的 `onStarted` 起算，該測試無 request failure／retry，Range 逐 byte 正確。

仍保留整塊 25 秒總期限、最多三輪、headers／body stall timeout、取消清理與連線上限。這證實的是排隊誤耗 `attempt-deadline`，**不能用來解釋實機所有 `reason=timeout`**；後者仍可能來自連線／headers 或 body 等待，沒有當時 phase／傳輸進度無法分辨。

### 2. 舊世代 speculative 分塊占用新 GET 所需連線

原本不同世代的 head／speculation 使用相同優先權；舊 GET 的預取與 head hedge 能占滿 video slots，新 GET 即使有 4 MiB 視窗中的 head 空間，也只能等待舊 HTTP 工作結束。受控 Fake CDN 將舊分塊阻住，新 Range 可正常回覆：舊碼在 700 ms 上限內無法完成新 head，修正後通過，之後舊 GET 也完整逐 byte 完成。

只有**同軌實際出現較新世代的有效 GET** 才重整舊 demand：取消尚未交付的 speculative 工作，等 producer 清理後釋放其預留；舊 demand 正在等待／交付的 head 保留，後續可按需繼續讀。較新 GET 存活時舊 demand 限制成單 head；排程仍優先供應 head，再區分世代。沒有因 Seek 一律取消 GET，沒有判定所有舊 GET 無效，也沒有移除 handler 或音訊保留名額。

每軌仍為 4 MiB、HTTP handler 仍為 4、全域資源上限仍為 16。重取被回收的 speculation 可能增加局部重下載、降低舊串流預取深度；本機測試不代表真實 CDN 吞吐量改善。169 秒 GET 年齡本身不是失效證據，單一長 Range 可跨多個有期限的 piece 持續存在。

### 3. 舊需求晚到失敗污染新世代 terminal 計數

三個舊 GET 的 recoverable 耗盡結果，可在較新 GET 已成功後把整軌標成 terminal。新增測試先完成新世代 Range，再放行三個舊 GET 的受控 503／耗盡結果，修正前 `terminal=true`，修正後軌道仍可正確讀取。

連續耗盡計數現在歸屬於**實際開始供應的最新 GET 世代**；舊成功也不能重設新世代失敗數。單純 Seek 不重設這個計數，仍可能使用舊 GET。不可恢復的 Range／身分／協定違規不受世代豁免，照常 fail closed。舊事件仍保留自己的 request／generation，近期恢復證據不接納跨 Seek 世代晚到失敗。

### 4. 沒有 native error 時，持續讀取停滯沒有恢復入口

候選 04 的恢復主要依賴 native error／已記錄讀取錯誤的 completed callback；meter 只檢查 terminal。單有上游失敗、代理寫入失敗或 handler 503，不會主動安排 reopen。`playerErrors=0` 因此並不保證能恢復。

在既有 500 ms meter 增加檢查：使用者仍要求播放、目前來源有效、不是開源中、buffering 或已抑制的異常 completed，且時間線至少 15 秒沒有變化。還必須有近期同一 Seek 世代的明確證據：至少兩筆 demanded-head attempt 失敗，或 demand 耗盡／代理 response 失敗／handler 容量拒絕。證據必須發生在該停滯開始附近或之後，且不早於最近 30 秒。沒有證據、短暫緩衝、持續時間線進展、暫停或來源已變更不觸發此入口。

符合條件後沿用三秒 grace、每個明確來源最多一次自動 reopen，以及 stop → retire handlers/producers → open。新 Seek／來源／實際進展使舊恢復失效，重開保留最新 Seek 及播放／暫停意圖。一次 reopen 後再次符合有證據的長停滯，會暫停、關閉 transport、顯示錯誤，要求使用者重新開啟影片或切 original，避免反覆自動重開。

15 秒與三秒 grace 是有限恢復策略，不是 CDN 根因判定。無法把它套回缺失的實機時間線，保證當時何時一定會觸發。單純凍結／無聲或未知 decoder／ao error，不會被猜成網路故障。

## 503、completed 與音訊的證據界線

9,760 ms 摘要中的 completed 發生於 2,192 ms，503 在 4,692～4,694 ms；後來的 503 不能作為先前 completed 的已證實原因。既有真實 localhost 四個背壓 socket 測試仍驗證容量 503、鎖定 SDK error 轉送、控制器 stop／retire／雙軌重讀的本機路徑；新增情境驗證先異常 completed、再有 proxy failure 而沒有 native error 時的恢復。這些均不是 Android 原生事件鏈的重建。

獨立檢查鎖定的 media_kit `73771ec38176be2d984a3049c28177bce23b54a0`：`real.dart` 的 `eof-reached` 分支會清空公開 track／tracks 並清除 buffering。native error log 只將特定 prefix 轉入 error stream，`ao` 不在該清單中；非同步命令錯誤另可透過 `mpv_error_string` 產生通用訊息。因此 `playerErrors=0`、`unclassified`、EOF 後軌道消失，都不能單獨證明 Android 音訊解碼或輸出裝置狀態。

`audio-pts` 不前進與 buffering 相容，但不是可聽音訊證據；音軌選取、socket bytes、sample rate、mute 欄位也不能證明真的出聲。本次沒有修改 EDL、audio source、codec、filter、audio output、焦點策略或 SDK。音訊輸出／解碼異常及原生畫面凍結仍為 UNRESOLVED。

有限診斷補充：build ID；每個 demand 的預留量／預取降優先狀態；upstream-piece 失敗的 request、generation、headers/body phase、queueMs、attemptMs、收到的 bytes；近期恢復證據類型／年齡。原 128 事件上限不變，另用固定 allowlist 的最多八個 origin 計數及首／末錯誤分類保留摘要。沒有保存原生錯誤文字、URL/query、headers、ETag、codec 名稱或裝置名稱；摘要不能還原全部事件。

## 驗證

| 項目 | 結果及限制 |
|---|---|
| 基準候選 04 純 Dart suite | 104/104 PASS |
| 最終本機 suite | **109/109 PASS**，`tests-final.log`，含真實 localhost socket、Fake CDN、取消、雙軌、身分／Range、Hedge／Resume、音訊容量、Seek／EOF／來源切換 |
| 控制器入口 | 上述 suite 內 **28 個子情境 PASS**；從 production 擷取實際方法與鎖定 SDK log 轉送，使用受控 player contract；不是執行 mpv ABI／Android |
| 前版對照 | `scheduling-baseline-red.log`：排隊誤耗 attempt、新 head 被舊工作擋住；`old-failure-red.log`：舊失敗錯誤終止新世代；均保留失敗證據 |
| 修改範圍分析 | **No issues found**，`analyze-changed-final.log` |
| 全 app 分析 | **0 errors / 0 warnings / 37 既有 infos**；與候選 04 的位置／規則集合一致，exit 0（`--no-fatal-infos`） |
| Flutter/native test | **BLOCKED，未進入案例**：cnativeapi native assets 找不到 Windows MSVC／cl.exe |
| ARM64 DEV APK | **PASS**，218.3 秒；僅 ARM64、DEV package、v2 簽章有效、與候選 04 相同 certificate；AOT 內確認含本候選 buildId |
| Android 安裝、手機操作、真實 CDN 壓力、長時播放 | **NOT RUN** |
| Android 可聽音訊、畫面、音畫同步及連續 Seek | **NOT RUN / UNRESOLVED** |

第一次 build 實際遇到 `Unable to establish loopback connection`，保存 `build-01.log` 後，才以候選 `.ipc` 及程序級 `JAVA_TOOL_OPTIONS` 重試。沒有改全域 TEMP／TMP、JDK、hosts、Android source 或依賴。SDK/cache 重用檢查了版本、lock、patch 輸入與 25 個 Flutter patches 的 reverse check，沒有對 seed SDK 套用修改。

## APK 與保留核對

完整路徑：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1017-05\build\btr-candidates\playback-fix-20261017-05\PiliPlus-BTR-PlaybackFix-20261017-05-dev-arm64-v8a.apk`

- SHA-256：`8c9dac9f6c2e26b84f976a3f477f5f9348592a516824c74bbc5a35fb04d480c7`。
- 大小：24,511,879 bytes；建置原件與交付副本雜湊相同。
- package：`com.example.piliplus.btr.experiment.dev`；label：`PiliPlus BTR DEV`；versionName 2.1.6／versionCode 1；minSdk 24／targetSdk 37。
- buildId：`playback-fix-20261017-05`，已在 APK 的 ARM64 `libapp.so` 中核對；這是編譯識別標記，仍需以 APK SHA-256 核對實際交付物。
- v2 certificate SHA-256：`fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`，新舊 APK 均重新檢驗。
- `artifact.json` 與 `build-source.json` 保留識別、雜湊與驗收界線；建置後十一個來源／測試／工具檔與 pin 全部相符。沒有安裝。

165 個其他 heads/tags refs、26 份既有 APK 保護檔、DEV key、pubspec.lock、Git config、seed SDK diff 均核對不變，見 `before.json`／`preservation.json`。沒有改舊候選／維護線、push、PR、上游同步、依賴升級或提升穩定版本。`build-source.json` 綁定程式 commit 及十一個修改檔案雜湊，evidence 與 APK 保存在本候選內。

## Android 待重新驗收

1. 核對本候選 APK 雜湊與診斷 buildId，再記錄正常播放、cache 內／外連續 Seek、EOF 回拖、0／結尾、自然 EOF；確認最新目標、沒有非預期零秒重播或自動下一集。
2. Seek 中暫停／恢復／切來源；確認舊結果不覆寫意圖，stop／retire／reopen 次數有界。記錄首次失敗附近的 phase、世代、預留量與實際時間線進展；一次恢復後仍持續停滯時應明確報錯。
3. 分別驗證雙軌、audio-only 的可聽聲音、畫面更新與 A/V sync；將 audio-pts／output properties、ao/ad/vd 分類與實際耳聽／畫面結果分開記錄。需要完整原生證據才能區分 decoder、輸出裝置或緩衝停滯。
4. original 對照；真實 CDN 效能、耗電／記憶體與長時穩定性沒有在本機得到驗收。僅剩舊世代失敗、無近期同世代證據、無法辨識的中途 EOF、native stop/open 永不返回等情況仍不能保證自動恢復；不以擴大未知錯誤分類或強制重開掩蓋。

**本機測試與 APK 建置成功不代表 Android 播放異常已解決。**
