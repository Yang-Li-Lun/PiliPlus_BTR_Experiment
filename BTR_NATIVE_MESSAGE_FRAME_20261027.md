# 原生訊息格式與 ImageReader 診斷

本候選僅修改 native_failure_hint.dart 與其測試，不調整播放器、Surface、解碼器、GET 取消／容量、CDN、Range 或完整性驗證。前版原生錯誤未分類，不足以支持播放行為修正。

## 已確認的靜態證據

實際 APK 的 libmpv.so 與 repository cache 的 default-arm64-v8a.jar 原生庫逐位元組相同。JAR SHA-256 98df6410375cc7a4be7e6eff56f9ccd88fa52678973cc23bcf7e934ab8c8682d 與 build.gradle 及 GitHub 20260906 release 相同。原生庫回報字串 mpv v0.41.0-dirty；該 release 建置定義選用 mpv 0.41.0／FFmpeg 9.0.1，包含 Java VM 本機 patch，不能當作未修改的原版。

mpv [common/av_log.c](https://github.com/mpv-player/mpv/blob/v0.41.0/common/av_log.c) 在 FFmpeg 訊息前加 AVClass item name 與冒號；Dart SDK 只 trim()，既有分類器只匹配訊息開頭。因此有已確認的格式涵蓋缺口，但未證明前幾輪三則未知訊息均屬於這個機制。

本候選只移除一層固定元件白名單（http／https／tcp／tls 與已列出的 MediaCodec／AVIO／AVHWDevice context），不接受任意標籤、不重複剝除、不保存元件名稱或原文後綴。仍先限制最多 256 字元，再進行比對。

mpv [hwdec_aimagereader.c](https://github.com/mpv-player/mpv/blob/v0.41.0/video/out/hwdec/hwdec_aimagereader.c) 的 map 路徑包含 100 ms 影格等待，再呼叫 acquireLatestImage；失敗時記錄 media_status_t，是否回傳失敗取決於 image_available。與本案第一次 Seek 後約 107 ms 的 vo 紀錄時間相符，但這只是待驗證線索。

新增四個 ImageReader 固定階段及最多六位數的 reportedMediaStatus，只保留原生報告的整數，不解讀為 HTTP、errno 或已確認根因。五個相關固定格式字串已在實際 APK 找到。來源與雜湊證據在 evidence/native-message-frame-20261027-01/。

## 驗證狀態

分類／隱私、計數界限、FFI 釋放與 Surface 探針 15 項離線測試 PASS，兩個修改 Dart 檔靜態分析無問題。播放行為未變，不重跑未受影響的完整測試。尚未進行本候選實機測試，不能回填前版未知事件，整體驗收未達成。
