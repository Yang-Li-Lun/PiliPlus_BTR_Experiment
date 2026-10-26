# 原生訊息格式與 ImageReader 診斷

本候選僅修改 native_failure_hint.dart 與其測試，不調整播放器、Surface、解碼器、GET 取消／容量、CDN、Range 或完整性驗證。前版原生錯誤未分類，不足以支持播放行為修正。

## 已確認的靜態證據

實際 APK 的 libmpv.so 與 repository cache 的 default-arm64-v8a.jar 原生庫逐位元組相同。JAR SHA-256 98df6410375cc7a4be7e6eff56f9ccd88fa52678973cc23bcf7e934ab8c8682d 與 build.gradle 及 GitHub 20260906 release 相同。原生庫回報字串 mpv v0.41.0-dirty；該 release 建置定義選用 mpv 0.41.0／FFmpeg 9.0.1，包含 Java VM 本機 patch，不能當作未修改的原版。

mpv [common/av_log.c](https://github.com/mpv-player/mpv/blob/v0.41.0/common/av_log.c) 在 FFmpeg 訊息前加 AVClass item name 與冒號；Dart SDK 只 trim()，既有分類器只匹配訊息開頭。因此有已確認的格式涵蓋缺口，但未證明前幾輪三則未知訊息均屬於這個機制。

本候選只移除一層固定元件白名單（http／https／tcp／tls 與已列出的 MediaCodec／AVIO／AVHWDevice context），不接受任意標籤、不重複剝除、不保存元件名稱或原文後綴。仍先限制最多 256 字元，再進行比對。

mpv [hwdec_aimagereader.c](https://github.com/mpv-player/mpv/blob/v0.41.0/video/out/hwdec/hwdec_aimagereader.c) 的 map 路徑包含 100 ms 影格等待，再呼叫 acquireLatestImage；失敗時記錄 media_status_t，是否回傳失敗取決於 image_available。與本案第一次 Seek 後約 107 ms 的 vo 紀錄時間相符，但這只是待驗證線索。

新增四個 ImageReader 固定階段及最多六位數的 reportedMediaStatus，只保留原生報告的整數，不解讀為 HTTP、errno 或已確認根因。五個相關固定格式字串已在實際 APK 找到。來源與雜湊證據在 evidence/native-message-frame-20261027-01/。

## 驗證狀態

分類／隱私、計數界限、FFI 釋放與 Surface 探針 15 項離線測試 PASS，兩個修改 Dart 檔靜態分析無問題。播放行為未變，不重跑未受影響的完整測試。

## 實機結果

程式提交 f39804c91108dc02c8976bcddebe8b1f3e998a98，Build ID native-message-frame-20261027-01。ARM64 DEV 建置 89.6 秒成功，APK SHA-256 38ee72a83f62a710f75be2e4aa942387762ddf479c815c736a45cbdeb1850e1c。DEV 包名、原簽章、權限、AOT Build ID 已核對，libmpv／libflutter 與前版相同；install -r 成功，手機 base.apk 雜湊相同，未清除資料。

唯一確認 POCO M2012K11AG／4138ece6，僅 DEV 套件。F1 在同一次有界操作中開片、關閉實際出現的更新提示、重新確認指定 BV／播放中／緩衝 50.3 秒、三次快速 Seek、取樣及正常返回關閉。三次實際目標 809872／3099524／1912297 ms，間隔約 1.39 秒；session 33.078 秒，開片至關閉壁鐘 38.351 秒。沒有跨模型回合持續播放、長測或額外壓力測試。

最後 Seek 時間軸恢復指標 1782 ms，seekPending=false。playerErrors／額外緩衝／容量 503／requestFailures／terminalFailures 均零。一次 seek-capacity 重開後八筆 GET 有 released／player-stopped 紀錄，原生 unload 24545 ms，回應釋放 24661–24662 ms。consumerValidity 仍 unobservable，不能把 HTTP 本身當成消費者已失效的直接證明。關閉後代理與上游及每軌保留歸零；8／4／16 限制不變，實測執行槽峰值 4、上游峰值 12。一般事件未丟棄，lifecycle 丟棄八筆，不能宣稱完整 GET 歷史。

關鍵新證據：第一次 Seek 21461 ms，vo 紀錄 21569 ms（相隔 108 ms），failureHint=android-image-acquire、reportedMediaStatus=-30001。實際本機 NDK 28.2.13676358 的 NdkMediaError.h 定義 -30001 為 AMEDIA_IMGREADER_NO_BUFFER_AVAILABLE；已取得影格達上限是不同的 -30002。官方 [AImageReader 文件](https://developer.android.com/ndk/reference/group/media#aimagereader_acquirelatestimage) 說明前者是 reader queue 當下沒有可用影格。這定位了本輪 vo 紀錄的失敗階段與狀態，不是 frame pool 達上限或 Surface 建立失敗的證據。

仍未直接觀察 mapper 的 image_available 分支，因此不能確認其傳回成功／失敗，也不能把「等待 100 ms」及狀態相符直接提升為造成全部 Seek 延遲的確定根因。未改 mpv、未抑制 error、未更改原生錯誤計數。兩則 ffmpeg 紀錄仍為 unclassified，均在 unload 同一毫秒 24545 ms；只能保留時間關聯，不能宣稱無害、確定由取消造成或已修復。

PSS 511248→998228 KiB，Graphics 193224→605744 KiB，未達 1048576 KiB 停止門檻。關閉後 PSS 467277／Graphics 156908 KiB。末端截圖有指定影片畫面，回報硬解種類仍為 mediacodec。這些不是記憶體長期有界、每次第一幀或完整聲畫同步驗收。

本次兩軌實際均 ALI-OV，影音表示 6507038367／45633327 bytes、single-origin-strong-etag，未調整 CDN 偏好或驗證限制。原始報告手機與本機 SHA-256 相同：654a65bcd7d0c0342e2ead51277afc06bf4606f6ee4735170516bd20ed16f47b。不能回填前版未知事件；相較前版單次時間差不是效能改善證明。

手機目前安裝本診斷版，combined／自動線程／preferredCdn=null，影片已關閉。整體驗收未達成：兩則 FFmpeg 內容、高圖形記憶體 session 內界限、BTR 相對健康原始模式的 Seek 延遲、第一幀及完整聲畫同步仍未解決。保留所有候選、APK 與穩定基準，不提升為正式穩定版。
