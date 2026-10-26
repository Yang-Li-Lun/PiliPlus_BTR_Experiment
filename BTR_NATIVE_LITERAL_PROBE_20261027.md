# 原生影片錯誤固定訊息診斷

延續 0489aa468 的診斷結果：快速 Seek 的 vo error 先於容量 unload，回報解碼種類仍為 mediacodec；現有證據不足以修改 Surface 或解碼生命週期。本候選只補足錯誤分類，沒有宣稱修正原生播放或高圖形記憶體。

從已安裝 Surface 診斷 APK 的 libmpv.so 查核 26 個固定訊息前綴均存在，涵蓋 EGL、原生視窗、硬解畫面映射／複製、影格池、codec 佇列／flush／釋放與呈現階段。只輸出固定列舉值，仍最多讀取 256 字元，不保存任意訊息後綴、來源網址、地址或解碼器名稱。固定訊息反映原生程式報告的失敗階段，不等同已確認根因；「leaking resources」亦不能單靠此訊息證明本案記憶體增量來源。

修改限於 lib/services/btr/native_failure_hint.dart 及其測試。沒有改變 GET 取消、回應釋放、8／4／16 限制、Range／ETag 驗證、播放器、CDN 或 SDK。隔離分支 codex/btr-native-literal-probe-20261027-01，前一診斷提交 a5a13fd72 保留。

離線驗證：26 個前綴均在實際 APK 原生庫中找到；針對分類／隱私、計數／事件界限、FFI 釋放及 Surface 探針的 13 項測試 PASS，兩個修改 Dart 檔靜態分析無問題。未重跑未受影響的完整測試。證據存於 evidence/native-literal-probe-20261027-01/，不修改先前已封存證據。

目前沒有本候選的實機分類結果，不能回填歷史 unclassified 事件或宣稱原生錯誤已排除。後續須在同一有界操作流程中，以指定 POCO／DEV／BV1kUpsedE4R／4K HEVC 1.0X 完成前置健康確認、三次快速 Seek、記憶體檢查與關閉；維持既有記憶體停止門檻，不進行長測。整體驗收仍未達成。
