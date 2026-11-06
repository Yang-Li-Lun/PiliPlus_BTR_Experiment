# 原始碼所有權與可重現組合

## 有效來源

本候選將同一 Git repository 內的來源分成四個實體目錄，不新增 Dart package、外部 repository 或 submodule。分離來源由 `integration/sources.json` 列舉並鎖定；目前官方基準為 `d680e3f95cf777ff20492dd2a23c89264481dca0`，行為比對來源為模組化候選 `1f0d304a3e161e35980565b1088dc79c0717b424`，既有 APK 的程式碼來源為 `d30b2e0d3e6694fe13fece12f30034a257454848`。

| 目錄 | 所有權與編輯規則 |
| --- | --- |
| `PiliPlus/` | 1,651 個純官方 Git blobs，含官方 pubspec、lock、Flutter patches、Android、其他平臺與 notices。檔案集合與內容必須精確符合官方 pin；不在這裡加入 BTR。官方 README 位於此目錄。 |
| `BTR/` | 55 個自有新增檔：傳輸／CDN／播放模組、設定模型與 UI、監控診斷、Android 輔助實作、回歸測試及 MIT notice。內部相對路徑就是重組後路徑。 |
| `integration/overlay/` | 8 個自有適配檔：播放器私有 part、DASH 擷取、Hive binding、來源／Seek／task scope／dispose 接點與 Android loopback network security。 |
| `integration/patches/` | 16 個逐檔 patch，僅修改必要的官方接點；每份 patch 有固定目標與 base blob。不得用完整修改後官方檔取代 patch。 |
| `tools/` | 重組、SDK/cache 核對、測試、建置、同步與接受流程。`tools/legacy/` 保留既有建置／測試 helper 的單一來源，重組時映射為 app 的 `tool/`。同步命令直接在候選根執行。 |
| 根目錄文件 | 本機維護規則、現況架構與既有歷史報告；不是官方來源。 |
| `.assembled/` | 忽略於 Git 的完整 Flutter 輸出。是必要建置產物，不是第二份可編輯的原始碼。 |

`PiliPlus/` 本身可辨識為完整官方專案，但官方工具鏈／正式套件仍屬上游流程；本候選的建置入口產生 Android BTR DEV APK。官方目錄的搬移是建立實體所有權邊界所需的一次重定位；未對官方檔案重新格式化或更名。原有 Dart import 與 Kotlin package 保留在重組結果中，沒有跨 package API 改寫。

## 組合與驗證

`tools/btr_sources.py compose` 驗證官方 pin、完整檔案清單、逐檔 blob 與 patch base，再複製官方來源、套用宣告的 patch，加入 BTR／適配檔及既有 helper。overlay 不得覆蓋官方檔、名稱不得碰撞或越界。Git 的換行設定只透過每次命令參數控制，不修改全域設定；`.gitattributes` 保留來源 bytes。

組合只接受本候選 `.assembled/` 或 `.scratch/` 下的新目錄。既有目錄、失敗後的部分輸出、來源檔及 APK 不自動覆寫或清除。每次產生 `.btr-composition.json`，列出輸入 fingerprint、每個輸出 blob 與所有權。`verify` 拒絕過期來源、輸出被修改及未列舉的 app source；Flutter 產生的標準 Java plugin registrant 是唯一 app source 例外。

```powershell
python tools/btr_sources.py compose
python tools/btr_sources.py verify --baseline
# 修改來源後，以新目錄重組；後續各命令帶同一個 -Output。
pwsh -NoProfile -File tools/btr.ps1 -Task Compose -Output .assembled/review-02
```

`--baseline` 額外驗證 `lib/`、`android/`、`test/`、第三方 notice、pubspec、lock 與 `.fvmrc` 等 1,525 個檔案，與模組化來源的 Git blobs 完全一致。這是本次分離工程的行為保留證據；未來修改功能／官方版本後，不能仍宣稱符合舊行為基準。一般 `verify` 檢查當前分離來源與輸出的一致性。

## 工具鏈、驗證及建置

需要 PowerShell 7、Git、Python 3、現有 Flutter／Pub／Gradle cache、Android SDK、JDK 與原 DEV key。Python 可透過每個 `btr.ps1` 命令的 `-Python '<python.exe>'` 指定，不依賴特定電腦路徑。

```powershell
pwsh -NoProfile -File tools/btr.ps1 -Task Setup -SeedRoot '<同 repository 的既有工作樹>'
pwsh -NoProfile -File tools/btr.ps1 -Task Core
pwsh -NoProfile -File tools/btr.ps1 -Task Settings
pwsh -NoProfile -File tools/btr.ps1 -Task Analyze
pwsh -NoProfile -File tools/btr.ps1 -Task Native
pwsh -NoProfile -File tools/btr.ps1 -Task VerifiedWrite -JavaHome '<JDK>'
python tools/test_sources.py
pwsh -NoProfile -File tools/btr_sync_tests.ps1
python tools/test_separated_sync.py
# 候選須先提交且乾淨；唯一 BuildId 保護歷史 APK。
pwsh -NoProfile -File tools/btr.ps1 -Task Build -BuildId '<唯一 ID>' -AndroidSdk '<SDK>' -JavaHome '<JDK>'
```

Setup 核對同 repository、Flutter 版本、pubspec、lock、所有 Flutter／Material patch（僅正規化 Windows 換行後比較），再建立候選輸出內的 cache junction 並複製既有 DEV key。它只做 offline locked pub resolution，不更新依賴或套用 SDK patch；不能對共享 junction 執行 prepare/repair helpers。不同 inputs 需獨立工具鏈，不准改種子。

Build 沿用既有 `BTR_DEVICE_TEST=true` 診斷編譯旗標與 ARM64 DEV 建置，沒有裝置操作。APK 與 `artifact.json` 保存於候選 `build/btr-candidates/<BuildId>/`，紀錄來源 SHA、官方 pin、fingerprint、大小與 SHA-256。來源組合可重現；不宣稱不同時間的 APK ZIP bytes 必然相同。

僅遇到 AGENTS.md 指定的 Windows Gradle IPC 症狀後，才加 `-ShortIpcPath`，使用該重組專案推導的 `.ipc`。缺 MSVC 的完整 Flutter/native 測試須列 BLOCKED；不得以隔離 harness 或 APK 成功代替。

## 耦合範圍

官方 1,651 個檔案現在不含 BTR 修改；自有新增檔案有唯一維護位置，16 個官方修改以可審查 patch 保存。更新上游時，純官方樹與 BTR 模組可以各自比較，工具負責重新組合，無須人工複製完整播放器或 Android 檔案。

執行期耦合沒有被宣稱消失：`player_integration.dart` 仍屬於 `PlPlayerController` library，依賴其私有欄位／來源序號／Seek 意圖／generation；DASH 依賴選定 representation 與上游 selector 的順序；設定 binding 依賴 GStorage；監控／設定 UI 依賴 PiliPlus 路由與播放器；MainActivity 依賴 AudioService engine，manifest／Gradle 依賴 DEV 身分與 loopback 契約。完整逐檔清單見 [CONTACTS](integration/CONTACTS.md)。

更新上述接點仍需三方審查；來源分離改善所有權與更新操作，不代表任意上游版本可以無衝突套用，也不代表實機播放或長時間資源驗收已通過。
