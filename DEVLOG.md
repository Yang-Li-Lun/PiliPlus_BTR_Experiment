# PiliPlus BTR 開發日誌

本檔記錄 `PiliPlus_BTR_Experiment` 可追溯的專案維護事項，供跨專案每日開發日誌讀取。歷史成果須依實際發生日期、Git metadata 與具日期的驗證文件判定；不可將文件建立或整理日期當成過去工作的完成日期。

## 有效來源與界線

- 專案定位、目前穩定使用版 APK 及未解問題：`BTR_DEVELOPMENT_INDEX.md`、`BTR_EXPERIMENT.md`。
- 上游整合流程與既有驗證：`BTR_UPSTREAM.md`、`BTR_UPSTREAM_RESULT_20261016.md`。
- 工作樹保留與退役前置調查：`PiliPlus_BTR_Worktree_Retirement_Preflight_20261030.md`。
- 專案安全與開發限制：`AGENTS.md`。來源文件中的歷史計畫不自動代表目前尚未完成的工作。
- `README.md` 含上游 PiliPlus 的通用說明，不可單獨作為 BTR 當日開發成果或驗證證據。

## 2026-11-05｜導入跨專案每日開發日誌

- 新增此 `DEVLOG.md` 作為本機專案開發紀錄入口。日後重要開發里程碑應記錄實際日期、完成內容、Commit SHA、已執行驗證、失敗／未驗證事項與對應證據。
- 導入時唯讀核對本專案的 `AGENTS.md`、BTR 開發文件與 Git metadata。主工作樹最新可見提交為 `5f1d067c176cd1d81202e69e67631619e705f539`（2026-10-27，臺灣時間）；`AGENTS.md` 有既存未提交修改，本次未覆寫。
- 依 2026-10-27 `BTR_DEVELOPMENT_INDEX.md`，`55fd75e41ae518c0330a11ea646ddf8b8b2bcae2` 是當時的暫用建議來源；兩輪短測的證據不代表完整穩定性、長時間播放、正式發布或普遍效能優勢已通過。
- 依 2026-10-30 退役前置審查文件，相關工作樹與依賴鏈仍有保全限制；本次未移動、刪除或退役任何工作樹或封存。
- 本次日誌接入未執行建置、測試、Android 裝置操作、APK 安裝、上游同步或 Git 遠端操作。


## 2026-11-06｜接受 upstream-20261027-01 為目前穩定使用版

- 使用者確認 `PiliPlus-BTR-Upstream-20261027-01` 可以使用，明確指定為目前最新穩定使用版；本次記錄為本機接受，不是正式發布。
- APK 固定來源為 `790e357f661b935b5eb064d9affa54279b0c51a9`，審查候選為 `c687c98aa290cafc8a36751b00fb7d18a10eb0b0`，上游為 `d680e3f95cf777ff20492dd2a23c89264481dca0`。`codex/btr-stable` 對應 APK 建置來源；`codex/btr-accepted` 對應候選加接受文件的維護提交，固定標籤為 `btr-maintenance-accepted-20261106-up-1027-01`。
- 本機重新計算封存 APK SHA-256，確認為 `4b70a98ea4dd6ab8a4cc17b3586cec855796029188fb9b64bf6f554811b05a5d`，大小 24,799,322 bytes；核對 Git 祖先、非應用程式碼差異、版本清單及保留項目。驗證收據見 `evidence/stable-acceptance-20261106/`。
- POCO F8 Ultra 安裝成功及手機內 APK 雜湊一致是使用者提供的確認；本次未操作裝置。歷史 55fd 短測只屬於該舊版本，不轉記為新版實測。
- 沿用既有離線測試／建置紀錄，未重跑或重建；長時間播放、完整效能、原生／GPU 資源驗收仍未完成，Flutter/native 的 MSVC 阻擋維持原狀。
- 保留舊版 55fd、歷史穩定版、分支、標籤、APK、工作樹與證據。根工作樹既有未提交／未追蹤檔案保持原樣；此日誌在已接受候選中延續既有日誌內容。
- 完整定位與證據界線見 `BTR_STABLE_ACCEPTANCE_20261106.md`；沒有推送、PR、正式發布或核心程式修改。

## 2026-11-06｜BTR 模組化與專屬設定候選

- 從已接受維護來源 `184c1fe8ea5649593d0dcedda1b420e101bcc2b4` 建立 `codex/btr-modular-20261106-01`／`.btr-wt/mod-1106-01`。應用程式碼 Commit 為 `d30b2e0d3e6694fe13fece12f30034a257454848`；未同步上游、未接受候選或提升穩定版。
- 將 BTR 播放器適配集中至既有私有 part/extension，保留共用狀態所有權及原操作順序；抽出 DASH 候選擷取、獨立設定儲存／通知與專屬設定 panel。傳輸核心、安全上限、Android 平臺碼及應用依賴未變。模組與同步審查邊界見 `BTR_MODULES.md`。
- Dart 169 項均取得通過結果（168 項完整執行通過，加 1 項擷取位置修正後針對性通過）；設定頁／診斷通道 13/13、同步安全 19 assertions 通過。完整及最終修改範圍靜態分析均無 error／warning；Flutter/native 仍因缺 MSVC 在案例前阻擋。
- 建置 `modular-20261106-01` ARM64 DEV APK，套件及既有簽章一致。SHA-256 `ad50e0e6c20c6c29479f49bb737719fdc90ba4fe1ae12e3176d64d364362715d`，24,796,590 bytes。初次 Gradle loopback 錯誤後依規則以候選短 IPC 路徑建置成功。
- 完整交付、失敗／阻擋及證據界線見 `BTR_MODULAR_RESULT_20261106.md`；APK 位於候選 `build/btr-candidates/modular-20261106-01/`，原始日誌位於候選 `evidence/modular-20261106-01/`。
- 未安裝或操作裝置；原 stable／accepted refs、版本清單、歷史 APK／evidence／工作樹保留。原生資源、長時播放、完整效能及實機 UI／SAF 驗收仍未完成。

## 2026-11-06｜BTR 實體來源分離候選

- 從模組化來源 `1f0d304a3` 建立 `codex/btr-separated-20261106-01`／`.btr-wt/sep-1106-01`。實作及 APK 來源 `ff19eabea607719b423eabee359f980731cb000a`；狀態為未接受候選。
- 官方 PiliPlus tree 與 `d680e3f9` 完全相同；55 個 BTR 自有來源、8 個 adapter、16 個官方 patch 與整合工具分區管理。重組後 1,525 個 app／測試／lock inputs 與模組化基準 blob 完全一致。
- 核心 169、設定／診斷 13、Kotlin 9、既有同步 19 assertions 通過；新增組合 11 案例及分離同步 3 場景／重複同步取得通過。分析 0 errors／0 warnings、40 info；完整 Flutter/native 因缺 MSVC 在案例前阻擋。
- ARM64 DEV APK 24,796,198 bytes，SHA-256 `0c7a7cb2b30ca3ec9733cfcead71d3b2fab984a7d44f7e479c7d3ca69905c686`；DEV package／既有 certificate 已核對。Gradle IPC 症狀後依規則使用候選短路徑建置成功。
- accepted／stable／模組化 refs、根 owner 內容與歷史成果保留，未同步官方新版、未接受候選或操作裝置。完整結果與限制見 [分離來源交付報告](BTR_SEPARATED_RESULT_20261106.md)，原始證據於 `evidence/separated-20261106-01/`。
