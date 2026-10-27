# PiliPlus+BTR 維護架構與首個更新候選

日期：2026-10-27（Asia/Taipei）。狀態：**候選已交付，尚未接受為維護來源；沒有提升暫用建議或穩定版本。**

## 固定來源與產物

| 項目 | 值 |
| --- | --- |
| 完整功能基準 | 55fd75e41ae518c0330a11ea646ddf8b8b2bcae2 |
| 固定暫用 tag | btr-user-trial-20261027-55fd75e41 |
| 架構來源 commit | c277ccb3d293afc2d7a82e1ab28943d8ba8932e9 |
| 架構工作樹／分支 | .btr-wt/mt-1027-01／codex/btr-architecture-20261027-01 |
| 官方 main | d680e3f95cf777ff20492dd2a23c89264481dca0（取得及建置期間再次查詢一致） |
| 整合 merge | 7e31a6da2（包含架構來源與官方 main 祖先） |
| APK 建置 commit | 790e357f661b935b5eb064d9affa54279b0c51a9 |
| 更新候選分支 | codex/btr-update-up-1027-01 |
| 更新工作樹 | D:\codee\PiliPlus_BTR_Experiment\.btr-wt\up-1027-01 |
| Build ID | upstream-20261027-01；沿用 55fd 的 BTR_DEVICE_TEST 診斷旗標 |
| APK | [PiliPlus-BTR-Upstream-20261027-01-dev-arm64-v8a.apk](build/btr-candidates/upstream-20261027-01/PiliPlus-BTR-Upstream-20261027-01-dev-arm64-v8a.apk) |
| APK 大小／SHA-256 | 24,799,322 bytes／4b70a98ea4dd6ab8a4cc17b3586cec855796029188fb9b64bf6f554811b05a5d |
| 身分 | com.example.piliplus.btr.experiment.dev；PiliPlus BTR DEV；僅 arm64-v8a |
| Android | versionName 2.1.6／versionCode 1；minSdk 24／targetSdk 37 |
| DEV certificate SHA-256 | fc32b2cbc48673d7f110c98acfcf360bb9a0d5bc166ecfeeeb2bd33935c22264 |
| 歷史穩定基準 | 788faa8abee2ff325205d89a9fa24869821685e3，未移動 |

本報告的提交只增加文件；可執行程式碼與上述建置 commit 相同。
[產物清單](build/btr-candidates/upstream-20261027-01/artifact.json) 包含完整 SHA、路徑與驗收分類。
APK 原件與交付副本雜湊相同；實際讀取舊暫用 APK 與新 APK 的 certificate，二者相同且都驗章成功。

## 維護架構與來源機制

BTR 傳輸、CDN 政策、驗證、排程、資源容量、監控、設定與診斷維持既有模組。
7 個與 native error、terminal、read-stall、EOF 及 Seek resume 有關的方法集中到
lib/services/btr/player_integration.dart，作為 PlPlayerController library 的私有 part/extension。
[搬移等價證據](evidence/upstream-20261027/extraction-equivalence.json) 確認方法內容與 55fd 完全一致（僅正規化 Git 換行）。

共用 open/refresh/seek/play/dispose、來源序號與 Seek 意圖仍由 controller 持有。
此整理減少專用恢復程式碼與上游播放器直接交錯的範圍；沒有引入另一套生命週期或改寫傳輸。
仍需審查的整合面是 DASH 候選、控制器生命週期與事件、設定入口、overlay、AudioService 與 Android engine。

同步工具沿用 tool/btr_sync_upstream.ps1：
- 唯一定期同步的上游為官方 PiliPlus main；Android BTR 自行維護，不同步 thread-ripper。
- 預設從已接受的 codex/btr-accepted 建立候選；尚未建立此 ref 時從固定 55fd tag 啟動。
- 不再預設使用較舊的 codex/btr-maintenance；每個來源都必須包含 55fd 與已接受來源。
- 每次新增分支／同層工作樹，保留恢復 tag 與 sync.json；不覆寫既有路徑。
- 未接受候選不自動成為下一次來源；僅明確指定 SourceRef 可接續它。
- AcceptCandidate 是獨立、需明確使用者決定的步驟，留下收據並以 compare-and-swap 更新來源 ref。
- 本次沒有執行實際專案的 AcceptCandidate；回歸中的接受動作只在 disposable fixture。

原根目錄工具保持原狀。後續使用本候選內的新版工具；完整指引見 [BTR_UPSTREAM.md](BTR_UPSTREAM.md)。

## 上游整合與相容性審查

原始 [sync.json](../mt-1027-01/evidence/upstream-sync/up-1027-01/sync.json) 保留最初 CONFLICTS 結果。
四個衝突讀取 base／候選／上游後整合：

| 整合點 | 結果 |
| --- | --- |
| play_settings.dart | 保留 BTR 設定入口，接上上游設定分類及 fullscreen SC 新頁面 |
| VideoDetailController | 使用上游 findTargetVideo/findTargetAudio；選定 representation 後仍經 _dashUrl 捕捉各軌完整 API URL |
| PlPlayerController | 接上 rotate 與 multiBackward；保留來源序列、生命週期、可取消 retry timer、最新 Seek 意圖及 stop → retire GET → reopen |
| AudioService | 保留可測試的背景播放設定與 onTaskRemoved 清理；整合上游 Linux MPRIS 與 Android vivo 初始化 |

其餘共改檔案已檢查：AndroidManifest、音訊頁、播放器 header/view、pubspec/lock。
BTR 的傳輸、來源政策、Range/ETag、代理容量、排程與設定檔案等 61 個沒有上游變動的檔案與架構來源逐檔一致。
核心 BTR 原檔與 55fd 也無差異，新增 part 為唯一新增模組。

CDN 路徑確認：
1. 畫質／codec／音質先由上游新 selector 決定，影音候選仍分別取自該 representation 的完整原始 URL。
2. 原始模式使用上游 VideoUtils，包括保留 Akamai 自有簽章 URL 的新修正。
3. BTR 使用捕捉到的原始候選，不把 native URL host 改寫結果當成 representation 候選。
4. 既有合格候選政策與驗證保留。固定已驗證來源後，URI、內容長度與強 ETag 必須相符；跨來源即使相同長度／ETag 也不能拼接。
5. 沒有降低 Range、ETag、encoding、overrun 或內容身分規則；8 回應／4 執行槽／16 上游限制及 retire 清理保留。

media_kit 核心仍鎖定 73771ec38176be2d984a3049c28177bce23b54a0。
media_kit_video 從 fd8421d2 到 85f0a69e 的差異僅 linux/texture_gl.cc；
[依賴差異證據](evidence/upstream-20261027/media-kit-video-diff.txt) 不代表 Android 實機回歸通過。

## 工具鏈與驗證

候選私有 Flutter 3.47.8／Dart 3.13.7；SDK commit 737ba8f885dc774b53b442759999a312c9461e4e。
獨立 SDK/Pub cache，複用 211 個吻合鎖定版本的 package tree，其餘依 lock 取得。
既有 Gradle cache 以 junction 重用；DEV key 複製且 hash 相同。
btr_prepare 改為核對實際 .fvmrc 與 package_config 的 material_ui 版本（本次 1.8.0），拒絕對共享 SDK/cache junction 套 patch。
25 個 Flutter／9 個 material patches 套用成功，Flutter patches 另以 reverse-check 核對。
沒有執行會 reset SDK 的上游 helper，沒有修改種子 SDK、全域 Git 或原 PiliPlus 專案。

| 驗證 | 結果 | 證據（本候選相對路徑） |
| --- | --- | --- |
| Git 祖先與功能結構 | PASS；包含 55fd、架構來源與官方 main；61 檔與來源一致 | evidence/upstream-20261027/feature-final.log |
| 同步工具 | 19 個安全斷言 PASS；含舊維護線防退版、接受與未接受來源、髒檔保留、重複 run、衝突及上游歷史改寫拒絕 | evidence/upstream-20261027/sync-tests-final.log |
| 純 Dart／本機 Fake CDN | 168/168 PASS；含真實 controller 方法的 deterministic fixture、Seek/恢復/取消、原始模式、設定、同 ETag 不同 CDN bytes、容量與清理 | evidence/upstream-20261027/dart-tests-02.log |
| 靜態分析 lib/test | 0 errors／0 warnings／40 infos，exit 0；包含既有提示及本次測試檔一項字串插值提示 | evidence/upstream-20261027/analyze-app-03.log |
| 診斷 Flutter channel | 10/10 PASS，mock channel | evidence/upstream-20261027/diagnostics-flutter-02.log |
| Kotlin 寫入／讀回 | 9/9 PASS，JVM；Android SAF/provider 未執行 | evidence/upstream-20261027/verified-write.log |
| AudioService Flutter／上游 test/utils | BLOCKED：cnativeapi 需要本機未安裝的 MSVC，未進入案例 | evidence/upstream-20261027/flutter-native-01.log |
| ARM64 DEV APK | PASS，第二次建置 319.0 秒 | evidence/upstream-20261027/build-02-short-ipc.log |
| APK 身分與簽章 | PASS；實際舊／新 APK certificate 相同，v2 驗章成功 | evidence/upstream-20261027/apk-badging.txt、apk-signature.txt、baseline-apk-signature.txt |
| Git whitespace | PASS | 最終 git diff --check |
| 實機、真實 CDN、聲畫、長時與資源上界 | NOT RUN／UNRESOLVED | 本次禁止裝置操作 |

失敗／中止的嘗試保留，不計為通過：
- Dart 首次在沙箱暫存 dill 複製權限被阻擋，未載入案例；取得執行權限後第二次 168/168 通過。
- 未限定目錄的分析未完成而中止；完成結果僅為 lib/test，沒有宣稱 SDK/cache 全根掃描通過。
- 診斷 harness 首次固定舊 file_picker 13.1.0，與新獨立 cache 不符；工具改讀 app lock 的 13.2.0 後通過，未改 app 依賴鎖定版本。
- 首次 Gradle 實際出現 Unable to establish loopback connection；第二次使用候選推導的 .ipc 路徑及 jdk.net.unixdomain.tmpdir 成功，未改 TEMP/TMP、hosts、Android source 或 JDK。
- 建置仍有既有 plugin compileSdk／Kotlin migration／Java deprecated 警告，未為消除警告升級依賴。

## 保留與剩餘風險

[保留檢查](evidence/upstream-20261027/preservation-check.json) 記錄根工作樹原有 AGENTS.md 修改與附件 status 不變，
舊 APK／DEV key／AGENTS 原檔 SHA-256 不變，版本清單內容不變（Git 換行正規化除外）。
除了本次兩個候選分支、pre-sync tag 與純上游鏡像前進，原有分支／tags 保留。
codex/btr-stable、main、codex/btr-maintenance 與暫用 tag 均未提升；codex/btr-accepted 尚未建立。

本次新增的 ignored 內容僅為候選 SDK/cache、建置／Pub 產物、離線 fixture 與 evidence。
未建立額外正式備份或複製舊 APK；保留可重建候選與失敗診斷所需的檔案，沒有清理既有工作樹或未知檔案。

未解決問題沿用 55fd 的範圍：原生 ffmpeg／ImageReader 中斷成因、反覆 Seek 的原生／GPU 資源上界、長時間播放與一般效能優勢。
新 Flutter engine 與上游 UI／依賴的 Android 實機行為仍需另行授權驗證。
原始模式的離線路徑與設定保留，不能以此宣稱裝置播放已通過。
沒有操作 ADB／手機、安裝 APK、清資料、推送、建立 PR 或正式發布。

## 日後操作

從本候選工具目錄要求「同步 PiliPlus 最新版本並保留 BTR 功能」即可。
未接受本候選時，預設仍從 55fd；若明確要在本候選上接續，使用 -SourceRef codex/btr-update-up-1027-01。
使用者另行接受後，依 BTR_UPSTREAM.md 的 AcceptCandidate 步驟建立維護來源，再進行一般同步。
接受維護來源與提升目前建議版本是兩個不同操作，本次兩者均未執行。
