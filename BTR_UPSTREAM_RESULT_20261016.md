# 首次上游同步驗證（2026-10-16）

## 版本與隔離

- 官方來源：`https://github.com/bggRGjQaUbCoE/PiliPlus.git`；本次 fetch 固定於 `bb2d86ca25d2d4ad9ed42addf37990ae8931c098`。
- 原上游基準：`3d0aed958b3b7e59c39c121196f189f429719904`；本次新增 4 個上游 Commit。
- 原 `main` 維持 `788faa8abee2ff325205d89a9fa24869821685e3`。
- 原 `codex/btr-settings-monitor` 維持 `f583de9e24871984470895bc71598773d28baab0`。
- `codex/btr-stable` 固定既有可用基準 `788faa8ab`；未增加其驗收範圍。
- `codex/btr-maintenance` 從完整功能 Commit 建立，新增同步工具與文件。
- 更新候選：`codex/btr-update-20261016-01`，工作樹 `.btr-wt/20261016-01`。
- 程式整合／APK 建置來源 Commit：`9dec750f0`；後續工具與驗證文件合併不改變 APK production source。
- 還原點：`btr-stable-baseline-20261016`、`btr-feature-snapshot-20261016`、`btr-pre-sync-20261016-01`。

## 合併與功能保留

選用正常三方 merge，保留原版與兩個 BTR 功能 Commit 的歷史。
首次腳本遇到一處播放器重試 Timer 衝突並正確停止；由 Codex 讀三方內容後解決。
上游只改寫 callback 語法，候選保留 BTR `_retryTimer` 的保存／取消，供生命週期清理使用。

`git diff` 核對 36 個 BTR production／Android／測試／依賴檔案：

- 33 個沒有上游改動的檔案與 BTR 來源的 Git blob 完全一致。
- `lib/plugin/pl_player/controller.dart` 解決衝突後亦與 BTR 來源相同。
- `lib/pages/video/controller.dart` 只加入上游留言跳轉 key/import；影音候選與畫質接線保留。
- `lib/plugin/pl_player/view/view.dart` 只採用上游音量手勢 callback 簡化；BTR monitor 保留。

多 Range、多線程預算與排程、CDN 選源／備援、同來源內容身分檢查、Hedge／續傳／Seek、
設定／遷移／監控、AudioService task removal／PlaybackTaskScope／native player disposal、
Kotlin 共用 engine、DEV package／network security 均保留，沒有重設計傳輸架構。

原始 `sync.json` 的 `CONFLICTS` 不改寫；另有 `resolution.json` 與 `compatibility-review.json` 記錄解決。

## 驗證結果

| 項目 | 結果 |
|---|---|
| 同步腳本本機 Git fixtures | 11 個斷言 PASS：自動合併、髒工作樹保留、source/stable 不變、接續候選重複同步、唯一 run 防覆寫、衝突現場保留、上游 non-ff 拒絕 |
| BTR 功能結構檢查與三個共用檔案審查 | PASS；只是結構與 source 比對，不代表實機功能驗收 |
| 純 Dart／本機 Fake CDN | 58/58 PASS；直接測候選 production source |
| 全專案 Flutter analyze | PASS；0 errors、0 warnings、37 個既有 info；使用 `--no-fatal-infos` |
| Flutter AudioService 測試 | BLOCKED BEFORE TEST EXECUTION：cnativeapi 找不到 Windows x64 MSVC compiler；未執行測試案例 |
| Android ARM64 DEV APK | PASS；Gradle 341.0 秒；候選獨立 build 輸出 |
| APK package／ABI／簽章 | PASS；正確 DEV package、僅 ARM64、單一 v2 簽章、certificate 與既有 DEV 相同 |
| Git whitespace／工作樹 | PASS；原工作樹與候選均無未提交 source 修改 |
| 原有 refs／APK／key | 原有 161 refs 與 9 份既有 APK/key 雜湊不變 |
| Android 實機／實際 CDN／長時播放 | UNRESOLVED / NOT RUN；未安裝、未操作手機，既有驗收狀態不變 |

建置第一次出現 `Unable to establish loopback connection`，保留 `build-01.log`；
才以既有 `-ShortIpcPath` 使用候選 `.ipc`，在新日誌重試。
未改全域 TEMP/TMP、Git 設定、JDK、hosts、Android source 或依賴版本。
SDK、lockfiles 與 patches 相同，候選以受檢查的 junction 重用本專案私有 cache；
build 輸出獨立，DEV key 複製到候選，種子 key 不變。

## APK

- 交付：`build/btr-candidates/20261016-01/PiliPlus-BTR-Upstream-bb2d86ca-2.1.6-dev-arm64-v8a.apk`。
- SHA-256：`b7596f743d5999826314ff399cec0cadac3520f7db51c45742fcffca050825ae`。
- 大小：24,482,375 bytes；`2.1.6+1`；minSdk 24／targetSdk 37；`arm64-v8a`。
- applicationId：`com.example.piliplus.btr.experiment.dev`；label：`PiliPlus BTR DEV`。
- 簽章 certificate SHA-256：`fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`。
- 完整建置來源：`9dec750f07858b29e3dda33ff35331dcf6bbd4e3`；`artifact.json` 與 APK 一起保存。
- 後續只新增操作文件／AGENTS 入口及測試依賴鎖定旗標；以 Git diff 核對 production source 與此建置 Commit 相同。

建置仍有上游 plugins 的 KGP／compileSdk／deprecated API 提示；此次沒有升級依賴以消除提示。

## 證據與後續操作

- `evidence/upstream-bootstrap-20261016-01/`：原 refs／舊 APK/key 清單及雜湊核對、同步工具回歸日誌。
- `evidence/upstream-sync/20261016-01/`：固定來源／上游 SHA、初始衝突、解決與相容性審查。
- `.btr-wt/20261016-01/evidence/validation-20261016-01/`：功能、依賴、58 項測試、analysis、Flutter 前置阻擋、兩次 build、APK 實讀日誌。
- `AGENTS.md` 指向 [操作文件](BTR_UPSTREAM.md)，未來可直接要求 Codex「同步 PiliPlus 最新版本並保留 BTR 功能」。
- 簡短指令：`pwsh -NoProfile -File .\tool\btr_sync_upstream.ps1`。

所有變更只保留在本機新維護線／候選線；沒有推送 GitHub、建立 PR、修改舊版封存或自動穩定提升。
候選需要另行 Android 驗收；接受後才由使用者明確授權前進維護線或穩定線。
