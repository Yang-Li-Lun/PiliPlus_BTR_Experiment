# 後續低供應速率與 Wi-Fi 切換驗證

APK 來源維持 f33097956，未修改程式碼、依賴、線程、播放器緩衝或安全限制，未重建 APK。先前成功短測只適用於當時條件；本報告包含後續失敗，整體驗收仍未通過。證據分別在 evidence/seek-verified-ab-20261026-01/（切換前）及 evidence/wifi-retest-20261026-01/（使用者切換 Wi-Fi 後）。

## 切換前

| 組別 | 起播 ms | Seek 時間軸 ms | playerErrors／額外緩衝 | 結論 |
| --- | --- | --- | --- | --- |
| A4 原始模式 | 6,470 | 6,098 | 1／14 | 不健康；包含額外 user 重開，不作純 Seek 速度比較 |
| B4 BTR | 8,036 | 6,626 | 0／10 | 零容量 503，但穩定性驗收失敗 |
| C5 BTR、COS 偏好、無 Seek | 7,873 | 無 | 0／6 | 實際回退 ALI-OV，仍有緩衝 |
| C6 BTR、ALI 偏好、無 Seek | 9,638 | 無 | 0／7 | 實際仍是 ALI-OV，未證實換源 |

A4／B4 的三個實際目標均吻合 809,872／3,099,524／1,912,297 ms，修正後操作流程可命中絕對進度條。兩輪均已在 Seek 前有多次正常播放緩衝，不能當成健康暖機的公平效能 A/B。A4 末端為黑畫面，原定暫停點擊在失敗狀態觸發 user 重開，該次之後有一筆 other player-error；保留整個 session 計數，不將它單獨歸因為 Seek。A4 的 6,098 ms 也不能當作黑畫面已恢復的第一幀證據。

B4 正常結束時直接返回關閉，沒有播放／暫停切換或額外 user 重開。仍有一次 seek-capacity 重開，零 proxyCapacityRejections、requestFailures、terminalFailures，關閉後 proxy／upstream 資源歸零。一般事件丟棄 81、lifecycle 丟棄 2，因此不宣稱完整保存所有 GET 歷史。原始模式不提供代理指標，不能填成原始模式零代理 503。

B4 畫面取樣總實收約 1.04 MiB/s，原生末次 demux input 918,693 bytes/s，低於本片全片平均視訊需求約 1.52 MiB/s；兩模式均反覆緩衝，提示資料供應不足。這些是不同範圍的取樣，包含場景碼率、探測／重複請求與 consumer 背壓影響，不能直接證明 CDN、WAN 限速或 Wi-Fi 的確定瓶頸。Wi-Fi 唯讀連線取樣 RSSI -38、1200 Mbps；僅是實體鏈路資訊，不代表上網頻寬。

C5 實際 session 42,343 ms，COS video 在 926 ms 發生 source-failed/http-io，session health 為 quarantined-for-session；接著 video 選 ALI-OV，audio 也選 ALI-OV，single-origin-strong-etag，crossSourceComposition=false。這是實際來源探測失敗後安全選用備援的證據，不是強制 403、既有下載中途切源或完整檔案雜湊驗收。http-io 僅分類 HttpException，沒有保存精確 HTTP 狀態或原因。C6 session 44,863 ms，ALI 偏好沒有實際選到 ALI，不能宣稱測過該 CDN 吞吐。

A4 PSS 412,400→770,376；B4 427,527→508,910 KiB，均未達停止門檻。這不能證明較低記憶體帶來改善，因緩衝與實際消費進度不同。

## 使用者切換 Wi-Fi 後

使用者確認已切換，未由工具修改網路設定。新連線唯讀取樣 RSSI -51、866 Mbps，未收集 SSID、MAC 或憑證。新舊網路結果分開，不視為同一測試環境。

N1 尚未完成正常播放前置確認：沒有更新提示時送出的返回鍵已關閉影片，guard 沒讀到指定 BV，故未執行預定取樣，不列為正常播放成功。後續流程改為先讀到更新提示才以返回鍵關閉，再確認指定 BV。

N2 在新程序完成 session 44,669 ms 的無 Seek 正常播放：起播 3,265 ms，playerErrors／額外緩衝／容量 503／requestFailures／terminalFailures 皆零，75,000 ms 寫入期限生效，四筆 GET 都是正常 session 關閉取消，沒有 timeout。前後截圖顯示實際影片畫面，未變更 4K HEVC 表示（影音 6,507,038,367／45,633,327 bytes，single-origin-strong-etag）。PSS 三次 533,123／534,083／576,363 KiB；實際採樣時間 18.253／30.015／42.004 秒，第一筆晚於檔名中的 nominal 15 秒。這支持切換網路後供應恢復，不能單靠前後兩組就精確定位舊網路哪一層限速。

A5 原始模式在約 6,070 ms 已有起播錯誤，後續 UI 操作觸發 user 重開，只留下兩個相對 Seek；總 session 75,425 ms、playerErrors=9、額外緩衝=3。整輪無法作健康原始／BTR 速度對照，不把失敗換成零恢復時間；不隱藏操作引入的重開。

B5 在播放中且原生緩衝 48.9 秒的前置確認後，三個實際 Seek 目標吻合。最後時間軸 1,213 ms，零 playerErrors／額外緩衝／容量 503／requestFailures／terminalFailures，session 關閉後所有代理資源歸零。但 PSS 由 648,077 上升至 1,116,706 KiB，已超過 1,048,576 KiB 停止門檻，隨即正常關閉，不能列為整體驗收通過。

B5 開片到關閉壁鐘 121,640 ms、session 121,156 ms，超出原定短測時窗。原因是開片與有界測試分在兩次工具執行，中間模型處理時間未受裝置側硬時限涵蓋；不將它當成受控短測或長時間穩定性驗收。之後若再做實機測試，必須把開片、前置判斷、所有等待、採樣與關閉放在同一個有界執行流程，不讓影片在兩個模型回合間持續播放。N2 已採此流程；沒有為取得通過而提高記憶體門檻。

## 記憶體證據與剩餘缺口

B5 的 Graphics 前 194,764、後 608,956 KiB；其中 Gfx dev 從 22,236 升到 436,428，EGL mtrack 維持 171,568、GL mtrack 維持 960。Native Heap PSS 320,588→362,916。這將本輪主要增量縮小到 Gfx dev 分類，但尚未對應到具體 Surface／MediaCodec／驅動物件，不可寫成確定解碼器或 GPU 洩漏原因。

關閉後 PSS 356,005、Graphics 157,580、Native Heap PSS 65,460 KiB；代理 active／open／waiting／parked 及每軌保留均零。這證明大部分資源在關閉後釋放，不能排除播放 session 內不斷成長，或宣稱 native／GPU 沒有洩漏。B5 音訊／畫面探針為 48 kHz／2 聲道、未靜音、末次 avsync -0.000792 秒與取樣掉幀零，僅代表該取樣，不是第一幀、可聽音訊或全程同步驗收。

目前維持 combined／autoConcurrency／preferredCdn=null，current=null，影片已關閉，未清除資料。所有關鍵原始 JSON 均比對手機 SHA-256。仍保留 f33097956 為診斷 DEV 候選與既有 4a806ca3b 回退，不提升穩定基準。

整體目標尚未完成：快速回應容量拒絕在已測流程未再現、正常播放期限修正有改善證據、真實來源探測失敗備援已有局部證據；但新網路下健康原始模式 A/B、圖形記憶體峰值／session 內界限、未分類原生錯誤及完整聲畫同步仍缺乏充分證據。沒有以提高線程、改畫質、放寬驗證或重設計數掩蓋未通過項目。
