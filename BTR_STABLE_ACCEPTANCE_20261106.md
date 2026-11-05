# PiliPlus BTR 穩定使用版接受紀錄

日期：2026-11-06（Asia/Taipei）。使用者明確確認 **PiliPlus-BTR-Upstream-20261027-01 可以使用，並指定為目前最新穩定使用版**。此決定同時授權本機維護來源接受及穩定分支提升，不代表完整技術驗收或正式發布。

## 版本與 Git 定位

| 項目 | 固定值／用途 |
| --- | --- |
| 目前穩定使用版 | PiliPlus-BTR-Upstream-20261027-01 |
| APK 建置 Commit | `790e357f661b935b5eb064d9affa54279b0c51a9` |
| 穩定分支及固定標籤 | `codex/btr-stable`、`btr-stable-upstream-20261027-01`，皆對應 APK 建置 Commit |
| 接受前候選 HEAD | `c687c98aa290cafc8a36751b00fb7d18a10eb0b0`；由 `btr-accepted-candidate-20261106-up-1027-01` 固定 |
| 候選工作分支 | `codex/btr-update-up-1027-01`，在上述 HEAD 後新增接受文件與版本 metadata 提交 |
| 已接受維護來源 | `codex/btr-accepted`；本次固定標籤 `btr-maintenance-accepted-20261106-up-1027-01`，包含上述候選及接受文件 |
| PiliPlus 上游基準 | `d680e3f95cf777ff20492dd2a23c89264481dca0` |
| Build ID | `upstream-20261027-01` |
| APK 大小 | 24,799,322 bytes |
| APK SHA-256 | `4b70a98ea4dd6ab8a4cc17b3586cec855796029188fb9b64bf6f554811b05a5d` |
| 套件／ABI | `com.example.piliplus.btr.experiment.dev`／`arm64-v8a` |
| APK 相對 repository 根目錄位置 | `.btr-wt/up-1027-01/build/btr-candidates/upstream-20261027-01/PiliPlus-BTR-Upstream-20261027-01-dev-arm64-v8a.apk` |
| 後續維護工具工作樹 | `.btr-wt/up-1027-01` |

維護提交與 APK 建置來源分開：本次只新增文件及版本 metadata，不重建 APK，不改 BTR 傳輸、CDN 核心或應用程式碼。維護來源接受使用既有 `tool/btr_sync_upstream.ps1 -AcceptCandidate` 流程，其完整 Commit 由上述 ref／固定標籤及 `evidence/source-acceptance/stable-up-20261106-01.json` 收據解析。

`codex/btr-maintenance` 是保留的舊維護線，與候選存在分歧；不強制移動或把它當成新版應用來源。主工作樹僅更新已追蹤的維護入口及版本清單，既有未提交 AGENTS.md、未追蹤 DEVLOG.md 與其他 owner 檔案保持原樣。有效開發日誌在已接受工作樹的 `DEVLOG.md`，延續根目錄既有日誌內容。

## 使用者確認與客觀驗證分離

- **使用者提供的確認**：POCO F8 Ultra 安裝成功，手機內 APK SHA-256 與上表一致；實際使用可以接受，指定為目前最新穩定版。本次沒有操作手機或重新取得裝置證據，不將此手機等同於歷史短測的 POCO M2012K11AG。
- **本次本機核對**：重新計算封存 APK 的大小與 SHA-256；確認上游、55fd 功能基準、APK 建置來源與候選的祖先關係；核對 APK 建置來源之後只有文件／維護工具變化，本次接受提交只變更文件及 metadata；檢查 JSON、版本指向、Git whitespace 與歷史／owner 檔案保留。
- **沿用歷史結果，未重跑**：2026-10-27 交付報告記錄純 Dart 168/168、同步安全 19 斷言、mock Flutter channel 10/10、JVM 9/9、靜態分析 0 errors／0 warnings／40 infos、APK 建置與簽章通過。本次閱讀既有報告及相關日誌，不將這些結果記為 2026-11-06 新執行的測試。
- **仍未完成**：長時間播放、完整效能比較、反覆 Seek 原生／GPU 資源上界及原生 ffmpeg／ImageReader 中斷成因。AudioService Flutter/native 與上游 test/utils 因缺 MSVC 的 BLOCKED 狀態保留。沒有建立 BTR 普遍較快或無資源洩漏的結論。

舊 55fd 的兩輪短測及聲畫確認只屬於舊 APK，不移植為此版本的實測結果。`overallAcceptance` 維持 `NOT_ACHIEVED`，與 `USER_ACCEPTED_CURRENT_STABLE` 的日常使用決定並存。

## 歷史保留及下次同步

- `btr-stable-baseline-20261016` 繼續固定 `788faa8abee2ff325205d89a9fa24869821685e3`；舊 `main`、功能分支及所有既有標籤保持原值。
- `btr-user-trial-20261027-55fd75e41`、舊 APK、工作樹、SDK/cache、artifact.json 及驗證證據保留。artifact.json 的 `CANDIDATE_NOT_ACCEPTED` 為 2026-10-27 建置交付時狀態，不覆寫歷史；現行狀態見 `tool/btr_current_recommendation.json`。
- 版本清單的 `historicalRecommendations` 保存被取代的 55fd APK 與短測資料；未採用及禁止日常使用的控制候選維持原分類。
- 在 `.btr-wt/up-1027-01` 依 `BTR_UPSTREAM.md` 執行下一次同步，預設讀取 `codex/btr-accepted`，同時要求包含完整 55fd 基準。根目錄舊工具的預設來源設定也改為該接受分支；完整新版流程仍使用已接受工作樹內的工具。
- 本次未 fetch、push、建立 PR、正式發布、安裝 APK 或清除 App 資料；未移動／刪除歷史工作樹及任何既有產物。

機器收據與前後保留核對：`evidence/stable-acceptance-20261106/`。歷史交付：`BTR_MAINTENANCE_RESULT_20261027.md`；目前清單：`tool/btr_current_recommendation.json`。
