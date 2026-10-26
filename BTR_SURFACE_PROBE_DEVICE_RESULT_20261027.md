# Surface 診斷候選實機結果

實測於台北時間 2026-10-26 23:54／23:58，報告整理於 10-27。APK 來源 0489aa468a9b9afae657cd137b863d010ecc385e，Build ID surface-probe-20261026-01，手機 POCO M2012K11AG／4138ece6，僅 DEV 套件 com.example.piliplus.btr.experiment.dev。這是 f33097956 播放行為的診斷候選，不是新的效能修正。

## 量測

BV1kUpsedE4R，沿用 4K HEVC／1.0X；影音表示 6,507,038,367／45,633,327 bytes、single-origin-strong-etag，未改畫質、CDN 策略或 8 回應／4 執行槽／16 上游限制。

| 組別 | Session／開片至關閉指令返回 | 起播／最後 Seek ms | playerErrors／額外緩衝／容量 503 | PSS KiB |
| --- | --- | --- | --- | --- |
| R0 正常播放、無 Seek | 23.049／28.145 秒 | 1,873／不適用 | 0／0／0 | 512,372→517,654 |
| R1 三次快速 Seek | 31.301／35.338 秒 | 詳見原始 JSON／1,902 | 0／0／0 | 536,757→1,012,194 |

R1 實際目標為 809,872／3,099,524／1,912,297 ms，間隔約 1.37–1.45 秒，最後目標完成。開始前 UI 已確認指定 BV、播放中及緩衝超過十秒；不在錯誤／黑畫面上切換播放。兩輪均從開片、前置判斷至關閉與匯出在同一次有界工具執行完成，沒有讓影片跨模型回合持續播放；R1 設 45 秒協定預算，沒有觸發超時或記憶體停止門檻。R0 檔名 nominal 15／20 秒取樣實際較晚，真正時鐘保留於 device-actions.json，不以檔名宣稱精確採樣時點。

R1 確實發生 seek-capacity 重開，保存八筆 player-stopped 回應釋放，零容量拒絕。關閉後 current=null，open／active／waiting／parked 及上游連線與每軌保留歸零。一般事件未丟棄；lifecycle 丟棄八筆，不能宣稱保存了全部 GET 歷史。末端截圖有影片畫面，不代表已量測每次 Seek 的第一幀或可聽音訊。

## Surface 假說的實際證據

| R1 session 時間 ms | 觀察 |
| --- | --- |
| 17 | 第一次 load，widNonzero=true |
| 20,262 | 第一次一般 Seek |
| 20,373 | 一則 vo 未分類 error |
| 23,084 | 第三次 Seek，觸發容量重開 |
| 23,397 | unload，widKnown=true、widCleared=true；兩則 ffmpeg 未分類 error |
| 23,457 | 第二次 load，widNonzero=true、widSameAsPreviousLoad=true |

正常播放、R1 第一則／最後一則原生錯誤所保存的探針，以及 R1 末端均回報 hwdec-current=mediacodec。沒有保存到 surface-connect／surface-create／video-output-init／hardware-decode-failed 提示。

這些觀察不足以支持「容量重開導致轉軟解」：vo error 早於該次 unload 約 3,024 ms，回報的解碼種類未改變。相等 JNI 參照值可由槽回收造成，不是 Java Surface 物件身分證明；白名單未識別錯誤也不等於排除 Surface 問題。故不修改 SDK 的 _current／Surface 重建方式，不將此線索宣稱為根因。hwdec-current 是原生屬性回報，定義參見 https://mpv.io/manual/stable/ ，不能單獨代替實機硬解與畫面驗收。

R1 仍有 vo 1／ffmpeg 2 的未分類 native error，與零 playerErrors 分開保留。雖未越過 1 GiB 門檻，快速 Seek 的圖形記憶體仍高；關閉後 PSS 362,332、Graphics 156,320、Native Heap PSS 68,648 KiB。這不能證明 session 內記憶體峰值已受控或沒有 native／GPU 洩漏。沒有做六次連續 Seek、長時間播放或完整聲畫同步驗收。

## 版本與驗證

相關離線 37 項 PASS，最後樣式修正受影響三項再測 PASS；修改檔靜態分析通過。完整 Flutter/native suite 仍因既有 Windows MSVC 缺失失敗，不列為通過。一般沙箱的 Android 建置因暫存物件 rename 存取拒絕／0xC0000008 失敗；正式審查後同建置成功（254.6 秒），未修改 TEMP/TMP、擁有權或系統安全設定。

APK：build/btr-candidates/surface-probe-20261026-01/PiliPlus-BTR-SurfaceProbe-20261026-01-dev-arm64-v8a.apk。SHA-256 6c306e96e1a60ded57d37d9d054e5e5648f6113193c8791efa2877b988e93842，手機 base.apk 相同，原 DEV 簽章與權限相同。libmpv／libflutter 逐位元組相同；libdartjni 僅 20-byte GNU build ID 不同、正規化後相同，其他 runtime library 沒有差異，libapp 是預期的新 AOT。沒有修改共享 SDK 原始碼或依賴鎖。

原始 JSON、手機／本機雜湊、操作時鐘、記憶體、截圖及離線檢查在 evidence/surface-probe-20261026-01/。R0-normal.json 與 R1-rapid.json 各只計算 recent 最後一個獨立 session，不將歷史重複加總。

手機目前安裝此診斷版，combined／自動線程／自動 CDN，影片已關閉。保留 f33097956 作播放改善候選、既有 4a806ca3b 回退，均不提升為正式穩定版。整體目標仍未完成：高圖形記憶體根因與 session 內界限、未分類原生錯誤、健康原始模式同條件 A/B、第一幀及完整聲畫同步仍缺充分證據。本候選沒有可宣稱的相對效能提升。
