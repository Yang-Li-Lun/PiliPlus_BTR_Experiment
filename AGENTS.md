# BTR 維護

- 要求「同步 PiliPlus 最新版本並保留 BTR 功能」時，先讀 `BTR_UPSTREAM.md`、`tool/btr_upstream.json`、`BTR_EXPERIMENT.md` 與實際 Git 狀態，依文件建立獨立候選。
- `main` 含 BTR，不能當純上游。保留原功能分支、穩定分支、歷史 tags、舊 APK 與 evidence；不改寫歷史，不推送、不建 PR。
- 無衝突時由 `tool/btr_sync_upstream.ps1` 自動 merge；有衝突時讀三方程式碼，保留 BTR 行為，精確 stage，完成測試與 ARM64 DEV APK。
- 不把 Git／測試／建置成功視為 Android 實機驗收。保留既有 UNRESOLVED；不自動提升穩定版本。明確授權的 BTR 實機驗證任務可透過 ADB 安裝本專案 DEV APK（僅限 `com.example.piliplus.btr.experiment.dev`），並進行播放、Seek、介面操作、截圖與唯讀診斷；驗收以實際證據為準。
- ADB 操作前須以裝置序號唯一確認目標為 POCO `M2012K11AG`，未確認即停止；不得操作 `SM-T720` 或其他裝置／App，不得清除使用者資料、修改系統安全設定、取得 Root、安裝非本專案 APK、推送遠端或正式發布。
- 本機 Windows 作業；檔案留在本專案。候選重用 SDK/cache 時先核對版本、lock 與 patches，不修改種子 SDK 或全域 Git 設定。
- 僅在遇到 `Unable to establish loopback connection`、`PipeImpl`、`UnixDomainSockets` 或 `Invalid argument: connect` 時，先用 repository-local 短路徑的 `jdk.net.unixdomain.tmpdir` 測試；依實際 repository 路徑推導，不硬編碼，不先修改 TEMP/TMP、Android source、dependencies、hosts 或 JDK。
