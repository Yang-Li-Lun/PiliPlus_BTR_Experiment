# BTR 模組化與專屬設定頁交付紀錄

日期：2026-11-06（Asia/Taipei）。本次為行為保留的本機架構候選，未同步官方 PiliPlus，未接受或提升穩定版本。

## 來源與範圍

- 候選分支：`codex/btr-modular-20261106-01`。
- 候選工作樹：repository 根目錄下 `.btr-wt/mod-1106-01`。
- 建立來源：`codex/btr-accepted`，`184c1fe8ea5649593d0dcedda1b420e101bcc2b4`。
- 應用程式碼 Commit／APK 建置來源：`d30b2e0d3e6694fe13fece12f30034a257454848`。
- 上游基準：`d680e3f95cf777ff20492dd2a23c89264481dca0`。
- 原穩定使用版及 `codex/btr-stable`：`PiliPlus-BTR-Upstream-20261027-01`／`790e357f661b935b5eb064d9affa54279b0c51a9`，保持不變。

模組清單及所有權契約見 [BTR_MODULES.md](BTR_MODULES.md)。`PlPlayerController` 淨減少 398 行；來源開啟、Seek、refresh 及診斷 hook 集中到現有私有 part/extension。共享狀態仍由控制器持有，三個主要搬移方法忽略空白及私有方法名稱後內容一致。DASH 候選擷取成為獨立適配物件，保留先擷取原始完整 URL、再呼叫上游 CDN selector 的順序及影音分離。

設定模型與原 Hive keys／遷移保留；新增獨立設定 controller 與 app storage binding。BtrExperimentPage 組合 BTR 設定 panel、監控與診斷 panel；頁面不再另存設定副本。模式、自動／六種手動值、四種 CDN 偏好及四個顯示開關集中於同一頁。顯示已保存上限、Android 生效上限與本次 session 狀態；手動 32／64／128 不會突破 16 個上游請求。

Transport、Network、CDN policy、scheduler、容量、設定模型、量測／匯出核心、Android 原生碼、pubspec／lock 均與接受來源相同。原始模式繞過 BTR、Range／ETag、HTTPS、MCDN／P2P 過濾、不跨 CDN 拼接、8 回應／4 執行槽／16 上游與每軌有序視窗保護未變。設定於下次播放／畫質切換套用，顯示偏好於成功儲存後即時通知。

## 已執行驗證

證據相對本候選：`evidence/modular-20261106-01/`。

| 項目 | 結果與範圍 | 日誌／收據 |
| --- | --- | --- |
| 純 Dart／本機 Fake CDN／Hive 磁碟重開 | 169 項均取得 PASS：完整執行 168 PASS／1 FAIL，失敗為 source-retirement harness 仍在舊檔擷取方法；更新擷取位置後該 1 項 PASS。已通過項目未重跑 | `dart-tests-02.log`、`source-retirement-retest.log` |
| 播放器契約 | 實際 production 方法編譯進可控制 native contract fixture；EOF、最新 Seek、pause/source/task-close、失敗 stop 保留 GET 所有權、stop→retire→open 及原始模式案例 PASS。這些不是 Android/mpv 實測 | 上述 Dart 日誌、`method-equivalence.json` |
| 設定頁／診斷 channel | 13/13 PASS：3 設定 controller／widget 案例及 10 匯出 channel 案例。涵蓋舊模式遷移、保存／重載、所有選項、上限顯示、不可變 session 快照、即時通知及失敗後重試；初次 UI 測試的向上捲動方向已修正 | `flutter-isolated-02.log`、`flutter-isolated-03.log` |
| Flutter/Dart analyze | 完整 `lib test` 首輪 0 errors／0 warnings／43 infos；新增 3 個格式提示已修正。最後所有修改 Dart 範圍 0 errors／0 warnings，1 個既有 controller fixture 字串風格 info | `analyze-01.log`、`analyze-final.log` |
| 同步與接受安全回歸 | 19 assertions PASS，僅 disposable 本機 Git fixtures；來源接受不提升 stable、未接受候選不成預設、舊來源不能丟失接受修正、非 fast-forward 上游拒絕 | `sync-tests-02.log`、`sync-fixture-receipts.json` |
| 新舊應用來源相容 | 新版結構驗證器以來源 Git tree 判別契約，模組化 78 個／已接受舊版 71 個非上游變動檔符合來源；舊版設定 UI harness 明確列為不適用，仍保留診斷測試 | `features-modular-final.log`、`features-legacy-final.log`、`settings-harness-legacy.log` |
| Flutter/native AudioService | **BLOCKED**，cnativeapi 找不到 Windows MSVC／cl.exe，未進入測試案例 | `flutter-native.log` |
| Android 實機、真實 CDN、播放／Seek／音畫、實際 SAF、長時與效能 | **NOT RUN／UNVERIFIED**，本次未安裝、未連線、未操作 Android 裝置 | 本次授權邊界 |

第一輪 Dart／Flutter 受 Windows sandbox 暫存檔複製權限阻擋；Git fixture 受 MSYS kernel object 權限阻擋。失敗日誌保留於 `dart-tests-01.log`、`flutter-isolated-01.log`、`sync-tests.log`；相同案例在允許的本機程序環境重試。上述功能結果與環境阻擋分列。

## 建置與 APK

Build ID：`modular-20261106-01`；Flutter 3.47.8，既有 DEV 簽章，`-DeviceTest` 僅保留接受版本既有的 DEV 診斷旗標。SDK、lock 與 patches 核對後使用既有 setup 重用本專案種子；未套用新 patch 或更換依賴。

首次 Gradle 出現 `Unable to establish loopback connection`，保留 `build-01.log`；依專案規則加入候選 `.ipc` 的 `jdk.net.unixdomain.tmpdir` 重試，保留 `build-02.log`。沒有修改 TEMP／TMP、hosts、Android source 或 JDK。

第二次建置 **PASS**（Gradle 351.7 秒）。交付 [ARM64 DEV APK](build/btr-candidates/modular-20261106-01/PiliPlus-BTR-Modular-20261106-01-dev-arm64-v8a.apk) 與 [artifact.json](build/btr-candidates/modular-20261106-01/artifact.json)。

- 大小：24,796,590 bytes。
- SHA-256：`ad50e0e6c20c6c29479f49bb737719fdc90ba4fe1ae12e3176d64d364362715d`。
- aapt 實讀：`com.example.piliplus.btr.experiment.dev`、`PiliPlus BTR DEV`、僅 `arm64-v8a`，versionName 2.1.6／versionCode 1，minSdk 24／targetSdk 37。
- `apksigner verify --verbose --print-certs` PASS，APK v2 簽章，既有 certificate SHA-256 `fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`。
- 原 Flutter output 移至唯一交付位置，另一份本次 Gradle APK 副本核對相同 SHA-256 後刪除；mapping、native symbols 及其餘必要建置快取保留。沒有覆寫既有 APK。
- 最終維護提交另含驗證工具對舊已接受來源的相容處理及本報告；應用程式碼與上述 APK 建置來源一致。

APK 量測證據：`apk-badging.txt`、`apk-signature.txt`。此候選未安裝，未接受為穩定使用版。

## 保留與後續入口

`tool/btr_sync_upstream.ps1`、`tool/btr_upstream.json`、版本清單及既有接受／穩定 ref 未更動。根工作樹 owner 的 AGENTS.md 修改及既存未追蹤檔保持原樣，有效接受工作樹乾淨。原穩定 APK 重算 SHA-256 仍為 `4b70a98ea4dd6ab8a4cc17b3586cec855796029188fb9b64bf6f554811b05a5d`。

候選內保留測試／建置日誌、失敗結果、收據、工具鏈與建置必要 cache。此次一次性修改腳本及 disposable Git fixtures 已刪除，fixture JSON 收據先保存至 evidence；清單為 `cleanup.json`。沒有清理任何既有工作樹、APK、evidence、備份或使用者資料。

後續從本候選入口執行 `tool/btr_sync_upstream.ps1 -RunId <唯一短名稱>`，預設仍從 **已接受來源** 建立獨立候選。若明確要接續尚未接受的模組化成果，另加 `-SourceRef codex/btr-modular-20261106-01`；這不等於接受。只有使用者另行接受後才執行文件所列 AcceptCandidate；本次未執行。

既有 UNRESOLVED 保留：原生 ffmpeg／ImageReader 成因、反覆 Seek 的 native／GPU 資源上界、長時間播放及完整效能驗收均未完成；未建立普遍速度優勢。本次離線測試、靜態分析或 APK 建置不能代替實機驗收。沒有 Push、PR、正式發布或自動提升穩定版本。
