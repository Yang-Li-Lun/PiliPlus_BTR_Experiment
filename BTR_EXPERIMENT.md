# PiliPlus BTR Android 功能整合

本專案是獨立的 Android DEV 工程。這一階段以 `788faa8ab` 為基準，保留使用者已確認順暢的整合模式預設傳輸、CDN 策略及 media_kit/mpv，優先增加設定與監控。新增功能尚未經 Android 實機驗證。

## 設定與監控整合（2026-10-16）

- 本機分支 `codex/btr-settings-monitor`；還原標籤 `btr-before-monitor-20261016` 固定於 `788faa8abee2ff325205d89a9fa24869821685e3`，`main` 未移動。修改保留在工作樹，未推送遠端。
- 設定入口：設定 → 播放設定 → **BTR 功能設定**；播放中也可從播放器「更多設定」→ **BTR 功能設定與監控** 進入。
- 僅提供「原始 PiliPlus」與「BTR 整合加速（預設）」。保留原模式設定鍵，舊 `threaded`／`switcher` 會遷移為 `combined`；`original` 不變。
- 新設定存於既有 Hive setting box 的 `btrSettingsV2`，不讀寫其他帳號或設定內容。自動線程保留 8→12→16；手動提供 4／8／16／32／64／128。手動值會作用於共用傳輸排程，但目前 Android 資源硬上限仍是 16，並保留每軌 4 MiB 有序視窗、音訊保留容量、Hedge 預算及 CDN 拒絕退讓。32／64／128 不代表可突破 16 個上游連線。
- CDN 偏好可選自動、ALI-OV、ALI、COS，只調整既有合格候選順序；保留驗證、競速與失敗備援，不增加任意來源或跨 CDN 分段拼接。
- 每次播放固定一份傳輸設定；模式、線程與 CDN 變更在重新開啟影片／切換畫質時套用。監控、詳細資訊、錯誤與事件顯示偏好可即時變更。
- 播放畫面的小型監控使用 IgnorePointer，不攔截手勢。完整監控顯示總／分軌活動請求、設定／實際／資源上限、排隊、實收與有效交付速率、實際 CDN／選源／失敗、緩衝／播放／時間線、失敗／重試／Hedge／取消／續傳及累計交付量。詳細資訊與事件預設收合，JSON 僅在點擊複製時產生。
- 監控每秒刷新小範圍 UI；關閉後移除 UI 計時器，不增設網路探測或 mpv 輪詢。每軌速率以 250 ms 有界 bucket 計算五秒平均。實收只計已讀 HTTP body（含 probe／Hedge／重試），不含協定開銷；有效交付為 loopback socket 交付，並非解碼量。原始模式、不適用軌道及未知數值保持 null／「未取得」。
- 診斷只保留最近 8 次 session、每次 128 個事件及 32 次 Seek。CDN 僅記錄 host，錯誤僅記錄受控代碼／HTTP 狀態；不記錄完整 URL、簽名 query、ETag 內容、Cookie、Token 或帳號。

| 本階段驗證 | 結果 | 證據 |
|---|---|---|
| 純 Dart／本機 Fake CDN／Hive 磁碟重開 | **46/46 PASS**；涵蓋兩模式與遷移、六種上限實際 permit、手動低上限 429 退讓後完整交付、高設定資源限制、CDN 偏好／備援、分軌流量與未知值、既有 Range／身分／Hedge／續傳／取消 | `evidence/btr-monitor-20261016/tests-final.log` |
| 所有修改的 Dart 檔與 BTR 測試靜態分析 | **No issues found** | `evidence/btr-monitor-20261016/analyze-final.log` |
| Flutter/native 測試 | **環境阻擋，未進入案例**：既有 cnativeapi 缺 Windows MSVC C compiler | `evidence/btr-monitor-20261016/flutter-native-test.log` |
| Android UI、實際播放／CDN、CPU／記憶體開銷及長時測試 | **未驗證**；未操作手機，未建置或安裝新 APK | 本階段工作範圍 |

以下 APK、雜湊及 28 項測試是基準版本的既有交付紀錄，不是本階段修改後的建置或驗收結果；歷史 evidence 與 APK 均未更動。

## 基準版本既有交付結果（2026-10-16）

- APK：`build/btr-dev/PiliPlus-BTR-Experiment-2.1.6-dev-arm64-v8a.apk`
- SHA-256：`a7428322daa4f667f1b5cc99c0a5dc3a7b7c62a125e36f0571493bc3b739ed2a`
- 大小 24,435,767 bytes；ARM64；versionName 2.1.6 / versionCode 1；minSdk 24（Android 7.0）/ targetSdk 37。
- APK 實讀 applicationId：`com.example.piliplus.btr.experiment.dev`，label `PiliPlus BTR DEV`，launch activity `com.example.piliplus.MainActivity`。所有合併 Provider authority 使用實驗版 applicationId，具備與原版並存的封裝條件；未進行實際並存安裝驗收。
- 本機 DEV RSA-2048 簽章；`apksigner verify` 通過，APK Signature Scheme v2 為 true。建置原件與交付副本 SHA-256 完全一致。

| 驗證 | 結果 | 證據 |
|---|---|---|
| 純 Dart 政策/排程/傳輸/指標 | **28/28 PASS**，真實 HTTP 僅限本機 Fake CDN | `evidence/btr-tests-final-03.log` |
| 修改的 Dart 檔案及新測試靜態分析 | **No issues found** | `evidence/analyze-changed-final-03.log` |
| 全專案 Dart 靜態分析 | **0 errors / 0 warnings / 37 infos**；提示皆為上游既有檔案/既有 package 名稱 | `evidence/analyze-full-final.log` |
| 完整上游 Flutter/native test suite | **未通過環境前置條件**：cnativeapi 缺 Windows MSVC，未進入測試案例 | `evidence/btr-tests-01.log`, `evidence/btr-tests-02.log` |
| Android ARM64 DEV release | **PASS**，第三次建置 218.4 秒 | `evidence/build-dev-03.log` |
| APK package/ABI/minSdk 與簽章 | **PASS** | `evidence/apk-badging.txt`, `evidence/apk-signature.txt`, `build/btr-dev/artifact.json` |
| Git whitespace | **PASS** | `evidence/diff-check-final.json` |
| 舊專案 HEAD / 完整 Git status | **前後一致**，本次未寫入舊專案 | `evidence/isolation-check.json` |
| Android 實機/真實 CDN/效能比較 | **UNVERIFIED，未執行** | 本次授權邊界 |

原始失敗日誌均保留。28 項測試包含 6 MiB 以上、內容不同的影音雙軌、亂序、精確 Range、同長度/同 ETag/不同 CDN 內容不混合、部分前綴續傳、弱驗證退回單串流、錯誤資料拒絕、候選耗盡、MCDN-only 拒絕、Hedge/Seek 取消與清理，以及自適應與指標邊界。測試不能取代 mpv 在 Android 裝置上的整合驗收。

## 來源與隔離

- 上游：<https://github.com/bggRGjQaUbCoE/PiliPlus>
- 乾淨 clone 基準：`3d0aed958b3b7e59c39c121196f189f429719904`；初始化時已確認 status 為空，`evidence/upstream-commit.txt` 記錄基準，`evidence/clone-provenance.json` 保存 clone reflog 與獨立 Git 目錄資訊。
- 工作目錄：`D:\codee\PiliPlus_BTR_Experiment`；獨立 `.git`、Flutter SDK、Pub cache、Gradle cache、DEV signing key、建置產物、設定與 evidence。
- 原專案 `D:\codee\PiliPlus` 僅唯讀查詢 Git 狀態及工具路徑，沒有匯入其修改或舊實驗補丁。
- Android SDK 使用現有安裝；SDK 自動下載關閉。Flutter 使用私有 3.47.7，套用上游現有 CI 所需的 Flutter/material_ui patches。沒有執行會修改全域 Git 設定的上游 patch helper。
- DEV applicationId：`com.example.piliplus.btr.experiment.dev`；名稱 `PiliPlus BTR DEV`。原本 Java/Kotlin namespace 維持 `com.example.piliplus`，FileProvider authority 仍由 `${applicationId}` 展開，快捷方式 action 另行隔離。
- 未安裝、未操作手機、未 push、未建立 PR。

## 附件分析與授權

完整閱讀兩份附件後，以傳輸行為分解移植；附件中的註解、UI 提示與網站注入指令不作為本次操作授權。

| 附件 | SHA-256 | 授權處理 |
|---|---|---|
| Bilibili 线程撕裂者-2026.10.8.1.user.js | `7766622730f6d24febb89cd3669ff0c384997c260c652668082d84af61724dd9` | MIT，保留 `third_party/BTR-LICENSE.txt` 與適用原始註記 |
| Bilibili Video CDN Switcher (Reliable - Hotspot Optimized)-0.3.1.user.js | `6a5143258ebbf58ed8c55d5508db03df8057190836c45427819a357911428cad` | No License，只獨立實作行為規格，不複製程式碼或附帶原腳本 |

PiliPlus 的 GPLv3 `LICENSE` 保留；本專案新增整合程式碼隨本專案適用 GPLv3，參考 BTR 的部分同時保留 MIT notices。參考專案：<https://github.com/MrTangLuyao/Bilibili-thread-ripper>。

BTR 附件不是單一通用下載器：

1. Range/resolver/downloader 核心具備 206 精確範圍檢查、候選來源池、量測、優先佇列、分段、Hedge、重試與續傳。橋接層預設啟用 autoConcurrency；底層 normalize 的單獨預設不同，不能混為一談。
2. 完整接管模式使用 MSE、init/SIDX、分段時間線、video/audio 視窗、播放器期限與 buffer 目標。45 秒 buffer、2.5–10 秒起播調整及 MSE quota 處理屬於此模式。
3. 相容 Range 模式接管符合條件的 Fetch/XHR Range，完成所請求範圍後交回網頁播放器；不能把完整 MSE 的時間線排程當成此模式必有行為。番劇相容路徑與一般影片也不同。
4. Live 是獨立、預設關閉的 fMP4/HLS 整段抓取：急迫/普通/預取 Hedge、短 TTL segment cache、有限預取與猜測下一段，並非 VOD byte-range 拼接。
5. DOM、頁面 hook、品質切換橋接、通知與面板不是 Android 傳輸的可直接移植部分。

Switcher 的有效行為是先選 ALI-OV、提供 ALI/COS 與合格原始備援、過濾 MCDN/P2P、保留 Dolby/FLAC 音訊結構。瀏覽器的遞迴 API 改寫與攔截不移植；Android 僅在既有 DASH 畫質/音質選定後處理該 representation 的 URL 集合。

## 目前兩種模式

入口：設定 → 播放設定 → **BTR 功能設定**。切換後重新開啟影片或切換畫質生效，不會中途混用新舊來源。

| 模式 | 選源 | 傳輸 |
|---|---|---|
| 原始 PiliPlus | 上游原有 VideoUtils / 使用者 CDN 設定 | 原生 media_kit/mpv，完全繞過實驗代理 |
| BTR 整合加速（預設） | ALI-OV、ALI、COS、合格原始備援；可調整合格 CDN 偏好 | 選源驗證後套用同來源 BTR 多 Range、動態分段、Hedge／續傳 |

整合模式先做有限的 64 KiB Range 選源驗證。自動優選下 ALI-OV 有 120/300 ms 的先行機會，但無法回傳合法內容時不強制使用；設定 CDN 偏好時將偏好來源排在首位，保留相同驗證與備援。URL 只改寫一次；影片與音訊分別持有候選池、來源身分、有序視窗及取消狀態，共用連線預算。

## 已移植與明確差異

| 機制 | Android 實作與差異 |
|---|---|
| HTTP Range 並行 | `network.dart` / `transport.dart`；嚴格 206、Content-Range 起訖/總長、Content-Length（若提供）、identity encoding、精確 body 長度。拒絕 redirect，不隨機向任意 host 轉送簽名網址。 |
| 多 CDN 競速 | 一次至多 3 個候選，0/120/300 ms 啟動，整次至多 9 個；首個合法 64 KiB 結果獲選，取消並回收其他請求。沒有週期性背景探測。 |
| 多 CDN 分段分配 | **安全退回單一實際來源，未啟用跨來源分段拼接。** 附件依總長等條件處理來源，不能滿足本任務更嚴格的內容一致性要求。不同 host 即使長度與 strong ETag 相同也不是證明。 |
| 內容身分 | 選定的完整 URI、總長與 strong ETag 固定。後續每段與同來源續傳帶 If-Range 並重新驗證。身分變更立即停止，不藉忽略 ETag、相同長度或相同短樣本放行。沒有 strong ETag 時使用單一不分段回應，不保留部分資料做續傳。 |
| 自適應線程 | Android 8→12→16；依有效交付吞吐量、播放需求、低 buffer、飽和與待辦工作啟動 10 秒試升，無收益退回並冷卻；412/429 同一冷卻期只降一次。未移植瀏覽器最高 64 線程、完整 15/30 秒起播 boost 控制器。 |
| 動態分段 | EWMA 連線速度 × 0.6 秒，64 KiB 單位、64 KiB 至 1 MiB。首次與非零 Seek Range 的第一塊為 64 KiB；只在單一來源/身分允許時重用初始樣本。 |
| 速度與健康 | 有界初始候選速度量測、失敗來源在本 session 隔離、選中來源 EWMA、拒絕碼退讓。未啟用跨 CDN smooth weighted round-robin、每四段探索、TTL 重測與背景復活，因來源已固定。 |
| 優先權 | 每次放行重新評估目前阻塞頭段；音訊優先且保留容量，音訊也有上限；相同優先序 FIFO。未移植 MSE/SIDX 的逐段播放 deadline、完整 aging 及瀏覽器 video/audio 視窗控制器。 |
| Hedge | 僅有需求且阻塞頭段、低緩衝/非播放預載、連線有餘額時，同來源 rescue；250–900 ms 自適應延遲，每軌至多一個副本，獲勝後取消並等待 loser 清理。沒有跨來源 Hedge 拼接。 |
| 重試/續傳 | 每塊至多 3 輪、500/1000 ms 延遲、25 秒總上限；單次 15 秒、header 5.5 秒、body idle 4 秒。至少 32 KiB 的已驗證同來源前綴才續傳剩餘 Range。壞 Range、ETag、encoding、overrun 不以重試掩蓋。 |
| 有序與記憶體 | 每軌至多 4 MiB 有序預留，影片/音訊不混合；另有至多一塊 1 MiB Hedge 及重試前綴/暫存副本，64 KiB 選源樣本與 HTTP/native buffer。因此 4 MiB 是有序視窗上限，不是整個 app 記憶體上限。 |
| 連線/釋放 | 全域最多 16 個有效 upstream 請求，完整讀完才重用 client；取消時關閉該連線、取消 body reader，再歸還 permit。idle client pool 至多 16，idle 15 秒。回應已送出後出錯直接截斷，不在同一回應重送前綴。 |
| Seek/生命週期 | Seek 立即取消舊需求，不等上游原本的 buffer-first 等待；新 Range 優先頭塊。換畫質/影片、結束及初始化失敗釋放 session。有限重試耗盡後結束該 track，需使用者重新開啟；不自動無限重連。 |
| Flutter/播放器 | 保留原 UI、media_kit/mpv、codec 選擇、Dolby/FLAC 原有列表、音訊 filter。只增加設定入口、選定 DASH URLs 的擷取及本機傳輸接線。直播、DURL、離線、投屏不加速。 |

代理綁定 `127.0.0.1` 隨機埠，路徑有 192-bit 隨機 capability，限制 Host、無 Origin/查詢參數、GET/HEAD 與最多 4 個在處理的本機請求。Android network security config 僅為 loopback 開啟明文 HTTP；remote 媒體候選必須 HTTPS。選定 DASH 軌的候選均不合格或全部驗證失敗時，終止這次實驗 track，不透過 native fallback 重新引入 MCDN/P2P，也不強制接上失效 CDN。原始模式、不適用的 DURL/手動 URL 路徑，以及本機服務無法建立的情況會明確記錄 native path/fallback。

## 指標的意義與限制

設定頁可複製當前及最近 8 次 session 的 JSON；每次最多 128 個事件及 32 次 Seek，超出有丟棄計數。實驗紀錄不保存 URL query、Cookie、帳號、原始 player error。

- `startupTimelineMs`：session 建立到播放器時間實際前進且未 buffering。不是首個解碼畫面或使用者按下播放至 API 回應的完整時間。
- `seekTimelineMs`：Seek 要求到目標附近的播放時間再次前進。緩衝次數排除起播與 Seek，另有 player error 與傳輸失敗次數。
- `loopbackDeliveredBytes` / `deliveredByTrack` / `loopbackDeliveredBps5s`：成功交給 loopback socket 的有序資料與最近五秒速率；不是已解碼量，也不是精確「不同 byte offset 的去重流量」。
- `networkBytesIncludingProbesAndHedges` 包含選源、失敗前綴與 Hedge 浪費，不能拿來當有效播放吞吐量。
- 所有模式另取 mpv `cache-speed` 與 `demuxer-cache-state/total-bytes`。前者是主 demuxer 的輸入速率估計，後者是目前 packet queue 大小，**不是累計下載量**；未提供時為 null，分離音訊未必包含在主 demuxer 中。依據：[mpv properties](https://mpv.io/manual/stable/#properties)。
- **原始模式的精確累計傳輸量/音訊吞吐量尚不可由上游 mpv 介面量得**，代理統計為 null。兩模式可比較時間線/緩衝/player errors 與原生主 demuxer 速率；精確代理交付量只適用於實際走代理的軌。不可把 null 當 0，或把兩種口徑畫成等價數據。

## 本機重現

工具全部放在此專案。先 clone Flutter 3.47.7 至 `.toolchain/flutter`，以該私有 SDK 執行 `flutter pub get --enforce-lockfile`，並設定 `PUB_CACHE=<repo>/.toolchain/pub-cache`，再執行 `tool/btr_prepare.ps1` 套用上游既有 patch。

```powershell
# 純 Dart 傳輸與政策測試：只連本機 Fake CDN
./tool/btr_test.ps1

# 靜態分析
$env:PUB_CACHE = Join-Path $PWD '.toolchain/pub-cache'
./.toolchain/flutter/bin/flutter.bat analyze --no-pub

# ARM64 DEV APK；路徑參數為本機既有工具，沒有部署/安裝動作
./tool/btr_build.ps1 -AndroidSdk '<existing SDK>' -JavaHome '<existing JDK>'
```

本機第一次 Gradle 出現 `Unable to establish loopback connection`；依任務規則，後續命令加入 `-ShortIpcPath`，由腳本計算 repo-local `.ipc` 並僅設定該程序的 `JAVA_TOOL_OPTIONS=-Djdk.net.unixdomain.tmpdir=...`。未更動 Windows TEMP/TMP、hosts 或 JDK。Flutter 自動選用既有 Android Studio JBR 21.0.10；`JavaHome` 供本機 DEV keytool/工具使用，不覆寫 Flutter 全域 JDK 設定。

第二次建置進入 Java 編譯後，發現私有 Git 依賴 checkout 缺少超過 Windows 傳統長度限制的檔案：WebView 69 個、chat packages 2 個，範例完整路徑 267 字元。`tool/btr_repair_git_cache.ps1` 只補回私有快取內實際缺少的檔案，使用各自鎖定 HEAD 與 per-command `core.longpaths=true`，不覆蓋既有檔案、不升級依賴、不修改全域 Git。`btr_prepare.ps1` 已包含此步驟，缺檔清單與修復日誌保留在 evidence。

傳輸測試 runner 位於 `tool/btr_tests`，有獨立 lockfile。它直接解析本 repo 的 production Dart files，沒有複製實作；只排除測試用不到的 Flutter/桌面 native import closure。根 pubspec 新增的 test_api/matcher 為原 lockfile 已有版本，不升級任何應用程式依賴。

第一次完整 `flutter test` 在測試收集前，因上游 `cnativeapi` 需要 Windows MSVC 而失敗；停用 native assets 也被套件需求拒絕，兩次日誌都保留。沒有修改 cnativeapi 或全域工具鏈來掩蓋此結果。完整上游 Flutter/native suite 與 UI 執行驗收因此不是 PASS；純 Dart 傳輸測試及 Android APK 建置另列結果。

## 後續 Android 人工驗收（本次未執行）

1. 由使用者另行授權安裝 DEV APK，確認 `PiliPlus BTR DEV` 與原 app 並存、原 app 資料未變。本版本使用本地 DEV key，並非官方簽章。
2. 使用相同裝置/網路/影片/畫質/codec/音質，固定一次播放長度與 Seek 點；每次重新開啟影片。先短片確認音畫正確，再測高碼率。兩模式順序交錯，避免把 CDN 時段或 native cache 差異當成策略收益。另驗證設定重啟保存、手動上限、CDN 偏好備援、監控顯示與手勢。
3. 各模式記錄起播、每次 Seek、緩衝、錯誤、原生速率與有效代理交付量；複製 JSON。檢查 `tracks` 實際 host、identity、terminal、連線峰值及 native fallback，不能只看所選模式名稱。
4. 驗證連續 Seek、取消/返回、換畫質、切音質、影片末端、暫停恢復、背景/前景、音訊單播；確認沒有混軌、花屏或音畫不同步。錯誤時保留紀錄並停止該輪，不反覆對 CDN 重試或壓測。
5. 驗證 Dolby/FLAC、字幕/彈幕/PiP 及一般導覽仍按上游行為；直播/離線/投屏為回歸項目，不能當成已移植 BTR 的模式。

待完成的核心差距是：有可靠完整身分證據才能啟用的跨來源分段、完整 MSE/SIDX deadline 等價控制器、瀏覽器的全部健康/起播調整機制、原始模式精確 byte instrumentation，以及 Android 實測效果。這個交付是可獨立安裝及驗證的工程實驗版，不是兩份 userscript 的逐行 Android 移植或已證實的效能優化版。
