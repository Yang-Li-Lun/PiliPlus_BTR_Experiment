# 4K 快速 Seek 回應容量修正：2026-10-26 實機短測

## 結果與適用範圍

`4a806ca3b9dd63dac1508d8aa6f7b25dace1a576` 已通過本影片的兩輪三次快速 Seek、一輪六次快速 Seek、一般間隔 Seek 與約 26 秒正常播放短測。這五輪均無本機容量 503、playerErrors、額外緩衝、terminalFailures 或未完成 Seek。這證明本次重現條件下的容量問題已有改善；不代表完整播放穩定性、所有原生錯誤與實際 CDN 切換均已驗收。

建議保留此版本作為 DEV 候選，不提升穩定基準 `788faa8abee2ff325205d89a9fa24869821685e3`。未推送、建立 PR 或發布。

## 版本、裝置與方法

- 工作樹 `.btr-wt/cr-1023-01`；分支 `codex/btr-seek-capacity-20261023-01`。本報告之後的文件提交不改變 APK 來源。
- 唯一指定 POCO M2012K11AG，序號 `4138ece6`。所有目標操作均指定該序號；已連線的 SM-T720 未操作。
- 僅操作 `com.example.piliplus.btr.experiment.dev`，未清除使用者資料或修改系統安全設定。使用者手動開片後才接手，未重試先前被工具拒絕的開片指令或使用替代開片方式。
- BV1kUpsedE4R，4K 超高清、HEVC、192K 音訊、1.0X。`final-20261026-quality-menu.png` 同時顯示上述設定。
- 修正前對照為診斷候選 `f357ef889` 的 `cold04.json`，不是穩定基準 788faa8，也不是純原始模式。影音大小分別 6,507,038,367／45,633,327 bytes；新舊均為 ALI-OV host、single-origin-strong-etag。
- 起點 279,859 ms，三次目標依序 809,872／3,099,524／1,912,297 ms。拖動 500 ms、手勢間等待 300 ms；實際 Seek 間隔約 1.07–1.18 秒。每輪重新載入同一已開啟影片，預熱 10 秒。六次組重複同三個目標兩次。
- 新舊資料分別在 10 月 23 日及 26 日取得；沒有清除 cache、強制相同網路狀態或進行同日隨機交替。因此速度差是歷史同流程比較，不能獨立歸因於程式修改或推論其他網路的速度。

## 實機量測

| 組別 | Seek 恢復時間軸 ms | 容量 503 | playerErrors | 額外緩衝 | 最高執行槽／上游連線 |
| --- | --- | --- | --- | --- | --- |
| 修正前 cold04：三次快速 | 31、4,836 | 2 | 2 | 1 | 4／9 |
| B1：三次快速 | 1,500 | 0 | 0 | 0 | 4／12 |
| B2：三次快速 | 1,678 | 0 | 0 | 0 | 4／9 |
| B3：一般間隔三次 | 2,047、1,746、862 | 0 | 0 | 0 | 4／10 |
| B4：六次快速 | 1,489 | 0 | 0 | 0 | 4／10 |
| B5：約 26 秒正常播放 | 不適用 | 0 | 0 | 0 | 4／8 |

快速組只將最後目標恢復時間作比較；被後續目標取代的 Seek 不是遺漏樣本的零毫秒恢復。B1／B2 最後恢復中位數 1,589 ms，相對歷史 4,836 ms 低約 67.1%。一般組沒有本次同條件修正前對照，只能判斷其功能短測通過，不能宣稱一般 Seek 速度提升。

## 拒絕機制與回收證據

修正前拒絕快照直接顯示 response-limit、openResponses=8、activeHandlers=3、parkedWriters=5、pendingAdmissions=0、admissionWaitMs=0。這次拒絕為回應容量用盡，並非 4 執行槽等待逾時。快照不能判斷原生消費者是否已失效；本修正沒有用 generation、暫停或寫入停滯推論失效並取消 GET。

修正只在即將沒有足夠回應名額容納影音新 GET 時，透過既有序列化 Seek 路徑等待 `player.stop()` 完成，再 `retirePlayerRequests()`，重新開啟最新意圖位置。限制仍為 8 回應／4 執行槽／16 上游資源，Range、來源身分、重試及完整性規則未變。

B1／B2 均實際到達八回應；第三次 Seek 觸發 seek-capacity。B1 舊八回應於 14,970–14,971 ms 以 player-stopped 釋放至零，隨後重開。B2 也保留八筆 player-stopped 釋放。程式碼的 await 順序及離線 gate 測試證明停止完成前不回收；實機 ledger 與該順序一致，但未新增獨立的原生 stop-complete 探針。

B4 六個目標均命中，兩次 seek-capacity 重開完成，無 retirement rejection、容量拒絕或播放器錯誤。一般事件 B4 丟棄 1 筆，其餘五輪測試／補充快照未丟棄；生命週期 ledger 為有界 64 筆，B1／B2 各丟棄 5 筆、B4 丟棄 53 筆，因此不能宣稱保留了壓力組所有 GET 的完整歷史。拒絕快照沒有丟棄。

## 影音、資源與剩餘問題

五輪末端均選中單一音軌、48 kHz／2 聲道、opensles、gpu、未靜音；原生探針沒有 cache pause，取樣 AV sync 絕對值均小於 2 ms，取樣掉幀計數為零。截圖有實際畫面，正常播放前後畫面不同。這些只證明取樣狀態與短時播放，未量測可聽聲音、Seek 第一幀或全程音畫同步。

未分類原生錯誤仍存在：修正前 ffmpeg 9／vo 1；B1 ffmpeg 4、B2 ffmpeg 4、B3 ffmpeg 2／vo 1、B4 ffmpeg 6、B5 ffmpeg 2。它們不是 playerErrors，沒有以 playerErrors=0 隱藏；DEV PID 的唯讀 logcat 沒有保留匹配的原始訊息，根因仍 UNRESOLVED。

各組仍有 1–3 筆 proxyLocalResponseFailures；部分是暫停後既有回應逾時，不能宣稱消除了所有本機失敗。B1／B2／B4 匯出時資源已歸零；B3 與 B5 暫停匯出時仍有回應。B5 114,316 ms 的補充快照顯示一筆 generation 0 GET 持續進展，交付 878,575,616 bytes，仍有 4 MiB 有序保留與四條上游連線；播放位置維持 305.133 秒。這是暫停後持續讀取的直接證據，尚不能確定其原生目的或將其判為洩漏／失效消費者，因此未取消該 GET。補充快照不算第六輪獨立測試。

取證後透過正常返回結束影片頁，最後停在 DEV 搜尋結果（`final-20261026-playback-closed.png`）。沒有使用 force-stop 或清除資料。沒有在關閉後取得 transport 完整釋放快照，因此不宣稱已由實機證明關閉後所有資源歸零。

CDN 403 備援、來源驗證、Range 與資料逐位元組一致性已有離線回歸覆蓋；本次真實 CDN 沒有觸發來源切換，不能當作真實 CDN 故障切換驗收。原始模式的歷史黑畫面也未在本輪診斷或解決。

## 離線驗證與交付

既有且條件未變的離線結果沿用：完整 BTR suite 144／144 PASS、控制器 45 個子情境 PASS、修改三檔靜態分析 No issues found。已核對其涵蓋有效 GET 在 stop 完成前保持、八回應容量回收、最新 Seek／pause／來源變更／close 競態、stop 失敗不得回收，以及雙軌資料一致性。未重跑未受影響的測試。

APK：`build/btr-candidates/seek-capacity-20261023-01/PiliPlus-BTR-SeekCapacity-20261023-01-dev-arm64-v8a.apk`（相對本工作樹）。Build ID `seek-capacity-20261023-01`，SHA-256 `8991facdf7778859fba9142c9ea5196768c132818e440875040d59b238b69260`。本輪已再次讀取手機 DEV base.apk，雜湊相符。

證據在專案 `evidence/seek-capacity-device-20261023-01/`：B1–B5 原始 JSON／操作時間／截圖、`report-files.jsonl` 遠端與本機雜湊、`verified-device-20261026.json`、可重跑的唯讀 `analyze-device.ps1`。只統計各份 current，不加總 recent，不將 B5 補充快照當獨立樣本。

完整目標尚未全部通過：可聽音訊及全程同步、真實 CDN 故障切換、未分類原生錯誤、暫停後持續消費與關閉後完整資源釋放仍缺乏充分實機證據。不得將此短測報告當作正式穩定版驗收。
