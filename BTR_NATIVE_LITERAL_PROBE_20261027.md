# 原生影片錯誤固定訊息診斷

延續 0489aa468 的診斷結果：快速 Seek 的 vo error 先於容量 unload，回報解碼種類仍為 mediacodec；現有證據不足以修改 Surface 或解碼生命週期。本候選只補足錯誤分類，沒有宣稱修正原生播放或高圖形記憶體。

從已安裝 Surface 診斷 APK 的 libmpv.so 查核 26 個固定訊息前綴均存在，涵蓋 EGL、原生視窗、硬解畫面映射／複製、影格池、codec 佇列／flush／釋放與呈現階段。只輸出固定列舉值，仍最多讀取 256 字元，不保存任意訊息後綴、來源網址、地址或解碼器名稱。固定訊息反映原生程式報告的失敗階段，不等同已確認根因；「leaking resources」亦不能單靠此訊息證明本案記憶體增量來源。

修改限於 lib/services/btr/native_failure_hint.dart 及其測試。沒有改變 GET 取消、回應釋放、8／4／16 限制、Range／ETag 驗證、播放器、CDN 或 SDK。隔離分支 codex/btr-native-literal-probe-20261027-01，前一診斷提交 a5a13fd72 保留。

離線驗證：26 個前綴均在實際 APK 原生庫中找到；針對分類／隱私、計數／事件界限、FFI 釋放及 Surface 探針的 13 項測試 PASS，兩個修改 Dart 檔靜態分析無問題。未重跑未受影響的完整測試。證據存於 evidence/native-literal-probe-20261027-01/，不修改先前已封存證據。

## 建置與實機結果

程式提交 d9d308ee62cca961a6433f1b0cca8b7ee4b302c0。ARM64 DEV 建置成功（168.6 秒），Build ID native-literal-probe-20261027-01，APK SHA-256 8742983cf33c2ef19dd50f64aa4329da14ec5e0d70b615699c20eaafc51b2a75。已核對 DEV 包名、原簽章、權限、AOT Build ID，libmpv／libflutter 與前版逐位元組相同。adb install -r 成功，手機 base.apk 雜湊相同，未清除資料；唯一確認 POCO M2012K11AG／4138ece6，未操作其他裝置。

R2 開片後發現更新提示，關閉提示並返回結束影片，壁鐘 18,682 ms；未做 Seek，排除於快速 Seek 比較，操作紀錄保留。R3 確認指定 BV、播放中、緩衝 54.7 秒及隱藏進度條位置後才開始，三次實際目標 809,872／3,099,524／1,912,297 ms，間隔 1,376／1,401 ms。最後時間軸恢復指標 1,921 ms，seekPending=false；session 26,772 ms，開片至關閉壁鐘 32,455 ms。所有開片、健康判斷、Seek、等待、取樣、正常關閉均在同一次有界工具執行，沒有跨模型回合持續播放。

playerErrors、額外緩衝、容量 503、requestFailures、terminalFailures 均零。發生一次 seek-capacity 重開，八筆 GET 保存 released／player-stopped 紀錄；逐筆 consumerValidity 仍為 unobservable，不能將它誤稱為 HTTP 層直接觀察到消費者失效。關閉後 current=null，代理 active／open／waiting／parked、上游與每軌保留均零。lifecycle 丟棄八筆，不宣稱完整 GET 歷史。資料表示維持視訊 6,507,038,367／音訊 45,633,327 bytes，single-origin-strong-etag，8／4／16 限制不變。

PSS 526,492→994,870 KiB，Graphics 197,200→607,344 KiB；未達 1,048,576 KiB 停止門檻，但仍不能證明 session 內峰值受控。關閉後 PSS 397,748／Graphics 158,264 KiB。末端截圖有實際影片畫面，音訊軌選中、未靜音、取樣 avsync -0.000502 秒；不是每次第一幀、可聽音訊或全程同步驗收。

仍重現 vo 一則與 ffmpeg 兩則 error，全部 failureHint=unclassified：vo 在 15,416 ms，第一次 Seek 為 15,309 ms；ffmpeg 在容量重開附近 18,370 ms。新增 26 個白名單均未命中，無法據此歸因 EGL、frame pool 或 codec。此為新增診斷未識別實際錯誤的負面結果，不能回填歷史事件或宣稱原生錯誤已排除。不再依此線索修改 Surface／解碼行為。

R3 原始報告手機與本機 SHA-256 相同：ca6cef9cd9c09d28675a17b51c94448161d65518bf8bfb21b0ed4a76da354477。整體驗收仍未達成：高圖形記憶體與原生錯誤未定位、健康原始模式同條件 A/B、第一幀及完整聲畫同步未完成。此診斷版沒有可宣稱的相對效能提升，保留 f33097956 功能候選、4a806ca3b 回退與穩定基準；目前手機安裝 d9d308ee6，combined／自動線程／自動 CDN，影片已關閉。
