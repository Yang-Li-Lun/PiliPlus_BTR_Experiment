# DEV 原生 Surface 診斷候選

獨立分支 codex/btr-surface-probe-20261026-01／工作樹 sp-1026-01，來源 db7505cc0，承接 f33097956 的播放行為。這是診斷候選，不是已確認的 Surface 或圖形記憶體修正；沒有修改 SDK、播放器參數、CDN 策略、Range／來源驗證或 8／4／16 資源限制。

## 證據與問題

新 Wi-Fi 的既有 B5 三次快速 Seek 後，PSS 1,116,706 KiB，主要增量在 Gfx dev；關閉後降至 356,005 KiB。現有資料不能對應到具體 Surface／MediaCodec／驅動物件，也不能證明 session 內的記憶體有界或沒有洩漏。既有 B5 時窗超時與原始模式暖機失敗仍保留，不列為成功 A/B。

實際固定 SDK 的 AndroidVideoController 以 path 字串決定是否呼叫 CreateSurface，onUnload 設 vo=null／wid=0，但不清除 _current。專案 seek-capacity 會 stop 並重開相同 Media URI，故需要確認該路徑是否伴隨 Surface 連接錯誤。套件註解指出重新建立影片輸出而重用 Surface 可能造成 MediaCodec 連接失敗；這只是調查線索，尚未證實為本機故障原因。

Player 由 PlaybackTaskScope 登記釋放，AndroidVideoController 將自身 _dispose 加入 Player.release，Java manager 依 handle 移除 VideoOutput，並釋放 SurfaceTexture／Surface。靜態查核未找到明顯重複 Player 擁有者，但釋放路徑存在不等於所有 native 資源已在實機正確釋放。相同 DEV PID 的兩種有界 logcat 讀取均無可用訊息，不能據此認定沒有發生錯誤。取證在 evidence/surface-lifecycle-audit-20261026-01/。

## 最小診斷變更

- 僅 BTR_DEVICE_TEST=true，在既有 Android controller hooks 後追加唯讀 load／unload 觀察；無新 timer、無重建 Surface、無改變播放意圖或 GET 生命週期。
- 新事件 native-surface-load／unload 只保留序號與布林值，固定在既有 128 事件上限內；不匯出媒體 path、JNI 位址或任意字串。widSameAsPreviousLoad 是報告值的相等比較；JNI 參照槽可回收，不能把相同值當成相同 Java Surface 物件或有效消費者證據。未知／零值不偽造相等判斷。
- 既有 BTR DEV 原生取樣增加白名單 hwdec-current，僅接受 no／mediacodec／mediacodec-copy，其他值為 null。非 DEV 不讀取、不新增欄位，也未增加原始模式的週期性 AV 探針。它是原生回報值，不能單獨當成硬體解碼或畫面驗收。屬性參考：https://mpv.io/manual/stable/ 。
- 固定錯誤前綴新增 Surface／video-output／hardware-decode 提示；仍只讀前 256 字元並保留固定分類，不存訊息尾碼。所有原始錯誤與緩衝計數照舊。
- 固定 SDK getProperty 在 native 回傳 null 時沒有釋放名稱字串；新欄位與 hook 使用獨立 try/finally 讀取器，確保 null、query／UTF-8／release 例外下仍釋放名稱，native 結果由 mpv_free 釋放。不修改共享 SDK，也不宣稱這個小型配置缺口解釋 Gfx dev 的數百 MiB 增量。

## 驗證與限制

隔離 Dart harness 的相關 37 項 PASS，含新增 handle 觀察／未知值／隱私、原生字串匹配釋放與例外路徑、既有診斷計數、容量 Seek／stop 失敗／新意圖／來源取代／關閉競態回歸。之後只修正 test 的 cascade 樣式，受影響三項再測 PASS，其餘條件未變不重跑。11 修改 Dart 檔靜態分析無錯誤，唯一樣式提示修正後該檔 No issues found。

完整 Flutter/native suite 在收集前仍因既有 cnativeapi 缺 Windows MSVC 失敗，不列為 PASS，未安裝或變更全域工具鏈。隔離 harness 一般沙箱曾因 OS 暫存 kernel 複製拒絕而失敗；使用正式 require_escalated 審查後同 harness 通過，沒有變更 TEMP/TMP。SDK／lock／patches 與既有候選雜湊核對一致，僅重用專案 cache，未新增依賴。

本文件建立時 Android APK 尚未建置或安裝，沒有本候選的實機結果。後續驗證必須在同一個有界執行流程內完成開片至關閉，確認 DEV／BV／播放中與足夠緩衝後才送 Seek；任一前置失敗或超過既定 PSS 門檻就關閉，不用播放切換誤觸重開。僅靠本診斷仍不能證實或修正圖形記憶體根因，不提升穩定版本。

程式變更：controller.dart、playback.dart、metrics.dart、diagnostics.dart、native_failure_hint.dart，新增 surface_probe.dart、native_property.dart、native_property_string.dart；測試為 surface_probe_test.dart、native_property_string_test.dart 及 native_failure_hint_test.dart。證據在 evidence/surface-probe-20261026-01/。
