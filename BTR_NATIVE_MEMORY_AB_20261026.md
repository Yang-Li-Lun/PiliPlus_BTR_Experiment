# 原始模式記憶體與短測限制

APK 來源仍為 f33097956，沒有修改程式碼或重建；新增證據在 evidence/native-memory-ab-20261026-01/。僅操作指定 POCO 4138ece6 的 DEV。此次沒有取得完全同條件的原始／BTR 三次絕對位置 Seek A/B，不能據此計算速度或記憶體改善百分比。

## 可用證據

A2 為新程序 PID 3260，交接 JSON recent=[]、mode=original、transport／tracks=null，故該程序尚未使用 BTR。已確認 BV1kUpsedE4R、4K 超高清、HEVC、1.0X。起播 2,329 ms，playerErrors=0、bufferingEvents=0。

恢復播放後的三次拖曳只留下兩次相對位置 Seek，實際目標 2,000,615／2,020,385 ms，最後恢復 1,880 ms，零 playerErrors／額外緩衝。不能當成預定 809,872／3,099,524／1,912,297 的三次快速 Seek。PSS 前 545,199、後 702,435、暫停後補充 696,839 KiB；Graphics 前 194,424、後 334,788、補充 334,256 KiB。這證明健康起播的原始模式也有圖形記憶體成長，但沒有重現 1 GiB，不能歸因或排除 BTR 額外成長。先前口頭更新以 MiB 描述原始數值不精確；此處正確單位為 KiB，PSS 前後約 532／686 MiB。

A3 為另一次全新原始程序 PID 14038，UI 明確讀到指定 BV；PSS 取樣 391,033、Graphics 192,984 KiB。原定先核對展開進度條才送 Seek，但第二次 uiautomator dump 耗時約 7.3 秒，回傳時只剩收起的進度顯示 [0,680][1080,688]，guard 未通過，因此沒有送任何 Seek，隨即正常關閉影片。

A3 關閉 session 為 59,599 ms，起播 9,225 ms、playerErrors=0、額外緩衝=9、Seek=[]。部分緩衝持續 1.8–2.8 秒。這是原始模式的短時播放異常，不能將該輪標為健康正常播放或成功快速 Seek；原始模式未提供 BTR upstream／CDN 身分診斷，原因仍 UNRESOLVED，不能直接認定網路、解碼或代理問題。

## 無效操作與測試流程

A1 在處理更新提示後意外切換至同 DEV 的另一推薦影片；發現後關閉並保存 A1-invalid.json 與畫面。其 Seek、錯誤及記憶體不得用來驗收指定影片。後續改用返回鍵處理提示，再讀取 BV 與畫質／格式。

控制器 play(hideControls=true) 會立即隱藏控制列，controls setter 又啟動 hideTaskControls 的有限顯示 timer。因此 resume 後直接對固定 y=527 拖曳可能走播放器畫面的相對 Seek 手勢；耗時超過顯示期限的 UI dump 也不能證明手勢送出時控制列可見。這些是已確認的驗證流程限制，不修改播放器設定、計數或產品行為來取得通過。

## 最終狀態與結論

final-settings.json 已確認 current=null，設定恢復 combined、自動線程、自動 CDN，其餘設定一致，沒有清除資料。原始 A2、A3、最終設定三份關鍵 JSON 均比對手機 SHA-256。證據保留全部有效、無效與未執行的樣本，沒有混算 recent。

本輪未修正記憶體問題，未證明 native／GPU 無洩漏，也未完成同條件 A/B。f33097956 的先前正常／快速／一般 Seek 短測結果仍有效；新資料只限制根因判斷：原始模式也能出現記憶體成長及不穩定緩衝，不能把所有現象直接歸為 BTR。下一步應先建立可確認實際目標與控制列狀態的短測流程，再作相同條件採樣，不能重複盲目手勢或依本輪數字調整 native 緩衝／CDN／線程。
