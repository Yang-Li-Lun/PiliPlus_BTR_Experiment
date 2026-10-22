# 指定影片 4K 實機比較與代理排程候選

指定影片已核對為 `BV1kUpsedE4R`《漫步日本・东京涩谷大雨夜行【4K HDR】》，漫游看世界，上傳時間 2024-09-10 16:35，畫面播放量 68.7 萬。播放器已選中「4K 超高清」並顯示 4K、1.0X；沒有把標題中的 4K 當作畫質選取證據。

目前修正候選已完成本機回歸、建置與安裝，**修正後實機播放仍為 PENDING**。自動核准審查拒絕 ADB 開啟指定影片，尚待使用者手動將 DEV App 開至指定影片的 4K 暫停畫面後，才能繼續短測。不得將候選安裝成功視為改善通過。

## 來源與測試範圍

- 裝置：唯一核對的 POCO M2012K11AG，ADB serial `4138ece6`。所有指令指定序號及 DEV 套件 `com.example.piliplus.btr.experiment.dev`；SM-T720 未被操作。
- 對照 APK：`device-baseline-20261022-01`，診斷來源 `4f787fcde2f212c067df27b6246ebd57aed23f29`，播放核心與候選 08 `5b7e242f5e50d9fa8ca0de85bc4b7e6016899b9a` 相同。SHA-256：`391561bd31dfc5d7abfe16e87d97e3321fdaa7168a8ef7ff034ca22b1cbb2ced`。
- 原始模式是同一 APK 內完全繞過 BTR 的原始 PiliPlus 路徑；沒有操作或安裝另一個 App。
- 修正分支：`codex/btr-seek-fairness-20261022-01`；來源 commit `ed8a5bf4942945ade0990dd3bab95c6e37a0ffe3`。獨立候選工作樹仍位於 `.btr-wt/dv-1022-01`；原診斷分支與 APK 保留。
- 本次指定影片證據位於 `D:\codee\PiliPlus_BTR_Experiment\evidence\device-playback-20261022-02`。前一部 1080P+ 影片的資料只屬探索，另見第一輪報告，不作為本影片 4K 的驗收結果。
- 影片約 1:07:59。每輪先在暫停下用相同座標設定起點，再重新載入、等待 10 秒，依次拖至三個固定目標，手勢各 500 ms、每次觀察 6 秒後截圖，最後暫停及保存 JSON。不是連播整部影片或長時壓測。
- 目標為 809,872、3,099,524、1,912,297 ms（約 13:30、51:40、31:52）；起點可見的 player-open 紀錄為 279,859 ms。部分初期事件被有界視窗丟棄，不聲稱每輪全部初期事件都能從 JSON 還原。
- 不清 cache／資料、不強制相同 CDN、不改系統設定。每份 JSON 的手機與本機 SHA-256 相符。只計 `current`，不重複加總報告內的 `recent`。

## 修正前四輪 4K 結果

| 輪次 | 啟動時間軸 ms | Seek 時間軸 ms | 額外緩衝計數 | playerErrors | 本機容量拒絕 |
|---|---:|---|---:|---:|---|
| A1 原始 | 無完成樣本 | 無完成樣本（0/3） | 0，未啟動故不可當流暢證據 | 9 | 未量測 |
| B1 BTR 候選 08 核心 | 7,276 | 4,133 / 2,907 / 2,130 | 1 | 4 | 0 |
| B2 BTR 候選 08 核心 | 4,368 | 15 / 4,406 / 1,850 | 1 | 1 | 1 |
| A2 原始 | 無完成樣本 | 無完成樣本（0/3） | 0，未啟動故不可當流暢證據 | 7 | 未量測 |

原始模式兩輪在本短時流程中沒有恢復的時間軸樣本，截圖為黑畫面／Seek 待恢復；不能把缺失值填成零，也無法計算 BTR 相對原始模式的 Seek 改善百分比。原始錯誤含 network 分類，但實際 CDN、原生 HTTP、解碼或渲染原因未被確認。

BTR 六筆中位數 **2,518.5 ms**。15 ms 樣本保留，但既有量測只要求兩個位置樣本前進、playing、非 buffering，且在目標 2.5 秒內；不表示 15 ms 內解碼影格或可聽聲音已恢復。BTR 每輪仍各有一次額外緩衝，不能宣稱已流暢或沒有重大缺陷。

B1／B2 native unclassified 錯誤為 7／8，Hedge／Resume 為 126／112 與 40／37；事件丟棄 169／22。counter 保留，但被丟棄的事件不憑空補足。原始模式沒有相同 native-origin 診斷，空集合不等於零錯誤。兩輪 BTR 的影音 CDN 為同一 ALI-OV host，video totalBytes 為 12,409,224,508，平均需求約 3,041,683 bytes/s；這不證明原始模式也使用相同連線條件。

## 已定位的局部瓶頸與最小修改

`B2-combined.json` 的事件鏈：19,829 ms 發出第二次 Seek；19,833 ms 新 video GET 被接納；21,966 ms 同 generation 2 的 audio GET 因 `handler-capacity` 回覆 **503**，activeHandlers=4；21,970 ms 隨即有 player-error。這是本機代理容量拒絕的直接證據，不能歸咎 CDN。

來源顯示四個執行槽只會在 socket flush 超過 100 ms 或回應結束時釋出；若舊回應持續被消費、每次 flush 都很快，它們可長時間佔著槽，新音訊則在兩秒 admission deadline 到期後被拒絕。這不等於應取消舊 GET；舊 GET 仍有消費者。

候選在成功 flush 完成後，只有存在等待者時才讓出執行槽，讓已被喚醒的請求先執行。原回應及已驗證資料仍保留，下一次產出前沿用既有 acquire 重新取得槽。新增 `proxyCooperativeYields` 計數供實機確認路徑是否實際發生。

四個執行槽、八個回應、每軌 4 MiB、上游 16 連線、15 秒 flush deadline、來源／ETag／Range／編碼／長度驗證與既有回退均未放寬。沒有取消仍有效的 GET，也沒有關閉 Hedge／Resume；大量 Hedge 的效益與成本尚未被此修正證明。

## 本機驗證與交付

- 原來源的兩個新增案例確實失敗：快速 flush 後等待請求逾時；四條持續交付中的 HTTP 回應使新音訊收到 503（`fairness-red.log`）。
- 修正後相關 10 項回歸通過：新請求可接納、舊回應逐 byte 一致、取消可釋放所有容量，並保留真正滿額／上游停等時的拒絕（`fairness-green.log`）。
- 完整純 Dart／loopback BTR suite **139/139 PASS**；包括既有來源完整性、GET 重疊、Seek／EOF、回退、關閉與容量回歸（`tests-fairness-full.log`）。這不是 Android mpv 音畫輸出測試。
- 三個修改檔分析 **No issues found**；git diff --check 通過。
- ARM64 DEV build **PASS，65.4 秒**。沿用本工作樹先前確實遇到 IPC 問題後使用的 repository-local `.ipc`，沒有全域設定修改。
- package、ABI、相同簽章、相同 permissions 與 AOT Build ID 已核對；`libmpv.so`／`libflutter.so` 與對照 APK 逐 byte 相同。
- 已成功覆蓋安裝，手機 APK SHA-256 相符；沒有清除使用者資料。修正後的播放驗證 **PENDING**，完整 Flutter/native 本次未執行。

候選 APK：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\dv-1022-01\build\btr-candidates\seek-fairness-20261022-01\PiliPlus-BTR-SeekFairness-20261022-01-dev-arm64-v8a.apk`。

SHA-256：`f235213c370f197d4371be256851c0df8a08801cb6671bfda689632a818bc68d`。Build ID：`seek-fairness-20261022-01`。未推送、發布或提升任何穩定分支。

## 尚未完成與環境限制

修正後的兩輪 4K 比較、快速連續 Seek 與暫停／繼續尚未完成，不能建議以本候選取代已量測的基準。自然 EOF、長時間播放、可聽聲音／全程音畫同步與正式 ANR 監控也未驗收。

本次自動核准審查拒絕 ADB 開啟指定影片及準備暫停的指令，只回報 `blocked by policy`，未提供詳細原因，指令未執行；沒有使用另一個工具自動開啟。另有前一輪回裝候選 08 與清除兩個編譯輸出目錄的指令遭同樣拒絕，詳見第一輪紀錄；未改換方式繞過。

主工作樹原有 AGENTS.md 修改保留。執行期間另出現未追蹤 `.codex-remote-attachments/`，只查看了檔案 metadata，來源未判定，未修改、stage 或刪除。新候選的編譯輸出因清理拒絕仍保留，舊 APK、歷史 evidence、簽章 key 與共享 SDK/cache 沒有刪除。
