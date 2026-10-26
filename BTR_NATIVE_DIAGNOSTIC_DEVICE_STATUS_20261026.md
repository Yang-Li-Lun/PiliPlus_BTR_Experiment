# 2026-10-26 原生錯誤診斷 APK 與 A3 暫停觀察

實作來源 `407303f1e876b3b964cfd9c5b9639a407c9a072d`，Build ID `source-diag-20261026-02`，已建置並安裝於唯一指定 POCO M2012K11AG／4138ece6 的 DEV 套件。裝置 base.apk 與保存 APK SHA-256 均為 `f8905dd5ecb0be30abd99ffb79f1ef02768abf28580bded6f60c8ee6f3a27168`。原 DEV 簽章、權限、ARM64、AOT Build ID 已核對，mpv／Flutter 等原生執行庫一致；libdartjni 僅 20-byte GNU build ID 不同，正規化內容一致。

APK 位於本工作樹 `build/btr-candidates/source-diag-20261026-02/PiliPlus-BTR-SourceDiag-20261026-02-dev-arm64-v8a.apk`。此為診斷候選，不是新穩定版本；先前最佳快速 Seek 版本 4a806ca3b、未通過整體改善的 553114375 與尚未完整驗收的 7c7734d6d APK／證據均保留。

## 實際裝置觀察

先前開片指令再次經使用者明確授權後仍於執行前遭工具 `blocked by policy` 拒絕，沒有詳細原因。其後未將開片改成其他命令或 UI 路徑。使用者另將 DEV 手動開至指定影片後，唯讀 UI 證實 BV1kUpsedE4R／原始模式／暫停；本輪沒有成功打開播放器選單，因此 4K、HEVC、1.0X 未由這輪介面重新確認。

A3 PID 13789 handoff 的 PSS 411,930、Graphics 121,816 KiB。影片區為灰畫面，分別點按後沒有觀察到控件／選單；返回鍵與全域設定正常運作。這不足以判定 Flutter UI 凍結、原生解碼失敗或工具未送達；控件未顯示的原因仍未確認。

正常關閉影片後，從全域 BTR 設定匯出 `A3-manual-session-closed.json`，遠端／本機 SHA-256 相符：`182ef8a1477b34c6aecc50475100511b3771d5910f5747b0178d9ad0baf835e1`。current=null，recent 僅一筆已結束原始 session，playerErrors=0／native errors=0，startupTimelineMs=null、沒有 Seek，bufferAheadSeconds=60.252。原始路徑代理／上游欄位保留未量測，不填為零。

此 session 沒有確認過播放進展；暫停載入不能因 startupTimelineMs=null 或灰畫面就判定暖機失敗，也不能因零錯誤判為播放通過。代理未啟用，不能用它驗證容量拒絕修正。其約 356 秒 elapsed 是手動暫停狀態的 session 年齡，不是代理執行長時間播放測試。Agent 沒有在這輪發出播放、Seek 或重載；也沒有執行預備的 reload-probe.ps1。

## 當前界線

原生固定提示／狀態碼與緩衝時間診斷已完成離線驗證，但本 session 沒有原生錯誤，尚未由實機命中提示欄位。五檔靜態分析 No issues found；離線測試範圍與修正 fixture 的紀錄見 `BTR_NATIVE_FAILURE_DIAGNOSTICS_20261026.md`，不因本次手動交接重跑。

依使用者新偏好，本輪 ADB 動作逐條下達，未執行 ADB helper 腳本。下一輪須先由使用者在 DEV 開啟指定影片，確認 4K HEVC、1.0X 且實際畫面前進後暫停，再繼續短時重載取證。開片工具拒絕沒有被解除；後續短測授權保留。完整專案目標仍未全部驗收，不推送、建立 PR、發布或提升穩定基準。
