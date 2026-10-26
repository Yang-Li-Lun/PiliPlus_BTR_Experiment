# 2026-10-26 換源順序候選實機與記憶體停測

來源 `7c7734d6df50b3937f1e63249aca58512d4dbbeb`，Build ID `source-stop-20261026-01`。只將舊 BTR session 的 close 移到 await native stop 之後；不含 553114375 的續播重開。未提升穩定基準或取代最佳已驗證的 4a806ca3b。

指定 POCO M2012K11AG／4138ece6、DEV 套件、BV1kUpsedE4R、4K HEVC、使用者確認 1.0X。未改動 128 MB／60 秒播放器設定、CDN／線程或 8／4／16 限制。原始 JSON 匯出遠端／本機雜湊相符，證據目錄 `evidence/source-stop-20261026-01/`。

| 組別 | 啟動時間軸 ms | 最後 Seek 恢復 ms | playerErrors | 額外緩衝 | 容量 503 |
| --- | --- | --- | --- | --- | --- |
| B1 BTR 三次快速 Seek | 2,795 | 1,716 | 0 | 1 | 0 |
| A1 原始，同程序自動流程 | 3,473 | 1,306 | 0 | 0 | 未量測／不使用代理 |
| B2 BTR 預定回測 | 未執行 | 未執行 | 未測 | 未測 | 未測 |
| A2 新程序原始，失敗樣本 | 未恢復 | 未恢復 | 6 | 0，尚未完成 startup | 未量測／不使用代理 |

B1 與 A1 截圖均有實際畫面，三個目標命中且 seekCommandFailures=0。B1 最高執行槽／上游 4／12，最後單一音軌選中、48 kHz／兩聲道、未靜音、取樣 AV sync -0.001127 秒，取樣掉幀為零。沒有本輪人工可聽或全程同步量測。B1 多一次緩衝且比 A1 最後恢復慢，不能宣稱沒有退化或優於原始模式；既有診斷沒有緩衝事件時間，尚無法歸因。

新候選 B1 起始沒有 playerErrors，不能只憑一輪就認定先前三次起始錯誤已由換源順序修復。後續 B2 因既定 PSS 安全門檻被拒絕，沒有開始播放；不把 B2 的 preflight 檔案算成完成樣本。

## 記憶體門檻與新程序原始對照

同程序 PID 5421 的取樣（KiB）：

| 位置 | PSS | Graphics |
| --- | --- | --- |
| B1 前 | 572,143 | 222,604 |
| A1 前 | 627,610 | 220,260 |
| B2 preflight，仍原始模式暫停 | 1,126,550 | 635,884 |
| 關閉影片後 | 802,023 | 317,476 |
| 關閉後較晚 | 794,240 | 317,476 |

B2 preflight 超過既定 1,048,576 KiB 門檻，停止影片測試並正常關閉。較晚 native heap allocated 81,323 KiB、free 300,600 KiB，不能將 resident pool 視為仍在配置相同數量的有效影片物件。post-close current=null，已結束 BTR session 的代理／上游／兩軌資源均歸零。這些不能證明所有 native 或 GPU 資源無洩漏，也不能將 Graphics 歸因為 Dart 代理。

保存資料後將 DEV 設原始模式並僅 force-stop 本套件，未清除資料；使用者重新開片，PID 20086、handoff current=original／recent=[]，4K HEVC 已重新確認。新程序 handoff PSS 531,664、Graphics 219,948 KiB。A2 完全沒有啟用 BTR 傳輸。

A2 重載後約十秒截圖已黑畫面、startupTimelineMs=null，後續快速 Seek 仍 pending，20,358–25,721 ms 六次錯誤（四 network／兩 other），不能填成零延遲、成功播放或納入速度比較。失敗取樣 PSS 952,053／Graphics 555,772 KiB，證明沒有 BTR 傳輸的程序也能有圖形記憶體成長與播放異常；不是健康播放下高記憶體根因或洩漏證明。因暖機失敗，memory-burst.ps1 在狀態驗證即停止，沒有完成其預定暫停觀察；另外保存失敗 meminfo 並正常關閉影片。

DEV PID 的唯讀 logcat 沒有匹配的 HTTP／ffmpeg／MediaCodec／OOM 訊息，無法解釋此原始路徑失敗。目前原始模式未訂閱 native log，player-error 只有類別，尚不能區分 HTTP 拒絕、讀取錯誤、原生解碼或其他機制。必須先補充不含網址、憑證與任意原始文字的診斷，不能盲目改寫重試、來源安全或播放器參數。

## 離線與交付狀態

7c7734d6d 完整離線 suite 145／145 PASS、來源停止六情境 PASS，兩修改 Dart 檔靜態分析 No issues found。APK 建置、原 DEV 簽章、權限、ARM64、AOT Build ID 及裝置安裝後雜湊均核對；mpv／Flutter 執行庫位元組相同，libdartjni 差異僅 20-byte GNU build ID。

APK `build/btr-candidates/source-stop-20261026-01/PiliPlus-BTR-SourceStop-20261026-01-dev-arm64-v8a.apk`（相對本工作樹），SHA-256 `6ba82198905df2a438989fe3552c75918957bad72eb0368f986702c263a3ce3a`。此候選尚未通過完整實機驗收，不將五行生命週期修正當成所有起始錯誤、記憶體或續播問題的解答。穩定基準與先前 APK／證據保留，沒有推送、PR 或正式發布。
