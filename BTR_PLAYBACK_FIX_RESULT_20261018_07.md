# BTR 播放可靠性與效能候選 07（2026-10-18）

候選 07 修復可在本機重現的 Seek／EOF 恢復缺口與傳輸退化。**Android 實際 Seek 後的畫面／聲音、凍結、無聲及「至少恢復初版順暢度」仍為 NOT RUN / UNRESOLVED。** 本機時鐘／HTTP bytes／原生契約 stub 均不是解碼、畫面或可聽聲音的驗收。

## 版本與證據來源

- 工作樹：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1018-07`。
- 分支：`codex/btr-playback-fix-20261018-07`。
- 基礎：候選 06 `e41269c0d82077f9e17107a8868a91c478513085`；開始時維護線與 06 工作樹乾淨，07 分支／路徑不存在。
- 程式 commit：`c4e823c32ae0ecd2770f05b01afe67c879c6f8cf`；交付文件另以後續 commit 保存。
- buildId：`playback-fix-20261018-07`。
- 初版：`788faa8abee2ff325205d89a9fa24869821685e3`，與實讀 tag `btr-stable-baseline-20261016` 相同。
- 實讀 AGENTS.md、BTR_UPSTREAM.md、tool/btr_upstream.json、BTR_EXPERIMENT.md、06 原始碼／報告／evidence、05 使用者觀察摘要、04 的 `device-43515-parsed.json` 與 investigation。
- 04 紀錄有 Seek → 約 5.1 秒後 network error → 第二次等待後 handler 503 → completed 的順序；較早的 05 摘要與 06「audio-pts 推進但無聲」摘要屬於不同觀察，未混為同一次故障。沒有新的 Android 原始 log 或裝置擷取。
- 本次 evidence 全部位於 `evidence/playback-fix-20261018-07/`；舊 evidence 留在原位。初版與 06 的唯讀 source snapshots 從固定 Git commit 匯出到本候選 evidence，用獨立 package config 執行相同 benchmark。

## 已確認的 Seek／EOF 缺陷及修復

1. **播放中的 Seek 在指令期間收到 EOF，會漏掉恢復播放。** 06 只在送出前 `completed=true` 時保留 resume intent；鎖定 media_kit 的 EOF dispatch 會改成 `playing=false`，而 seek 的 command reply 只清 completed。07 在 BTR 指令完成後再核對 native 播放狀態與最新使用者意圖；晚到的 EOF 暫停可恢復，明確 pause／新來源仍優先。
2. **指令回覆後才到達 EOF 時，06 只抑制完成通知，沒有真正恢復位置。** 07 在來源操作序列內，對尚未確認的使用者目標最多補一次原生 seek，然後依目前播放意圖恢復。不是 UI clamp，也不執行 stop/open／loadfile／重播零秒。新 Seek、來源、task close、pause 或實際進展使舊補救失效；已分類讀取錯誤沿用原有有限恢復路徑，不同時再花這次 EOF 補救。
3. **單次位置跳轉不足以確認已恢復。** BTR 現在要求目標附近兩筆向前的位置樣本，且正在播放、非 buffering、非 completed，才解除 pending target。load reset → target、EOF 的位置值或暫停樣本不能提前丟掉目標。原始模式沿用既有確認方式。

`seek-red.log` 是在未修改的 06 production controller 上執行新增情境：分別出現 `EOF during command left native playback paused` 與 `late EOF never restored target/playback`。修復後兩案通過，並驗證自然 EOF、刻意 Seek 到結尾、從結尾往回拖、連續 Seek 合併、pause／來源切換／關閉／指令中途的新 Seek，以及不重開／不重播零秒。

控制器測試擷取實際 production methods、completed/error listeners 與鎖定 SDK log dispatch，再以確定性 stub 發事件。它證明控制器確實下達目標 native seek／play，而非只更新進度條；**沒有執行 Android mpv ABI 或解碼器**。這兩條事件競態與使用者本次實機故障的逐事件因果關係尚未證實。

## 已確認的傳輸退化及修復

| 差異 | 初版／06 的實際行為 | 07 處理 |
|---|---|---|
| 同一 Seek 世代的重疊 GET | 初版直接取消舊 GET，首塊快但可能截斷仍有效的 native 讀取；06 保留 GET，卻只為較新 Seek 世代回收預取，native 重試／demuxer 新 GET 仍可能等舊連線 | 按同軌實際 GET 的單調 request ID 排定新需求，保留舊 head 與 GET；兩個 GET 都能正確完成 |
| 已完成的舊預取 | 06 回收整個未交付 queue，連已驗證完成的第一塊也丟棄，之後重抓 | 最多保留一塊連續、已完成的資料；其餘 suffix 取消並等 producer 清理後歸還預留。仍計入原 4 MiB，沒有另設無界 cache |
| 單一讀者的視窗 | 初版可用 4 MiB；06 永久為不存在的其他 handler 預留 192 KiB，搭配 1 MiB 分塊使測試峰值只有 3,211,264 bytes，少了一個並行分塊 | 同軌只有一個 GET 時恢復原 4 MiB；實際重疊時保留 head 預留。所有新 GET 都先觸發回收，因此滿視窗舊 writer 不會擋住新 head |
| 回收時的驗證錯誤 | 已完成的 speculative piece 若發現身分矛盾，可能在 head 仍被阻塞時被回收丟掉 | 回收前檢查已觀察到的不可恢復錯誤，立即標記該軌 terminal、取消該軌需求並清理，不用取消掩蓋 Range／身分錯誤 |

修復前後證據：`scheduling-red.log`、`scheduling-green-01.log`、`candidate06-window-identity-red.log`、`tests-final.log`。06 首塊測試超過 700 ms、已完成 prefix 被抓兩次、單一讀者只能用 3,211,264 bytes，且可在已觀察到身分矛盾後接受新 GET；07 對應案例通過。最後一項是調整回收時一併發現的既有缺陷，不是使用者影音症狀的已證實原因。

### 可比較的短時量測

相同 `tool/btr_tests/transfer_comparison.dart`、相同鎖定 Dart、相同 payload／FakeNetwork、同一台 Windows，HTTP 僅 loopback。每版本每情境三次小樣本，沒有播放器、公開 CDN 或壓力／長時測試。steady 為 video 8 MiB + 內容不同的 audio 2 MiB，每個 upstream request 固定 15 ms 延遲；比較接收端完整逐 byte 資料的時間。所有成功案例另等交付計數完成，避免把尚未 flush 計帳的尾塊誤算成零。

| 情境 | 初版 | 06 | 07 |
|---|---:|---:|---:|
| 雙軌 10 MiB 交付，中位數 | 118.6 ms | 132.9 ms | 118.9 ms |
| 雙軌三次範圍 | 111.5–122.0 ms | 129.6–155.2 ms | 117.3–129.5 ms |
| 同世代重疊 GET 首塊，中位數 | 4.1 ms，但舊 GET 全部失敗 | 717.6 ms，須等 fixture 在 700 ms 解除舊阻塞 | 6.1 ms，解除舊阻塞前已交付 |
| 同世代重疊時兩個 GET 都逐 byte 正確 | 0/3 | 3/3 | 3/3 |
| 不同世代新首塊，中位數 | 4.8 ms，但舊 GET 全部失敗 | 4.9 ms | 3.6 ms |
| completed-prefetch 第一塊預取的下載次數 | 舊 GET 被取消，不具等價比較條件 | 每次 2 次 | 每次 1 次 |
| completed-prefetch 總實收 body bytes | 舊 GET 未完成，不比較節省率 | 4,325,376 | 3,276,800 |

資料：`benchmark-final-initial.json`、`benchmark-final-candidate06.json`、`benchmark-full-window-candidate07.json`。07 在這組雙軌 synthetic 條件下接近初版，completed-prefetch 減少 1,048,576 bytes 重下載。同世代首塊差異是對受控阻塞的敏感度，700 ms 是 fixture 的放行時間，**不是預測實際 CDN 延遲**。

調查中曾試把剩餘預留空間切成較小分塊，雖提高視窗使用率，但 steady requests 從 12 增至 15，時間沒有改善；該嘗試未納入程式。原始探索資料 `benchmark-*.json`／`benchmark-final-candidate07.json` 保留，最終 07 成果使用上表指定檔。樣本短且有限，不能推導 Android 流暢度、CPU／記憶體／耗電、實際網路吞吐改善比例或統計顯著性。

## 保留的契約與影音調查界線

- Range／Content-Range／body 長度、encoding、strong ETag／If-Range、完整來源 URI 固定、redirect 拒絕、MCDN/P2P 排除及同來源 Hedge／Resume 保留；沒有跨 CDN 分段拼接。
- 共享連線上限 16、handler 上限 4、每軌共享 4 MiB、音訊容量、有限重試／deadline、取消清理均保留。沒有增加線程、提高 handler 上限或放寬驗證。
- 新 EOF 補救只在 BTR transport 存在且有 pending target 時作用，最多一次；沒有擴大既有自動 reopen 預算。原始模式的 bypass 與對應控制器契約通過。
- 沒有修改 EDL、codec、AO backend、audio filter、音訊焦點、Android lifecycle、media_kit dependency 或原生 library 來源。保持候選 06 的有界影音診斷，只增加有界 `seek-eof-correction` 事件與 prefetch retained bytes。
- 傳輸飢餓、延遲首塊及過早結束都可能影響影音，但本機證據不能證明它們解釋每一次凍結／無聲。特別是 `audio-pts` 持續前進卻無聲，仍缺同次 Android AO／AudioTrack／AAudio、route／focus 與實際輸出證據，保持 UNRESOLVED。

## 驗證與交付

| Gate | 結果 |
|---|---|
| 未修改候選 06 基準 | 111/111 PASS，baseline-tests.log |
| 最終純 Dart／Fake CDN | 116/116 PASS，包含 38 個 production controller 子情境；雙軌逐 byte、連續／EOF Seek、取消、Hedge、Resume、身分、資源上限與四個阻塞 socket 清理等回歸通過 |
| 修改六個 app/test Dart 檔分析 | No issues found，analyze-changed-final.log |
| 全 app／BTR tests／pubspec 分析 | 0 errors / 0 warnings / 37 infos；規則與位置逐項等同 06，analyze-app-summary.json |
| Flutter/native | BLOCKED：缺 Windows MSVC，cnativeapi native assets 失敗，未進入案例；flutter-native-test.log |
| 工具鏈 | Flutter 3.47.7 / Dart 3.13.5；相同 SDK／lock／patch 輸入，25 個 Flutter + 9 個 material_ui reverse checks 通過；未執行上游 patch helper |
| Git | diff --check 通過；只提交候選 07 精確檔案，未 push／建立 PR／提升穩定版 |
| ARM64 DEV APK | PASS，230.8 秒；DEV package／ABI／v2 簽章／AOT buildId／來源 pin／交付副本 SHA-256 均通過 |
| Android 裝置／實際播放／真實 CDN／長時播放 | NOT RUN / UNRESOLVED；未安裝或操作裝置 |

首次 build-01 實際出現 `Unable to establish loopback connection`，保留原日誌後才用 `-ShortIpcPath`；路徑從本候選推導為 `.ipc`，僅建置程序設定 `jdk.net.unixdomain.tmpdir`，沒有更動全域 TEMP／TMP、hosts、JDK、Android source 或依賴。

交付 APK：`build/btr-candidates/playback-fix-20261018-07/PiliPlus-BTR-PlaybackFix-20261018-07-dev-arm64-v8a.apk`。同目錄 `artifact.json` 記錄來源 commit、buildId、SHA-256、大小、簽章與驗收界線。建置來源七檔固定於 `evidence/playback-fix-20261018-07/build-source.json`。

- SHA-256：`b06e2a1c5babc9e9cd2d42735b7843ee04f559f8c5ae647c1be8b75ddb81c70a`。
- 大小：24,514,139 bytes；buildId：`playback-fix-20261018-07`，已在 APK 的 `lib/arm64-v8a/libapp.so` 實讀確認。
- applicationId：`com.example.piliplus.btr.experiment.dev`；label：`PiliPlus BTR DEV`；versionName 2.1.6 / versionCode 1；minSdk 24 / targetSdk 37；僅 arm64-v8a。
- v2 簽章有效；certificate SHA-256：`fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`，與實讀候選 06 相同。
- `libmpv.so`、`libflutter.so`、media_kit helper/event loop、cnativeapi 與 datastore 共六個非 AOT library 與 06 的 SHA-256 相同；`libdartjni.so` 重建雜湊不同，不宣稱整組 native libraries 全部相同。明細在 `native-library-comparison.json`。
- `preservation.json` 確認其餘 **185 個 refs、8 個既有工作樹、427 份受保護檔案（含所列 12 份舊 APK、既有 evidence、DEV key／lock／Git config）均不變**；共享 Flutter SDK tracked state／diff 與 media_kit tracked state 也不變。沒有修改 main、穩定分支或舊候選。

後續 Android 短時驗收仍需另行授權：同裝置／網路／影片／畫質／codec／音軌比較初版、06、07 與 original；確認正常與連續 Seek、載入後真正停在指定位置並有連續音畫、自然 EOF／刻意到結尾／往回拖、pause／resume，以及無聲或凍結時同次診斷。最終實際播放目標尚未驗收，不能宣稱完全修復。
