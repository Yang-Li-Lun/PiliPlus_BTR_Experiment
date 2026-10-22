# POCO 短時播放與 Seek 實機量測

2026-10-22 的短時測試沒有建立 BTR 相對原始模式的 Seek 改善證據，也不足以定位單一瓶頸。依本次任務的停止條件，停止效能迭代，保留候選 08 的播放實作，不新增未經證實的播放修補、不提升穩定分支。

手機目前保留 `device-baseline-20261022-01` DEV 量測版，播放已暫停。它與候選 08 使用相同播放／傳輸來源，只增加手動保存診斷的功能。重新安裝原候選 08 的動作遭自動核准審查拒絕，並未執行，不能宣稱已回裝。

## 版本與保留範圍

- 主工作樹 `D:\codee\PiliPlus_BTR_Experiment`：`codex/btr-maintenance`，`a86c5daae6f614485f5b4542ceea13eb68c70729`。本次開始時只有使用者修改的 `AGENTS.md`；其內容與 hash 保留。
- 既有穩定參照：`788faa8abee2ff325205d89a9fa24869821685e3`。`main` 含 BTR，沒有將它誤當純上游，也沒有在本次重新安裝／驗收該穩定 APK。
- 手機起始安裝與本次播放基礎：候選 08，`5b7e242f5e50d9fa8ca0de85bc4b7e6016899b9a`，舊 APK 與原分支仍保留。
- 新獨立工作樹：`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\dv-1022-01`；分支 `codex/btr-device-validation-20261022-01`。
- 診斷功能 commit：`4f787fcde2f212c067df27b6246ebd57aed23f29`。只有診斷 exporter、BTR 設定頁、DEV build 開關及既有 channel 測試的依賴宣告四個檔案改動。報告另以文件 commit 保存。
- 本次 evidence：`D:\codee\PiliPlus_BTR_Experiment\evidence\device-playback-20261022-01`。`measurement-summary.json` 可由同目錄 `summarize.ps1` 從五份原始 JSON 重算，並先核對匯出 hash。只計各報告的 `current`，不把重複的 `recent` sessions 再加總。
- 未修改 CDN 身分、strong ETag、If-Range、Range／長度／編碼驗證、完整性、重試、回退、排程或資源上限。未 push、建 PR、發布或改寫既有 refs。

## 裝置與方法

唯一操作目標為 POCO `M2012K11AG`／`alioth`，ADB serial `4138ece6`。同時連線的 `SM-T720` 未被指定操作。`device.ps1` 每次輸入前檢查裝置清單中只有這一台匹配型號，再以 `-s 4138ece6` 核對 model／brand 及前景套件；不符合即拒絕輸入。

只操作 `com.example.piliplus.btr.experiment.dev`。登入由使用者完成並明確交還操作後才測試。沒有清除資料、取得 Root、改系統安全設定或安裝其他 App。安裝採相同簽章的 `install -r`，登入狀態保留；套件 firstInstallTime 仍為 2026-10-22 17:37:17。

比較使用同一 DEV APK 內的「原始 PiliPlus」bypass 與「BTR 整合加速」，不是另外安裝獨立上游 App。影片為 `BV1ECHj6eENm`，約 23:55，畫面確認 1080P+、1.0X。測試期間未切換網路或手動改畫質，BTR 使用自動線程與預設 CDN。原始模式的實際 CDN／codec 未固定與核對，不能聲稱所有網路與解碼條件完全相等。

執行順序 A1 原始 → B1 BTR → B2 BTR → A2 原始。每次經播放器選單重新載入影片，三次 Seek 的 JSON 目標均完全一致：284,914、1,090,419、672,750 ms。B1／B2／A2 的三次操作區間分別為 26.701／26.300／26.131 秒；這不含所有載入、觀察與暫停後匯出時間。A1 的前兩次 Seek 間隔較長，A1／B1 的第一次 Seek 前等待也比 B2／A2 長。原計畫每輪約 60 秒，實際採更短的重複操作與暫停匯出，未做等長或長時間壓測。

沿用未修改的 `BtrMetrics.position`：Seek 後取得兩筆位置樣本，第二筆前進、處於 playing 且非 buffering，並在目標 2.5 秒內才記錄 `seekTimelineMs`。這是播放器時間軸恢復，不是首張解碼影格、可聽聲音或音畫同步的精確量測。`bufferingEvents` 排除啟動期與尚待恢復的 Seek。保留 A1 的 11 ms 原始數值，但不把它解釋成 11 ms 內畫面已恢復。

匯出只在暫停後手動觸發，不增加背景量測 timer。新功能限 `BTR_DEVICE_TEST=true` build，寫入本 App external files 目錄，flush 後逐 byte 核對；五份實機檔案再以 ADB pull 與手機 SHA-256 交叉核對成功。不透過其他 App 的檔案選擇器，不改播放器量測與資料隱私契約。

## 實測結果

| 輪次 | 啟動時間軸 ms | 三次 Seek 時間軸 ms | 非啟動／非 pending Seek 緩衝 | playerErrors | BTR 終止失敗／容量拒絕 |
|---|---:|---|---:|---:|---|
| A1 原始 | 21,076 | 1,820 / 11 / 966 | 3 | 14 | 未量測 |
| B1 BTR | 2,236 | 1,583 / 1,356 / 1,031 | 0 | 0 | 0 / 0 |
| B2 BTR | 2,343 | 1,230 / 341 / 1,108 | 0 | 0 | 0 / 0 |
| A2 原始 | 1,714 | 1,101 / 600 / 883 | 0 | 0 | 未量測 |

原始模式六筆 Seek 中位數 **924.5 ms**，BTR 六筆 **1,169 ms**，本批 BTR 多 **244.5 ms／26.45%**。這是小樣本描述值，並非一般化的效能退步或改善結論；預熱長度、原生 cache、CDN／網路時變未完全控制。兩輪 BTR 的最慢樣本為 1,583 ms，原始為 1,820 ms；樣本不足以建立尾延遲優勢。

A1 有三次額外緩衝與 14 個 player error 事件，主要分類為 network；A2 為零。不能只用 A1 對 BTR 宣稱消除卡頓，亦不能將這些分類直接歸因為 CDN 故障。啟動量測涉及歷史位置重新載入與不等長觀察，僅逐輪列出，不推導啟動改善百分比。JSON 的 elapsedMs 包含暫停、設定頁與匯出時間，不當作有效播放時長或計算每小時故障率。

B1／B2 另外仍記錄 **4／3 個未分類 native error**（ffmpeg／vo）；`playerErrors=0` 不表示完全沒有錯誤訊息。原始模式沒有訂閱相同 native log 診斷，空集合不能當作原生錯誤為零。五輪的事件視窗 `eventsDropped=0`，但這不等於完整記錄原生播放器所有內部行為。

額外 C1 短時邊界測試：三次 Seek 間隔約 826／828 ms，指令全部 command-complete；中間 Seek 被下一次取代，只有 **552／1,793 ms 兩筆完成的時間軸恢復**。最後目標已恢復，暫停／繼續後截圖可見畫面與位置變化。C1 的額外緩衝、playerErrors、requestFailures、terminalFailures、容量拒絕均為零，另有三個未分類 native error。不能報成三次獨立 Seek 恢復全部完成。

候選 08 原 APK 上的初步探索也保留在 `protocol.json` 與監控截圖；原始／BTR 的 Seek 分別觀察到 5,878／1,151 ms，但目標與手勢不同，且原始啟動含刻意暫停，**不納入比較與改善百分比**。

## 瓶頸判斷與停止理由

- B1／B2 的 requestFailures、terminalFailures、proxyCapacityRejections 均為零。執行槽峰值仍達 4／4；沒有容量拒絕不代表從未等待。上游連線峰值為 8／10，資源上限為 16，C1 為 11／16。沒有足夠證據支持提高線程或回應上限。
- BTR 影音來源均為 `upos-sz-mirroraliov.bilivideo.com`，身分為 `single-origin-strong-etag`；每軌 ordered reservation 峰值未超過 4 MiB。這證明本批保留既有界線，不能推導原始模式也選同一 CDN 或認定來源是延遲主因。
- B1 有 3 Hedge／1 Resume，B2 有 8／5，C1 為 0／0。沒有相同請求條件下的反事實對照，無法把額外請求直接定為此次 Seek 延遲根因，未關閉救援或放寬安全限制。
- ffmpeg／vo 的未分類錯誤不足以辨識解碼、渲染、AO 或音訊路由原因。C1 最後快照可見 opensles、48 kHz、雙聲道、未靜音、gpu 與非 EOF；這不證明實際可聽聲音、全程無掉幀或音畫同步。

實際卡頓／Seek 延遲的單一根因維持 **UNRESOLVED**。本次可採用的改動僅為可驗證的診斷保存；未取得足以安全選擇新播放修補的證據，按授權停止，避免盲目修改正在消費的 GET、增加並行度或削弱驗證。

## 驗證層級

| 項目 | 本次結果 |
|---|---|
| 診斷相關 Dart 分析 | 0 errors、0 warnings、1 個 async IO style info；見 analyze-instrumentation.log |
| 既有診斷 Flutter channel contract | 10/10 PASS；見 diagnostics-channel-02.log。涵蓋既有 channel，新增 App 目錄分支由五次實機匯出及 hash 核對驗證 |
| 依賴與 SDK | 相同 Flutter 3.47.7、lock 與 patch 輸入，沿用候選 08 SDK/cache；未執行修改種子 SDK 的 patch helper |
| ARM64 DEV build | PASS，約 284 秒。初次實際遇到 loopback IPC 錯誤後，用 repository-local `.ipc` 與單程序 `jdk.net.unixdomain.tmpdir` 重試成功；未改 TEMP／TMP、JDK、hosts 或依賴 |
| APK 與安裝 | exact DEV package、ARM64、相同簽章／permissions；安裝成功且手機 APK hash 相符 |
| 播放／Seek | 已執行本文件所列短時對照、快速連續 Seek、暫停／繼續、重新載入；不能擴充為完整實機驗收 |
| 崩潰／重大缺陷 | 操作期間未觀察到崩潰；未建立正式 ANR 監控，不能宣稱所有嚴重問題均已排除 |
| 尚未執行 | 自然 EOF、結尾往回 Seek、4K／高碼率、多影片／多網路、長時間播放、可聽聲音與全程音畫同步驗收 |
| 完整 Flutter/native／全部離線 suite | 本次未重跑；候選 08 的歷史測試結果僅屬既有 evidence，不算本次通過 |

## APK、回退與最終建議

目前已量測並安裝的 DEV APK：

`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\dv-1022-01\build\btr-candidates\device-baseline-20261022-01\PiliPlus-BTR-DeviceBaseline-20261022-01-dev-arm64-v8a.apk`

SHA-256：`391561bd31dfc5d7abfe16e87d97e3321fdaa7168a8ef7ff034ca22b1cbb2ced`。

可回退候選 08 原 APK：

`D:\codee\PiliPlus_BTR_Experiment\.btr-wt\pf-1018-08\build\btr-candidates\playback-fix-20261018-08\PiliPlus-BTR-PlaybackFix-20261018-08-dev-arm64-v8a.apk`

SHA-256：`17a5a4c8f74340d68c44e2dd8bac6c1e5ff270be69c168d481678403f16913fb`。

兩者 certificate SHA-256 均為 `fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`；`libmpv.so`／`libflutter.so` bytes 相同，證據在 native-library-hashes.json。量測 APK 對應上述診斷 commit 的四檔變更；不是新播放核心。

建議保留候選 08 的播放實作，手機暫留已量測的 `device-baseline-20261022-01` DEV 版；不採用額外效能改動，不將此次短測當作穩定版升級依據，也不宣稱 BTR 已普遍優於原始模式。既有穩定 APK、候選 08 APK、分支與歷史 evidence 保留。

自動核准審查在執行前拒絕「重新安裝候選 08 並開啟測試影片」，僅回報 `blocked by policy`，沒有詳細原因。因此沒有回裝、沒有改換方式重試；最終套件 hash／暫停狀態記錄在 device-final.json。將來若獲允許回裝，可在再次唯一核對同一 POCO 與 package／簽章／hash 後，以覆蓋安裝保留資料；本次不提供已執行回退的假象。

本次清理也受相同自動審查限制：已確認兩個新候選編譯輸出 `build/app` 與 `build/media_kit_libs_android_video` 都在本工作樹內且無 reparse point，保留交付 APK 後嘗試移除，但指令在執行前被拒絕。兩目錄約 **733 MiB** 仍保留；見 cleanup-plan.json／cleanup-result.json。沒有繞過限制或清理共享 SDK/cache。測試證據、五份手機 App 專屬診斷 JSON 與本次 App 目錄中的 UI dump 保留，其他專案及使用者資料未清除。
