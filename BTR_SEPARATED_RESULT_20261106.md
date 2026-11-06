# BTR 分離來源候選驗證結果（2026-11-06）

狀態：`LOCAL_UNACCEPTED_CANDIDATE`。候選分支 `codex/btr-separated-20261106-01`，工作樹為 repository 根下 `.btr-wt/sep-1106-01`。實作及 APK 建置來源為 `ff19eabea607719b423eabee359f980731cb000a`；後續結果文件提交不更換 APK 的來源識別。

## 基準與實作

- 模組化基準：`1f0d304a3e161e35980565b1088dc79c0717b424`；舊 APK 程式碼來源：`d30b2e0d3e6694fe13fece12f30034a257454848`。
- 官方 PiliPlus：`d680e3f95cf777ff20492dd2a23c89264481dca0`。`PiliPlus/` 的 1,651 個檔案及 Git tree `9bc6d6493f445fffcc46c7d09552e8c119e4a8cb` 與該官方 commit 的根 tree 完全相同。
- BTR 自有新增來源集中於 `BTR/`：55 個檔案；Integration 有 8 個 adapter 檔及 16 個逐檔官方 patch；`tools/` 管理組合／驗證／建置及同步。沒有新 Dart package 或 submodule。
- `integration/sources.json` 明列來源與目標。工具在新目錄重組 1,730 個檔案；1,525 個 app／測試／lock／SDK pin 檔的 blob 與模組化基準完全一致，包括所有 Dart、Android、Hive keys、安全上限與原生 lifecycle 接點。這是來源等價證據，不是裝置驗收。
- 最終建置輸出為 `.assembled/build/`；fingerprint `417bc2ef4eeb34c2f83d25b62a4365f990a9111e581d63c0385556b62e0ba0b3`。官方源、overlay、patch 及 tools 皆來自本候選，沒有人工修改生成 app。

現況架構見 [BTR_SOURCES.md](BTR_SOURCES.md)、[BTR_MODULES.md](BTR_MODULES.md)；所有官方接點、依賴與審查規則見 [CONTACTS](integration/CONTACTS.md)及[BTR_UPSTREAM.md](BTR_UPSTREAM.md)。

## 驗證

| 驗證 | 實際結果 |
| --- | --- |
| BTR 核心、Fake CDN、設定／Hive、播放器生命周期 | 完整執行 169/169 PASS |
| 專屬設定頁及診斷 channel harness | 13/13 PASS |
| Kotlin 正式覆讀核對 | 9/9 PASS；未執行 Android picker／provider 實機測試 |
| Flutter analyze（lib、test） | 0 errors、0 warnings、40 既有 info，exit 0 |
| 既有同步安全 | 19 assertions PASS |
| 新來源組合保護 | 11 個案例取得 PASS（原 10 個完整執行，加 1 個增補案例） |
| 分離來源同步 | 3 個本機場景取得 PASS；追加相同 pin 重複同步，確認無額外 commit、manifest 變更及髒工作樹 |
| 完整 AudioService Flutter/native | BLOCKED：cnativeapi 缺 Windows MSVC `cl.exe`，未進入案例 |
| ARM64 DEV APK | 建置成功，aapt 與 apksigner 核對通過 |

分離同步場景涵蓋：新官方純來源映射至 PiliPlus 並保留雙方祖先；整合目標改變時保留 MERGE_HEAD／patch 並停止；預設來源仍為 accepted 舊 layout。只使用 disposable 本機 Git fixtures，沒有 fetch 官方新版或遠端 push。

初次核心測試受 Windows sandbox 暫存檔複製限制，初次 Git fixture 受 MSYS 程序限制；同來源獲准以本機程序重試後通過。新同步 fixture 的換行／日誌編碼與重複同步案例經針對性修正及復測；各輪日誌保留，不宣稱初次整輪全綠。初次建置出現 `Unable to establish loopback connection`；依 AGENTS.md 僅使用 repo-local `jdk.net.unixdomain.tmpdir` 後成功，未改 TEMP/TMP、hosts、JDK、Android source 或依賴版本。

官方 README 的既有空白與 patch context 空白原樣保存；新撰寫程式／文件的 `git diff --check` 通過，官方樹與核心檔以 blob／tree 比對驗證。詳見 `evidence/separated-20261106-01/validation.json`、`source-verification.json`、`source-final.log` 及原始日誌。

## APK

- [ARM64 DEV APK](build/btr-candidates/separated-20261106-01/PiliPlus-BTR-separated-20261106-01-dev-arm64-v8a.apk)
- Build ID：`separated-20261106-01`。
- 大小：24,796,198 bytes。
- SHA-256：`0c7a7cb2b30ca3ec9733cfcead71d3b2fab984a7d44f7e479c7d3ca69905c686`。
- 套件：`com.example.piliplus.btr.experiment.dev`；名稱 `PiliPlus BTR DEV`；僅 ARM64；versionName `2.1.6`、versionCode `1`、minSdk `24`、targetSdk `37`。
- DEV certificate SHA-256：`fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264`，與既有 DEV 身分一致；APK v2 signature 驗證通過。
- [artifact.json](build/btr-candidates/separated-20261106-01/artifact.json) 保存建置來源、上游 pin、fingerprint、雜湊與未接受狀態。

## 耦合與保留範圍

官方檔案現在可獨立辨識、比較及更新；BTR 新增檔有單一來源，官方修改只由 16 個明確 patch 表達，工具負責重新組合，不需人工複製整份播放器／Android 檔。這次沒有改傳輸演算法或執行期契約。

剩餘接點包括 PlPlayerController private part 與共享來源／Seek／generation 狀態、DASH representation／selector 順序、Hive GStorage binding、設定路由／監控 overlay、AudioService engine、task removal／dispose、DEV manifest／Gradle。這些是必要 runtime 依賴，官方更動時仍需三方審查。

`codex/btr-accepted` 保持 `184c1fe8ea5649593d0dcedda1b420e101bcc2b4`；`codex/btr-stable` 保持 `790e357f661b935b5eb064d9affa54279b0c51a9`；模組化分支保持 `1f0d304a3e161e35980565b1088dc79c0717b424`。根工作樹既有修改／未追蹤清單不變，歷史工作樹、APK、evidence 與 refs 保留。

沒有接受候選、提升 stable、推送遠端、建立 PR、正式發布、安裝 APK 或操作 Android 裝置／資料。AGENTS.md 的 POCO F8 Ultra `79eb079a`／`25102PCBEG` 限制保留。真實 CDN、實機播放／Seek／音畫、長時性能、SAF、原生資源上界與既有 UNRESOLVED 均未由本次離線工程消除。

本次一次性 migration 腳本、disposable fixtures、Python cache、重複測試重組與重複 APK 在保存必要收據後清理；種子 junction 只移除連結，未刪除目標。保留最終可建置重組專案、正式候選 APK 與驗證證據，清理清單見 `evidence/separated-20261106-01/cleanup.json`。
