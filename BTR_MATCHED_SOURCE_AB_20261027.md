# ALI-OV 同來源短時對照

本次沒有修改播放程式碼、建置或安裝。沿用診斷 APK d9d308ee62cca961a6433f1b0cca8b7ee4b302c0／native-literal-probe-20261027-01。唯一確認 POCO M2012K11AG／4138ece6，DEV 套件 com.example.piliplus.btr.experiment.dev，指定影片 BV1kUpsedE4R，維持既有 4K／HEVC／1.0X 設定。

## 比較條件與來源差異

先讀取 App「播放地址」，其視訊、音訊主機均為 upos-sz-mirrorcosov.bilivideo.com，而前次 BTR 實際選擇 ALI-OV。原始模式與 BTR 選源不同，不能將前次原始模式失敗歸因播放器效能。這項觀察亦未直接證明 COS-OV 是失敗原因。

從實際 SDK 原始碼確認 mpv log text 只經 trim() 後傳入 PlayerLog，未發現可解釋目前未分類錯誤的重新包裝格式。沒有修改共享 SDK。

本次透過既有「音视频设置」暫時將原生 CDN 偏好設為 aliov。先暫時停用 CDN 測速：實際原始碼顯示，開啟全域 CDN 選擇對話框時，預設測速會請求其他固定影片；停用可避免本次測試使用指定影片以外的媒體。音訊「不跟随 CDN」維持原先關閉，未改畫質、解碼或緩衝設定。兩輪測試後均在 App 播放地址對話框確認視訊、音訊主機為 ALI-OV；BTR 報告也確認實際兩軌均選 ALI-OV。

UI XML 以 /dev/tty 串流在記憶體解析，只輸出經允許網域篩選的主機名稱。沒有匯出完整來源 URL／查詢簽名、按確定修改地址或操作外部 App。前兩次讀取因 UI XML 解析問題中止並正常關閉（13.959／12.805 秒），未做 Seek，不列入效能比較；修正解析附加的狀態文字後，主機讀取於 23.683 秒內完成。所有嘗試保留於 evidence/native-source-audit-20261027-01/。

## 量測

各輪先保存模式、結束 DEV 程序，再以新程序開片，避免將前一模式的 native 記憶體當作本輪新分配。開片、前置確認、三次 Seek、等待、取樣、主機讀取與正常關閉均在同一次有界工具執行完成；前置 UI 必須為指定 BV、播放中且至少十秒緩衝。兩輪均未觸發 1,048,576 KiB 停止門檻，沒有進行六次 Seek 或長時間播放。

| 指標 | A6 原始模式 | B6 BTR |
| --- | --- | --- |
| 前置緩衝 | 53.4 秒 | 50.0 秒 |
| 實際三次 Seek 目標 ms | 809872／3099524／1912297 | 相同 |
| 起播時間軸指標 | 2408 ms | 984 ms |
| 最後 Seek 時間軸恢復指標 | 1069 ms | 1960 ms |
| playerErrors／額外緩衝 | 0／0 | 0／0 |
| native error | 0 | vo 1／ffmpeg 2，均未分類 |
| 容量 503 | 不適用，未走代理 | 0 |
| Session／開片至關閉壁鐘 | 37.268／41.552 秒 | 40.419／45.424 秒 |
| Seek 後 PSS | 1038328 KiB | 996192 KiB |
| Seek 後 Graphics | 606876 KiB | 604708 KiB |
| 關閉後 PSS／Graphics | 369294／156676 KiB | 388060／156072 KiB |

本次 BTR 最後恢復指標多 891 ms，約 83.3%，沒有證據支持 BTR 比健康原始模式快。這是一次 A→B 順序比較，未隨機化；初始播放目標 1950000／1926000 ms 不同，快取與開片前 API 時間亦未控制。起播指標以 BtrMetrics 建立時鐘計算，不是完整 Android 啟動時間；不從此單次差異推論固定加速比例。

兩輪一般事件均未丟棄。B6 實際一次 seek-capacity 重開，八筆 GET 有 released／player-stopped 紀錄，lifecycle 丟棄八筆，不代表保存全部請求歷史。consumerValidity 仍為 unobservable，不宣稱 HTTP 層直接證明消費者失效。B6 關閉後 active／open／waiting／parked、上游及每軌保留均零；8 回應／4 執行槽／16 上游限制、Range 與來源驗證未變更。BTR 影音表示 6507038367／45633327 bytes、single-origin-strong-etag；原始模式沒有輸出 ETag、總長與原生 codec 探針，不將主機對齊說成完整表示與 native pipeline 逐項相同。

兩張末端截圖均有指定影片畫面，音訊軌選中。時間軸恢復與單張畫面不能替代每次 Seek 第一幀、可聽聲音或全程音畫同步驗收。

## 結論與保留項目

原始模式以 ALI-OV 可完成這次健康短測，補足先前一直失敗的基準。它在完全未啟用 BTR 的新程序也有約 593 MiB Graphics，故目前不能把同量級圖形記憶體歸因 BTR 容量重開；這亦未證明記憶體峰值受控或不存在共同 native／GPU 洩漏。

原生 CDN 偏好已恢復「备用URL」，CDN 測速恢復開啟，預設畫質仍為 4K；BTR 維持 combined／自動線程／preferredCdn=null，影片已關閉。未清除資料、變更其他 App／裝置、推送或提升穩定版本。

本次程式未修改，相關離線測試沿用 d9d308ee6 的有效結果，不重跑或宣稱新增測試。原始 JSON 已比對手機 SHA-256：A6 26eff1a47249cd2d1ae26c5685b3ec25f9368544da01c00e652ed14a920c68bb；B6 65b4b1245643ca9fd80f8cf506f91b1eb9557cd06fc02c9274cf42b9045e55bf。

整體驗收仍未達成。BTR 的容量拒絕在已測流程未重現，但本次健康原始模式更快，BTR 未分類原生錯誤仍在；記憶體 session 內界限、第一幀及完整聲畫同步尚未證明。保留 f33097956 功能候選與既有回退，不把診斷候選升為正式穩定版本。
