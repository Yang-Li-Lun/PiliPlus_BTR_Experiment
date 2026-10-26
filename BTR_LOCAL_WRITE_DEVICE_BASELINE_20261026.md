# 2026-10-26 實機正常播放：本機寫入期限反證

基準實作 `407303f1e876b3b964cfd9c5b9639a407c9a072d`，Build ID `source-diag-20261026-02`。資料在專案 `evidence/source-diag-20261026-02/`，不要與其他候選的同名樣本混用。

裝置為唯一指定 POCO M2012K11AG／4138ece6，DEV 套件；指定影片 BV1kUpsedE4R，介面再次確認 4K 超高清／HEVC／1.0X。沒有修改原有 128 MB／60 秒播放器設定或 CDN「备用URL」偏好；BTR 仍 combined／自動線程／自動優選，8 回應／4 執行槽／16 上游。開片由使用者手動完成，後續每條 ADB 命令獨立依序執行，沒有重試未解除的開片拒絕。

## 已確認正常起播再做對照

A4-before-reload 有實際播放進展，startupTimelineMs=2582、零 playerErrors／額外緩衝。原始模式 A4 重載至 279,859 ms，約 13.1 秒後暫停，startupTimelineMs=4074，零 playerErrors／額外緩衝，有兩張不同實際畫面。兩筆未分類 ffmpeg 訊息保留，沒有將其自動歸為 HTTP 或解碼故障。

A3 灰畫面的手動暫停 session 從未確認進展，不能納入失敗起播或速度比較。此結論與先前 A2 已有六個 playerErrors 的失敗樣本不同，不能相互替換。

## C1 三次快速 Seek

三次手勢起點間隔約 1.166／1.228 秒，目標為 809,872／3,099,524／1,912,297 ms。最終恢復時間軸 2,151 ms，零 playerErrors／容量 503／retirement rejection，seekPending=false。額外緩衝計數為 1，沒有調整或過濾。

新增事件直接顯示：第一個 Seek 在 12,385 ms，恢復時間軸先記錄 10 ms，12,395 ms 的 buffering-transition 已是 seekPending=false；該目標的新視訊 GET 到 12,660 ms 才開始。這個 10 ms 不能當作新目標媒體資料或第一幀已恢復的證據，也不能把中間被取代目標算成獨立成功樣本。控制器自身是否同時提早清除 pending 尚缺直接探針，不以 metrics 欄位替代證明。

最高執行槽／上游為 4／14。末端單一音軌選中、48 kHz／兩聲道、未靜音，取樣 AV sync 0.000878 秒，取樣掉幀為零；不是每次 Seek 可聽延遲或全程同步證明。事件丟棄 18 筆、lifecycle 丟棄 4 筆，相關已保留時序可查，但不能宣稱完整保留所有 GET 歷史。

## C2 不含 Seek 的正常播放

C2 從 1,918,820 ms 重載，沒有發出 Seek 或中途 pause，約 44.4 秒後正常返回關閉。startupTimelineMs=2563，playerOpenCount=1、額外緩衝=0、容量／retirement rejection=0、requestFailures=0、terminalFailures=0，但出現 **一次 network player-error**。

| 時間 ms | 事件 |
| --- | --- |
| 740 | 最新視訊 GET 2，start=3,144,968,123 |
| 10,821 | GET 2 writer parked，原生已有緩衝仍持續播放 |
| 25,722 | GET 2 proxy-write timeout；明確套用 response deadline=0，130,809,856 bytes 已記錄交付；回應由 1 釋放為 0 |
| 29,323 | ffmpeg 未分類 error |
| 29,328 | network player-error，無 Seek、非 terminal |
| 29,330 | 同 generation 0 的新視訊 GET 3，start=3,276,751,925 |
| 43,540 | 正常關閉，GET 3 以 session-closed 結束 |

拒絕、執行槽等待與上游失敗不是此輪觸發機制；這裡是本機既有 15 秒 flush 期限主動終止仍由同一 native load 使用的最新 response。29,002 ms 的原生取樣 time-pos=1945.313、audio-pts=1945.285135、core-idle=false／eof=false，支持錯誤前仍持續播放。接著原生另開 Range，最終位置 1959.527；畫面仍前進不等於零錯誤驗收。

這個時序足以支持針對本機寫入期限的候選與 A/B 驗證，但沒有原始錯誤文字，仍不把未分類 ffmpeg 訊息斷言成某個特定 HTTP／TLS／解碼錯誤。也不以 flush bytes 當成原生已消費 bytes，或猜測 metadata GET 的消費者已失效。

## 記憶體、資源與驗證限制

C2 在 10／25／40 秒 PSS 為 738,081／721,130／745,606 KiB，未達既定 1 GiB 停測門檻。關閉後 PSS 477,244、Graphics 118,640 KiB，native allocated 79,861、free 201,442 KiB。不是全程序峰值或無洩漏證明。

最後匯出 current=null，C1／C2 已結束，代理、上游、兩軌 demand／有序保留均歸零。C2 事件未丟棄。所有新增原始 JSON 的遠端／本機 SHA-256 相符，列於 report-files.jsonl。C2-normal-closed.json SHA-256：`79e7c50f409462e2ba4183fa0a6ece1083e617d05344d641a9ea2c46b45e5233`。

官方文件與本工作階段有效權限已核對：sandbox=danger-full-access、approval_policy=never，無互動升級請求通道。先前工具只回 blocked by policy，細因仍未知；沒有修改核准設定或換指令繞過。影片已手動開啟後即繼續測試，沒有把核准限制當成停止其他可執行工作的理由。
