# 2026-10-26 記憶體與續播驗證：續播門檻未通過

實作來源仍為 `4a806ca3b9dd63dac1508d8aa6f7b25dace1a576`。本次未修改或重新安裝 APK；所有目標操作均為唯一確認的 POCO M2012K11AG／4138ece6 與 DEV 套件。較早的 ADB offline 期間沒有執行手機輸入，恢復身分確認後才接手。

## 交接時的高記憶體觀察

證據：`evidence/paused-memory-20261026-01/`。交接程序 31686 已包含人工使用歷史；匯出的 session 已存在約 1,004 秒、包含六次既有 Seek 與一次額外緩衝。這不是自動長時間播放或受控 Seek 驗收。該 session 的 video totalBytes=12,409,224,508，與先前 4K HEVC 的 6,507,038,367 不同；未取得當時實際 codec 標籤，不憑資料大小稱它是 AVC。

交接 PSS=1,369,538 KiB；稍後暫停取證 PSS=1,330,920 KiB，其中 Graphics=742,360 KiB、Native Heap allocated=479,395 KiB。當時代理回應、上游連線及兩軌有序保留已為零，網路／loopback 近五秒流量均為零。這些資料不支持將高占用直接歸因於當時仍在下載或未釋放的代理 demand。

正常關閉影片後，10 秒取樣 PSS=939,070 KiB，Graphics=354,376 KiB，Native Heap allocated=84,955 KiB、free=419,272 KiB。已配置量明顯下降，PSS 仍保留較多空間；與圖形／配置器保留相容，但尚不能認定具體保留者或宣稱不存在其他洩漏。

原定的 `sample.ps1` 冷重載流程沒有執行，因初始占用已超過其 1 GiB 保守警戒。改為當前暫停狀態取證與正常關閉，沒有把警戒放寬以取得通過結果。關閉後診斷 current=null，已結束 BTR session 的 transport 資源均歸零。

## 新程序對照

為排除舊程序使用歷史，先保存所有上述資料，再只結束已無播放 session 的 DEV 程序，沒有清除使用者資料或重啟共用 ADB server。使用者手動重開指定影片；新 PID 為 19739。已在設定頁確認 4K 超高清／HEVC／192K，速度 1.0X。只切換同一 APK 的原始／BTR 模式，其餘設定保留。

新證據：`evidence/paired-memory-20261026-01/`。每階段連續自動重載、播放、暫停後取樣 0／10／20／30 秒，記錄同一 PID 的 PSS、RSS、Native Heap allocated/free 與 Graphics。警戒仍為 PSS 1 GiB 或觀察窗成長 256 MiB；三階段均未觸發。

| 階段 | 播放時間 | 暫停窗開始 PSS KiB | 30 秒 PSS KiB | 30 秒 Native allocated KiB |
| --- | --- | --- | --- | --- |
| A1 原始 | 約 10 秒 | 671,573 | 628,757 | 265,078 |
| B1 BTR | 約 10 秒 | 635,739 | 626,718 | 265,710 |
| B2 BTR | 約 26 秒 | 635,430 | 627,834 | 266,633 |

三階段沒有持續成長，均無 playerErrors 或額外緩衝。BTR 兩個暫停觀察窗的 loopbackDeliveredBytes 均沒有增加；B1 為 197,197,824 bytes，B2 為 192,086,016 bytes。B1 回應由一筆降為零、B2 起訖均為零，末端有序保留歸零；影片位置在各暫停窗固定。這些短測沒有重現先前持續讀取，不能推論那個條件已修好或與高記憶體完全無關。原始模式的 transport／native-origin 欄位未量測，不填成零。

## 續播：實際失敗證據

在 B2 暫停後，另外執行約 10 秒續播並再次暫停。由於中間分析等待，這是幾分鐘暫停後的續播，不是精確暫停 30 秒便續播；30 秒取樣結束到錯誤事件約相隔 167 秒。

`B2-resumed.json` 顯示：playerErrors=1、分類 network，額外緩衝=0、容量 503=0、terminalFailures=0、requestFailures=0。time-pos 由 305.867 前進到 317.696 秒，audio-pts 也前進，AV sync 取樣約 0.8 ms；截圖有播放畫面。這表示續播有進展，但**不能將此項驗收判為通過**。

直接事件順序：

- video request 2 自 byte 388,135,198 開始，於 28,536 ms 因 proxy-write timeout 結束，完整 flush 的 deliveredBytes=184,090,624；audio request 2 亦已於 26,616 ms 因相同階段逾時結束。
- 241,575 ms 出現 ffmpeg unclassified，241,577 ms 出現 network player-error。
- 241,580 ms 原生播放器建立 video request 3，自 byte 572,502,286 重讀，沒有新的 Seek 事件或 Dart player-open；之後畫面仍前進。

既有程式在這類未完成回應套用 deadline=zero 結束 socket，因此新證據指向「已逾時截斷的 HTTP 回應在續播時被再次消費」；未保留原生錯誤文字，沒有直接的 native-response ID 關聯，不能把每一筆未分類訊息都歸因於此。

唯讀設定頁另確認既有 bufferSize=128 MB、bufferSec=60 秒。`Pref.initBuffer(1.0)` 會產生 cache-secs=60、demuxer-hysteresis-secs=40。mpv 官方文件說明，滯後門檻是緩衝剩餘降到門檻才再次讀取，可能形成較長的合法讀取間隔；這支持檢查 15 秒寫入逾時與緩衝策略是否衝突，但未讀取 mpv 的實際 option 值，因此不是普通播放根因已完全確認。來源：[mpv 官方穩定版手冊](https://mpv.io/manual/stable/)。未修改手機緩衝設定。

## 保存與後續修正範圍

4a806ca3b 仍保留為快速 Seek 已驗證候選，不提升穩定版。新發現的續播錯誤不表示它由該 Seek 修正引入：B2 重載後沒有 Seek，該修正分支未在此 session 執行。

後續功能修改應在新隔離候選處理「最新實際媒體 GET 已異常截斷」的續播條件；不得把較舊 metadata GET 的失敗視為目前仍有有效消費者的 GET 已失效，不得為消除錯誤訊息而過濾記錄。維持 8 回應／4 執行槽／16 上游、15 秒寫入逾時與來源／Range 驗證；如需回收，必須先等待原生 stop 完成。新候選的離線與實機驗收尚未執行。
