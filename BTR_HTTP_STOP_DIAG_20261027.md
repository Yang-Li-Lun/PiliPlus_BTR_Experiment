# HTTP 停止階段診斷

延續 f39804c91 的證據：一則 vo error 已識別為 AImageReader -30001，兩則 FFmpeg error 仍未知，且發生於 native unload、早於代理回應退休。查核 transport.dart 已有 response.done 的錯誤取消監聽；沒有以新 GET、Seek generation 或寫入背壓推定舊消費者失效，也未改動取消規則。

本候選只擴充 native_failure_hint.dart 的 HTTP 固定階段，以及 metrics.dart 的三個固定 libav namespace 列舉，測試位於 native_failure_hint_test.dart。HTTP 來源為實際套件對應 [FFmpeg n9.0.1 libavformat/http.c](https://github.com/FFmpeg/FFmpeg/blob/n9.0.1/libavformat/http.c)，元件來源為 [mpv v0.41.0 common/av_log.c](https://github.com/mpv-player/mpv/blob/v0.41.0/common/av_log.c)。11 個靜態訊息前綴／組成字串已在已安裝 APK 的 libmpv.so 核對。

診斷區分讀取中斷、提前結束、offset／chunk／method／version 等 HTTP 階段，不推定具體 HTTP 狀態、不保存 offset、任意元件、完整 URL 或訊息後綴。固定元件僅 ffmpeg/audio、video、demuxer，輸出列舉名稱；不輸出 codec 名稱。保留原生 error 與 playerErrors 計數，不將取消相關文字視為已確認無害或自動抑制。

沒有修改播放器、CDN、Range、身分與完整性驗證、回應取消或 8／4／16 限制。17 項相關離線測試 PASS，三個修改 Dart 檔靜態分析通過；最後僅將等價 null 條件改為 null-aware map 元素並復查該檔。未重跑未受影響的完整測試。實機結果尚未取得，整體驗收未達成。
